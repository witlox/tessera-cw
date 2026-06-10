-- Tessera content store schema (bundled read-only SQLite; wrap with GRDB/Core Data)
-- One physical DB ships in the app bundle. Free build queries WHERE language='en'.

PRAGMA foreign_keys = ON;

CREATE TABLE meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- A theme is language-independent in concept ("cinema"), but membership is per word.
CREATE TABLE groups (
    id        INTEGER PRIMARY KEY,
    slug      TEXT UNIQUE NOT NULL,      -- 'cinema'
    label_en  TEXT NOT NULL             -- human label; localized labels can live in a side table
);

-- One row per (surface word, language). gridForm is the A-Z crossing key.
CREATE TABLE words (
    id          INTEGER PRIMARY KEY,
    language    TEXT NOT NULL,           -- ISO code: en, de, fr, ...
    surface     TEXT NOT NULL,           -- canonical spelling WITH diacritics ("Straße")
    grid_form   TEXT NOT NULL,           -- A-Z only ("STRASSE") -- used for layout/crossing
    grid_len    INTEGER NOT NULL,
    zipf        REAL,                    -- wordfreq zipf frequency (NULL if unknown)
    difficulty  TEXT,                    -- easy | medium | hard
    is_concat   INTEGER NOT NULL DEFAULT 0,  -- multi-word entry filled without spaces
    UNIQUE(language, surface)
);

CREATE INDEX idx_words_lang_len  ON words(language, grid_len);
CREATE INDEX idx_words_gridform  ON words(grid_form);
CREATE INDEX idx_words_lang_diff ON words(language, difficulty);

-- Many-to-many: a word can belong to several themes.
CREATE TABLE word_groups (
    word_id  INTEGER NOT NULL REFERENCES words(id) ON DELETE CASCADE,
    group_id INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    PRIMARY KEY (word_id, group_id)
);

-- A word may have multiple candidate clues (different difficulty / source).
-- clue.language == word.language always (the clue language signals the answer language
-- to the solver in a mixed grid).
CREATE TABLE clues (
    id        INTEGER PRIMARY KEY,
    word_id   INTEGER NOT NULL REFERENCES words(id) ON DELETE CASCADE,
    language  TEXT NOT NULL,
    text      TEXT NOT NULL,
    source    TEXT NOT NULL,            -- 'seed' | 'llm' | 'human'
    validated INTEGER NOT NULL DEFAULT 0,  -- passed the harness
    UNIQUE(word_id, text)
);

CREATE INDEX idx_clues_word ON clues(word_id);
