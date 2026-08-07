# 04 · Clustering

## Objetivo

Agrupar artículos de distintas fuentes que hablan del mismo acontecimiento, para tratarlos como un único evento con múltiples fuentes citadas, en lugar de mostrar noticias casi idénticas por separado.

Convierte una lista plana de artículos normalizados y deduplicados en una lista de **eventos**, cada uno con sus artículos asociados. Es el input que consumirá la fase 05 (Análisis LLM) para comparar fuentes y detectar discrepancias.

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

### Un artículo que no llega a persistirse no puede perderse

Esa separación tiene una arista peligrosa: **03 inserta los links en `seen_articles` antes de que 04 los persista.** Si algo falla por el camino, el artículo queda marcado como visto sin haber llegado nunca a `normalized_articles`, y 03 no lo volverá a considerar en ninguna corrida futura. No es un fallo ruidoso que se pueda reintentar: es una pérdida permanente y silenciosa.

Hay **tres** puntos por los que se puede llegar ahí, y no todos acotan lo mismo:

| Fallo | Alcance |
|---|---|
| `Generate Embeddings` (HTTP a Ollama) | La petición es única para toda la corrida — se lleva el lote entero |
| `Merge Embeddings with Items` (`throw` por desajuste de longitud) | Igual: el lote entero |
| `Insert Normalized Articles` (Postgres) | Solo los items que fallaron; n8n encamina el resto por la rama de éxito |

Los tres desembocan en `Collect Links to Requeue`, que resuelve el alcance leyendo lo que le llega: si los items traen `link` propio son artículos concretos y se reencolan solo esos; si son objetos de error sin `link`, el fallo fue del lote y se reencola la corrida completa desde `Prepare Embedding Input`. Después, `Requeue Articles With Failed Embedding` los borra de `seen_articles` y el fallo pasa a ser autorreparable — la corrida siguiente los vuelve a ingerir.

Reencolar de más es seguro: el `INSERT` es `ON CONFLICT (link) DO NOTHING`, así que un artículo que sí había entrado y vuelve a pasar por aquí no se duplica ni rompe nada. La asimetría es deliberada — el coste de reingerir un artículo de sobra es una petición RSS; el de perderlo es que no vuelve nunca.

**Tras reencolarlos, la corrida continúa hacia el clustering en vez de morir.** Agrupa lo que ya hay en la ventana de 24h, de modo que un fallo degrada el briefing del día pero no lo cancela. Los reintentos son 3 con 10s entre medias en el nodo de embeddings (margen para el arranque en frío de Ollama cargando el modelo) y 3 con 5s en el `INSERT`.

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
      true  → Generate Embeddings (Ollama, retryOnFail) → Merge Embeddings with Items → Insert Normalized Articles ─┐
      false → No New Articles - Skipping Clustering ──────────────────────────────────────────────────┤
                                                                                                          │
      (las tres ramas de error) → Collect Links to Requeue → Requeue Articles With Failed Embedding ──────┤
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
  "articles": [ { "title": "...", "link": "...", "source_name": "...", "category": "...", "content": "..." } ]
}
```

`content` se añadió al pasar a diseñar la fase 05: sin el texto del artículo, un análisis LLM no tiene con qué comparar fuentes.

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

**`Compute Similarity Edges` tiene `executeOnce: true`:** por defecto, un nodo Postgres en n8n ejecuta su query una vez por cada item de entrada. Esta query es estática (no depende de ningún campo del item), así que sin `executeOnce` se repetiría N veces — mismo resultado final (Union-Find es idempotente ante aristas repetidas), pero con una query pesada ejecutándose N veces de más.

## Validación

Sobre 284 artículos reales (4 fuentes, mismo día): 276 clusters, 7 de ellos multi-fuente y confirmados manualmente como el mismo evento cubierto por medios distintos — incluyendo un caso con cifras discrepantes entre fuentes (10 vs. 9 muertos en un mismo ataque), el tipo de discrepancia que la fase 06 deberá señalar. Sin falsos positivos detectados en revisión manual.

**Tras la migración a pgvector**, se validó además la estabilidad: mismo resultado (mismos pares por encima del umbral, mismos clusters) en 5 ejecuciones consecutivas sobre el mismo conjunto de artículos — confirmando que el cálculo en SQL es determinista, a diferencia del Code node original (ver sección de arquitectura).

### La forma real de la salida

Conviene saber leer el número de items que devuelve esta fase, porque a primera vista desconcierta: **un item es un acontecimiento, no un artículo**, y aun así la cifra queda muy cerca del total de artículos. Ejecución del 7 de agosto de 2026, con 818 artículos en la ventana y 164 aristas por encima del umbral:

| Artículos por cluster | Clusters |
|---|---|
| 1 | **667** |
| 2 | 24 |
| 3 | 9 |
| 4 | 5 |
| 5 | 3 |
| 6 | 2 |
| 7 | 3 |
| 8 | 1 |

714 clusters en total, que cubren exactamente los 818 artículos. **667 son de un solo artículo**: solo 47 clusters agrupan algo, absorbiendo 151 artículos entre todos. Y contando por medios en vez de por artículos, solo **43 clusters son multi-fuente** — los únicos que consume 05; los otros 671 los descarta en su primer `IF`.

El embudo completo del pipeline queda así: 818 artículos → 714 acontecimientos → 43 multi-fuente → 30 analizados (tope de Groq). El estrechamiento no lo produce el clustering, sino un hecho del material de partida: **la gran mayoría de las noticias las publica un solo medio**. Un cluster de 8 artículos con 7 fuentes indica además que un medio publicó dos piezas del mismo suceso, caso que 05 maneja bien porque filtra por `source_count` y no por `article_count`.

## Mejora futura

- **Identidad persistente de eventos entre ejecuciones no consecutivas**: hoy el clustering solo compara artículos dentro de la ventana de 24h. Un evento en desarrollo durante varios días (ej. cobertura de un incendio) no se vincula automáticamente con artículos de días anteriores. Pendiente de diseño hasta definir cómo la fase 06 consumirá "eventos que se actualizan".
- Añadir índice `ivfflat`/`hnsw` sobre `embedding` si el volumen de artículos crece lo suficiente para que el self-join deje de ser trivial. Hay ya un índice B-tree sobre `processed_at`, que es por donde filtra la ventana.
- **El reencolado por fallo de embeddings no deja aviso.** La corrida sigue y termina en `success`, así que la degradación solo se ve entrando al historial de n8n. Ahora que existe la fase 09, el canal para notificarlo ya está montado.
- **`normalized_articles` no se poda.** Crece ~700 filas/día con un vector de 1024 dimensiones cada una, y el clustering solo mira las últimas 24h. Habrá que decidir si el histórico se conserva (útil el día que exista identidad persistente de eventos) o se recorta.
- Revisar el umbral de similitud con una muestra de varios días acumulados.
