# 08 · Briefing Builder

## Objetivo

Ensamblar el documento final del briefing a partir de lo que 05 analizó y 07 categorizó, y guardarlo en Postgres listo para que la fase 09 lo entregue. Es la primera fase que produce algo consumible por una persona: hasta aquí el pipeline solo dejaba filas en tablas.

## Arquitectura

### Sin LLM, a propósito

08 no hace ni una llamada a un modelo. Todo el juicio editorial ya está hecho: 05 decidió qué dice cada fuente y dónde discrepan, 07 asignó el tema. Lo que queda es seleccionar, clasificar, ordenar y renderizar — operaciones deterministas.

Meter un LLM aquí solo añadiría una capa capaz de inventar sobre un texto que ya fue validado, además de coste en tokens y dependencia de los límites de Groq. El briefing se genera en **14 ms**.

### Selección: día natural UTC

La consulta toma los análisis con `status = 'ok'`, `categoria IS NOT NULL` y `analyzed_at` dentro del día natural UTC.

Se descartó la ventana deslizante de 24h por un fallo concreto: con un `Schedule Trigger` a hora fija, los análisis caen justo en el borde de la ventana. Si 05 tarda unos segundos más o menos, las mismas noticias salen dos días seguidos o desaparecen. Es el mismo problema que ya había hecho autobloqueante el tope diario de 05 (ver `docs/05-llm-analysis.md`), y la frontera de medianoche lo elimina porque nadie analiza a medianoche.

El filtro `categoria IS NOT NULL` es deliberadamente conservador: si 07 falló, esos análisis esperan al briefing siguiente en lugar de salir sin tema.

### El hallazgo que definió el formato: las discrepancias están sobredisparadas

05 marca como discrepancia cualquier diferencia entre fuentes. Sobre datos reales, **el 100% de los clusters tenía al menos una**. Clasificándolas:

| Tipo | Proporción |
|---|---|
| Cifras que no coinciden (contradicción real) | 20% |
| Matiz o paráfrasis | 50% |
| Cobertura desigual (un medio no lo cubre) | 24% |
| Incompleta o idéntica | 6% |

Ejemplos del 20% bueno: el eclipse a las 19:30 según 20minutos y a las 20:30 según elDiario.es; 49.000 migrantes según cuatro medios y 50.000 según el Ministerio del Interior; la gasolina a 1,69 € en El País y a 1,68 € en 20minutos.

Ejemplos de lo demás: *"El País: no hay métodos caseros seguros / Europa Press: no se mencionan métodos alternativos"* (eso es una ausencia, no una contradicción), o dos descripciones distintas del mismo vestido.

**Si el briefing destacara las 54, el aviso dejaría de significar algo** — el diferencial del proyecto se convertiría en papel pintado. Se separan con reglas deterministas: si algún valor encaja con un patrón de ausencia ("no se menciona", "sin datos"), es cobertura desigual; si todos los valores contienen números y esos números difieren, es contradicción real; el resto es matiz. Solo las contradicciones reales se muestran, y en el briefing del 6 de agosto fueron **5 de 25 noticias**.

Esto trata el síntoma. El arreglo de fondo es que 05 distinga precisión de contradicción en origen, anotado como pendiente.

### Formato

- **Índice por categorías**, ordenadas por volumen: el tema con más cobertura del día abre el briefing.
- **Dentro de cada tema, de más fuentes a menos.** El número de medios que cubren un suceso es la única señal de relevancia fiable que existe en los datos: `published_date` no está en el análisis y la categoría del RSS es `portada` en el 85% de los casos.
- **Titular neutro**: se usa el `que_paso` que escribió 05, no el titular del medio. Los titulares de prensa vienen editorializados ("vuelve a dispararse", "en una victoria clave") y el proyecto rechaza el lenguaje periodístico.
- **La caja de cada medio es el enlace a su artículo.** Una sola fila: pintar los nombres de los medios y debajo otra vez los mismos nombres como enlaces era información repetida.
- **Las divergencias se componen como tabla de conciliación**, medio → cifra en monoespaciada con `tabular-nums`. Ver `ABC 350.000` y `elDiario.es 348.000` alineados uno debajo del otro hace el desacuerdo literalmente legible.
- **Tema visual**: el ocre está reservado en exclusiva a las contradicciones numéricas. Si aparece cinco veces en todo el documento, significa algo. La página se adapta a tema claro y oscuro.

### "Ver más" y el campo `desarrollo`

El desplegable muestra el `desarrollo` que escribe 05: el cuerpo de la noticia en prosa. **Solo se muestra si supera las 25 palabras.**

Ese umbral no es cosmético. Cuando las fuentes son teasers escuetos, 05 devuelve una línea o nada — correctamente, porque forzarle una extensión mínima le hacía inventar (ver `docs/05-llm-analysis.md`). Ofrecer un desplegable que al abrirse no aporta nada es peor que no ofrecerlo.

Los análisis anteriores a la introducción de `desarrollo` no tienen el campo y simplemente no muestran desplegable.

Medido sobre los 30 análisis del 7 de agosto: **3 se quedan por debajo del umbral** (5, 9 y 15 palabras), justo los tres cuyos clusters no llegaban a 1.500 caracteres de material. El umbral hace lo que debe.

### Almacenamiento: el documento y también la selección

La tabla `briefings` guarda `content_html` **y** `payload` (JSONB con la selección ya clasificada).

Guardar solo el HTML fosilizaría el diseño: cambiar el maquetado obligaría a reanalizar. Con el payload se puede re-renderizar a cualquier formato —o a otro canal en la fase 09— sin gastar un token.

`briefing_date` es `UNIQUE` con `ON CONFLICT DO UPDATE`: regenerar el briefing de un mismo día lo reemplaza en vez de duplicarlo, así que **08 es idempotente y reejecutable**.

## Implementación

**Flujo de nodos:**
```
Execute Workflow Trigger
  → Get Today's Analyses (Postgres, alwaysOutputData)
  → Anything to Brief Today? (IF: id existe)
      true  → Build Briefing Document (Code, runOnceForAllItems)
            → Store Briefing (Postgres, INSERT ... ON CONFLICT DO UPDATE ... RETURNING)
      false → Nothing to Brief Today (NoOp)
```

Un único Code node contiene la clasificación de discrepancias, la agrupación, el orden y el renderizado completo, incluido el CSS. El HTML resultante es autocontenido: sin hojas de estilo externas, sin fuentes remotas, sin JavaScript. Se puede servir, enviar por correo o abrir desde un fichero sin depender de nada.

**Tabla `briefings`** (ver `db/schema.sql`): `briefing_date, cluster_count, divergence_count, payload, content_html, generated_at`.

## Validación

Ejecución real sobre los datos del 6 de agosto de 2026:

- 25 análisis seleccionados (no 50: el filtro por día natural descartó correctamente los del día 4), 8 categorías, 5 divergencias numéricas.
- Documento de 57.427 bytes bien formado — abre en `<!doctype html>`, cierra en `</html>`, con 25 `<article>` y 25 `<details>` balanceados y 67 enlaces a fuentes. `payload` de 61 KB, JSON válido.
- Tiempo del Code node: **14 ms**.
- Idempotencia comprobada en una transacción revertida: al simular una segunda ejecución del mismo día, la tabla mantiene una sola fila con el contenido reemplazado.

El renderizador se desarrolló primero en Python como prototipo visual y después se portó a JavaScript. **El port se validó ejecutándolo dentro del contenedor de n8n**, sobre el mismo Node que ejecuta el Code node, comprobando que ambas implementaciones producían las mismas cifras (50 noticias, 11 divergencias, 8 secciones) sobre el mismo conjunto de datos.

## Mejora futura

- **Un briefing de 25 noticias sigue siendo largo.** Con varios días acumulados habrá que ver si conviene un tope por categoría o un criterio de corte, sabiendo que descartar análisis ya pagados al LLM tiene su propio coste.
- **Vigilar la densidad de divergencias**: 5 en 25 noticias el 6 de agosto, **3 en 30 el día 7** — del 20% al 10%. Ese segundo día 05 declaró 30 discrepancias sobre 29 de los 30 clusters y el clasificador dejó pasar 3. Con dos días no hay tendencia, pero es la cifra a seguir: si el marcador de contradicción casi no aparece, el elemento diferencial del briefing se diluye, y habrá que decidir si el problema es el filtro de 08 o la detección de 05.
- **El reparto por categorías está escorado**: el 7 de agosto, `espana` reunió 14 de 30 noticias. Es esperable con ocho medios españoles, pero si se mantiene habrá que revisar si ordenar el índice por volumen tiene sentido cuando una categoría es la mitad del documento.
- **La sección secundaria de 06 no está integrada.** 06 está pausado; cuando se reanude, sus piezas de fuente única entran como segunda sección bajo la misma taxonomía. El `payload` ya está estructurado para admitirlo sin cambiar el esquema.
- El orden de categorías por volumen hace que el briefing cambie de estructura cada día. Un orden editorial fijo sería más predecible para lectura diaria.
