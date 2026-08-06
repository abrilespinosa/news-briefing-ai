# 07 · Categorización

## Objetivo

Asignar una categoría temática a cada cluster multi-fuente ya analizado por 05, para que la fase 08 (Briefing Builder) pueda organizar el briefing principal por temas en vez de como una lista plana.

## Arquitectura

### Por qué existe esta fase (y por qué no la cubre 06)

06-quality-filter ya asigna categorías, pero **solo a la rama de fuente única**. Los clusters multi-fuente —el briefing principal, lo que 05 analiza— no pasan por 06 en ningún momento, así que nadie los categorizaba.

La categoría del RSS no sirve como sustituto, por dos motivos comprobados sobre los datos reales:

- **No es informativa**: 108 de 127 artículos en `cluster_analysis` llegan etiquetados como `portada`. Solo El País etiqueta con sentido; el resto de fuentes vuelca todo por un único feed de portada.
- **Está en el nivel equivocado**: es una etiqueta por artículo, pero un cluster es un único acontecimiento cubierto por varios medios. Un cluster de 4 fuentes puede traer 4 etiquetas distintas para el mismo hecho.

Por eso 07 asigna **una categoría por cluster**, no por artículo.

### Por qué una fase aparte y no un campo más en el prompt de 05

La alternativa obvia es añadir `categoria` al esquema JSON que ya devuelve 05: el modelo ya ha leído los artículos, así que el campo extra cuesta prácticamente cero tokens adicionales. Se descartó por dos razones concretas de este proyecto:

1. **No cubre lo ya analizado.** Recategorizar los análisis existentes exigiría re-analizarlos, y 05 corre sobre `llama-3.3-70b-versatile` con 100.000 tokens/día — un presupuesto que ya topa su cap de 25 análisis/día. Serían días de presupuesto quemados para obtener una etiqueta.
2. **Acopla la taxonomía al análisis.** Cambiar la lista de categorías obligaría a rehacer el análisis completo (caro) en vez de solo la categorización (barato).

Como fase independiente sobre un modelo barato, 07 cubre el histórico y lo nuevo con el mismo código, y es re-ejecutable sin tocar el presupuesto escaso de 05.

### Motor: Groq (`llama-3.1-8b-instant`)

Mismo modelo que 06, por la misma razón: presupuesto diario de 500.000 tokens frente a los 100.000 de 05. Aquí sobra de largo — categorizar 20 clusters cuesta ~3.000 tokens en total, porque el input por cluster son ~60 tokens.

### La entrada no es 05, es la tabla

07 **no** encadena con `Execute Workflow` a 05, a diferencia de cómo se encadenan las fases 01–04 entre sí. 05 no es una función que devuelva "los análisis del día": es un productor que drena una cola procesando 1 cluster por ejecución y auto-llamándose hasta vaciarla o topar el cap diario. Su valor de retorno es lo que emita el último nodo de la última ejecución recursiva, no el conjunto.

Lo que 05 sí garantiza es que todo análisis correcto queda escrito en `cluster_analysis`. **Esa tabla es el contrato entre ambas fases**, y 07 lee de ella. Es el mismo patrón productor/consumidor que ya separa a 05 de 06, aquí hecho explícito.

### La cola es la ausencia de valor

07 no necesita tabla de control ni columna de estado propia: su cola es literalmente `WHERE status = 'ok' AND categoria IS NULL`.

Un cluster que falle —por error de red, por respuesta no parseable o porque el modelo devolvió una categoría fuera de la lista— simplemente no recibe `UPDATE`, se queda en `NULL` y vuelve a entrar solo en la siguiente ejecución. Nada que reconciliar, y ningún riesgo de marcar como hecho algo que no lo está.

El coste de esta simplicidad es que un cluster que falle sistemáticamente se reintentará de forma indefinida. A este volumen (~25 clusters/día, ~150 tokens por reintento) es un precio irrelevante frente a mantener una máquina de estados.

### Sin auto-encadenado ni tope diario, a propósito

05 y 06 procesan 1 unidad de trabajo por ejecución y se auto-llaman con un `Wait` intermedio, porque su coste por unidad es alto y su volumen los pone contra los límites de Groq. **07 no replica ese patrón**, y es una decisión, no un olvido: con ~25 clusters al día y ~60 tokens de input por cluster, todos los pendientes caben en una o dos llamadas dentro de una única ejecución, espaciadas con el `batchInterval` del nodo HTTP —que sí funciona *dentro* de una ejecución; lo que no frena son los saltos entre ejecuciones recursivas distintas—.

Aplicar aquí el auto-encadenado sería añadir un `Wait`, un `IF` de cola restante y una llamada recursiva para resolver un problema que esta fase no tiene.

Lo que sí hay que respetar es el límite de Groq que de verdad muerde aquí, que **no es el de peticiones por minuto sino el de tokens por minuto**: `llama-3.1-8b-instant` admite 30 peticiones/minuto (irrelevante: son 1-3 llamadas) pero solo **6.000 tokens/minuto**, y un lote de 20 clusters gasta ~3.000. De ahí el `batchInterval` de 40 segundos: deja el consumo en ~4.500 tokens/minuto en el peor caso, con margen bajo el techo. El `waitBetweenTries` del reintento es de 20s por el mismo motivo — reintentar un 429 a los 5 segundos vuelve a chocar con la misma ventana.

### Taxonomía compartida con 06

Las categorías son la misma lista cerrada que usa 06: `internacional, economia, tecnologia, ciencia, espana, cultura, deportes, sociedad`. No es una coincidencia estética — si las dos ramas del briefing (principal y secundaria) no comparten taxonomía, la fase 08 no puede montar un documento coherente entre ambas.

El Code node valida contra esa lista tras normalizar acentos y mayúsculas (el modelo devuelve a veces `España` o `Economía` pese a que el prompt pide la forma sin tilde). Una categoría fuera de la lista no se escribe: se deja el cluster en cola en vez de forzar un valor inventado.

## Implementación

**Flujo de nodos:**
```
Execute Workflow Trigger
  → Get Uncategorized Clusters (Postgres, alwaysOutputData)
  → Has Clusters to Categorize? (IF: id existe)
      true  → Chunk into Batches of 20
            → Build Prompt per Batch
            → Call Groq for Categorization (llama-3.1-8b-instant, retryOnFail, continueErrorOutput)
                success → Parse & Validate Categories
                        → Update Cluster Categories (Postgres)
                        → Return Categorized Clusters
                error   → Handle Groq Call Failure → Batch Failed - Stays in Queue (NoOp)
      false → Nothing to Categorize (NoOp)
```

**Input del prompt por cluster:** el `que_paso` que 05 ya dejó escrito en `analysis`, más los titulares de las fuentes concatenados. Usar `que_paso` en vez del texto de los artículos es lo que hace la fase barata: ya es un resumen factual de una línea, mejor señal que un titular y dos órdenes de magnitud más corto que el artículo.

**Esquema de salida del LLM (JSON):**
```json
{
  "clusters": [
    { "indice": 0, "categoria": "internacional" }
  ]
}
```

**Columnas añadidas a `cluster_analysis`** (ver `db/schema.sql`): `categoria TEXT` y `categorized_at TIMESTAMPTZ`, ambas nullable. Enriquecer una fila existente con una etiqueta no contradice el carácter append-only de la tabla —no se reescribe el análisis, se completa—, y evita una tabla 1:1 y su join para no ganar nada.

**Atribución por `itemMatching()`**, no por posición: al dividirse la rama de éxito y la de error, n8n reindexa cada una desde 0, y la posición local dejaría de corresponder al lote de origen en cuanto una ejecución mezcle éxitos y fallos. Mismo problema ya resuelto en 05 y 06.

## Validación

El prompt se validó contra los 51 clusters reales de `cluster_analysis` antes de cablear la fase, comparando dos versiones sobre la misma muestra de 20:

- **v1** (solo criterios de desempate) acertó 18/20, con dos errores objetivos: una iniciativa de moneda local clasificada como `cultura` en vez de `economia`, y la retirada temporal de una cantante como `sociedad` en vez de `cultura`. El patrón era claro: `sociedad` funcionaba como cajón de sastre porque el prompt definía *cuándo desempatar* pero no *qué contiene cada categoría*.
- **v2** (alcance explícito por categoría + prohibición de usar `sociedad` si encaja una concreta) corrige ambos sin romper ninguno de los 16 ya correctos.

Quedan casos fronterizos donde v1 y v2 discrepan y un editor humano también dudaría —el gesto político de un futbolista (`espana` o `deportes`), una huelga en aeropuertos (`espana` o `sociedad`)—. No se persiguieron: no tienen respuesta única, y la palanca para ajustarlos es la lista de desempates del prompt.

Coste medido: 2.964 tokens para categorizar 20 clusters.

### v3 (descartada) y v4: el eje geográfico

Sobre datos reales apareció un defecto de la propia taxonomía: `internacional` es una categoría **geográfica** en una lista donde las otras siete son **temáticas**. v2 tenía una regla de desempate para `espana` frente al tema ("si ocurre en España pero la materia es económica, prevalece economía") pero no la simétrica para `internacional`, así que unos ciberataques a infraestructuras en EEUU caían en `internacional` en vez de en `tecnologia`.

**v3 intentó arreglarlo por la raíz y fue una regresión grave.** Enunciaba el principio de forma general —"`espana` e `internacional` no son categorías de país, son categorías de política e instituciones"—, y el modelo lo leyó como que `espana` era un cajón genérico de política: clasificó ahí al nuevo primer ministro del Reino Unido y las primarias demócratas de Michigan. La lección es que el nombre de la etiqueta pesa más que la definición que se le dé: no se puede pedir a un modelo que ignore lo que la palabra "espana" significa.

**v4 es la corrección quirúrgica**: mantiene v2 palabra por palabra y añade solo la regla que faltaba, simétrica a la que ya funcionaba, más `ciberseguridad` en el alcance de `tecnologia`. Medida sobre el mismo lote, cambia **1 asignación de 20** respecto a v2, y es exactamente la que se quería mover.

### Inestabilidad por composición del lote (medida)

Al comparar dos ejecuciones del **mismo prompt v2**, con el **mismo modelo** y `temperature: 0`, sobre lotes con distinta composición, **1 de los 14 clusters presentes en ambos (7%) recibió una categoría distinta**. Lo único que cambió fue con qué otros acontecimientos compartía llamada.

Es una consecuencia directa de agrupar: los artículos de un lote son contexto los unos de los otros. Un caso observado en producción lo ilustra bien: en un lote coincidieron una noticia de la reina Letizia en la clausura de un festival de cine (`cultura`, correcto) y otra del rey recibiendo al presidente de Ceuta (agenda institucional, o sea `espana`); la segunda acabó etiquetada como `cultura`, arrastrada por la primera. Conviene tenerlo presente al interpretar cualquier comparación entre versiones de prompt —una diferencia de 1-2 asignaciones puede ser ruido de lote y no efecto del cambio; por eso v4 se comparó contra v2 sobre el lote idéntico, no contra la corrida anterior—. Por la misma razón, cualquier comparación futura debe guardar la asignación **por `id`** antes de recategorizar: el reparto agregado por categoría no permite distinguir qué cluster se movió ni en qué dirección.

Se asume a cambio del coste: bajar a 1 cluster por llamada eliminaría la contaminación cruzada pero multiplicaría por 12 el número de peticiones y repetiría el bloque de reglas (~400 tokens) en cada una. Con un 7% de inestabilidad en una etiqueta temática —no en un hecho ni en una cifra— no compensa. Si alguna vez importa, la palanca es reducir el tamaño de lote, no cambiar de modelo.

### Ejecución real y calibración del espaciado

La primera ejecución completa en n8n sobre los 51 clusters pendientes categorizó 40 y dejó 11 sin tocar: los tres lotes salieron con solo 3 segundos de separación y el tercero recibió un 429 de Groq. El espaciado inicial se había calibrado contra el límite de peticiones/minuto cuando el que se agota aquí es el de tokens/minuto (ver arriba). Corregido a 40s.

El fallo sirvió como validación no planeada del diseño de la cola: los 11 clusters del lote rechazado se quedaron con `categoria IS NULL` —ni escritos con un valor inventado ni marcados como procesados— y volvieron a entrar solos en la siguiente ejecución. La ejecución en su conjunto terminó en `success`, porque un lote fallido es un camino previsto del workflow, no una excepción.

Reparto temático resultante sobre los 40 primeros: `espana` 13, `internacional` 8, `economia` 6, `deportes` 5, `ciencia` 3, `cultura` 2, `tecnologia` 2, `sociedad` 1. Que `sociedad` quede residual es la señal buscada: en v1 actuaba como cajón de sastre.

## Mejora futura

- Revisar la taxonomía con datos de varias semanas: `sociedad` como categoría-refugio y la frontera `espana`/`internacional` son las que más ruido acumulan.
- **Divergencia conocida con 06**: la regla simétrica de `internacional` que introduce v4 está solo en 07. 06 sigue con la lista de v2 porque está pausado y sus datos son de una ventana antigua; hay que replicarla antes de reanudarlo, o las dos secciones del briefing usarán criterios distintos para la misma etiqueta.
- La lista de categorías está fija en el prompt en dos sitios (06 y 07). Cuando se toque, hay que tocar ambos — candidata a moverse a configuración en Postgres.
- Un cluster que falle sistemáticamente se reintenta sin límite. Si alguna vez pasa de ser teórico, la solución es un contador de intentos, no una columna de estado.
