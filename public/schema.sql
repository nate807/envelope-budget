-- =============================================================================
-- Envelope Budget App — SQLite Schema (Integrated v2.1)
-- Architecture: Local-first (SQLite WASM) [cite: 5, 18]
-- Features: Household Management, Envelope Budgeting, Net Worth, CSV Import
-- =============================================================================

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

-- =============================================================================
-- 1. CORE HOUSEHOLD & SETTINGS
-- =============================================================================

CREATE TABLE IF NOT EXISTS household (
  id                TEXT PRIMARY KEY, -- UUID
  name              TEXT NOT NULL DEFAULT 'Our Budget',
  license_key       TEXT,
  license_status    TEXT NOT NULL DEFAULT 'free' 
                    CHECK (license_status IN ('free', 'premium')), [cite: 127, 139]
  db_version        INTEGER NOT NULL DEFAULT 1,
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS "setting" (
  key           TEXT PRIMARY KEY,
  value         TEXT,
  updated_at    INTEGER NOT NULL
);

-- Seed default settings
INSERT OR IGNORE INTO setting (key, value, updated_at) VALUES
  ('icloud_sync_enabled',   '0',        strftime('%s', 'now')),
  ('icloud_sync_path',      NULL,       strftime('%s', 'now')),
  ('currency_symbol',       '$',        strftime('%s', 'now')),
  ('theme',                 'system',   strftime('%s', 'now'));

-- =============================================================================
-- 2. ENVELOPE STRUCTURE & TEMPLATES
-- =============================================================================

CREATE TABLE IF NOT EXISTS envelope_group (
  id            TEXT PRIMARY KEY,
  household_id  TEXT NOT NULL REFERENCES household(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  sort_order    INTEGER NOT NULL DEFAULT 0,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS envelope (
  id            TEXT PRIMARY KEY,
  household_id  TEXT NOT NULL REFERENCES household(id) ON DELETE CASCADE,
  group_id      TEXT REFERENCES envelope_group(id) ON DELETE SET NULL, [cite: 79]
  name          TEXT NOT NULL,
  sort_order    INTEGER NOT NULL DEFAULT 0,
  archived_at   INTEGER, -- NULL = active, Timestamp = archived [cite: 89]
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS budget_template (
  id            TEXT PRIMARY KEY,
  household_id  TEXT NOT NULL REFERENCES household(id) ON DELETE CASCADE,
  envelope_id   TEXT NOT NULL REFERENCES envelope(id) ON DELETE CASCADE,
  amount_cents  INTEGER NOT NULL DEFAULT 0, -- Stored as cents
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL,
  UNIQUE(household_id, envelope_id)
);

-- =============================================================================
-- 3. MONTHLY BUDGETING & ALLOCATIONS
-- =============================================================================

CREATE TABLE IF NOT EXISTS budget_month (
  id              TEXT PRIMARY KEY,
  household_id    TEXT NOT NULL REFERENCES household(id) ON DELETE CASCADE,
  year            INTEGER NOT NULL,
  month           INTEGER NOT NULL CHECK (month BETWEEN 1 AND 12),
  income_cents    INTEGER NOT NULL DEFAULT 0, -- Total income for the month [cite: 86]
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,
  UNIQUE(household_id, year, month)
);

CREATE TABLE IF NOT EXISTS envelope_allocation (
  id              TEXT PRIMARY KEY,
  budget_month_id TEXT NOT NULL REFERENCES budget_month(id) ON DELETE CASCADE,
  envelope_id     TEXT NOT NULL REFERENCES envelope(id) ON DELETE CASCADE,
  budgeted_cents  INTEGER NOT NULL DEFAULT 0,
  rollover_cents  INTEGER NOT NULL DEFAULT 0, -- Auto-calculated/set on month start [cite: 88]
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,
  UNIQUE(budget_month_id, envelope_id)
);

-- =============================================================================
-- 4. ACCOUNTS & NET WORTH
-- =============================================================================

CREATE TABLE IF NOT EXISTS account (
  id                    TEXT PRIMARY KEY,
  household_id          TEXT NOT NULL REFERENCES household(id) ON DELETE CASCADE,
  name                  TEXT NOT NULL,
  type                  TEXT NOT NULL 
                        CHECK (type IN ('checking', 'savings', 'investment', 'retirement', 'credit_card', 'loan', 'mortgage')), [cite: 102, 103, 104, 105]
  balance_cents         INTEGER NOT NULL DEFAULT 0,
  debt_original_cents   INTEGER, -- Required for progress tracking [cite: 113, 116]
  is_archived           INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS account_snapshot (
  id            TEXT PRIMARY KEY,
  account_id    TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  balance_cents INTEGER NOT NULL,
  recorded_at   INTEGER NOT NULL -- Unix seconds [cite: 108, 110]
);

-- =============================================================================
-- 5. TRANSACTIONS & IMPORTING
-- =============================================================================

CREATE TABLE IF NOT EXISTS "transaction" (
  id                      TEXT PRIMARY KEY,
  household_id            TEXT NOT NULL REFERENCES household(id) ON DELETE CASCADE,
  account_id              TEXT REFERENCES account(id) ON DELETE SET NULL,
  -- IMPROVEMENT: Direct envelope assignment for 90% of use cases
  envelope_id             TEXT REFERENCES envelope(id) ON DELETE SET NULL, 
  amount_cents            INTEGER NOT NULL CHECK (amount_cents >= 0),
  is_debit                INTEGER NOT NULL DEFAULT 1 CHECK (is_debit IN (0, 1)),
  date                    INTEGER NOT NULL, -- Unix seconds (time zeroed)
  description             TEXT NOT NULL DEFAULT '',
  note                    TEXT,
  origin                  TEXT NOT NULL DEFAULT 'manual' 
                          CHECK (origin IN ('manual', 'import', 'merged')),
  import_status           TEXT 
                          CHECK (import_status IN ('pending', 'assigned', 'likely_duplicate', 'confirmed', 'rejected')), [cite: 74, 75]
  matched_transaction_id  TEXT REFERENCES transaction(id) ON DELETE SET NULL,
  is_flagged              INTEGER NOT NULL DEFAULT 0 CHECK (is_flagged IN (0, 1)),
  is_split                INTEGER NOT NULL DEFAULT 0 CHECK (is_split IN (0, 1)),
  assigned_at             INTEGER, -- Timestamp when moved from Inbox to Envelope [cite: 95]
  created_at              INTEGER NOT NULL,
  updated_at              INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS transaction_split (
  id              TEXT PRIMARY KEY,
  transaction_id  TEXT NOT NULL REFERENCES transaction(id) ON DELETE CASCADE,
  envelope_id     TEXT NOT NULL REFERENCES envelope(id) ON DELETE RESTRICT,
  amount_cents    INTEGER NOT NULL CHECK (amount_cents > 0), [cite: 93]
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS bank_mapping (
  id              TEXT PRIMARY KEY,
  household_id    TEXT NOT NULL REFERENCES household(id) ON DELETE CASCADE,
  label           TEXT NOT NULL, -- e.g., "Chase Checking" [cite: 62]
  col_date        TEXT NOT NULL,
  col_amount      TEXT NOT NULL,
  col_description TEXT NOT NULL,
  col_type        TEXT,
  amount_sign     TEXT NOT NULL DEFAULT 'negative' CHECK (amount_sign IN ('negative', 'positive')), [cite: 60]
  date_format     TEXT NOT NULL DEFAULT '%m/%d/%Y',
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,
  UNIQUE(household_id, label)
);

-- =============================================================================
-- 6. VIEWS (THE LOGIC ENGINE)
-- =============================================================================

-- IMPROVEMENT: Summary of income vs. budgeted vs. unallocated [cite: 86]
CREATE VIEW IF NOT EXISTS v_budget_month_summary AS
SELECT 
    bm.id AS budget_month_id,
    bm.year,
    bm.month,
    bm.income_cents,
    (SELECT COALESCE(SUM(budgeted_cents), 0) 
     FROM envelope_allocation 
     WHERE budget_month_id = bm.id) AS total_budgeted_cents,
    bm.income_cents - (SELECT COALESCE(SUM(budgeted_cents), 0) 
                       FROM envelope_allocation 
                       WHERE budget_month_id = bm.id) AS unallocated_cents
FROM budget_month bm;

-- Comprehensive Envelope Balance View [cite: 172]
-- Handles both direct transaction assignments AND splits
CREATE VIEW IF NOT EXISTS v_envelope_balance AS
WITH spent_summary AS (
    -- Sum from direct assignments
    SELECT envelope_id, SUM(CASE WHEN is_debit = 1 THEN amount_cents ELSE -amount_cents END) as total
    FROM transaction WHERE envelope_id IS NOT NULL AND assigned_at IS NOT NULL GROUP BY envelope_id
    UNION ALL
    -- Sum from splits
    SELECT ts.envelope_id, SUM(CASE WHEN t.is_debit = 1 THEN ts.amount_cents ELSE -ts.amount_cents END) as total
    FROM transaction_split ts JOIN transaction t ON ts.transaction_id = t.id 
    WHERE t.assigned_at IS NOT NULL GROUP BY ts.envelope_id
)
SELECT
  e.id                              AS envelope_id,
  e.name                            AS envelope_name,
  ea.budget_month_id,
  ea.budgeted_cents,
  ea.rollover_cents,
  (ea.budgeted_cents + ea.rollover_cents) AS available_cents,
  COALESCE((SELECT SUM(total) FROM spent_summary WHERE envelope_id = e.id), 0) AS spent_cents,
  (ea.budgeted_cents + ea.rollover_cents) - COALESCE((SELECT SUM(total) FROM spent_summary WHERE envelope_id = e.id), 0) AS remaining_cents
FROM envelope e
JOIN envelope_allocation ea ON ea.envelope_id = e.id
WHERE e.archived_at IS NULL;

-- Inbox View for unassigned items [cite: 91, 172]
CREATE VIEW IF NOT EXISTS v_inbox AS
SELECT t.*, a.name AS account_name
FROM transaction t
LEFT JOIN account a ON t.account_id = a.id
WHERE t.assigned_at IS NULL AND (t.import_status IS NULL OR t.import_status IN ('pending', 'likely_duplicate'));

-- Net Worth View [cite: 111, 174]
CREATE VIEW IF NOT EXISTS v_net_worth_current AS
SELECT
  SUM(CASE WHEN type IN ('checking','savings','investment','retirement') THEN balance_cents ELSE 0 END) AS assets,
  SUM(CASE WHEN type IN ('credit_card','loan','mortgage') THEN balance_cents ELSE 0 END) AS liabilities,
  SUM(CASE WHEN type IN ('checking','savings','investment','retirement') THEN balance_cents ELSE -balance_cents END) AS net_worth
FROM account WHERE is_archived = 0;

-- Debt Payoff View [cite: 113, 116, 176]
CREATE VIEW IF NOT EXISTS v_debt_summary AS
SELECT
  id, name, type, balance_cents, debt_original_cents,
  CASE WHEN debt_original_cents > 0 THEN ROUND((1.0 - (CAST(balance_cents AS REAL) / debt_original_cents)) * 100, 1) ELSE 0 END AS percent_paid
FROM account WHERE type IN ('credit_card', 'loan', 'mortgage') AND is_archived = 0;

-- =============================================================================
-- 7. MIGRATIONS
-- =============================================================================

CREATE TABLE IF NOT EXISTS schema_migration (
  version     INTEGER PRIMARY KEY,
  applied_at  INTEGER NOT NULL,
  description TEXT NOT NULL
);

INSERT OR IGNORE INTO schema_migration (version, applied_at, description)
VALUES (1, strftime('%s', 'now'), 'Initial schema with optimized transaction assignments and unallocated funds view');