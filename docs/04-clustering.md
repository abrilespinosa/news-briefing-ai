# 04 · Clustering

## Objetivo

Agrupar artículos de distintas fuentes que hablan del mismo acontecimiento, para tratarlos como un único evento con múltiples fuentes citadas, en lugar de mostrar noticias casi idénticas por separado.

Convierte una lista plana de artículos normalizados y deduplicados en una lista de **eventos**, cada uno con sus artículos asociados. Es el input que consumirá la fase 06 (LLM Analysis) para comparar fuentes y detectar discrepancias.

## Arquitectura

### Detección de eventos: embeddings semánticos, no LLM ni similitud léxica

- **Similitud léxica (TF-IDF/Jaccard)**: descartada — frágil ante redacciones distintas del mismo hecho, no escala a multi-idioma.
- **Clustering directo vía LLM**: descartado — no determinista, caro a volumen, riesgo de alucinar relaciones entre eventos.
- **Embeddings + similitud coseno**: elegida — determinista, barata, multi-idioma de fábrica. Separa responsabilidades: el LLM se reserva para razonar sobre contenido ya agrupado (fase 06), no para decidir qué se agrupa.

### Embeddings self-hosted (Ollama + `bge-m3`)

Anthropic no ofrece modelos de embeddings propios. En vez de depender de una API de pago externa (OpenAI, Google, Voyage), se despliega `bge-m3` localmente vía Ollama como contenedor adicional en Docker Compose:

- Coste $0, coherente con el resto del stack 100% self-hosted.
- Multilingüe de fábrica, alineado con el requisito de soporte multi-idioma sin pasos adicionales.
- Trade-off aceptado: sin acceso a GPU en Docker Desktop/Mac, la inferencia corre por CPU — irrelevante al volumen actual (~250-300 artículos/día).

### Persistencia desacoplada de la ejecución

El clustering no depende de la corrida puntual de deduplicación: los artículos normalizados con su embedding se persisten en `normalized_articles`, y el clustering los recupera por ventana temporal (últimas 24h). Esto separa dos preguntas distintas — "¿ya vi este link?" (`seen_articles`) y "¿qué artículos comparo en esta ejecución de clustering?" (`normalized_articles` + ventana) — y permite que el clustering se ejecute independientemente de si hubo ingesta nueva en esa corrida.

### Algoritmo: similitud coseno en Postgres (`pgvector`) + Union-Find en n8n

La comparación por pares (similitud coseno entre embeddings) se ejecuta en Postgres vía la extensión `pgvector` (operador `<=>`, distancia coseno), no en el Code node. Solo la fusión de pares en clusters (Union-Find / Disjoint Set Union) se hace en JavaScript puro dentro de n8n, ya que esa parte es barata (O(aristas), no O(n²)).

**Por qué se cambió de diseño (no fue la elección inicial):** la versión original calculaba las ~n²/2 comparaciones coseno en un único Code node síncrono de n8n. A partir de ~430 artículos/ventana esto se volvió poco fiable: el Code node corre en un runner externo con timeout (`N8N_RUNNERS_TASK_TIMEOUT`), y el cálculo pesado (cientos de millones de operaciones de punto flotante) provocaba tanto errores ("Task execution aborted because runner became unresponsive") como, en ejecuciones que sí "tenían éxito", resultados inconsistentes con el mismo dataset de entrada (ejecuciones consecutivas sobre exactamente los mismos 436 artículos dieron 421, 51, 101 y 196 clusters). Se diagnosticó con el historial real de ejecuciones (parseado desde `execution_data` en Postgres) — no era un problema del umbral ni del algoritmo Union-Find en sí (matemáticamente da igual el orden en que se procesen las aristas), sino de fiabilidad del entorno de ejecución bajo esa carga.

Mover el cálculo de similitud a SQL resuelve esto: Postgres hace la operación vectorial nativa (mucho más rápida que un bucle JS) y solo devuelve las parejas que ya superan el umbral — de ~94.000 comparaciones posibles sobre ~430 artículos, típicamente menos de 20 aristas viajan de vuelta a n8n.

## Implementación

**Infraestructura (`docker-compose.yml`):**
```yaml
ollama:
  image: ollama/ollama:latest
  restart: unless-stopped
  ports:
    - "11434:11434"
  volumes:
    - ollama_data:/root/.ollama
```

**Esquema (`normalized_articles`):** requiere `CREATE EXTENSION vector;` (imagen `pgvector/pgvector:pg16` en `docker-compose.yml`, en vez de `postgres:16` vainilla).
```sql
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
```

**Flujo de nodos:**
```
Execute Workflow Trigger
  → Call '03-deduplication'
  → Prepare Embedding Input (título + primeras 3 frases del contenido)
  → Check Has New Items (IF)
      true  → Generate Embeddings (Ollama) → Merge Embeddings with Items → Insert Normalized Articles ─┐
      false → No New Articles - Skipping Clustering ──────────────────────────────────────────────────┤
                                                                                                          ▼
                                                          Get Articles for Clustering Window (ventana 24h, sin embeddings)
                                                                                                          ▼
                                                          Compute Similarity Edges (self-join en SQL, similitud >= umbral)
                                                                                                          ▼
                                                                          Cluster Articles by Similarity (Union-Find sobre las aristas)
```

Umbral de similitud coseno: **0.83**, calibrado empíricamente sobre datos reales. Se aplica ahora dentro de la query SQL de `Compute Similarity Edges`, no en JavaScript.

## Flujo de datos

**Salida de "Cluster Articles by Similarity":** un ítem por cluster.
```json
{
  "cluster_id": 0,
  "article_count": 2,
  "source_count": 2,
  "sources": ["El País", "elDiario.es"],
  "articles": [ { "title": "...", "link": "...", "source_name": "...", "category": "..." } ]
}
```

`source_count` se calcula en esta fase, ya que es la única con acceso directo a los artículos agrupados; lo reutilizará la fase 07 (Quality Filter) como filtro estructural por número de fuentes.

### Queries SQL relevantes

**`Get Articles for Clustering Window`** — ya no trae `content` ni `embedding` (dejaron de hacer falta en n8n una vez que la similitud se calcula en Postgres):
```sql
SELECT id, link, title, category, source_name
FROM normalized_articles
WHERE processed_at >= NOW() - INTERVAL '24 hours';
```

**`Compute Similarity Edges`** (nodo nuevo) — hace el self-join dentro de la misma ventana de 24h y devuelve solo los pares que superan el umbral:
```sql
WITH window_articles AS (
  SELECT id, embedding
  FROM normalized_articles
  WHERE processed_at >= NOW() - INTERVAL '24 hours'
)
SELECT a.id AS id_a, b.id AS id_b
FROM window_articles a
JOIN window_articles b ON a.id < b.id
WHERE 1 - (a.embedding <=> b.embedding) >= 0.83;
```

No se añadió índice `ivfflat`/`hnsw` sobre `embedding`: al volumen actual (cientos de artículos/ventana) el self-join secuencial es inmediato, y un índice ANN con tan pocas filas no aporta y complica el mantenimiento sin necesidad. Queda anotado como mejora futura si el volumen crece mucho.

**Nota sobre `Compute Similarity Edges` y "Execute Once":** este nodo recibe como entrada los N artículos de la ventana (uno por item, desde `Get Articles for Clustering Window`). El comportamiento por defecto de un nodo Postgres en n8n es ejecutar su query **una vez por cada item de entrada** — como esta query es estática (no depende de ningún campo del item), sin la opción `executeOnce: true` activada, n8n repetía la misma consulta N veces y concatenaba los resultados (con 504 artículos, se detectaron 10.080 aristas en vez de las 20 reales — 504×20). El resultado final de clustering no cambiaba porque Union-Find es idempotente ante aristas repetidas, pero la query pesada se ejecutaba N veces de más. Con `executeOnce` activado, se ejecuta una sola vez sin importar cuántos items lleguen.

## Validación

Sobre 284 artículos reales (4 fuentes, mismo día): 276 clusters, 7 de ellos multi-fuente y confirmados manualmente como el mismo evento cubierto por medios distintos — incluyendo un caso con cifras discrepantes entre fuentes (10 vs. 9 muertos en un mismo ataque), el tipo de discrepancia que la fase 06 deberá señalar. Sin falsos positivos detectados en revisión manual.

**Tras la migración a pgvector**, se validó además la estabilidad: sobre los 496 artículos acumulados en la ventana de 24h, se comparó el resultado del cálculo antiguo (fuerza bruta en Python, fuera de n8n) contra el nuevo pipeline SQL — mismos 18 pares por encima del umbral, mismos 479 clusters totales (15 multi-fuente), y resultado idéntico en 5 ejecuciones consecutivas. Antes de este cambio, ejecuciones consecutivas sobre un conjunto fijo de 436 artículos habían dado 421, 51, 101 y 196 clusters — la inconsistencia no era del algoritmo sino del entorno de ejecución del Code node (ver sección de arquitectura).

## Mejora futura

- **Identidad persistente de eventos entre ejecuciones no consecutivas**: hoy el clustering solo compara artículos dentro de la ventana de 24h. Un evento en desarrollo durante varios días (ej. cobertura de un incendio) no se vincula automáticamente con artículos de días anteriores. Pendiente de diseño hasta definir cómo la fase 06 consumirá "eventos que se actualizan".
- Añadir índice `ivfflat`/`hnsw` sobre `embedding` si el volumen de artículos crece lo suficiente para que el self-join deje de ser trivial.
- Revisar el umbral de similitud con una muestra de varios días acumulados.
