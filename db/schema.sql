-- Tabla de deduplicación persistente.
-- Registra los links de artículos ya procesados para evitar
-- que reaparezcan en briefings posteriores.
CREATE TABLE IF NOT EXISTS seen_articles (
  id SERIAL PRIMARY KEY,
  link TEXT UNIQUE NOT NULL,
  source_name TEXT,
  category TEXT,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Requiere la extensión pgvector (imagen pgvector/pgvector:pg16 en docker-compose.yml)
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS normalized_articles (
    id SERIAL PRIMARY KEY,
    link TEXT UNIQUE NOT NULL,
    title TEXT NOT NULL,
    content TEXT,
    category TEXT,
    source_name TEXT,
    published_date TIMESTAMPTZ,
    language TEXT,
    embedding VECTOR(1024) NOT NULL,
    processed_at TIMESTAMPTZ DEFAULT now()
);

-- Registro append-only del análisis LLM por cluster (fase 05).
-- No hay UNIQUE sobre cluster_id: 04-clustering no persiste identidad de evento
-- entre ejecuciones, así que cluster_id no es estable de una corrida a otra.
-- status='error' guarda intentos fallidos (fallo de red/timeout con Ollama o
-- respuesta no parseable) para que un cluster problemático no tumbe el resto
-- del batch ni se pierda sin dejar rastro.
-- status='superseded' es un análisis correcto que otro posterior, con más
-- fuentes sobre el mismo suceso, ha dejado obsoleto (ver más abajo).
CREATE TABLE IF NOT EXISTS cluster_analysis (
    id SERIAL PRIMARY KEY,
    cluster_id INTEGER NOT NULL,
    source_count INTEGER,
    sources JSONB,
    articles JSONB,
    analysis JSONB,
    status TEXT NOT NULL DEFAULT 'ok',
    error_message TEXT,
    analyzed_at TIMESTAMPTZ DEFAULT now(),
    -- Enriquecimiento de la fase 07: la categoría del RSS no sirve aquí (el 85%
    -- de los artículos llegan como 'portada', y además es por artículo cuando el
    -- cluster es un único suceso). 07 la asigna con un LLM sobre el cluster entero.
    -- NULL = pendiente de categorizar: la ausencia de valor ES la cola de trabajo,
    -- no hace falta columna de estado propia.
    categoria TEXT,
    categorized_at TIMESTAMPTZ,
    -- Retirada de análisis obsoletos. 05 reanaliza un evento entero cuando se le
    -- suma una fuente nueva (deliberado: 4 fuentes comparan mejor que 2), lo que
    -- deja dos filas del mismo suceso. Al insertar la nueva, 05 marca la vieja
    -- como status='superseded' y apunta aquí a la que la reemplaza.
    -- No es deduplicación de entrada — eso es la fase 03, sobre artículos y por
    -- link, y funciona: los links de ambas filas están una sola vez en
    -- seen_articles. Aquí lo que sobra es una *salida* que ha quedado obsoleta.
    -- Como todo consumidor (07, 08) ya filtra status='ok', lo heredan gratis.
    superseded_by INTEGER REFERENCES cluster_analysis(id)
);

-- Para instalaciones que ya tenían cluster_analysis creada antes de las fases 07/08.
ALTER TABLE cluster_analysis ADD COLUMN IF NOT EXISTS categoria TEXT;
ALTER TABLE cluster_analysis ADD COLUMN IF NOT EXISTS categorized_at TIMESTAMPTZ;
ALTER TABLE cluster_analysis ADD COLUMN IF NOT EXISTS superseded_by INTEGER REFERENCES cluster_analysis(id);

-- Registro append-only del filtro de calidad de piezas de fuente única (fase 06).
-- A diferencia de cluster_analysis, aquí "link" SÍ es una clave estable (viene
-- directo de normalized_articles, no de una agrupación efímera de 04), así que
-- se usa como clave de "ya procesado" para no reevaluar el mismo artículo en
-- ejecuciones sucesivas. status='error' son intentos fallidos, reintentables;
-- status='ok' con incluir=false es una exclusión ya decidida, no se reintenta.
CREATE TABLE IF NOT EXISTS secondary_briefing_items (
    id SERIAL PRIMARY KEY,
    link TEXT NOT NULL,
    title TEXT,
    source_name TEXT,
    categoria TEXT,
    incluir BOOLEAN NOT NULL,
    resumen_hechos TEXT,
    status TEXT NOT NULL DEFAULT 'ok',
    error_message TEXT,
    processed_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_secondary_briefing_items_link ON secondary_briefing_items(link);

-- Briefing diario ya ensamblado (fase 08).
-- Se guarda el documento renderizado Y la selección estructurada que lo originó:
-- con solo el HTML, cambiar el maquetado obligaría a reanalizar; con el payload
-- se puede re-renderizar a cualquier formato (o a otro canal en la fase 09) años
-- después sin gastar un token.
-- briefing_date es UNIQUE a propósito: regenerar el briefing de un mismo día
-- reemplaza el anterior en vez de duplicarlo, así que 08 es idempotente y se
-- puede reejecutar sin ensuciar el historial.
CREATE TABLE IF NOT EXISTS briefings (
    id SERIAL PRIMARY KEY,
    briefing_date DATE NOT NULL UNIQUE,
    cluster_count INTEGER NOT NULL,
    divergence_count INTEGER NOT NULL,
    payload JSONB NOT NULL,
    content_html TEXT NOT NULL,
    generated_at TIMESTAMPTZ DEFAULT now()
);

-- Configuración de despliegue que no es un secreto pero tampoco puede vivir en
-- el JSON de un workflow versionado en un repositorio público (fase 09).
--
-- El camino natural sería una variable de entorno, pero n8n 2.x deniega $env en
-- las expresiones salvo que se arranque con N8N_BLOCK_ENV_ACCESS_IN_NODE=false,
-- y ese permiso es global: cualquier expresión de cualquier workflow pasaría a
-- poder leer TODAS las variables del contenedor, incluida POSTGRES_PASSWORD.
-- Las Variables nativas de n8n, que resolverían esto, son de licencia de pago.
-- Postgres ya es el contrato entre fases, así que el valor se lee de aquí: 09 lo
-- recoge con una subconsulta dentro del SELECT que ya hace sobre briefings, sin
-- añadir ningún nodo.
--
-- Se rellena a mano en la instalación (ver README), igual que este mismo fichero.
CREATE TABLE IF NOT EXISTS app_config (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- Índices de las columnas por las que filtran las consultas del pipeline.
-- Hoy las tablas son pequeñas y Postgres resuelve con recorrido secuencial, pero
-- normalized_articles crece ~700 filas/día y 04 la consulta por processed_at en
-- cada corrida; cluster_analysis la filtran 05 (tope diario), 07 (cola) y 08
-- (selección del día).
CREATE INDEX IF NOT EXISTS idx_normalized_articles_processed_at
    ON normalized_articles(processed_at);
CREATE INDEX IF NOT EXISTS idx_cluster_analysis_analyzed_at
    ON cluster_analysis(analyzed_at);
CREATE INDEX IF NOT EXISTS idx_cluster_analysis_status_categoria
    ON cluster_analysis(status, categoria);

-- Estado diario del pipeline, reconstruido íntegramente a partir de las tablas
-- que las fases ya escriben: ni un nodo de logging, ni una columna nueva.
--
-- Antes de añadir instrumentación conviene ver cuánto sale gratis. Con los
-- timestamps que ya existen se responde qué entró, cuánto sobrevivió a cada
-- filtro y cuánto llegó al briefing. Lo único que NO se puede deducir de aquí
-- son los fallos que se autorreparan sin dejar rastro (un feed RSS vacío, un
-- 429 de Groq, un reencolado de embeddings) y el consumo de tokens.
CREATE OR REPLACE VIEW v_daily_pipeline AS
WITH dias AS (
    SELECT DISTINCT (processed_at AT TIME ZONE 'UTC')::date AS dia
    FROM normalized_articles
)
SELECT d.dia,
  (SELECT count(*) FROM normalized_articles n
     WHERE (n.processed_at AT TIME ZONE 'UTC')::date = d.dia)                          AS articulos,
  (SELECT count(DISTINCT n.source_name) FROM normalized_articles n
     WHERE (n.processed_at AT TIME ZONE 'UTC')::date = d.dia)                          AS fuentes,
  (SELECT count(*) FROM cluster_analysis c
     WHERE (c.analyzed_at AT TIME ZONE 'UTC')::date = d.dia AND c.status = 'ok')       AS analisis_ok,
  (SELECT count(*) FROM cluster_analysis c
     WHERE (c.analyzed_at AT TIME ZONE 'UTC')::date = d.dia AND c.status = 'superseded') AS superseded,
  (SELECT count(*) FROM cluster_analysis c
     WHERE (c.analyzed_at AT TIME ZONE 'UTC')::date = d.dia AND c.status = 'error')    AS analisis_error,
  (SELECT count(*) FROM cluster_analysis c
     WHERE (c.analyzed_at AT TIME ZONE 'UTC')::date = d.dia AND c.categoria IS NULL)   AS sin_categoria,
  b.cluster_count    AS en_briefing,
  b.divergence_count AS divergencias,
  round(b.cluster_count * 100.0 / NULLIF((SELECT count(*) FROM normalized_articles n
     WHERE (n.processed_at AT TIME ZONE 'UTC')::date = d.dia), 0), 1)                  AS pct_supervivencia
FROM dias d
LEFT JOIN briefings b ON b.briefing_date = d.dia
ORDER BY d.dia DESC;