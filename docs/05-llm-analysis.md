# 05 · Análisis LLM

## Objetivo

Tomar los clusters multi-fuente que produce la fase 04 y generar, por cluster, un análisis estructurado y conciso: qué ha pasado, por qué importa, qué impacto tiene, qué hechos confirman todas las fuentes, qué es interpretación de una fuente concreta, y qué discrepancias factuales hay entre medios. Es el input que consumirá la futura fase 08 (Briefing Builder) para el briefing principal.

## Arquitectura

### Filtro estructural antes del LLM: solo clusters multi-fuente

Un nodo IF descarta los clusters con `source_count < 2` antes de llegar al LLM. No tiene sentido "comparar fuentes" cuando solo hay una, y evita gastar cómputo en la mayoría de artículos del día, que son de fuente única — esas piezas las trata la fase 06 por separado. Como 04-clustering no persiste identidad de evento entre ejecuciones (ver `docs/04-clustering.md`), un artículo de fuente única hoy que gane una segunda fuente mañana se reagrupa solo en la siguiente ejecución de 04.

### Motor: Groq (`llama-3.3-70b-versatile`), no self-hosted

La decisión inicial fue self-hosted (Ollama, coherente con el resto del stack), pero se descartó tras validar con datos reales de producción:

- **Contención de CPU compartida**: en la máquina de desarrollo, la generación caía de ~7 a ~0.1-0.5 tokens/segundo bajo carga de otras aplicaciones, llevando llamadas de 100-200s a superar cualquier timeout razonable.
- **No escala con más fuentes**: sin margen de CPU para paralelizar en local, más fuentes significa más tiempo de forma estrictamente lineal, sin ninguna palanca de hardware disponible.

Se migró a **Groq** (nivel gratuito, modelo `llama-3.3-70b-versatile`) — sigue siendo un modelo open-weight, pero corre en hardware dedicado: las mismas llamadas que tardaban 100-900s en local tardan ~1-2s. Validado con datos reales (comparación de fuentes sobre sucesos reales, incluyendo una discrepancia de cifras entre medios ya documentada) sin alucinaciones detectadas.

La autenticación vive en una credencial de n8n (`Groq API`, tipo `httpHeaderAuth`), nunca en los parámetros del nodo — la API key no queda en texto plano en `workflows/05-llm-analysis.json`, que sí se versiona en git.

### Prompt: instrucción explícita contra conocimiento paramétrico

El prompt no se limita a pedir el JSON con el esquema — instruye explícitamente al modelo a ignorar cualquier conocimiento previo que pueda tener sobre el suceso (o uno similar) de su entrenamiento, y a basarse únicamente en los textos proporcionados, con un ejemplo concreto de qué no hacer. Es una instrucción dirigida a un modo de fallo real y medido (un LLM completando datos plausibles de memoria en vez de ceñirse a la fuente), no una advertencia genérica de "no alucines".

### Parseo robusto de la respuesta

El Code node que interpreta la respuesta del LLM tolera manías de formato conocidas (bloques `<think>` de modelos de razonamiento, comas finales antes de `}`/`]`) antes de intentar el `JSON.parse`. Si aun así no es válido, o faltan campos requeridos del esquema, lanza un error explícito con un fragmento de la respuesta cruda — nunca un fallback silencioso que devuelva un análisis vacío o inventado.

## Resiliencia

Un cluster lento o fallido no debe tumbar el resto del lote:

- **Timeout de 60s** y **`retryOnFail`** (2 intentos) en la llamada a Groq.
- **Batching** (1 petición cada 2s): el nivel gratuito de Groq limita tokens/minuto: disparar varias llamadas casi a la vez lo supera.
- **`onError: continueErrorOutput`**: un fallo tras los reintentos no detiene el workflow — se enruta a una rama de error separada que registra el fallo sin perder el resto del lote.
- **Parseo aislado por item**: cada cluster se procesa en su propio try/catch; un JSON inválido marca ese cluster como `status: 'error'` sin interrumpir los demás.
- **Persistencia en Postgres** (`cluster_analysis`): cada cluster analizado (o fallido) se inserta como registro propio, no como salida final agregada del workflow completo.
- **Atribución de resultados por `itemMatching()`**, no por posición: al dividir los items en rama de éxito/error, n8n reindexa cada rama desde 0 — usar la posición local para localizar la metadata de origen atribuye el resultado al item equivocado en cuanto una ejecución mezcla éxitos y fallos. `itemMatching()` resuelve el item de origen real vía `pairedItem`.

## Procesamiento en cola

04-clustering no persiste identidad de evento entre ejecuciones, así que no hay un `cluster_id` estable de una corrida a otra — descarta una cola clásica de "marca este cluster como hecho". La identidad estable que sí existe es el `link` de cada artículo (`UNIQUE` en `normalized_articles`), y sobre eso se construyó el filtro:

- **`Get Already-Analyzed Links`**: los links que ya tienen un análisis `status='ok'` en las últimas 48h.
- **`Filter Unanalyzed Clusters`**: descarta un cluster solo si *todos* sus artículos ya están cubiertos por un análisis previo exitoso — si se suma una fuente nueva a un evento ya analizado, se reprocesa entero (se acepta algo de trabajo redundante a cambio de simplicidad).
- **Tope de 5 clusters por ejecución**: ninguna ejecución queda a merced de cuántos clusters haya ese día.
- **Auto-encadenado**: al terminar un lote, el workflow comprueba si queda más por analizar y, si es así, se llama a sí mismo para el siguiente lote — un solo disparo (manual o, en el futuro, programado) drena toda la cola disponible hasta vaciarla o alcanzar el tope diario.
- **Tope diario de 25 análisis**, calibrado contra el límite real de Groq para este modelo (100.000 tokens/día ÷ ~3.000 tokens/análisis), verificado en Postgres antes de gastar ninguna llamada — y contando solo `status='ok'`, para que un intento fallido y reintentable no consuma presupuesto del tope dos veces.

**Nota de n8n**: un workflow solo puede llamarse a sí mismo si está *publicado* (`active: true`) — llamar a otro workflow inactivo sí funciona, pero la auto-referencia no. Publicar exige además que toda la cadena de sub-workflows referenciados esté publicada también. Las seis fases del pipeline están publicadas por este motivo.

## Implementación

**Flujo de nodos:**
```
Execute Workflow Trigger
  → Call '04-clustering'
  → Filter Multi-Source Clusters (IF: source_count >= 2)
      true  → Get Already-Analyzed Links (Postgres, executeOnce)
            → Filter Unanalyzed Clusters
            → Count Groq Calls Today (Postgres, executeOnce)
            → Under Daily Cap? (<25)
                true  → Restore Cluster List
                      → Limit Batch Size (5/run)
                      → Build Prompt per Cluster
                      → ⚠️ DEV ONLY - Limit to 2 Clusters (desactivado por defecto)
                      → Call Groq for Analysis (llama-3.3-70b-versatile, retryOnFail, continueErrorOutput)
                          success → Parse & Validate LLM Response ─┐
                          error   → Handle Groq Call Failure ──────┤
                                                                    ▼
                                                  Insert Cluster Analysis (Postgres)
                                                                    ▼
                                        More Unanalyzed Than This Batch?
                                            true  → Call '05-llm-analysis' Again (self)
                                            false → Queue Drained - Stopping
                false → ⛔ Daily Cap Reached - Skipping Groq
      false → Single Source - Skipped for Now (NoOp, tratado en 06)
```

**Esquema de salida del LLM (JSON):**
```json
{
  "que_paso": "string",
  "por_que_importa": "string",
  "impacto": "string",
  "hechos_confirmados": ["string"],
  "interpretaciones": [{"fuente": "string", "afirmacion": "string"}],
  "discrepancias": [{"aspecto": "string", "version_por_fuente": {"<fuente>": "string"}}],
  "preguntas_abiertas": ["string"]
}
```

`hechos_confirmados` son solo los hechos en los que coinciden todas las fuentes citadas; `interpretaciones` marca juicios de valor o adjetivos calificativos atribuidos a una fuente concreta; `discrepancias` recoge datos distintos entre fuentes sobre el mismo hecho (una diferencia de precisión, como "misiles" vs. "misiles y drones", cuenta como discrepancia factual, no como interpretación); `preguntas_abiertas` es lo que ninguna fuente resuelve todavía.

**Tabla `cluster_analysis`** (ver `db/schema.sql`): un registro por cluster procesado — `cluster_id, source_count, sources, articles, analysis, status, error_message, analyzed_at`. Sin `UNIQUE` sobre `cluster_id` (no es estable entre ejecuciones de 04): es un log append-only, no una tabla de estado.

**Concisión sin sobre-resumir:** el prompt pide 1-3 frases directas por campo de texto, sin sacrificar información necesaria para entender el hecho — no es "acorta al máximo", es evitar relleno mientras se mantiene la sustancia.

**Truncado de contenido:** cada artículo se recorta a los primeros 2.000 caracteres antes de entrar al prompt, por tamaño de contexto/latencia — no es un recorte equilibrado entre fuentes (algunas dan mucho menos que otras, ver "Mejora futura").

## Validación

Validado con datos reales en tres niveles:

1. **Calidad del análisis**: contra clusters reales con discrepancias ya documentadas manualmente (ej. cifras de víctimas distintas entre dos medios sobre el mismo suceso) — el modelo las detecta y las señala correctamente, sin fabricar datos no presentes en las fuentes.
2. **Cola sin repetir trabajo**: dos ejecuciones consecutivas sobre la misma ventana — la primera analiza los clusters disponibles, la segunda detecta (por los links ya cubiertos) que la mayoría ya están hechos y solo procesa los pendientes.
3. **Resiliencia end-to-end**: un fallo puntual de red o límite de tasa en un cluster no afecta al resto del lote ni bloquea el auto-encadenado.

## Mejora futura

- El tope diario real de Groq para este modelo (~33 análisis/día) puede quedarse corto según crezca el volumen de fuentes — hay margen en el nivel gratuito con otros modelos de mayor presupuesto diario (ver `docs/06-quality-filter.md`, que ya usa ese enfoque).
- Extracción de contenido completo (Mozilla Readability) para que el recorte a 2.000 caracteres no penalice a las fuentes con teasers más cortos.
- Distinguir "discrepancia de precisión" (una fuente da menos detalle) de "discrepancia factual real" (un dato directamente distinto) en el esquema — hoy ambas caen en `discrepancias`.
- Revisar si el filtro `source_count >= 2` debe convertirse en un umbral configurable compartido con la fase 06.
