# 01 — Ingestion RSS

## Qué hace

Sub-workflow de ingesta que obtiene noticias desde múltiples fuentes RSS públicas y las normaliza a un formato común, listo para las fases posteriores del pipeline (Normalización, Deduplicación, Clustering, etc.).

No deduplica ni filtra por relevancia — eso corresponde a fases posteriores. Esta fase solo se encarga de: obtener, parsear y normalizar el formato de salida.

## Arquitectura

**Patrón: data-driven, no un nodo por fuente.**

En vez de crear un `RSS Feed Read` por cada fuente (lo cual obligaría a tocar el workflow cada vez que se añade o quita una fuente), la lista de fuentes vive como datos dentro de un nodo `Set`, y un único `RSS Feed Read` procesa todas las fuentes gracias al comportamiento implícito de n8n de ejecutar un nodo una vez por item de entrada.

Flujo de nodos:

```
Manual Trigger
   → Set (lista de fuentes en JSON)
   → Split Out (un item por fuente)
   → RSS Feed Read (una ejecución por fuente)
   → Edit Fields (normalización de campos)
```

**Por qué este patrón:** añadir una fuente nueva es una fila más en el JSON del `Set` node — cero cambios de lógica en el resto del workflow. Se validó con 4 fuentes reales y estructuralmente distintas entre sí sin necesidad de tocar `Split Out`, `RSS Feed Read` ni la estructura general de `Edit Fields`.

## Fuentes activas

| Fuente | Categoría | Notas |
|---|---|---|
| El País | internacional, economía, tecnología, ciencia, españa (5 feeds) | `content:encoded` trae HTML completo del artículo |
| elDiario.es | portada (1 feed) | `content` (no `content:encoded`) trae HTML completo, incluye multimedia embebida |
| El Mundo | portada (1 feed) | Feed de portada verificado con contenido completo |
| ABC | portada (1 feed, RSS 2.0) | Se descartó la variante Atom por sección (`/rss/atom/...`) porque solo traía resúmenes de 1-2 líneas, insuficientes para análisis LLM fiable. El feed de portada RSS 2.0 (`/rss/2.0/portada/`) sí trae contenido completo y categoriza cada item individualmente |
| 20minutos | portada (1 feed) | `description` |
| La Vanguardia | portada (1 feed) | `description` |
| Europa Press | portada (1 feed) | `description` |

**RTVE evaluado y descartado:** sus feeds RSS (`rtve.es/rss/*.xml`) responden con HTTP 200 pero devuelven contenido sin actualizar desde mediados de 2022 — el servicio parece abandonado aunque las URLs sigan activas. Verificado con dos feeds distintos (`temas_noticias.xml`, `temas_espana.xml`) antes de descartarlo, no es un fallo puntual de uno solo.

**Por qué varias fuentes y no solo una ampliada:** el objetivo del proyecto es minimizar el sesgo de depender de un único medio para decidir qué es relevante y cómo se enmarca. Consultar varios medios independientes entre sí, en vez de ampliar la cobertura de uno solo, es la base sobre la que se apoyará el futuro filtro de "corroboración por múltiples fuentes" (ver Limitaciones conocidas). Este proyecto no asigna ni documenta posicionamientos editoriales a los medios consultados; la selección de fuentes prioriza cobertura nacional generalista y variedad de redacciones independientes entre sí.

## Configuración de fuentes (nodo `Set`, modo JSON)

```json
{
  "sources": [
    { "source_name": "El País", "category": "internacional", "rss_url": "https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/section/internacional/portada" },
    { "source_name": "El País", "category": "economia", "rss_url": "https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/section/economia/portada" },
    { "source_name": "El País", "category": "tecnologia", "rss_url": "https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/section/tecnologia/portada" },
    { "source_name": "El País", "category": "ciencia", "rss_url": "https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/section/ciencia/portada" },
    { "source_name": "El País", "category": "espana", "rss_url": "https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/section/espana/portada" },
    { "source_name": "elDiario.es", "category": "portada", "rss_url": "https://www.eldiario.es/rss" },
    { "source_name": "El Mundo", "category": "portada", "rss_url": "https://e00-elmundo.uecdn.es/rss/portada.xml" },
    { "source_name": "ABC", "category": "portada", "rss_url": "https://www.abc.es/rss/2.0/portada/" },
    { "source_name": "20minutos", "category": "portada", "rss_url": "https://www.20minutos.es/rss" },
    { "source_name": "La Vanguardia", "category": "portada", "rss_url": "https://www.lavanguardia.com/rss/home.xml" },
    { "source_name": "Europa Press", "category": "portada", "rss_url": "https://www.europapress.es/rss/rss.aspx" }
  ]
}
```

## Normalización de campos (`Edit Fields`)

El mayor reto de esta fase fue que cada medio nombra sus campos RSS de forma distinta. La expresión de contenido usa una cadena de fallback:

```
{{ $json["content:encoded"] ?? $json.content ?? $json.contentSnippet ?? $json.summary ?? $json.description ?? '' }}
```

| Fuente | Campo real de contenido |
|---|---|
| El País | `content:encoded` |
| elDiario.es | `content` |
| El Mundo | (pendiente de confirmar campo exacto tras el último cambio) |
| ABC (portada RSS 2.0) | a confirmar — verificar tras el cambio desde Atom |
| 20minutos | `description` |
| La Vanguardia | `description` |
| Europa Press | `description` |

> Nota: al pasar ABC de feeds Atom a feed de portada RSS 2.0, conviene reconfirmar el nombre exacto del campo de contenido — puede diferir del que tenían los feeds Atom descartados.

## Ejemplo de input → output

**Input crudo (RSS Feed Read, item de El País):**
```json
{
  "title": "Ejemplo de titular",
  "link": "https://elpais.com/...",
  "isoDate": "2026-07-30T10:00:00.000Z",
  "content:encoded": "<p>Cuerpo completo del artículo en HTML...</p>"
}
```

**Output normalizado (Edit Fields):**
```json
{
  "title": "Ejemplo de titular",
  "link": "https://elpais.com/...",
  "published_date": "2026-07-30T10:00:00.000Z",
  "raw_summary": "<p>Cuerpo completo del artículo en HTML...</p>",
  "category": "internacional",
  "source_name": "El País"
}
```

## Limitaciones conocidas (pendientes de fases posteriores)

1. **Desbalance de volumen entre fuentes.** El País aporta ~51% del total de items (~142 de ~280), frente a ~9% de El Mundo o ABC. Sin corrección, esto podría sobrerrepresentar editorialmente a El País en el briefing final. Pendiente de abordar en la fase Quality Filter (posible límite de items por fuente antes de Clustering).

2. **Categoría inconsistente entre fuentes.** El País declara categoría fija por feed (definida en el `Set` node). elDiario.es, El Mundo y ABC usan un único feed de "portada" con categoría fija `"portada"` en el dato de origen, aunque ABC sí trae categoría real por item en su RSS (sin usar todavía). La categorización real y consistente entre fuentes se resolverá en la fase 8 (Categorización, vía LLM).

3. **Sin deduplicación entre ejecuciones.** Cada ejecución del workflow trae los items actuales del feed, sin memoria de qué ya se procesó en ejecuciones anteriores. Necesario antes de considerar ejecuciones múltiples al día (mañana/mediodía/noche) — requiere una tabla en Postgres para persistir qué artículos (por URL o `guid`) ya se incluyeron en un briefing.

4. **"Múltiples fuentes" no garantiza ausencia de sesgo**, solo corrobora que un hecho ocurrió y reduce el riesgo de depender del enfoque de una sola redacción. No equivale a verificación neutral objetiva. Es una limitación estructural a tener presente al diseñar el futuro filtro de Quality Filter.

## Cómo depurar esta fase

1. Ejecutar el workflow manualmente.
2. Revisar el output del `Split Out` — debe haber 8 items (uno por fuente/feed).
3. Revisar el output del `RSS Feed Read` en crudo, por fuente — comprobar nombres de campo reales antes de asumir nada (usar la vista JSON `{}`, no solo la tabla).
4. Revisar el output de `Edit Fields` — confirmar ausencia de `null`/vacíos en `raw_summary`.
5. Para conteos por fuente, añadir temporalmente un nodo `Summarize` (agrupar por `source_name`, función `count`) y borrarlo después de anotar los números.
