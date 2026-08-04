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
| 00 | Trigger | ✅ Implementado | — |
| 01 | Ingesta (RSS) | ✅ Implementado | [`docs/01-ingestion-rss.md`](docs/01-ingestion-rss.md) |
| 02 | Normalización | ✅ Implementado | [`docs/02-normalization.md`](docs/02-normalization.md) |
| 03 | Deduplicación | ✅ Implementado | [`docs/03-deduplication.md`](docs/03-deduplication.md) |
| 04 | Clustering (mismo acontecimiento) | ✅ Implementado | [`docs/04-clustering.md`](docs/04-clustering.md) |
| 05 | Análisis LLM | ⏳ Construido, sin validar en ejecución real de n8n | [`docs/05-llm-analysis.md`](docs/05-llm-analysis.md) |
| 06 | Quality Filter | ⏳ Roadmap | — |
| 07 | Categorización | ⏳ Roadmap | — |
| 08 | Construcción del briefing | ⏳ Roadmap | — |
| 09 | Entrega | ⏳ Roadmap | — |

**Con el estado actual del repositorio, el sistema ingiere, normaliza, deduplica, agrupa y analiza (comparando fuentes, señalando discrepancias) noticias del mismo acontecimiento entre 4 fuentes — todavía no genera un briefing.**

---

## Arquitectura

Cada fase es un sub-workflow de n8n independiente, invocado mediante `Execute Workflow Trigger`. Esta modularidad es deliberada: cada fase se puede testear, depurar y versionar de forma aislada, en vez de mantener un único canvas monolítico.

```
Schedule Trigger
      │
      ▼
01 · Ingesta ──── RSS multi-fuente (El País, elDiario.es, El Mundo, ABC)
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
06 · Quality Filter ⏳
      │
      ▼
07 · Categorización ⏳
      │
      ▼
08 · Briefing Builder ⏳
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
| Análisis LLM | Groq API (`llama-3.3-70b-versatile`), nivel gratuito | Modelo open-weight, coste $0 a este volumen; se probó Ollama local primero pero la CPU compartida del portátil no daba fiabilidad ni escalaba con más fuentes — ver [`docs/05-llm-analysis.md`](docs/05-llm-analysis.md) |
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

1. En n8n, `⋮` → `Import from File` → importa, en este orden: `01-ingestion-rss.json`, `02-normalization.json`, `03-deduplication.json`, `04-clustering.json`, `05-llm-analysis.json`
2. Publica los cinco workflows (`Publish` en la esquina superior derecha del editor)
3. En `05-llm-analysis`, asigna la credencial "Groq API" al nodo "Call Groq for Analysis" (ver arriba)

Cada fase invoca a la anterior internamente (`Execute Workflow`) — no hace falta ejecutarlas por separado; basta con ejecutar `05-llm-analysis` para disparar todo el pipeline hasta ese punto.

---

## Fuentes de noticias

El sistema ingiere RSS de 4 medios españoles: El País, elDiario.es, El Mundo y ABC. La selección busca diversidad de fuentes como mecanismo para reducir la dependencia de un único punto de vista — el sistema no clasifica ni etiqueta a los medios por línea editorial.

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
│   ├── 01-ingestion-rss.md
│   ├── 02-normalization.md
│   ├── 03-deduplication.md
│   ├── 04-clustering.md
│   └── 05-llm-analysis.md
└── workflows/
    ├── 01-ingestion-rss.json
    ├── 02-normalization.json
    ├── 03-deduplication.json
    ├── 04-clustering.json
    └── 05-llm-analysis.json
```

---

## Roadmap técnico

Decisiones ya tomadas para fases futuras, pendientes de implementar:

- **Re-validar 05-llm-analysis con una ejecución real encadenada en n8n** tras los cambios de resiliencia y de procesamiento en cola (timeout 900s, reintentos, tope de 5 clusters/ejecución, no reanaliza links ya cubiertos) — ver [`docs/05-llm-analysis.md`](docs/05-llm-analysis.md) para el porqué de cada decisión.
- **Fase 00 (Trigger/Schedule)**: con 05 ya preparado para correr en cola de forma segura (tope por ejecución, no repite trabajo ya hecho), falta diseñar qué dispara el pipeline periódicamente.
- **Identidad persistente de eventos**: hoy el clustering compara artículos dentro de una ventana de 24h; un evento en desarrollo durante varios días (ej. cobertura de un incendio) no se vincula todavía con artículos de días anteriores.
- **Quality Filter en cascada**: filtro estructural por número de fuentes que cubren el mismo acontecimiento, seguido de un filtro LLM que rescata piezas de fuente única con valor periodístico (p. ej. exclusivas de investigación).
- **Cola de revisión humana asíncrona**, no bloqueante — nunca debe frenar la ejecución automática diaria.
- **Extracción de contenido completo** del artículo (más allá del resumen del RSS) para dar más contexto al análisis LLM.
- **Índice ANN (`ivfflat`/`hnsw`) sobre `pgvector`** si el volumen de artículos crece lo suficiente para que el self-join de similitud deje de ser trivial (ya migrado a `pgvector`; ver [`docs/04-clustering.md`](docs/04-clustering.md)).

---

## Licencia

Pendiente de definir.

---

## Autora

[@abrilespinosa](https://github.com/abrilespinosa)
