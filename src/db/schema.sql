-- =============================================================================
-- Envelope Budget App — SQLite Schema
-- Version: 1.0
-- Storage: SQLite WASM (runs entirely in browser, no server required)
--
-- Conventions:
--   - All IDs are TEXT (UUIDs generated in app layer)
--   - All monetary values stored as INTEGER cents (never floats)
--   - All timestamps stored as INTEGER Unix seconds
--   - All booleans stored as INTEGER 0 or 1
--   - Foreign keys enforced via PRAGMA foreign_keys = ON
-- =============================================================================

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

-- =============================================================================
-- HOUSEHOLD
-- Root record. One per database file. Holds license state.
-- =============================================================================

CREATE TABLE IF NOT EXISTS household (
  id                TEXT PRIMARY KEY,
  name              TEXT NOT NULL DEFAULT 'Our Budget',
  license_key       TEXT,
  license_status    TEXT NOT NULL DEFAULT 'free'
                    CHECK (license_status IN ('free', 'premium')),
  db_version        INTEGER NOT NULL DEFAULT 1,
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
);

-- =============================================================================
-- ENVELOPE GROUPS
-- Optional user-defined grouping for envelopes (e.g. "Housing", "Food").
-- Envelopes without a group_id are ungrouped (flat list).
-- =============================================================================

CREATE TABLE IF NOT EXISTS envelope_group (
  id            TEXT PRIMARY KEY,
  household_id  TEXT NOT NULL REFERENCES household(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  sort_order    INTEGER NOT NULL DEFAULT 0,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_envelope_group_household
  ON envelope_group(household_id);

-- =============================================================================
-- ENVELOPES
-- The core budgeting unit. group_id is nullable (ungrouped envelopes allowed).
-- archived_at: soft delete — archived envelopes are hidden but history preserved.
-- =============================================================================

CREATE TABLE IF NOT EXISTS envelope (
  id            TEXT PRIMARY KEY,
  household_id  TEXT NOT NULL REFERENCES household(id) ON DELETE CASCADE,
  group_id      TEXT REFERENCES envelope_group(id) ON DELETE SET NULL,
  name          TEXT NOT NULL,
  sort_order    INTEGER NOT NULL DEFAULT 0,
  archived_at   INTEGER,                          -- NULL = active
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_envelope_household
  ON envelope(household_id);
CREATE INDEX IF NOT EXISTS idx_envelope_group
  ON envelope(group_id);

-- =============================================================================
-- BUDGET TEMPLATE
-- One row per envelope storing the default monthly amount.
-- Applying the template copies these amounts into envelope_allocation
-- for the new month, with rollover added on top.
-- =============================================================================

CREATE TABLE IF NOT EXISTS budget_template (
  id            TEXT PRIMARY KEY,
  household_id  TEXT NOT NULL REFERENCES household(id) ON DELETE CASCADE,
  envelope_id   TEXT NOT NULL REFERENCES envelope(id) ON DELETE CASCADE,
  amount_cents  INTEGER NOT NULL DEFAULT 0,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL,

  UNIQUE(household_id, envelope_id)
);

CREATE INDEX IF NOT EXISTS idx_budget_template_household
  ON budget_template(household_id);

-- =============================================================================
-- BUDGET MONTHS
-- One record per calendar month. Tracks total income for that month.
-- year + month are stored separately for easy filtering (no date parsing needed).
-- =============================================================================

CREATE TABLE IF NOT EXISTS budget_month (
  id              TEXT PRIMARY KEY,
  household_id    TEXT NOT NULL REFERENCES household(id) ON DELETE CASCADE,
  year            INTEGER NOT NULL,
  month           INTEGER NOT NULL CHECK (month BETWEEN 1 AND 12),
  income_cents    INTEGER NOT NULL DEFAULT 0,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,

  UNIQUE(household_id, year, month)
);

CREATE INDEX IF NOT EXISTS idx_budget_month_household
  ON budget_month(household_id);
CREATE INDEX IF NOT EXISTS idx_budget_month_year_month
  ON budget_month(household_id, year, month);

-- =============================================================================
-- ENVELOPE ALLOCATIONS
-- One row per envelope per month.
-- budgeted_cents: amount set from template (editable after apply)
-- rollover_cents: unspent balance carried forward from prior month
--                 written once at month-close, never recalculated
-- spent_cents is always derived: SUM of transaction_split amounts for
--             this envelope + month — never stored here
-- =============================================================================

CREATE TABLE IF NOT EXISTS envelope_allocation (
  id              TEXT PRIMARY KEY,
  budget_month_id TEXT NOT NULL REFERENCES budget_month(id) ON DELETE CASCADE,
  envelope_id     TEXT NOT NULL REFERENCES envelope(id) ON DELETE CASCADE,
  budgeted_cents  INTEGER NOT NULL DEFAULT 0,
  rollover_cents  INTEGER NOT NULL DEFAULT 0,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,

  UNIQUE(budget_month_id, envelope_id)
);

CREATE INDEX IF NOT EXISTS idx_allocation_budget_month
  ON envelope_allocation(budget_month_id);
CREATE INDEX IF NOT EXISTS idx_allocation_envelope
  ON envelope_allocation(envelope_id);

-- =============================================================================
-- ACCOUNTS
-- Tracks financial accounts for net worth calculation.
-- balance_cents: current balance, updated manually by user or via CSV import.
-- type drives asset vs liability classification:
--   assets:      checking, savings, investment, retirement
--   liabilities: credit_card, loan, mortgage
-- debt_original_cents: starting balance for debt payoff tracking (set once).
-- =============================================================================

CREATE TABLE IF NOT EXISTS account (
  id                    TEXT PRIMARY KEY,
  household_id          TEXT NOT NULL REFERENCES household(id) ON DELETE CASCADE,
  name                  TEXT NOT NULL,
  type                  TEXT NOT NULL
                        CHECK (type IN (
                          'checking', 'savings',
                          'investment', 'retirement',
                          'credit_card', 'loan', 'mortgage'
                        )),
  balance_cents         INTEGER NOT NULL DEFAULT 0,
  debt_original_cents   INTEGER,                   -- NULL for asset accounts
  is_archived           INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_account_household
  ON account(household_id);

-- =============================================================================
-- ACCOUNT SNAPSHOTS
-- Time-series record of account balances.
-- Written every time the user updates an account balance.
-- Powers the net worth timeline chart.
-- =============================================================================

CREATE TABLE IF NOT EXISTS account_snapshot (
  id            TEXT PRIMARY KEY,
  account_id    TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  balance_cents INTEGER NOT NULL,
  recorded_at   INTEGER NOT NULL           -- Unix seconds, set by app on save
);

CREATE INDEX IF NOT EXISTS idx_snapshot_account
  ON account_snapshot(account_id);
CREATE INDEX IF NOT EXISTS idx_snapshot_recorded_at
  ON account_snapshot(account_id, recorded_at);

-- =============================================================================
-- TRANSACTIONS
-- Central table. Covers manual entries, CSV imports, and merged records.
--
-- origin values:
--   'manual'  — user entered by hand
--   'import'  — came from CSV import, not yet matched
--   'merged'  — import row merged with an existing manual entry
--
-- import_status values:
--   NULL              — not from an import (manual entry)
--   'pending'         — in inbox, unreviewed
--   'assigned'        — envelope assigned, cleared from inbox
--   'likely_duplicate'— import match found, awaiting user decision
--   'confirmed'       — user confirmed the duplicate merge
--   'rejected'        — user rejected the match, split back into two rows
--
-- matched_transaction_id:
--   Self-referential. When a merge occurs, both the manual and import
--   rows point at each other. Cleared on rejection.
--
-- account_id is nullable to support manual entries not tied to an account
-- (e.g. cash transactions entered on mobile before account is set up).
--
-- amount_cents is always stored as a positive integer.
-- is_debit flag clarifies direction: 1 = money out, 0 = money in.
-- =============================================================================

CREATE TABLE IF NOT EXISTS transaction (
  id                      TEXT PRIMARY KEY,
  household_id            TEXT NOT NULL REFERENCES household(id) ON DELETE CASCADE,
  account_id              TEXT REFERENCES account(id) ON DELETE SET NULL,
  amount_cents            INTEGER NOT NULL CHECK (amount_cents >= 0),
  is_debit                INTEGER NOT NULL DEFAULT 1 CHECK (is_debit IN (0, 1)),
  date                    INTEGER NOT NULL,         -- Unix seconds (date only, time zeroed)
  description             TEXT NOT NULL DEFAULT '',
  note                    TEXT,                     -- user-added memo, preserved on merge
  origin                  TEXT NOT NULL DEFAULT 'manual'
                          CHECK (origin IN ('manual', 'import', 'merged')),
  import_status           TEXT
                          CHECK (import_status IN (
                            'pending', 'assigned',
                            'likely_duplicate', 'confirmed', 'rejected'
                          )),
  matched_transaction_id  TEXT REFERENCES transaction(id) ON DELETE SET NULL,
  is_flagged              INTEGER NOT NULL DEFAULT 0 CHECK (is_flagged IN (0, 1)),
  is_split                INTEGER NOT NULL DEFAULT 0 CHECK (is_split IN (0, 1)),
  assigned_at             INTEGER,                  -- timestamp when moved out of inbox
  created_at              INTEGER NOT NULL,
  updated_at              INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_transaction_household
  ON transaction(household_id);
CREATE INDEX IF NOT EXISTS idx_transaction_account
  ON transaction(account_id);
CREATE INDEX IF NOT EXISTS idx_transaction_date
  ON transaction(household_id, date);
CREATE INDEX IF NOT EXISTS idx_transaction_inbox
  ON transaction(household_id, import_status)
  WHERE import_status IS NULL OR import_status IN ('pending', 'likely_duplicate');
CREATE INDEX IF NOT EXISTS idx_transaction_flagged
  ON transaction(household_id, is_flagged)
  WHERE is_flagged = 1;
CREATE INDEX IF NOT EXISTS idx_transaction_matched
  ON transaction(matched_transaction_id)
  WHERE matched_transaction_id IS NOT NULL;

-- =============================================================================
-- TRANSACTION SPLITS
-- Used when a transaction is divided across multiple envelopes.
-- is_split = 1 on the parent transaction signals splits exist.
-- SUM(amount_cents) across all splits must equal transaction.amount_cents
-- — enforced in the app layer, not here.
-- For simple single-envelope assignments, no split row is created;
-- the envelope_id is stored directly on the transaction via a view (see below).
-- =============================================================================

CREATE TABLE IF NOT EXISTS transaction_split (
  id              TEXT PRIMARY KEY,
  transaction_id  TEXT NOT NULL REFERENCES transaction(id) ON DELETE CASCADE,
  envelope_id     TEXT NOT NULL REFERENCES envelope(id) ON DELETE RESTRICT,
  amount_cents    INTEGER NOT NULL CHECK (amount_cents > 0),
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_split_transaction
  ON transaction_split(transaction_id);
CREATE INDEX IF NOT EXISTS idx_split_envelope
  ON transaction_split(envelope_id);

-- =============================================================================
-- BANK MAPPINGS
-- Remembers CSV column layout per bank (keyed by user-given label).
-- col_* fields store the exact column header string from the CSV file.
-- amount_sign: 'negative' = debits are negative numbers in the CSV,
--              'positive' = debits are positive numbers in the CSV.
-- date_format: strptime-style format string, e.g. '%m/%d/%Y' or '%Y-%m-%d'.
-- =============================================================================

CREATE TABLE IF NOT EXISTS bank_mapping (
  id              TEXT PRIMARY KEY,
  household_id    TEXT NOT NULL REFERENCES household(id) ON DELETE CASCADE,
  label           TEXT NOT NULL,               -- user-given name e.g. "Chase Checking"
  col_date        TEXT NOT NULL,               -- e.g. "Transaction Date"
  col_amount      TEXT NOT NULL,               -- e.g. "Amount"
  col_description TEXT NOT NULL,               -- e.g. "Description"
  col_type        TEXT,                        -- optional debit/credit column
  amount_sign     TEXT NOT NULL DEFAULT 'negative'
                  CHECK (amount_sign IN ('negative', 'positive')),
  date_format     TEXT NOT NULL DEFAULT '%m/%d/%Y',
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,

  UNIQUE(household_id, label)
);

CREATE INDEX IF NOT EXISTS idx_bank_mapping_household
  ON bank_mapping(household_id);

-- =============================================================================
-- SETTINGS
-- Key-value store for app preferences and sync configuration.
-- Avoids adding columns to household for every new setting.
-- =============================================================================

CREATE TABLE IF NOT EXISTS setting (
  key           TEXT PRIMARY KEY,
  value         TEXT,
  updated_at    INTEGER NOT NULL
);

-- Seed default settings
INSERT OR IGNORE INTO setting (key, value, updated_at) VALUES
  ('icloud_sync_enabled',   '0',        strftime('%s', 'now')),
  ('icloud_sync_path',      NULL,       strftime('%s', 'now')),
  ('last_sync_at',          NULL,       strftime('%s', 'now')),
  ('default_date_format',   '%m/%d/%Y', strftime('%s', 'now')),
  ('currency_symbol',       '$',        strftime('%s', 'now')),
  ('first_day_of_month',    '1',        strftime('%s', 'now')),
  ('theme',                 'system',   strftime('%s', 'now'));

-- =============================================================================
-- USEFUL VIEWS
-- Pre-built queries the app layer can call directly.
-- =============================================================================

-- Net worth at any point: sum assets, subtract liabilities
CREATE VIEW IF NOT EXISTS v_net_worth_current AS
SELECT
  SUM(CASE
    WHEN type IN ('checking','savings','investment','retirement')
    THEN balance_cents ELSE 0
  END) AS total_assets_cents,
  SUM(CASE
    WHEN type IN ('credit_card','loan','mortgage')
    THEN balance_cents ELSE 0
  END) AS total_liabilities_cents,
  SUM(CASE
    WHEN type IN ('checking','savings','investment','retirement')
    THEN balance_cents
    WHEN type IN ('credit_card','loan','mortgage')
    THEN -balance_cents
    ELSE 0
  END) AS net_worth_cents
FROM account
WHERE is_archived = 0;

-- Inbox: all transactions needing user action
CREATE VIEW IF NOT EXISTS v_inbox AS
SELECT
  t.*,
  a.name AS account_name,
  a.type AS account_type
FROM transaction t
LEFT JOIN account a ON t.account_id = a.id
WHERE
  t.assigned_at IS NULL
  AND (
    t.import_status IS NULL          -- manual entries not yet assigned
    OR t.import_status = 'pending'
    OR t.import_status = 'likely_duplicate'
  )
ORDER BY t.date DESC, t.created_at DESC;

-- Envelope balances for a given month (app passes year+month as parameters)
CREATE VIEW IF NOT EXISTS v_envelope_balance AS
SELECT
  e.id                              AS envelope_id,
  e.name                            AS envelope_name,
  eg.name                           AS group_name,
  ea.budget_month_id,
  ea.budgeted_cents,
  ea.rollover_cents,
  ea.budgeted_cents + ea.rollover_cents
                                    AS available_cents,
  COALESCE(SUM(
    CASE WHEN t.is_debit = 1 THEN ts.amount_cents ELSE -ts.amount_cents END
  ), 0)                             AS spent_cents,
  ea.budgeted_cents + ea.rollover_cents - COALESCE(SUM(
    CASE WHEN t.is_debit = 1 THEN ts.amount_cents ELSE -ts.amount_cents END
  ), 0)                             AS remaining_cents
FROM envelope e
LEFT JOIN envelope_group eg         ON e.group_id = eg.id
LEFT JOIN envelope_allocation ea    ON ea.envelope_id = e.id
LEFT JOIN transaction_split ts      ON ts.envelope_id = e.id
LEFT JOIN transaction t             ON ts.transaction_id = t.id
  AND t.assigned_at IS NOT NULL
WHERE e.archived_at IS NULL
GROUP BY e.id, ea.budget_month_id;

-- Debt payoff summary per account
CREATE VIEW IF NOT EXISTS v_debt_summary AS
SELECT
  a.id,
  a.name,
  a.type,
  a.balance_cents                   AS current_balance_cents,
  a.debt_original_cents,
  CASE
    WHEN a.debt_original_cents > 0
    THEN ROUND(
      (1.0 - (CAST(a.balance_cents AS REAL) / a.debt_original_cents)) * 100,
      1
    )
    ELSE 0
  END                               AS percent_paid,
  a.debt_original_cents - a.balance_cents
                                    AS amount_paid_cents
FROM account a
WHERE a.type IN ('credit_card', 'loan', 'mortgage')
  AND a.is_archived = 0;

-- =============================================================================
-- SCHEMA VERSION TRACKING
-- Simple table to manage future migrations.
-- =============================================================================

CREATE TABLE IF NOT EXISTS schema_migration (
  version     INTEGER PRIMARY KEY,
  applied_at  INTEGER NOT NULL,
  description TEXT NOT NULL
);

INSERT OR IGNORE INTO schema_migration (version, applied_at, description)
VALUES (1, strftime('%s', 'now'), 'Initial schema');
