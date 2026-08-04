# 05 · Análisis LLM

## Objetivo

Tomar los clusters de artículos (mismo acontecimiento, múltiples fuentes) que produce la fase 04 y generar, por cluster, un análisis estructurado y conciso: qué ha pasado, por qué importa, qué impacto tiene, qué hechos confirman todas las fuentes, qué es interpretación de una fuente concreta, y qué discrepancias factuales hay entre medios. Es el input que consumirá la fase 08 (Briefing Builder) para construir el resumen final.

## Arquitectura

### Filtro estructural antes del LLM: solo clusters multi-fuente

Antes de llamar al LLM, un nodo IF descarta los clusters con `source_count < 2`. No tiene sentido "comparar fuentes" cuando solo hay una, y evita gastar cómputo caro (cada llamada al LLM tarda minutos, corriendo por CPU) en la mayoría de artículos del día, que son de fuente única. Las piezas de fuente única quedan sin analizar por ahora — la fase 06 (Quality Filter) decidirá más adelante si alguna merece un tratamiento distinto (p. ej. detectar exclusivas de investigación).

Como 04-clustering no persiste identidad de evento entre ejecuciones (recluster desde cero cada vez, ver `docs/04-clustering.md`), un artículo que hoy es de fuente única y mañana gana una segunda fuente no se pierde: la siguiente ejecución de 04 lo agrupará de nuevo y esta vez sí pasará el filtro.

### Motor: de Ollama self-hosted a Groq (nivel gratuito)

**Elección inicial — Ollama self-hosted, sin API de pago:** mismo razonamiento que en embeddings (fase 04), coherencia con el stack 100% self-hosted, coste $0. A diferencia de embeddings, esta tarea sí requiere juicio (separar hechos de interpretación, detectar discrepancias) y no solo álgebra vectorial, así que la elección del modelo concreto importó mucho más.

**Modelos locales probados, con datos reales:**

| Modelo | Tiempo/cluster (CPU) | Resultado |
|---|---|---|
| `deepseek-r1:8b` (destilado de razonamiento) | 238s prompt simple; >15 min con instrucciones de auto-verificación (canceladas) | JSON con comas finales inválidas. Se creyó que alucinaba un dato ("10.000 hectáreas") — **corregido más abajo**, era un fallo de verificación propio, no del modelo. |
| `qwen2.5:14b-instruct` | 108-189s sin contención; hasta 900s+ bajo contención de CPU real (ver más abajo) | JSON válido, todos los campos rellenos, detectó correctamente una discrepancia real ya documentada (9 vs. 10 muertos). Requirió subir la RAM de Docker Desktop a ~12-14GB. |

**Corrección importante sobre `deepseek-r1:8b`:** el motivo original para descartarlo fue que "inventaba" datos no presentes en las fuentes (una cifra de hectáreas quemadas, días transcurridos). Verificando de nuevo con más cuidado, se descubrió que el contenido de `elDiario.es` en `normalized_articles` tiene entidades HTML sin decodificar (`hect&aacute;reas` en vez de `hectáreas`) — un problema separado y ya conocido de la fase 02. Las búsquedas de verificación (`grep`) no tenían en cuenta esas entidades, así que un dato que **sí estaba** en el texto fuente parecía inventado. `deepseek-r1:8b` probablemente nunca alucinó ese dato en concreto. Se deja constancia porque cambia la evidencia con la que se tomó una decisión, aunque no cambia la decisión final de motor (que se tomó por otras razones, ver abajo).

**Por qué se abandonó Ollama local igualmente (no por alucinaciones, por infraestructura):** con datos reales de producción (~8-16 clusters/ventana de 24h) surgieron dos problemas de fondo, no de calidad sino de fiabilidad operativa:

1. **Contención de CPU compartida**: la máquina de desarrollo corre Ollama junto a VS Code, Chrome, etc. La velocidad de generación cayó de ~7 tokens/segundo a ~0.1-0.5 tokens/segundo bajo carga (load average de 17-20 en una máquina de 10 núcleos), llevando llamadas normales de 100-200s a superar los 900s de timeout.
2. **No escala con más fuentes**: no hay margen de CPU para paralelizar (confirmado: Docker ya usa los 10 núcleos del host al completo). Más fuentes = más clusters = más tiempo total, de forma estrictamente lineal, sin ninguna palanca de hardware disponible en este equipo.

**Motor final: Groq**, nivel gratuito, modelo `llama-3.3-70b-versatile`. Sigue siendo un modelo open-weight (no propietario, coherente con la filosofía de `bge-m3`/`qwen2.5`), pero corre en hardware dedicado de Groq en vez de la CPU compartida del portátil — mismas llamadas que tardaban 100-900s en local tardan **0.9-1.4s**. Validado con los mismos dos clusters de prueba (helicópteros en Grecia, ataque a Kiev): sin alucinaciones detectadas (esta vez con una verificación que sí decodifica entidades HTML), misma discrepancia real (9 vs. 10 muertos) detectada correctamente.

La autenticación vive en una credencial de n8n (`Groq API`, tipo `httpHeaderAuth`), nunca en los parámetros del nodo — así la API key no queda en texto plano dentro de `workflows/05-llm-analysis.json`, que sí se versiona en git.

`qwen2.5:14b-instruct` y el modelo de embeddings `bge-m3` siguen instalados/en uso en el Ollama local — `bge-m3` porque la fase 04 (embeddings) no tiene los mismos problemas de contención (llamadas cortas, no comparables a generar cientos de tokens de análisis); `qwen2.5:14b-instruct` quedó sin usar, candidato a borrarse (`ollama rm qwen2.5:14b-instruct`, libera ~9GB) si no se vuelve a necesitar un motor local de respaldo.

### Prompt: instrucción explícita contra conocimiento paramétrico

Además de pedir el JSON con el esquema exacto, el prompt incluye instrucciones dirigidas específicamente al fallo observado en las pruebas: le dice al modelo que probablemente ya conoce el suceso (o uno similar) de su entrenamiento, que ignore ese conocimiento por completo, y le da un ejemplo concreto de qué NO hacer (inventar una cifra de hectáreas quemadas por analogía con incendios similares). No es una instrucción genérica de "no alucines" — apunta al patrón de fallo real que se midió.

Se evitó pedirle al modelo que "compruebe mentalmente" cada dato antes de escribirlo: con `deepseek-r1` (modelo de razonamiento) esa instrucción disparó un bloque de pensamiento interno mucho más largo, multiplicando el tiempo de inferencia por 4-5x sin confirmar si mejoraba la fiabilidad. `qwen2.5:14b-instruct` no tiene ese modo de razonamiento explícito, así que no aplica del mismo modo, pero se mantuvo el prompt conciso por rendimiento.

### Parseo robusto de la respuesta

El Code node que parsea la respuesta del LLM:
- Quita cualquier bloque `<think>...</think>` si el modelo lo incluye (relevante si en el futuro se vuelve a un modelo de razonamiento).
- Quita comas finales antes de `}` o `]` (manía de formato común en LLMs, JSON inválido en sentido estricto).
- Si tras esto el JSON sigue sin ser parseable, o faltan campos requeridos del esquema, **lanza un error explícito** con un fragmento de la respuesta cruda — nada de fallback silencioso que devuelva un análisis vacío o inventado.

## Resiliencia: un cluster lento o fallido no tumba el resto del batch

Estos mecanismos se diseñaron mientras el motor era Ollama local, donde una ejecución completa podía tardar 30-50 minutos y una petición huérfana podía quedar consumiendo CPU en segundo plano tras superar su timeout (así falló la primera ejecución real del workflow, encadenada en n8n). Con Groq (respuestas en ~1-2s) el riesgo de timeout/cola es mucho menor, pero los mecanismos se mantienen como red de seguridad — un fallo de red puntual sigue siendo posible con cualquier motor:

- **Timeout** (60s en Groq — antes 900s con Ollama, para absorber esperas en cola) en "Call Groq for Analysis".
- **Batching** (1 petición cada 2s) en el mismo nodo: el nivel gratuito de Groq limita tokens/minuto (`x-ratelimit-limit-tokens: 12000` en las cabeceras de respuesta), y disparar las 5 llamadas del lote casi a la vez lo supera — visto en producción ("Try spacing your requests out using the batching settings under 'Options'"). Sigue siendo órdenes de magnitud más rápido que Ollama local.
- **`retryOnFail`** (2 intentos): un fallo puntual de red/timeout se reintenta antes de darlo por perdido.
- **`onError: continueErrorOutput`**: si aun así falla, ese cluster concreto no detiene el workflow — su fallo se enruta a una rama de error separada (`Handle Groq Call Failure`).
- **`Parse & Validate LLM Response` nunca lanza una excepción que mate el batch**: cada item se parsea en su propio try/catch; si el JSON de un cluster no es válido, ese cluster se marca `status: 'error'` con el motivo, y el resto de items del array se procesan con normalidad. Antes, un solo fallo de parseo interrumpía los demás.
- **Persistencia en Postgres** (`cluster_analysis`, ver `db/schema.sql`): cada cluster analizado (o fallido) se inserta como registro propio, en vez de devolver todo junto como salida final del workflow. Matiz importante: n8n pasa los datos de un nodo a otro solo cuando ese nodo termina con *todos* sus items — no es streaming literal cluster a cluster mientras se generan. Protege bien contra el caso más probable (que un cluster falle no debe perder ni corromper el resto), pero no contra una caída total del workflow a mitad de la lista.

**Bug real encontrado y corregido en esta parte:** al dividir los items en rama de éxito/error, n8n reindexa cada rama desde 0. La primera versión de `Parse & Validate LLM Response` y del nodo de manejo de errores usaba esa posición local para buscar la metadata del cluster (`$('Build Prompt per Cluster').all()[idx]`), atribuyendo el análisis al cluster equivocado en cuanto una ejecución tenía fallos mezclados con éxitos. Corregido usando `itemMatching(idx)`, el mecanismo nativo de n8n para resolver el item de origen real vía `pairedItem` en vez de por posición.

## Procesamiento en cola: por qué no se analizan todos los clusters de golpe

04-clustering no persiste identidad de evento entre ejecuciones (repasa el problema en `docs/04-clustering.md`), así que no hay un `cluster_id` estable entre una corrida y la siguiente. Eso descarta una cola "marca este cluster como hecho" clásica. En su lugar, la identidad estable que sí existe es el `link` de cada artículo (columna `UNIQUE` en `normalized_articles`), y sobre eso se construyó el filtro:

- **`Get Already-Analyzed Links`**: query de una sola vez (`executeOnce`) que trae los links que ya tienen un análisis `status='ok'` en las últimas 48h.
- **`Filter Unanalyzed Clusters`**: descarta un cluster solo si **todos** sus artículos ya están cubiertos por un análisis previo exitoso. Si una fuente nueva se suma a un evento ya analizado, el cluster se vuelve a procesar (para capturar la fuente nueva) — no hay lógica de "solo lo delta", se re-analiza el cluster completo, aceptando algo de trabajo redundante a cambio de simplicidad.
- **`Limit Batch Size (5/run)`**: tope fijo de clusters por ejecución, activo siempre (a diferencia del límite de 2 para desarrollo, que está desactivado por defecto). Con esto, ninguna ejecución individual queda a merced de "cuántos clusters haya hoy" — procesa como mucho 5 y termina, quedando el resto para la siguiente vez que se dispare el workflow.

**Bug encontrado al probarlo por primera vez:** cuando `cluster_analysis` está vacía (o no hay links recientes), `Get Already-Analyzed Links` devuelve 0 filas — y por defecto, n8n no propaga la ejecución a los nodos siguientes cuando un nodo produce 0 items. Resultado: la rama entera se paraba en silencio ahí, sin analizar nada, sin error visible (ejecución "success" en ~1s, `cluster_analysis` seguía vacía). Mismo patrón que `Call '03-deduplication'` en 04-clustering — corregido igual, con `alwaysOutputData: true` en el nodo, para que un resultado vacío no corte la cadena.

Esto convierte 05 en un procesador de cola: da igual si hoy hay 8 clusters o 80, cada ejecución avanza un bloque acotado y nunca hay una carrera contra el tiempo dentro de una sola corrida. La fase 00 (Trigger/Schedule), todavía sin diseñar, será la que decida cada cuánto se dispara — con esto ya construido, dispararlo cada 10-15 minutos drenaría la cola de forma natural.

### Auto-encadenado: drenar la cola entera sin re-ejecutar a mano

Tras `Insert Cluster Analysis`, `More Unanalyzed Than This Batch?` comprueba si `Filter Unanalyzed Clusters` encontró más clusters de los que cupieron en este lote (`> 5`). Si es así, `Call '05-llm-analysis' Again` se llama a sí mismo (referencia al propio workflow) para procesar el siguiente lote; si no, `Queue Drained - Stopping` termina la cadena. Un solo disparo manual (o, en el futuro, un único disparo programado) drena toda la cola disponible ese día, en lotes de 5, hasta vaciarla o toparse con el límite diario — lo que llegue antes. Acotado de forma natural por dos condiciones de parada independientes (cola vacía, tope de 25), sin riesgo de recursión infinita.

`More Unanalyzed Than This Batch?` tiene `executeOnce: true` — no por necesidad estricta (`Insert Cluster Analysis` ya converge a un único item de salida pase lo que pase), pero es una salvaguarda barata dado que su condición no depende de qué item concreto llegue.

### Tope duro diario, calibrado contra los límites reales de Groq (no un número arbitrario)

Antes de `Limit Batch Size`, `Count Groq Calls Today` cuenta cuántas filas tiene `cluster_analysis` en las últimas 24h; si son **25 o más**, el nodo `Under Daily Cap?` corta la rama entera hacia `⛔ Daily Cap Reached - Skipping Groq` y no se hace ninguna llamada más ese día. No depende de que Groq rechace peticiones por su cuenta — es un límite propio, verificado en Postgres antes de gastar ni una llamada.

**Por qué 25 y no otro número:** el panel de Groq (`console.groq.com/settings/limits`) documenta los límites reales del nivel gratuito para `llama-3.3-70b-versatile`: **30 peticiones/minuto, 1.000 peticiones/día, 12.000 tokens/minuto, 100.000 tokens/día**. Con ~2.500-3.500 tokens por análisis (prompt + respuesta), el límite de tokens/día es el que manda: 100.000 ÷ ~3.000 ≈ **33 análisis/día como máximo real**. El tope de n8n se puso en 25 para quedar por debajo de ese techo con margen, no en un número redondo arbitrario — la primera versión de este tope (200) no tenía esto en cuenta y era irreal.

**Sin tarjeta de pago asociada a la cuenta de Groq, no hay manera técnica de que se genere un cargo real** — el panel de Groq lo confirma explícitamente ("Projected cost calculation as if you were enrolled in billing. You will not be billed until you upgrade"). El límite real a vigilar no es de coste, es de **capacidad diaria** (~33 análisis/día con este modelo) — sí es relevante de cara a añadir bastantes más fuentes, ver "Mejora futura".

## Implementación

**Flujo de nodos:**
```
Execute Workflow Trigger
  → Call '04-clustering'
  → Filter Multi-Source Clusters (IF: source_count >= 2)
      true  → Get Already-Analyzed Links (Postgres, executeOnce)
            → Filter Unanalyzed Clusters
            → Limit Batch Size (5/run)
            → Build Prompt per Cluster
            → ⚠️ DEV ONLY - Limit to 2 Clusters (desactivado por defecto, ver abajo)
            → Call Groq for Analysis (llama-3.3-70b-versatile, retryOnFail, onError: continueErrorOutput)
                success → Parse & Validate LLM Response ─┐
                error   → Handle Groq Call Failure ──────┤
                                                          ▼
                                            Insert Cluster Analysis (Postgres)
      false → Single Source - Skipped for Now (NoOp)
```

### Nodo "⚠️ DEV ONLY - Limit to 2 Clusters"

Nodo `Limit` insertado a propósito entre `Build Prompt per Cluster` y `Call Ollama for Analysis`, **desactivado por defecto** (n8n enruta automáticamente alrededor de un nodo desactivado, como si no existiera). Sirve para comprobar que el cableado del workflow funciona sin esperar 30-50 minutos por los 16 clusters reales — actívalo (un clic) solo durante desarrollo/depuración, nunca para una ejecución real, o truncará silenciosamente el análisis del día a 2 clusters.

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

**Salida de "Parse & Validate LLM Response" / "Handle Groq Call Failure":** un ítem por cluster, éxito o error — ambas ramas convergen en el mismo formato antes de `Insert Cluster Analysis`.
```json
{
  "cluster_id": 0,
  "source_count": 2,
  "sources": ["El País", "elDiario.es"],
  "articles": [ { "title": "...", "link": "...", "source_name": "...", "category": "..." } ],
  "analysis": { /* esquema de arriba, o null si status='error' */ },
  "status": "ok",
  "error_message": null
}
```

**Tabla `cluster_analysis`** (persistencia incremental, ver `db/schema.sql`): mismo contenido que el JSON de arriba, un registro por cluster procesado. Sin `UNIQUE` sobre `cluster_id` — no es un identificador estable entre ejecuciones de 04-clustering, así que es un log append-only, no una tabla de estado.

**Concisión sin sobre-resumir:** el prompt pide 1-3 frases directas por campo de texto, explícitamente sin sacrificar información necesaria para entender el hecho — no es una instrucción de "acorta al máximo", es evitar relleno/rodeos mientras se mantiene la sustancia. Igual con los arrays (`hechos_confirmados`, `discrepancias`, etc.): tantos elementos como estén respaldados por el texto, sin tope arbitrario.

**Truncado del contenido enviado al LLM:** cada artículo se recorta a los primeros 2000 caracteres de `content` antes de entrar al prompt. Es una medida pragmática de tamaño de contexto/latencia, no una decisión de calidad — algunas fuentes (El Mundo, ~174 caracteres de media) apenas dan un titular ampliado, mientras otras (elDiario.es, ABC) frecuentemente superan los 2000 caracteres reales. Ver "Mejora futura".

## Validación

**Con Ollama local** (histórico, ver tabla de modelos arriba): probado manualmente contra dos clusters reales, llamando a Ollama con el mismo prompt que construye el Code node.

**Primera ejecución real completa dentro de n8n** (encadenando `04` → `05`, 16 clusters multi-fuente en la ventana de 24h, todavía con Ollama): falló en la llamada al LLM con `ECONNABORTED` al superar el timeout (400s de entonces). Diagnóstico contra los logs de Ollama: no fue que ese cluster en concreto fuera lento (repetido de forma aislada, terminó en 68s limpio) — fue una petición huérfana anterior todavía consumiendo CPU en la cola. Una ejecución posterior, ya con timeout de 900s, sí completó pero con contención de CPU real (load average 17-20) causando generación a 0.1-0.5 tokens/s — confirmó que el problema era de infraestructura compartida, no del workflow, y motivó la migración a Groq.

**Con Groq** (`llama-3.3-70b-versatile`): revalidado contra los mismos dos clusters de prueba, esta vez con una verificación de alucinaciones corregida (decodificando entidades HTML antes de comparar contra el texto fuente, ver corrección más arriba):

1. **Helicópteros en Grecia** (El País, elDiario.es, ABC): sin alucinaciones detectadas; 1.4s.
2. **Ataque a Kiev** (El País, elDiario.es): detectó correctamente la discrepancia real de cifras (9 vs. 10 muertos); 0.9s.

**Validación end-to-end en n8n, con Groq + cola:** dos ejecuciones consecutivas reales sobre los mismos 8 clusters multi-fuente de la ventana de 24h:
- Ejecución 1: `Get Already-Analyzed Links` trae 0 (tabla vacía) → los 8 clusters pasan el filtro → tope de 5 → analiza 5 (2-3s totales).
- Ejecución 2 (inmediatamente después, sin cambios en la ventana): `Get Already-Analyzed Links` trae 11 (los links de los 5 clusters ya analizados) → `Filter Unanalyzed Clusters` descarta esos 5 y deja los 3 restantes (8 − 5 = 3) → tope de 5 no actúa (3 < 5) → analiza los 3 (2-3s).

Confirma que la cola no repite trabajo entre ejecuciones. Un cluster de la segunda ejecución falló por límite de tasa de Groq (ver batching arriba) — se registró como `error` sin afectar a los otros dos, confirmando también la resiliencia por item.

## Mejora futura

- **El tope diario real de Groq (~33 análisis/día con `llama-3.3-70b-versatile`, nivel gratuito) puede quedarse corto al añadir más fuentes.** Con el volumen actual (8-20 clusters multi-fuente/ventana de 24h) hay margen, pero no mucho. Opciones si se necesita más capacidad, sin gastar dinero: modelos con techo diario de tokens más alto en el mismo nivel gratuito de Groq (`llama-3.1-8b-instant`: 500K tokens/día, `openai/gpt-oss-120b`: 200K tokens/día — a costa de recalibrar y re-validar alucinaciones con el modelo nuevo, igual que se hizo aquí), o recortar más el contenido enviado por artículo para bajar el gasto por llamada.
- **Bug en fase 02 (normalización): entidades HTML sin decodificar.** El `content` de `elDiario.es` (y posiblemente otras fuentes) guarda `&aacute;`, `&oacute;`, etc. en vez de los caracteres reales — encontrado al verificar alucinaciones del LLM (ver corrección arriba). No afecta gravemente al LLM (los entiende igual), pero sí a cualquier verificación por texto y a la calidad visual si este contenido se muestra alguna vez sin pasar por un LLM. Corregible en `02-normalization` con un `decode` de entidades HTML al limpiar el HTML crudo.
- **Extracción de contenido completo** (Mozilla Readability, ya anotado como pendiente desde la fase 01): el recorte a 2000 caracteres de un RSS-teaser corto (El Mundo) da al LLM mucho menos con qué trabajar que fuentes con contenido más largo — no es un recorte equilibrado entre fuentes.
- **Distinguir "discrepancia de precisión" de "discrepancia factual real"** en el esquema: hoy ambas caen en `discrepancias`, pero una es que una fuente da menos detalle (no necesariamente contradice) y otra es un dato directamente distinto (9 vs. 10 muertos).
- Revisar si el filtro `source_count >= 2` debe convertirse en un umbral configurable compartido con la fase 06, en vez de vivir solo en 05.
- Medir el tiempo total de un batch diario completo de clusters multi-fuente una vez haya varios días de datos acumulados, para confirmar que el pipeline completo cabe en una ventana nocturna razonable.
