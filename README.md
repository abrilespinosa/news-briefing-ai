# news-briefing-ai

Sistema de briefing diario de noticias impulsado por LLM, construido con [n8n](https://n8n.io) y Docker.

El objetivo no es acumular noticias — es reducir el ruido informativo. El sistema compara varias fuentes, agrupa lo que hablan del mismo acontecimiento, y genera un resumen conciso (qué ha ocurrido, por qué importa, qué impacto puede tener), citando siempre las fuentes originales.

> ⚠️ **Proyecto en desarrollo activo.** No es un producto terminado. Este README documenta honestamente qué partes funcionan hoy y cuáles son roadmap — ver [Estado del proyecto](#estado-del-proyecto).

---

## Filosofía

- **Calidad antes que cantidad.** Menos noticias, mejor seleccionadas.
- **Transparencia antes que opiniones.** Cada pieza del briefing debe ser trazable a sus fuentes originales.
- **Diversidad de fuentes, sin etiquetas editoriales.** El sistema compara múltiples medios para reducir el sesgo de depender de una única fuente, sin clasificar a los medios por línea editorial.
- **Mantenibilidad antes que soluciones rápidas.** Arquitectura modular pensada para evolucionar, no un script desechable.

El sistema no sustituye al periodismo — está pensado para animar a consultar las fuentes originales cuando el lector quiera profundizar.

---

## Estado del proyecto

Arquitectura de pipeline en 10 fases, implementada como sub-workflows independientes en n8n:

| # | Fase | Estado | Documentación |
|---|------|--------|---------------|
| 00 | Trigger / Orquestador | ✅ Implementado | [`docs/00-orchestrator.md`](docs/00-orchestrator.md) |
| 01 | Ingesta (RSS) | ✅ Implementado | [`docs/01-ingestion-rss.md`](docs/01-ingestion-rss.md) |
| 02 | Normalización | ✅ Implementado | [`docs/02-normalization.md`](docs/02-normalization.md) |
| 03 | Deduplicación | ✅ Implementado | [`docs/03-deduplication.md`](docs/03-deduplication.md) |
| 04 | Clustering (mismo acontecimiento) | ✅ Implementado | [`docs/04-clustering.md`](docs/04-clustering.md) |
| 05 | Análisis LLM | ✅ Implementado | [`docs/05-llm-analysis.md`](docs/05-llm-analysis.md) |
| 06 | Quality Filter | ✅ Implementado | [`docs/06-quality-filter.md`](docs/06-quality-filter.md) |
| 07 | Categorización | ✅ Implementado | [`docs/07-categorization.md`](docs/07-categorization.md) |
| 08 | Construcción del briefing | ✅ Implementado | [`docs/08-briefing-builder.md`](docs/08-briefing-builder.md) |
| 09 | Entrega | ✅ Implementado | [`docs/09-delivery.md`](docs/09-delivery.md) |

**El pipeline está completo de punta a punta.** Cada mañana ingiere, normaliza, deduplica y agrupa noticias del mismo acontecimiento entre 8 fuentes, las analiza comparando cómo las cubre cada medio, las clasifica por tema, ensambla un briefing en HTML que destaca las cifras en las que los medios se contradicen y lo entrega por Telegram.

Corrida real del 7 de agosto de 2026: 1.000 clusters detectados, 53 multi-fuente, 30 analizados, briefing de 30 acontecimientos en 7 categorías entregado 11 minutos después de arrancar, sin un solo fallo.

Una segunda corrida ese mismo día ejercitó la **retirada de análisis obsoletos**: al ampliarse la ventana con artículos nuevos, dos sucesos ya cubiertos se reanalizaron con más fuentes (uno pasó de comparar 3 medios a comparar 4) y sus análisis anteriores quedaron marcados `superseded`. El briefing mantuvo 30 noticias — los mismos acontecimientos, dos de ellos mejor comparados.

---

## Arquitectura

### El embudo, medido

Una ejecución real del 7 de agosto de 2026 con las ocho fuentes activas:

```
818 artículos en la ventana de 24h
 →  714 acontecimientos          (04 agrupa; 667 de ellos los cubre un solo artículo)
 →   43 multi-fuente             (los únicos que compara 05)
 →   30 analizados               (tope del nivel gratuito de Groq)
```

El estrechamiento no lo produce ningún filtro de calidad, sino un hecho del material de partida: **la gran mayoría de las noticias las publica un solo medio**. De 818 artículos, solo 151 acaban compartiendo cluster con otro. Ese 6% que llega al briefing es exactamente el objetivo del proyecto — contrastar, no acumular.

### Fases

Cada fase es un sub-workflow de n8n independiente, invocado mediante `Execute Workflow Trigger`. Esta modularidad es deliberada: cada fase se puede testear, depurar y versionar de forma aislada, en vez de mantener un único canvas monolítico.

El orquestador (fase 00) dispara a diario `05`, después `07`, `08` y `09`; las fases `01`–`04` se invocan en cascada desde `05`.

```
00 · Orquestador ── Schedule Trigger diario (cron 0 7 * * *) → 05 → 07 → 08 → 09
      │
      ▼
01 · Ingesta ──── RSS multi-fuente (El País, elDiario.es, El Mundo, ABC, 20minutos, La Vanguardia, Europa Press, El Español)
      │
      ▼
02 · Normalización ── limpieza de HTML, fechas ISO 8601, URLs sin tracking
      │
      ▼
03 · Deduplicación ── tabla de trazabilidad en Postgres, evita reprocesar artículos vistos
      │
      ▼
04 · Clustering ── embeddings semánticos (Ollama + bge-m3), similitud coseno en Postgres (pgvector) + Union-Find, agrupa el mismo acontecimiento entre fuentes
      │
      ▼
05 · Análisis LLM ── Groq (llama-3.3-70b-versatile, nivel gratuito), compara fuentes, distingue hechos de interpretaciones, señala discrepancias
      │
      ▼
06 · Quality Filter ── Groq (llama-3.1-8b-instant), filtra/categoriza/resume piezas de fuente única para la sección secundaria
                       (⏸ pausado por decisión de producto: fuera de la cadena del orquestador por ahora)
      │
      ▼
07 · Categorización ── Groq (llama-3.1-8b-instant), asigna tema a cada cluster multi-fuente; lee de cluster_analysis, no encadena a 05
      │
      ▼
08 · Briefing Builder ── ensamblaje determinista (sin LLM): índice por temas, orden por nº de medios,
                       tabla de conciliación de cifras discrepantes; HTML autocontenido en Postgres,
                       con la fecha como titular y el bronce reservado a las contradicciones numéricas
      │
      ▼
09 · Entrega ──── Telegram: aviso + el HTML como adjunto (se lee con el equipo apagado, a diferencia
                  de un enlace servido por el propio n8n)
```

---

## Stack tecnológico

| Componente | Elección | Motivo |
|---|---|---|
| Orquestación | n8n (self-hosted) | Automatización visual, control total sobre el pipeline |
| Base de datos | PostgreSQL + `pgvector` | Persistencia robusta: trazabilidad de deduplicación, artículos normalizados con embeddings nativos (`vector(1024)`) y similitud coseno calculada en SQL |
| Embeddings | Ollama + `bge-m3` (self-hosted) | Coste cero, multilingüe de fábrica, sin dependencia de una API externa de pago |
| Análisis LLM (05, multi-fuente) | Groq API (`llama-3.3-70b-versatile`), nivel gratuito | Modelo open-weight, coste $0 a este volumen; se probó Ollama local primero pero la CPU compartida del portátil no daba fiabilidad ni escalaba con más fuentes — ver [`docs/05-llm-analysis.md`](docs/05-llm-analysis.md) |
| Quality Filter (06, fuente única) | Groq API (`llama-3.1-8b-instant`), nivel gratuito | Mismo proveedor, modelo distinto: 500K tokens/día frente a 100K, necesario para el volumen de piezas de fuente única (cientos/día) — ver [`docs/06-quality-filter.md`](docs/06-quality-filter.md) |
| Categorización (07, multi-fuente) | Groq API (`llama-3.1-8b-instant`), nivel gratuito | Fase aparte y no un campo más en el prompt de 05: así cubre también los análisis ya hechos y no consume el presupuesto escaso del modelo de 05 — ver [`docs/07-categorization.md`](docs/07-categorization.md) |
| Entrega (09) | Bot de Telegram | El HTML viaja como adjunto, no como enlace: el equipo que aloja el pipeline se suspende, así que cualquier URL servida por el propio n8n estaría caída al abrir la notificación — ver [`docs/09-delivery.md`](docs/09-delivery.md) |
| Infraestructura | Docker Compose | Entorno reproducible, sin dependencias manuales. La purga del historial de ejecuciones va configurada de forma explícita: n8n guarda el payload íntegro de cada nodo y aquí eso son cientos de artículos con embeddings de 1024 dimensiones, ~1,3 MB por ejecución de las fases 01-04 |
| Fuentes de noticias | RSS | Gratuito, sin necesidad de scraping ni APIs de pago |
| Secretos | `.env` / `.env.example` | Nunca se versionan credenciales |

---

## Instalación

### Requisitos

- Docker y Docker Compose
- Cuenta de n8n (se crea localmente al primer arranque)
- Una API key gratuita de [Groq](https://console.groq.com) (motor del análisis LLM de la fase 05)
- Un bot de Telegram creado con [@BotFather](https://t.me/BotFather) (canal de entrega de la fase 09)

### Pasos

```bash
git clone https://github.com/abrilespinosatortuero/news-briefing-ai.git
cd news-briefing-ai
cp .env.example .env
# edita .env: credenciales de Postgres, y GROQ_API_KEY con tu key de console.groq.com
docker compose up -d
```

n8n queda disponible en `http://localhost:5678`.

Tras el primer arranque, descarga el modelo de embeddings dentro del contenedor de Ollama (solo hace falta una vez, se persiste en un volumen):

```bash
docker exec -it news-briefing-ai-ollama-1 ollama pull bge-m3
```

Aplica el esquema de la base de datos, que no lo hace ningún workflow ni script:

```bash
docker exec -i news-briefing-ai-postgres-1 psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" < db/schema.sql
```

Registra el destinatario del briefing. **No va en `.env`**: n8n 2.x deniega el acceso a las variables de entorno desde las expresiones, y levantar ese bloqueo daría a cualquier workflow acceso a todas las variables del contenedor (el detalle, en [`docs/09-delivery.md`](docs/09-delivery.md)):

```bash
docker exec -it news-briefing-ai-postgres-1 psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "INSERT INTO app_config (key, value) VALUES ('telegram_chat_id', '<tu chat id>')
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;"
```

En n8n hay que crear dos credenciales a mano — no se versionan en los workflows exportados, por eso hay que asignarlas tras importar:

- **"Groq API"**, de tipo `Header Auth` (`Authorization` / `Bearer <tu GROQ_API_KEY>`), para los nodos de llamada a Groq de las fases 05, 06 y 07.
- **Una credencial de tipo `Telegram`** con el token que devuelve @BotFather, para los tres nodos de envío de la fase 09.

### Importar los workflows

Los workflows implementados están exportados en [`workflows/`](workflows/):

1. En n8n, `⋮` → `Import from File` → importa **de abajo arriba**: `01-ingestion-rss.json`, `02-normalization.json`, `03-deduplication.json`, `04-clustering.json`, `05-llm-analysis.json`, `06-quality-filter.json`, `07-categorization.json`, `08-briefing-builder.json`, `09-delivery.json` y por último `00-orchestrator-main.json`
2. Publica los diez workflows (`Publish` en la esquina superior derecha del editor), **en ese mismo orden**. Publicar es obligatorio para el auto-encadenado de `05` y `06`, y n8n rechaza publicar un workflow que referencie sub-workflows sin publicar — por eso `00` va el último
3. Asigna la credencial "Groq API" a los nodos "Call Groq for Analysis" (en `05-llm-analysis`), "Call Groq for Filtering" (en `06-quality-filter`) y "Call Groq for Categorization" (en `07-categorization`), y la credencial de Telegram a "Send Header", "Send Briefing Document" y "Send Sign-off" (en `09-delivery`)

Las fases `01`–`06` invocan a la anterior internamente (`Execute Workflow`), así que no hace falta ejecutarlas por separado: ejecuta `05-llm-analysis` para el briefing principal (clusters multi-fuente) o `06-quality-filter` para el secundario (fuente única) — ambos disparan `01`→`04` internamente.

`07-categorization` es la excepción: no encadena con `05`, sino que lee de la tabla `cluster_analysis` que `05` ya ha rellenado (el porqué, en [`docs/07-categorization.md`](docs/07-categorization.md)). Se ejecuta después de `05`, y categoriza todo lo que quede pendiente.

---

## Fuentes de noticias

El sistema ingiere RSS de 8 medios españoles: El País, elDiario.es, El Mundo, ABC, 20minutos, La Vanguardia, Europa Press y El Español. La selección busca diversidad de fuentes como mecanismo para reducir la dependencia de un único punto de vista — el sistema no clasifica ni etiqueta a los medios por línea editorial.

Detalle técnico de cada fuente (URLs de feed, estructura de campos) en [`docs/01-ingestion-rss.md`](docs/01-ingestion-rss.md).

---

## Estructura del repositorio

```
news-briefing-ai/
├── docker-compose.yml
├── .env.example
├── db/
│   └── schema.sql
├── docs/
│   ├── 00-orchestrator.md
│   ├── 01-ingestion-rss.md
│   ├── 02-normalization.md
│   ├── 03-deduplication.md
│   ├── 04-clustering.md
│   ├── 05-llm-analysis.md
│   ├── 06-quality-filter.md
│   ├── 07-categorization.md
│   ├── 08-briefing-builder.md
│   └── 09-delivery.md
└── workflows/
    ├── 00-orchestrator-main.json
    ├── 01-ingestion-rss.json
    ├── 02-normalization.json
    ├── 03-deduplication.json
    ├── 04-clustering.json
    ├── 05-llm-analysis.json
    ├── 06-quality-filter.json
    ├── 07-categorization.json
    ├── 08-briefing-builder.json
    └── 09-delivery.json
```

---

## Verificaciones pendientes

Cosas implementadas y documentadas cuyo comportamiento **todavía no se ha observado en una ejecución real**. Se listan aquí en vez de darlas por buenas:

- **Ruta de error de la llamada a 05 desde el orquestador**: cableada para que 07 corra igualmente, nunca ejercitada.
- **Rama `Nothing to Deliver` de 09**: requiere un día sin briefing, que solo ocurre si 05 y 07 no producen nada categorizado.
- **09 no reintenta.** Si Telegram falla, el briefing queda en la tabla y no se reenvía. Reejecutar `09-delivery` a mano lo resuelve y no cuesta ni un token, pero no es automático.
- **Divergencia conocida entre 06 y 07**: la regla de desempate de `internacional` introducida en 07 no está replicada en 06, que sigue pausado. Hay que replicarla antes de reanudarlo o las dos secciones del briefing usarán criterios distintos para la misma etiqueta.
- **Densidad de divergencias a la baja**: 5 de 25 noticias el 6 de agosto, 3 de 30 el 7. Con dos días no hay tendencia, pero es la cifra que hay que vigilar: si el marcador de contradicción casi no aparece, el elemento diferencial del briefing se diluye.
- **Las tres ramas de reencolado de 04 y la rama de error de 08 nunca se han disparado**: están cableadas y su camino feliz está comprobado en ejecución real, pero ni Ollama ni Postgres han fallado todavía, así que ni el `DELETE FROM seen_articles` ni `Briefing Not Stored` se han ejecutado nunca. Además el reencolado **no avisa**: la corrida sigue y termina en `success`, así que una ingesta perdida solo se ve entrando al historial de n8n.
- **El límite diario de Groq nunca se ha observado.** El tope de 30 análisis se calibra contra los 100.000 tokens/día que Groq documenta para este modelo, pero las cabeceras de la API solo exponen el bucket por minuto: todos los 429 que hemos visto eran por minuto, ninguno por día. El margen es autoimpuesto contra una cifra que no hemos podido confirmar en la cuenta.

## Roadmap técnico

Decisiones ya tomadas para fases futuras, pendientes de implementar:

- **Identidad persistente de eventos**: hoy el clustering compara artículos dentro de una ventana de 24h; un evento en desarrollo durante varios días (ej. cobertura de un incendio) no se vincula todavía con artículos de días anteriores.
- **Empotrar la tipografía como `data:` URI**: el briefing nombra la fuente de cada sistema (Roboto en Android, San Francisco en Apple, Segoe UI en Windows) porque `Iowan Old Style` solo existe en Apple y en Android caía en cualquier cosa. Se sostiene en los tres, pero no es idéntico. Empotrar una familia de licencia libre subconjuntada al español lo cerraría del todo — unos 30–60 KB sobre los ~55 KB actuales — y es el paso que hace falta si el bot pasa a ser multiusuario.
- **Al briefing le falta identidad visual propia.** Se probaron dos retículas con una idea estructural detrás y ninguna convenció; queda anotado como problema abierto en [`docs/08-briefing-builder.md`](docs/08-briefing-builder.md). El momento natural de retomarlo es cuando el proyecto tenga nombre.
- **Canal web para la entrega**: el adjunto de Telegram se eligió porque el equipo que aloja el pipeline se suspende y cualquier enlace estaría caído al abrir la notificación. Si el pipeline deja de vivir en un portátil, servir el HTML tiene ventajas (navegación, historial). El `payload` de 08 está guardado precisamente para poder renderizar a otro formato sin reanalizar.
- **Presupuesto de Groq como techo del proyecto**: medido, una llamada de 05 consume ~3.000 tokens sobre los 100.000/día del nivel gratuito, o sea ~33 acontecimientos diarios. El 7 de agosto había 53 clusters multi-fuente y 35 sin analizar. **El límite ya está por debajo del volumen que generan 8 fuentes**, y añadir más lo agrava. Las palancas son recortar el prompt (el 75% del gasto es entrada) a costa de calidad, o pasar al nivel de pago. Además el tope no aplaza trabajo, lo descarta: 04 agrupa en una ventana de 24h.
- **Extracción de contenido completo** (Mozilla Readability o `trafilatura`, en un contenedor aparte): hoy 05 analiza el teaser del RSS, no el artículo. El Mundo entrega 174 caracteres de media frente a los 6.236 de elDiario.es, y 6 de cada 25 clusters se quedan sin material suficiente para un cuerpo de noticia. **Implica revisar el principio "solo RSS, sin scraping"**, así que es una decisión de filosofía del proyecto y no solo técnica.
- **Distinguir en 05 discrepancia de precisión de contradicción factual**: hoy el 100% de los clusters reporta alguna discrepancia y solo el 20% son contradicciones reales. La fase 08 las separa con reglas deterministas, pero el arreglo de fondo es el prompt de 05.
- **Agente de investigación sobre `preguntas_abiertas`**: 05 ya registra por cluster lo que ninguna fuente resuelve. Es el material de partida para un agente que busque esas respuestas.
- **Cola de revisión humana asíncrona**, no bloqueante — nunca debe frenar la ejecución automática diaria.
- **Índice ANN (`ivfflat`/`hnsw`) sobre `pgvector`** si el volumen de artículos crece lo suficiente para que el self-join de similitud deje de ser trivial (ya migrado a `pgvector`; ver [`docs/04-clustering.md`](docs/04-clustering.md)).

---

## Licencia

Pendiente de definir.

---

## Autora

[@abrilespinosa](https://github.com/abrilespinosa)
