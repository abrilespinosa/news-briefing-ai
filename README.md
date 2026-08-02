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
| 03 | Deduplicación | ⏳ Roadmap | — |
| 04 | Clustering (mismo acontecimiento) | ⏳ Roadmap | — |
| 05 | Análisis LLM | ⏳ Roadmap | — |
| 06 | Quality Filter | ⏳ Roadmap | — |
| 07 | Categorización | ⏳ Roadmap | — |
| 08 | Construcción del briefing | ⏳ Roadmap | — |
| 09 | Entrega | ⏳ Roadmap | — |

**Con el estado actual del repositorio, el sistema ingiere y normaliza noticias de 4 fuentes — todavía no genera un briefing.**

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
03 · Deduplicación ⏳
      │
      ▼
04 · Clustering ⏳ ── agrupa noticias del mismo acontecimiento entre fuentes
      │
      ▼
05 · Análisis LLM ⏳ ── compara fuentes, distingue hechos de interpretaciones
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
| Base de datos | PostgreSQL | Persistencia robusta, necesaria para deduplicación entre ejecuciones |
| Infraestructura | Docker Compose | Entorno reproducible, sin dependencias manuales |
| Fuentes de noticias | RSS | Gratuito, sin necesidad de scraping ni APIs de pago |
| Secretos | `.env` / `.env.example` | Nunca se versionan credenciales |

---

## Instalación

### Requisitos

- Docker y Docker Compose
- Cuenta de n8n (se crea localmente al primer arranque)

### Pasos

```bash
git clone https://github.com/abrilespinosatortuero/news-briefing-ai.git
cd news-briefing-ai
cp .env.example .env
# edita .env con tus propias credenciales/valores
docker compose up -d
```

n8n queda disponible en `http://localhost:5678`.

### Importar los workflows

Los workflows implementados están exportados en [`workflows/`](workflows/):

1. En n8n, `⋮` → `Import from File` → selecciona `workflows/01-ingestion-rss.json`
2. Repite con `workflows/02-normalization.json`
3. Publica ambos workflows (`Publish` en la esquina superior derecha del editor)

Actualmente `02-normalization` invoca a `01-ingestion-rss` internamente — no hace falta ejecutarlos por separado.

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
├── docs/
│   ├── 01-ingestion-rss.md
│   └── 02-normalization.md
└── workflows/
    ├── 01-ingestion-rss.json
    └── 02-normalization.json
```

---

## Roadmap técnico

Decisiones ya tomadas para fases futuras, pendientes de implementar:

- **Deduplicación persistente** entre ejecuciones vía tabla en PostgreSQL (necesaria antes de soportar múltiples horarios de ejecución al día).
- **Quality Filter en cascada**: filtro estructural por número de fuentes que cubren el mismo acontecimiento, seguido de un filtro LLM que rescata piezas de fuente única con valor periodístico (p. ej. exclusivas de investigación).
- **Cola de revisión humana asíncrona**, no bloqueante — nunca debe frenar la ejecución automática diaria.
- **Extracción de contenido completo** del artículo (más allá del resumen del RSS) para dar más contexto al análisis LLM.

---

## Licencia

Pendiente de definir.

---

## Autora

[@abrilespinosa](https://github.com/abrilespinosa)
