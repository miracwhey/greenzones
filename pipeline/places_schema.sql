-- Schema der gebündelten Orts-Suche (SPEC 8).
--
-- EINE Quelle für beide Seiten: `build_places_sqlite.py` legt damit die echte
-- places.sqlite an, `SearchTestDatabase.swift` legt damit die Mini-Fixture im
-- Test an. Läge die DDL zweimal im Repo, könnte der Test eine Tabelle prüfen,
-- die die App nie sieht.
--
-- norm_name / norm_context sind mit normalize() vorberechnet (lowercase,
-- ä→ae ö→oe ü→ue ß→ss, Diakritika weg) — dieselbe Funktion normalisiert die
-- Query in Swift. Der Index hat KEINE eigene Meinung über Schreibweisen.

CREATE TABLE place(
    id           INTEGER PRIMARY KEY,
    name         TEXT,
    type         TEXT,
    state        TEXT,
    city         TEXT,
    lat          REAL,
    lng          REAL,
    norm_name    TEXT,
    norm_context TEXT
);

-- Treffermenge + Reihenfolge: prefix='2 3 4' trägt die Tipp-Suche ab 2 Zeichen,
-- remove_diacritics 2 fängt ab, was normalize() nicht schon vereinheitlicht hat.
CREATE VIRTUAL TABLE place_fts USING fts5(
    norm_name,
    norm_context,
    content='place',
    content_rowid='id',
    tokenize='unicode61 remove_diacritics 2',
    prefix='2 3 4'
);

-- Tippfehler-Fallback (Substring statt Wortanfang). Wird nur befragt, wenn
-- place_fts weder mit AND noch mit OR etwas findet.
CREATE VIRTUAL TABLE place_tri USING fts5(
    norm_name,
    content='place',
    content_rowid='id',
    tokenize='trigram'
);
