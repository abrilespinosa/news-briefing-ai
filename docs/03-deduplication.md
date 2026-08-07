# 03 — Deduplicación

## Objetivo

Evitar que el mismo artículo aparezca más de una vez en el pipeline, tanto:
- **dentro de una misma ejecución** (el mismo artículo aparece en más de un feed/categoría de la misma fuente), como
- **entre ejecuciones distintas** (un artículo que ya se procesó ayer sigue apareciendo hoy en el RSS).

Este sub-workflow NO resuelve duplicados semánticos (mismo hecho, distintas fuentes/redacciones) — eso corresponde a la fase de clustering (04).

## Arquitectura

Deduplicación persistente mediante una tabla propia en Postgres (`seen_articles`), en vez de:
- el modo "in-memory" del nodo nativo Remove Duplicates de n8n (no persiste entre ejecuciones), o
- el modo persistente nativo de n8n vía `Store in Database` (queda oculto en el estado interno de n8n, no auditable ni extensible).

La tabla propia da trazabilidad completa (`SELECT * FROM seen_articles`), es portable si se cambia de herramienta de automatización, y permite añadir metadatos (categoría, fecha de primera detección).

### Esquema

```sql
CREATE TABLE IF NOT EXISTS seen_articles (
  id SERIAL PRIMARY KEY,
  link TEXT UNIQUE NOT NULL,
  source_name TEXT,
  category TEXT,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

(`db/schema.sql`)

## Flujo de nodos

```
When Executed by Another Workflow
  → Call '02-normalization'
    → Validate Normalization (IF: normalization_valid is true)
        true  → Collect Links (Code) → Check Seen Links (Postgres SELECT)
                  → Filter New Items (Code) → Insert New Links (Postgres INSERT)
                  → Return New Articles (Code)
        false → Discarded - invalid normalization (NoOp, rama de inspección)
```

**Nota de diseño:** se usa un nodo `IF` (no `Filter`) para la validación de `normalization_valid`, porque `Filter` en n8n solo tiene un output — los items que no cumplen la condición se descartan sin dejar rastro navegable. `IF` expone ambas ramas (`true`/`false`) como outputs reales, lo cual es necesario para poder inspeccionar qué se descarta y por qué, en línea con el principio de transparencia del proyecto.

### Collect Links (Code, Run Once for All Items)

Agrupa todos los `link` de los items validados en un único array, para pasarlos como un solo parámetro a la consulta SQL siguiente (evita el antipatrón N+1 de una query por item).

### Check Seen Links (Postgres, Execute Query)

```sql
SELECT link
FROM seen_articles
WHERE link = ANY(
  SELECT jsonb_array_elements_text($1::jsonb)
);
```

Parámetro: `{{ JSON.stringify($json.links) }}`.

**Nota técnica:** se pasa el array como JSON (`jsonb_array_elements_text`) en vez de como array-literal nativo de Postgres (`{a,b,c}`), porque construir ese formato a mano con concatenación de strings resultó frágil con arrays grandes (~280 elementos) y propenso a errores de escape/truncamiento. JSON es un formato de serialización estándar sin esa fragilidad.

**Nota de configuración:** tiene activada la opción "Always Output Data" en Settings — sin ella, si la query devuelve 0 filas (por ejemplo, en la primera ejecución con la tabla vacía), n8n corta la cadena de ejecución y los nodos siguientes no se disparan.

### Filter New Items (Code, Run Once for All Items)

Dos responsabilidades:

1. **Deduplicación interna del lote**: si dos items del mismo batch comparten `link` (ej. el mismo artículo publicado bajo dos categorías de la misma fuente), se conserva solo uno, según una jerarquía de prioridad de categorías definida explícitamente:

   ```
   tecnologia > ciencia > economia > internacional > espana
   ```

   Razonamiento: ante empate entre una categoría temática y una geográfica, gana la temática, porque aporta más información sobre el contenido real del artículo. Entre `internacional` y `espana`, gana `internacional` porque `espana` tiende a ser la categoría por defecto con menos señal distintiva en estas fuentes.

2. **Filtrado contra Postgres**: descarta los items cuyo `link` ya está en `seen_articles`.

```javascript
const CATEGORY_PRIORITY = ['tecnologia', 'ciencia', 'economia', 'internacional', 'espana'];

function priorityOf(category) {
  const idx = CATEGORY_PRIORITY.indexOf(category);
  return idx === -1 ? CATEGORY_PRIORITY.length : idx; // desconocidas al final
}

const byLink = new Map();

for (const item of $('Validate Normalization').all()) {
  const link = item.json.link;
  const existing = byLink.get(link);

  if (!existing || priorityOf(item.json.category) < priorityOf(existing.json.category)) {
    byLink.set(link, item);
  }
}

const dedupedOriginalItems = Array.from(byLink.values());

const seenLinks = new Set(items.map(item => item.json.link));
const newItems = dedupedOriginalItems.filter(item => !seenLinks.has(item.json.link));

return newItems;
```

### Insert New Links (Postgres, Execute Query)

```sql
INSERT INTO seen_articles (link, source_name, category, first_seen_at)
VALUES ($1, $2, $3, now())
ON CONFLICT (link) DO NOTHING;
```

El `ON CONFLICT DO NOTHING` da idempotencia: reejecutar el workflow sobre los mismos datos no falla ni duplica.

**Esta escritura ocurre antes de que 04 genere los embeddings**, y ahí hay un acoplamiento que conviene tener presente: marcar un link como visto es un compromiso de que el artículo ha entrado en el pipeline, pero quien lo mete de verdad en `normalized_articles` es la fase siguiente. Si el embedding falla, el artículo queda visto y sin persistir, y 03 no volverá a considerarlo nunca. Se resuelve en 04, que devuelve esos links a la cola borrándolos de aquí (ver `docs/04-clustering.md`). La alternativa —insertar en `seen_articles` solo tras un embedding correcto— mezclaría en 04 una responsabilidad que es de 03.

### Return New Articles (Code, Run Once for All Items)

```javascript
return $('Filter New Items').all();
```

`Insert New Links` no lleva `RETURNING` en su `INSERT`, así que su propia salida es solo la confirmación de Postgres, no las filas insertadas. Este nodo hace explícito el retorno real del workflow (la lista de artículos nuevos filtrados), que es lo que espera `04-clustering` al invocarlo — sin él, el nodo terminal del workflow sería la confirmación de escritura, no los datos.

## Flujo de datos

- **Entra:** items normalizados desde `02-normalization`, con `title, link, published_date, content, category, source_name, language, normalization_valid`.
- **Sale:** subconjunto de esos items — solo los que son artículos nuevos (no vistos antes y sin duplicado interno de prioridad inferior) — con el mismo esquema.

**Cómo inspeccionar:**
- Panel Output de `Validate Normalization`, pestañas `true`/`false`, para ver cuántos y cuáles items se descartan por normalización inválida.
- Panel Output de `Check Seen Links`, para ver qué links ya existían en la tabla.
- Panel Output de `Filter New Items`, para ver el resultado final que llega al INSERT.

## Validación realizada

- Primera ejecución sobre tabla vacía: 279 items procesados, 278 insertados (1 descartado por `UNIQUE` antes de aplicar la jerarquía de categorías — corregido manualmente, ver "Incidencias").
- Segunda ejecución (misma ventana de RSS, sin cambios significativos en los feeds): 279 links de entrada, 277 únicos tras deduplicación interna (2 duplicados del mismo lote), 0 nuevos — correcto, ya estaban todos en `seen_articles`.

## Incidencias y aprendizajes

- El nodo `Filter` de n8n solo tiene un output; para trazabilidad de ambas ramas de una condición se necesita `IF`.
- Pasar arrays grandes como parámetro a una query Postgres vía array-literal nativo (`{a,b,c}`) es frágil; usar JSON + `jsonb_array_elements_text` es más robusto.
- Un `Filter`/`IF` con condición booleana debe tener el tipo de comparación explícitamente en `Boolean`, no en `String` (por defecto puede quedar en `String`, lo que rompe la comparación silenciosamente).
- Se detectó, en datos reales, que un mismo artículo de El País puede aparecer en más de un feed de categoría — de ahí la necesidad de la jerarquía de desempate.

## Mejora futura

- Deduplicación semántica (mismo hecho, distinta fuente/URL) — corresponde a la fase 04 (clustering), no a esta.
- La jerarquía `CATEGORY_PRIORITY` está hardcodeada en el Code node; migrar a configuración externa (Postgres) cuando se añadan más fuentes con categorías no cubiertas por la lista actual. La tabla `app_config` que introdujo la fase 09 es el sitio natural.
- **`seen_articles` no se poda.** Es correcto —olvidar un link significa reprocesarlo— pero crece indefinidamente. Con ~700 filas/día es despreciable durante años; conviene saber que el crecimiento es por diseño y no un descuido.
