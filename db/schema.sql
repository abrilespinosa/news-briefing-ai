-- Tabla de deduplicación persistente.
-- Registra los links de artículos ya procesados para evitar
-- que reaparezcan en briefings posteriores.
CREATE TABLE IF NOT EXISTS seen_articles (
  id SERIAL PRIMARY KEY,
  link TEXT UNIQUE NOT NULL,
  source_name TEXT,
  category TEXT,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS normalized_articles (
    id SERIAL PRIMARY KEY,
    link TEXT UNIQUE NOT NULL,
    title TEXT NOT NULL,
    content TEXT,
    category TEXT,
    source_name TEXT,
    published_date TIMESTAMPTZ,
    language TEXT,
    embedding JSONB NOT NULL,
    processed_at TIMESTAMPTZ DEFAULT now()
);