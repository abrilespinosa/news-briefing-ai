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

### Algoritmo: Union-Find + similitud coseno

Cada par de artículos se compara por similitud coseno entre embeddings; los que superan el umbral se fusionan mediante una estructura Union-Find (Disjoint Set Union) implementada en JavaScript puro, sin librerías externas ni extensiones de Postgres.

`pgvector` sería la solución más escalable a gran volumen, pero se descarta por ahora: desplazaría lógica de negocio de n8n a SQL, dificultando la depuración visual del flujo. Queda como mejora futura si el volumen lo justifica.

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

**Esquema (`normalized_articles`):**
```sql
CREATE TABLE IF NOT EXISTS normalized_articles (
    id SERIAL PRIMARY KEY,
    link TEXT UNIQUE NOT NULL,
    title TEXT NOT NULL,
    content TEXT,
    category TEXT,
    source_name TEXT,
    published_date TIMESTAMPTZ,
    language TEXT,
    embedding JSONB NOT NULL,
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
                                                          Get Articles for Clustering Window (ventana 24h)
                                                                                                          ▼
                                                                          Cluster Articles by Similarity
```

Umbral de similitud coseno: **0.83**, calibrado empíricamente sobre datos reales.

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

## Validación

Sobre 284 artículos reales (4 fuentes, mismo día): 276 clusters, 7 de ellos multi-fuente y confirmados manualmente como el mismo evento cubierto por medios distintos — incluyendo un caso con cifras discrepantes entre fuentes (10 vs. 9 muertos en un mismo ataque), el tipo de discrepancia que la fase 06 deberá señalar. Sin falsos positivos detectados en revisión manual.

## Mejora futura

- **Identidad persistente de eventos entre ejecuciones no consecutivas**: hoy el clustering solo compara artículos dentro de la ventana de 24h. Un evento en desarrollo durante varios días (ej. cobertura de un incendio) no se vincula automáticamente con artículos de días anteriores. Pendiente de diseño hasta definir cómo la fase 06 consumirá "eventos que se actualizan".
- Migrar a `pgvector` si el volumen de artículos crece significativamente.
- Revisar el umbral de similitud con una muestra de varios días acumulados.
