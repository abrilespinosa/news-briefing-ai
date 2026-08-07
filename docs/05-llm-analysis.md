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
- **1 cluster por ejecución, con 20s de espera antes de auto-encadenar el siguiente** (ver "Procesamiento en cola" más abajo): el nivel gratuito de Groq limita tokens/minuto, y el espaciado entre peticiones dentro de una misma ejecución no frena el salto a la siguiente ejecución recursiva — mismo problema y mismo arreglo que en 06-quality-filter.
- **`onError: continueErrorOutput`**: un fallo tras los reintentos no detiene el workflow — se enruta a una rama de error separada que registra el fallo sin perder el resto del lote.
- **Parseo aislado por item**: cada cluster se procesa en su propio try/catch; un JSON inválido marca ese cluster como `status: 'error'` sin interrumpir los demás.
- **Persistencia en Postgres** (`cluster_analysis`): cada cluster analizado (o fallido) se inserta como registro propio, no como salida final agregada del workflow completo.
- **Atribución de resultados por `itemMatching()`**, no por posición: al dividir los items en rama de éxito/error, n8n reindexa cada rama desde 0 — usar la posición local para localizar la metadata de origen atribuye el resultado al item equivocado en cuanto una ejecución mezcla éxitos y fallos. `itemMatching()` resuelve el item de origen real vía `pairedItem`.

## Procesamiento en cola

04-clustering no persiste identidad de evento entre ejecuciones, así que no hay un `cluster_id` estable de una corrida a otra — descarta una cola clásica de "marca este cluster como hecho". La identidad estable que sí existe es el `link` de cada artículo (`UNIQUE` en `normalized_articles`), y sobre eso se construyó el filtro:

- **`Get Already-Analyzed Links`**: los links que ya tienen un análisis `status='ok'` en las últimas 48h.
- **`Filter Unanalyzed Clusters`**: descarta un cluster solo si *todos* sus artículos ya están cubiertos por un análisis previo exitoso — si se suma una fuente nueva a un evento ya analizado, se reprocesa entero (se acepta algo de trabajo redundante a cambio de simplicidad).
- **1 cluster por ejecución**: ninguna ejecución queda a merced de cuántos clusters haya ese día.
- **Auto-encadenado con espera**: al terminar un cluster, el workflow comprueba si queda más por analizar; si es así, espera 20s (calibrado bajo el límite de 12.000 tokens/minuto de este modelo) y se llama a sí mismo para el siguiente — un solo disparo (manual o, en el futuro, programado) drena toda la cola disponible hasta vaciarla o alcanzar el tope diario. La espera entre ejecuciones recursivas es necesaria porque el espaciado interno de un nodo no frena el salto a la siguiente ejecución.
- **Tope diario de 30 análisis**, verificado en Postgres antes de gastar ninguna llamada, contando `status='ok'` y `status='superseded'` (esos tokens se gastaron) pero no `'error'`, para que un intento fallido y reintentable no consuma presupuesto del tope dos veces. La calibración está **medida, no estimada**: las respuestas de Groq traen su propio `usage`, y sobre clusters reales una llamada consume 2.558-3.307 tokens (~2.350 de prompt, ~640 de respuesta). Sobre los 100.000 tokens/día del nivel gratuito para este modelo son ~33 análisis de techo teórico; 30 deja margen para los clusters más grandes. El límite por minuto (12.000, leído de las cabeceras `x-ratelimit-limit-tokens`) no muerde: con un cluster por ejecución y 20s de espera se va al 60% de él.
- **El tope no aplaza trabajo, lo descarta.** 04 agrupa en una ventana de 24h, así que un cluster que se quede fuera del tope solo se recupera si sus artículos siguen dentro de esa ventana en la corrida siguiente. El 7 de agosto había 35 clusters multi-fuente en cola y el techo del nivel gratuito está en ~33: **el límite de Groq ya está por debajo del volumen que generan 8 fuentes.**
- **El corte del tope es el día natural UTC, no una ventana deslizante de 24h.** No es un detalle cosmético: con ventana deslizante el tope se vuelve **autobloqueante** en cuanto existe un trigger programado. Si el trabajo de un día se hace más tarde que la hora del cron —por ejemplo, análisis a las 09:22 con el `Schedule Trigger` a las 07:00—, la ventana de 24h todavía está llena cuando el cron dispara al día siguiente, la corrida se salta el análisis, y la situación se perpetúa indefinidamente. Se detectó en la primera corrida real del orquestador (ver `docs/00-orchestrator.md`), con 20 clusters pendientes bloqueados. El día natural UTC además coincide con el reset real del presupuesto diario de Groq, así que es el corte correcto por partida doble.

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
            → Under Daily Cap? (<30)
                true  → Restore Cluster List
                      → Limit Batch Size (1/run)
                      → Build Prompt per Cluster
                      → ⚠️ DEV ONLY - Limit to 2 Clusters (desactivado por defecto)
                      → Call Groq for Analysis (llama-3.3-70b-versatile, retryOnFail, continueErrorOutput)
                          success → Parse & Validate LLM Response ─┐
                          error   → Handle Groq Call Failure ──────┤
                                                                    ▼
                                                  Insert Cluster Analysis (Postgres)
                                                                    ▼
                                        More Unanalyzed Than This Batch?
                                            true  → Wait 20s Before Next Batch → Call '05-llm-analysis' Again (self)
                                            false → Queue Drained - Stopping
                false → ⛔ Daily Cap Reached - Skipping Groq
      false → Single Source - Skipped for Now (NoOp, tratado en 06)
```

**Esquema de salida del LLM (JSON):**
```json
{
  "que_paso": "string",
  "desarrollo": "string",
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

### Retirada de análisis obsoletos

El filtro de cola reanaliza un evento entero cuando se le suma una fuente nueva. Eso es deliberado —un análisis con 4 fuentes compara mejor que uno con 2— pero deja dos filas del mismo suceso en la tabla.

Esa segunda fila **no es un duplicado de entrada**: la deduplicación de artículos por `link` es la fase 03 y funciona (los links de ambas filas aparecen una sola vez en `seen_articles`). Lo que sobra es una *salida* que ha quedado obsoleta, y 03 no podría detectarlo aunque quisiera: se ejecuta antes que 04 y 05, cuando todavía no existe ningún cluster ni ningún análisis que pueda quedar reemplazado.

Quien sí lo sabe es 05, en el momento exacto de escribir. Por eso `Insert Cluster Analysis` no es un `INSERT` a secas sino un CTE que inserta y, en la misma sentencia, marca como `status='superseded'` (con `superseded_by` apuntando a la nueva fila) todo análisis previo que comparta algún link y no tenga más fuentes. Va en una sola sentencia y no en dos nodos porque un fallo entre insertar y retirar dejaría dos análisis vivos del mismo suceso.

- **Gana el análisis más rico, no el más reciente.** El criterio es `source_count`; la fecha solo desempata. Cuando 05 reprocesa, las fuentes del análisis viejo son un subconjunto de las del nuevo, así que retirarlo no pierde información.
- **Compartir un solo link basta** para considerarlos el mismo suceso: 04 asigna cada artículo a un único cluster por ejecución.
- **Los consumidores lo heredan gratis.** 07 y 08 ya filtran `status = 'ok'`, así que no necesitan ninguna lógica de deduplicación propia. Antes de esto, 07 llegó a gastar tokens categorizando las dos mitades de un mismo suceso.
- **El tope diario cuenta `'ok'` y `'superseded'`.** Esos tokens se gastaron de verdad; descontarlos del tope al retirar el análisis dejaría gastar por encima del presupuesto real de Groq.
- **`alwaysOutputData` en el nodo**: en el caso normal (sin duplicado que retirar) el `UPDATE` no afecta a ninguna fila y el nodo emitiría 0 items, cortando el auto-encadenado que cuelga justo detrás.

Esto trata el síntoma en la capa correcta, no la causa raíz: la razón de fondo es que 04 no persiste identidad de evento entre ejecuciones (ver `docs/04-clustering.md`). Mientras eso siga así, seguirán generándose análisis que otro reemplaza.

**El nodo emite cero filas siempre, no solo cuando no hay nada que retirar.** El CTE termina en un `UPDATE` sin `RETURNING`, así que el conjunto de resultados está vacío en toda inserción, incluidas las que sí retiran un duplicado. Es `alwaysOutputData` el único que mantiene vivo el auto-encadenado que cuelga justo detrás. Comprobado en producción: 30 inserciones consecutivas y 27 auto-llamadas sin que el bucle se cortara.

> **⚠️ La rama `UPDATE` sigue sin ejercitarse.** El SQL está validado contra datos de producción en una transacción revertida (retiró las dos filas correctas y ninguna otra), pero todavía no ha ocurrido en n8n un solapamiento que lo active. Hay una razón estructural, no un fallo: **con una corrida diaria y la ventana de 24h de 04, los clusters casi nunca cruzan ejecuciones.** La corrida del 7 de agosto a las 09:52 cubría artículos desde las 09:52 del día anterior, y los análisis del día 6 se hicieron a las 09:20-09:43 — sus artículos ya habían caído fuera. El duplicado que motivó este CTE apareció con varias corridas manuales el mismo día separadas por horas, que es cuando el escenario se da de verdad.

**Concisión sin sobre-resumir:** el prompt pide 1-3 frases directas por campo de texto, sin sacrificar información necesaria para entender el hecho — no es "acorta al máximo", es evitar relleno mientras se mantiene la sustancia. `desarrollo` es la única excepción (ver abajo).

### `desarrollo`: el cuerpo de la noticia, y por qué su extensión no es fija

El resto del esquema son fragmentos de análisis, no texto legible de corrido. Para que el briefing pudiera ofrecer algo más que un titular y una línea de contexto hizo falta un campo narrativo: `desarrollo`, el cuerpo de la noticia en prosa, con el detalle concreto que aporten las fuentes.

**El límite de extensión se calcula en el Code node a partir del material real de cada cluster**, no es una cifra fija en el prompt:

| Texto que aportan las fuentes | Techo |
|---|---|
| < 1.500 caracteres | 1 párrafo, 60 palabras |
| < 4.000 caracteres | 1-2 párrafos, 130 palabras |
| resto | 2-3 párrafos, 220 palabras |

Esto no es refinamiento gratuito: **un objetivo de longitud fijo produce invención, y se midió.** Con la instrucción "entre 150 y 220 palabras", un cluster con 14.959 caracteres de fuentes devolvió 135 palabras honestas, mientras que uno con 928 caracteres devolvió **166** — más texto a partir de dieciséis veces menos material. Entre ellas, esta frase: *"ha permitido al partido aumentar su visibilidad y atraer a nuevos votantes"*, que no aparece en ninguna de las dos fuentes del cluster, más un tercer párrafo que repetía el primero con otras palabras.

La lección es que **un objetivo de longitud convierte la extensión en la meta y la veracidad en el peaje**. El prompt pide ahora exhaustividad acotada —"incluye todos los hechos concretos que aparezcan en los textos y para cuando se te acaben; el número es un techo, no una cuota"— y prohíbe explícitamente deducir consecuencias que ninguna fuente afirma y cerrar con frases efectistas.

Con el techo proporcional, un cluster rico produce 146-168 palabras ancladas (organismos, normativas, horarios, cifras) y uno pobre produce menos de diez. **Esas diez palabras son el comportamiento correcto**: con dos teasers de RSS que solo dicen que un partido subió en las encuestas, no hay más hechos que contar. La fase 08 lo asume y no ofrece el desplegable "Ver más" cuando el desarrollo no llega a 25 palabras.

**Truncado de contenido:** cada artículo se recorta a los primeros 2.000 caracteres antes de entrar al prompt, por tamaño de contexto/latencia. El recorte casi nunca llega a activarse: lo que limita de verdad es cuánto entrega cada RSS, y ahí la diferencia entre fuentes es de dos órdenes de magnitud.

| Fuente | Caracteres de media que entrega el RSS |
|---|---|
| elDiario.es | 6.236 |
| ABC | 4.096 |
| 20minutos | 2.988 |
| El País | 689 |
| La Vanguardia | 421 |
| Europa Press | 296 |
| El Español | 271 |
| El Mundo | 174 |

Sobre una jornada real, 11 de 25 clusters reunían más de 3.000 caracteres y 6 se quedaban por debajo de 1.500. Un cluster de El Mundo y La Vanguardia le da al modelo unos 600 caracteres: sobre eso no hay análisis posible que no sea inventado. Es el techo real del pipeline y la razón de que la extracción de contenido completo esté en el roadmap.

## Validación

Validado con datos reales en tres niveles:

1. **Calidad del análisis**: contra clusters reales con discrepancias ya documentadas manualmente (ej. cifras de víctimas distintas entre dos medios sobre el mismo suceso) — el modelo las detecta y las señala correctamente, sin fabricar datos no presentes en las fuentes.
2. **Cola sin repetir trabajo**: dos ejecuciones consecutivas sobre la misma ventana — la primera analiza los clusters disponibles, la segunda detecta (por los links ya cubiertos) que la mayoría ya están hechos y solo procesa los pendientes.
3. **Resiliencia end-to-end**: un fallo puntual de red o límite de tasa en un cluster no afecta al resto del lote ni bloquea el auto-encadenado.

### El espaciado, medido contra su propio contraejemplo

El 6 de agosto una corrida produjo **25 análisis y 43 fallos 429**. El 7 de agosto, **30 análisis y 0 fallos**. La diferencia no está en los límites de Groq sino en el código: la versión del día 6 mandaba **5 clusters por tanda y no tenía nodo `Wait`**. Cinco llamadas simultáneas a ~3.000 tokens agotan de golpe los 12.000 tokens/minuto del modelo.

Con un cluster por ejecución y 20s de espera, la separación real medida entre auto-llamadas fue de 23-33 segundos (media 24) a lo largo de 27 iteraciones seguidas, sin un solo rechazo. Es la confirmación de que **el límite que muerde es tokens/minuto, no peticiones/minuto**: 1.000 peticiones/día no se rozan siquiera.

### El techo de `desarrollo` nunca llega a ser vinculante

Sobre los 30 análisis del 7 de agosto, agrupados por el tramo que les tocó:

| Techo | Clusters | Palabras (mín/media/máx) | Lo rebasan | Uso medio del techo |
|---|---|---|---|---|
| 60 | 3 | 5 / 9 / 15 | 0 | 14% |
| 130 | 12 | 26 / 37 / 48 | 0 | 28% |
| 220 | 15 | 33 / 122 / 201 | 0 | 55% |

**Ninguno lo rebasa y ninguno lo persigue.** Quitado el objetivo fijo, el modelo escribe lo que el material sostiene y el techo actúa como barandilla, no como meta — que era exactamente el objetivo del cambio. Los tres clusters del tramo bajo se quedan por debajo de las 25 palabras y por tanto no muestran desplegable "Ver más" en el briefing, que es el comportamiento correcto.

## Mejora futura

- **El tope diario de Groq ya se queda corto**, no "puede quedarse": ~33 análisis de techo frente a los 35 clusters multi-fuente que generaron 8 fuentes el 7 de agosto, y añadir fuentes lo agrava. Las palancas, en orden de coste: recortar el prompt (el 75% del gasto es entrada, así que truncar más el contenido compra clusters a costa de calidad de análisis), o pasar al nivel de pago. Bajar a un modelo más barato se descarta: 05 es donde vive el diferencial del proyecto.
- Extracción de contenido completo (Mozilla Readability) para que el recorte a 2.000 caracteres no penalice a las fuentes con teasers más cortos.
- Distinguir "discrepancia de precisión" (una fuente da menos detalle) de "discrepancia factual real" (un dato directamente distinto) en el esquema — hoy ambas caen en `discrepancias`.
- Revisar si el filtro `source_count >= 2` debe convertirse en un umbral configurable compartido con la fase 06.
