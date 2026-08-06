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
CREATE TABLE IF NOT EXISTS cluster_analysis (
    id SERIAL PRIMARY KEY,
    cluster_id INTEGER NOT NULL,
    source_count INTEGER,
    sources JSONB,
    articles JSONB,
    analysis JSONB,
    status TEXT NOT NULL DEFAULT 'ok',
    error_message TEXT,
    analyzed_at TIMESTAMPTZ DEFAULT now()
);

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