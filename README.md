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
| 09 | Entrega | ⏳ Roadmap | — |

**Con el estado actual del repositorio, el sistema ingiere, normaliza, deduplica y agrupa noticias del mismo acontecimiento entre 8 fuentes, las analiza comparando cómo las cubre cada medio, las clasifica por tema y ensambla un briefing diario en HTML que destaca las cifras en las que los medios se contradicen. Lo que falta es entregarlo: hoy el documento se queda en la base de datos.**

---

## Arquitectura

Cada fase es un sub-workflow de n8n independiente, invocado mediante `Execute Workflow Trigger`. Esta modularidad es deliberada: cada fase se puede testear, depurar y versionar de forma aislada, en vez de mantener un único canvas monolítico.

El orquestador (fase 00) dispara a diario `05`, después `07` y finalmente `08`; las fases `01`–`04` se invocan en cascada desde `05`.

```
00 · Orquestador ── Schedule Trigger diario (cron 0 7 * * *) → 05 → 07 → 08
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
                       tabla de conciliación de cifras discrepantes; HTML autocontenido en Postgres
      │
      ▼
09 · Entrega ⏳
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
| Infraestructura | Docker Compose | Entorno reproducible, sin dependencias manuales |
| Fuentes de noticias | RSS | Gratuito, sin necesidad de scraping ni APIs de pago |
| Secretos | `.env` / `.env.example` | Nunca se versionan credenciales |

---

## Instalación

### Requisitos

- Docker y Docker Compose
- Cuenta de n8n (se crea localmente al primer arranque)
- Una API key gratuita de [Groq](https://console.groq.com) (motor del análisis LLM de la fase 05)

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

En n8n, crea una credencial `Header Auth` llamada "Groq API" (`Authorization` / `Bearer <tu GROQ_API_KEY>`) — la usa el nodo "Call Groq for Analysis" de la fase 05. No se versiona en los workflows exportados, por eso hay que crearla a mano tras importar.

### Importar los workflows

Los workflows implementados están exportados en [`workflows/`](workflows/):

1. En n8n, `⋮` → `Import from File` → importa **de abajo arriba**: `01-ingestion-rss.json`, `02-normalization.json`, `03-deduplication.json`, `04-clustering.json`, `05-llm-analysis.json`, `06-quality-filter.json`, `07-categorization.json`, `08-briefing-builder.json` y por último `00-orchestrator-main.json`
2. Publica los nueve workflows (`Publish` en la esquina superior derecha del editor), **en ese mismo orden**. Publicar es obligatorio para el auto-encadenado de `05` y `06`, y n8n rechaza publicar un workflow que referencie sub-workflows sin publicar — por eso `00` va el último
3. Asigna la credencial "Groq API" a los nodos "Call Groq for Analysis" (en `05-llm-analysis`), "Call Groq for Filtering" (en `06-quality-filter`) y "Call Groq for Categorization" (en `07-categorization`)

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
│   └── 07-categorization.md
└── workflows/
    ├── 00-orchestrator-main.json
    ├── 01-ingestion-rss.json
    ├── 02-normalization.json
    ├── 03-deduplication.json
    ├── 04-clustering.json
    ├── 05-llm-analysis.json
    ├── 06-quality-filter.json
    ├── 07-categorization.json
    └── 08-briefing-builder.json
```

---

## Verificaciones pendientes

Cosas implementadas y documentadas cuyo comportamiento **todavía no se ha observado en una ejecución real**. Se listan aquí en vez de darlas por buenas:

- **Retirada de análisis obsoletos en 05** (`status='superseded'`): el SQL está validado contra datos reales en una transacción revertida, pero el nodo no se ha ejecutado aún dentro de n8n — la primera corrida del orquestador topó el tope diario antes de llegar al `INSERT`. A vigilar: que `alwaysOutputData` evite cortar el auto-encadenado cuando el `UPDATE` no afecta a ninguna fila. Ver [`docs/05-llm-analysis.md`](docs/05-llm-analysis.md).
- **Ruta de error de la llamada a 05 desde el orquestador**: cableada para que 07 corra igualmente, nunca ejercitada.
- **Corrección del tope diario autobloqueante** (ventana deslizante → día natural UTC): aplicada, pendiente de confirmar con la primera corrida programada que sí analice.
- **Divergencia conocida entre 06 y 07**: la regla de desempate de `internacional` introducida en 07 no está replicada en 06, que sigue pausado. Hay que replicarla antes de reanudarlo o las dos secciones del briefing usarán criterios distintos para la misma etiqueta.
- **Campo `desarrollo` de 05 en producción**: validado con llamadas directas a Groq sobre clusters reales (rico y pobre), pero ningún análisis guardado lo tiene todavía — se añadió después de la última corrida. Hasta que 05 vuelva a analizar, el briefing no muestra el desplegable "Ver más".
- **Techo proporcional de `desarrollo`**: los umbrales (1.500 y 4.000 caracteres) se calibraron con dos clusters, uno en cada extremo. Conviene revisarlos con una jornada entera antes de darlos por buenos.

## Roadmap técnico

Decisiones ya tomadas para fases futuras, pendientes de implementar:

- **Identidad persistente de eventos**: hoy el clustering compara artículos dentro de una ventana de 24h; un evento en desarrollo durante varios días (ej. cobertura de un incendio) no se vincula todavía con artículos de días anteriores.
- **Fase 09 (Entrega)**: decidido el destino — n8n sirviendo el HTML por webhook, más un aviso a Telegram con el índice del día y el enlace. Telegram no admite tablas, así que el documento completo vive en la web y el mensaje es solo notificación.
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
