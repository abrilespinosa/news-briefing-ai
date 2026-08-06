# 02 — Normalization

## Propósito

Este sub-workflow recibe el output crudo-pero-ya-mapeado de [`01-ingestion-rss`](./01-ingestion-rss.md) y lo transforma en un conjunto de items **limpios y consistentes en formato**, listo para las fases posteriores de deduplicación y clustering.

La normalización de *esquema* (mismos nombres de campo entre fuentes con formas de RSS distintas) ya ocurre dentro de `01-ingestion-rss`. Este sub-workflow se ocupa de la normalización de *valores*: limpieza de HTML, formato de fechas, URLs y metadatos derivados.

## Arquitectura

```
Execute Workflow Trigger (Accept all data)
        │
        ▼
Execute Workflow → llama a 01-ingestion-rss
        │
        ▼
Code node "Normalize Fields" (Run Once for Each Item)
```

Se implementa como sub-workflow independiente, invocado por `Execute Workflow`, siguiendo el patrón de arquitectura modular del proyecto: cada fase del pipeline es testeable y desplegable de forma aislada.

## Esquema de entrada

Campos recibidos desde `01-ingestion-rss` (output de su `Edit Fields`):

| Campo | Tipo | Notas |
|---|---|---|
| `title` | string | |
| `link` | string | URL del artículo, puede incluir parámetros de tracking |
| `published_date` | string (ISO 8601) | |
| `raw_summary` | string (HTML) | Contenido crudo, con tags HTML e imágenes embebidas |
| `category` | string | |
| `source_name` | string | Valores exactos: `"El País"`, `"elDiario.es"`, `"El Mundo"`, `"ABC"` |

## Transformaciones aplicadas

1. **Limpieza de HTML** (`raw_summary` → `content`): elimina tags, bloques `<script>`/`<style>`, decodifica entidades HTML (incluyendo vocales acentuadas y `ñ` — necesario porque algunas fuentes, como elDiario.es, las sirven sin decodificar en su RSS) y colapsa espacios/saltos de línea.
2. **Normalización de fecha** (`published_date`): validación explícita vía `DateTime.fromISO` (Luxon). Si el valor no es un ISO 8601 válido, el campo queda en `null` en vez de propagar un dato incorrecto sin avisar.
3. **Limpieza de URL** (`link`): elimina parámetros de tracking (`utm_source`, `utm_medium`, `utm_campaign`, `utm_content`, `utm_term`, `ref`, `fbclid`). Necesario para que la fase de Deduplicación no trate como distintas dos URLs que apuntan al mismo artículo.
4. **Idioma** (`language`, campo nuevo): mapeo estático por `source_name`. Todas las fuentes actuales son en español (`es`). Este mapeo tendrá que ampliarse si se añaden fuentes en otros idiomas.
5. **Validación** (`normalization_valid`, campo nuevo, booleano): `true` solo si `title`, `published_date` y `link` quedaron correctamente poblados tras la limpieza. No se descartan items inválidos en esta fase — se marcan, y la decisión de qué hacer con ellos corresponde a fases posteriores.

## Esquema de salida

Igual que el de entrada, con `raw_summary` sustituido por `content` (limpio), `published_date` normalizado, `link` sin tracking params, y los campos nuevos `language` y `normalization_valid`.

## Decisiones de diseño

- **Un único Code node**, no un nodo por transformación: todas las operaciones comparten una misma responsabilidad ("dejar el item limpio y consistente"), por lo que fragmentarlas en varios nodos añadiría ruido visual sin mejorar la mantenibilidad.
- **Limpieza de HTML por regex, no por parser real**: suficiente para este propósito y sin dependencias externas. La extracción de contenido completo del artículo (más allá del resumen del RSS) se aborda en una fase futura dedicada, con una herramienta de parsing HTML real.
- **Marcar en vez de descartar** los items inválidos: mantiene la responsabilidad de este sub-workflow acotada a "normalizar", dejando el filtrado a la fase de Quality Filter.

## Mejoras futuras

- Sustituir el mapeo estático de `language` por detección real cuando se incorporen fuentes no hispanohablantes.
- Añadir extracción de contenido completo del artículo (más allá del resumen del RSS) para reducir el riesgo de pérdida de contexto en el análisis LLM posterior.
- Revisar el trigger de `01-ingestion-rss`: actualmente depende de `Execute Workflow Trigger` sin input real; cuando exista el orquestador maestro del pipeline completo, conviene revisar si este patrón sigue siendo el adecuado para todos los sub-workflows.
