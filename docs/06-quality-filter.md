# 06 · Quality Filter

## Objetivo

Tomar las piezas de fuente única (`source_count = 1`) que 04-clustering produce pero que 05 no analiza (no tiene con qué comparar), y decidir cuáles tienen valor noticioso real para una sección secundaria del briefing, categorizarlas y resumirlas en hechos puros — sin interpretaciones ni relleno.

Junto con 05, cierra las dos mitades del producto: un briefing principal (clusters multi-fuente, con comparación entre medios) y uno secundario (piezas de fuente única, filtradas por valor, organizadas por tema).

## Arquitectura

### Alcance frente al roadmap original

El roadmap inicial separaba esto en fase 06 (filtro estructural) y 07 (categorización). En la práctica, el filtro estructural por número de fuentes (`source_count >= 2`) ya vive en la fase 05 por eficiencia — evita gastar LLM en piezas que no se van a comparar. Lo que queda para las piezas de fuente única es un único juicio editorial: ¿vale la pena, de qué trata, qué dice exactamente? Las tres preguntas se resuelven en una misma llamada al LLM.

06 y 05 son independientes entre sí: cada una llama a 04-clustering por su cuenta y se queda solo con la rama que le corresponde (multi-fuente para 05, fuente única para 06) — no hay solape ni trabajo compartido.

### Motor: Groq (`llama-3.1-8b-instant`) — modelo distinto al de 05

Mismo proveedor que 05, pero un modelo con presupuesto diario mayor, por una razón de volumen: 05 procesa decenas de clusters multi-fuente por ventana de 24h; 06 procesa cientos de piezas de fuente única. El modelo de 05 (`llama-3.3-70b-versatile`) tiene un tope de 100.000 tokens/día, insuficiente aquí. `llama-3.1-8b-instant` ofrece 500.000 tokens/día, a cambio de un límite por minuto más ajustado — compensado agrupando varios artículos por llamada.

Validado con datos reales antes de elegir: mismo resultado (qué se incluye/excluye) que el modelo de 05 sobre la misma muestra de artículos, sin datos inventados en ninguno de los dos. Al ser equivalente en calidad, se eligió el modelo con presupuesto diario acorde al volumen real.

### Agrupar artículos por llamada

Con cientos de piezas al día, una llamada por artículo sería cara en tokens y lenta. Los artículos sin procesar se agrupan en lotes de 8 antes de construir el prompt; cada lote es una única llamada que devuelve un array JSON con una decisión por artículo (`indice`, `incluir`, `categoria`, `resumen_hechos`).

### Cola con clave estable

A diferencia de 05 (donde la cola usa el `link` de los artículos porque `cluster_id` no es estable entre ejecuciones), aquí cada pieza de fuente única *es* directamente un artículo de `normalized_articles`, con un `link` permanente — no hace falta ventana de tiempo. Una vez que un artículo tiene un registro `status='ok'` en `secondary_briefing_items` (incluido o excluido, da igual), no se vuelve a evaluar.

### Resiliencia y auto-encadenado

Mismo patrón que 05: reintentos y rama de error separada en la llamada a Groq; si un lote entero falla, todos sus artículos se registran como `status='error'` (reintentables, sin perderse ni colarse como "ya procesados"); atribución de resultados por `itemMatching()` en vez de por posición.

Procesa **1 lote por ejecución**, con una espera de 40 segundos antes de auto-encadenar el siguiente — necesaria porque el límite de tokens/minuto de este modelo es más ajustado que el de 05, y el espaciado entre peticiones dentro de un mismo nodo no frena el salto entre ejecuciones recursivas distintas. Tope diario de 400 artículos, calibrado con margen bajo el techo real del modelo (~1.100 artículos/día), contando solo intentos completados con éxito.

## Implementación

**Flujo de nodos:**
```
Execute Workflow Trigger
  → Call '04-clustering'
  → Filter Single-Source Clusters (IF: source_count == 1)
      true  → Extract Single Article
            → Get Already-Processed Links (Postgres, executeOnce)
            → Filter Unprocessed Articles
            → Count Items Processed Today (Postgres, executeOnce)
            → Under Daily Cap? (<400)
                true  → Restore Unprocessed List
                      → Chunk into Batches of 8
                      → Limit Batch Count (1/run)
                      → Build Prompt per Batch
                      → ⚠️ DEV ONLY - Limit to 1 Batch (desactivado por defecto)
                      → Call Groq for Filtering (llama-3.1-8b-instant, retryOnFail, continueErrorOutput)
                          success → Parse & Validate Batch Response ─┐
                          error   → Handle Groq Call Failure ────────┤
                                                                      ▼
                                                    Insert Secondary Briefing Items (Postgres)
                                                                      ▼
                                          More Unprocessed Than This Batch?
                                              true  → Wait 40s Before Next Batch → Call '06-quality-filter' Again (self)
                                              false → Queue Drained - Stopping
                false → ⛔ Daily Cap Reached - Skipping Groq
      false → Multi-Source - Handled by 05 (NoOp)
```

**Esquema de salida por artículo (JSON del LLM, dentro del array `articulos`):**
```json
{
  "indice": 0,
  "incluir": true,
  "categoria": "tecnologia",
  "resumen_hechos": "..."
}
```

Categorías fijas: `internacional, economia, tecnologia, ciencia, espana, cultura, deportes, sociedad`. El LLM asigna siempre una de esta lista porque las categorías del RSS de origen no son fiables — solo El País las etiqueta con sentido; el resto de fuentes marcan casi todo como `portada`.

**Tabla `secondary_briefing_items`** (ver `db/schema.sql`): un registro por artículo evaluado — `link, title, source_name, categoria, incluir, resumen_hechos, status, error_message, processed_at`. `incluir=false` con `status='ok'` es una exclusión decidida (no se reintenta); `status='error'` es un fallo técnico (sí se reintenta).

## Validación

Validado con datos reales en dos niveles:

1. **Calidad del filtro**: sobre una muestra deliberadamente mixta (noticia sustancial — hallazgo arqueológico, mercados, deporte — junto a contenido de relleno — trucos de limpieza, piezas de opinión), el modelo separa correctamente ambos grupos, sin datos inventados, en ambos modelos candidatos evaluados.
2. **Ejecución real completa en n8n**: cadena `04`→`06` contra el volumen real de piezas de fuente única (varios cientos), con auto-encadenado drenando la cola en sucesivas ejecuciones hasta el tope diario, sin que un fallo puntual de red afectara al resto del lote.

## Mejora futura

- Revisar el tamaño de lote (8) y el tope diario (400) con datos de varios días acumulados.
- `categoria` podría pasar de lista fija en el prompt a configuración en Postgres, cuando se añadan fuentes con temáticas no cubiertas por la lista actual.
- Cómo consumirá la futura fase 08 (Briefing Builder) esta tabla junto con `cluster_analysis` para montar las dos secciones del briefing final no está diseñado todavía.
