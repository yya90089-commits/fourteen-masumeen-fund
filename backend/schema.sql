-- PostgreSQL schema foundation for Fourteen Masumeen Fund.
-- This file defines storage only; it does not implement authentication or a running API.
-- Never store plaintext passwords, bank credentials, or receipt files in this database.
-- Store only private object-storage keys for receipt files.

CREATE TABLE IF NOT EXISTS users (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    username VARCHAR(80) NOT NULL UNIQUE,
    display_name VARCHAR(160) NOT NULL,
    password_hash TEXT NOT NULL,
    role VARCHAR(20) NOT NULL CHECK (role IN ('super_admin', 'treasurer', 'member')),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS fund_settings (
    id SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    fund_name VARCHAR(160) NOT NULL DEFAULT 'صندوق خانوادگی چهارده معصوم',
    is_paused BOOLEAN NOT NULL DEFAULT TRUE,
    updated_by BIGINT REFERENCES users(id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS periods (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title VARCHAR(120) NOT NULL,
    starts_on DATE NOT NULL,
    due_on DATE NOT NULL,
    payout_on DATE NOT NULL,
    approved_amount NUMERIC(18,2) NOT NULL CHECK (approved_amount >= 0),
    status VARCHAR(20) NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft', 'open', 'locked', 'paid', 'cancelled')),
    created_by BIGINT NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (starts_on <= due_on AND due_on <= payout_on)
);

CREATE TABLE IF NOT EXISTS period_members (
    period_id BIGINT NOT NULL REFERENCES periods(id),
    user_id BIGINT NOT NULL REFERENCES users(id),
    sequence_no INTEGER NOT NULL CHECK (sequence_no > 0),
    is_recipient BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (period_id, user_id),
    UNIQUE (period_id, sequence_no)
);

CREATE TABLE IF NOT EXISTS contributions (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    period_id BIGINT NOT NULL REFERENCES periods(id),
    member_id BIGINT NOT NULL REFERENCES users(id),
    amount NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    paid_at TIMESTAMPTZ,
    status VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'approved', 'rejected')),
    reviewed_by BIGINT REFERENCES users(id),
    reviewed_at TIMESTAMPTZ,
    rejection_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (reviewed_by IS NULL OR reviewed_by <> member_id),
    CHECK (
        (status = 'pending' AND reviewed_by IS NULL AND reviewed_at IS NULL)
        OR (status = 'approved' AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL)
        OR (status = 'rejected' AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL
            AND rejection_reason IS NOT NULL AND length(trim(rejection_reason)) > 0)
    )
);

CREATE TABLE IF NOT EXISTS receipts (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    contribution_id BIGINT NOT NULL REFERENCES contributions(id),
    uploaded_by BIGINT NOT NULL REFERENCES users(id),
    private_object_key TEXT NOT NULL UNIQUE,
    original_filename VARCHAR(255) NOT NULL,
    content_type VARCHAR(100) NOT NULL,
    file_size_bytes BIGINT NOT NULL CHECK (file_size_bytes > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS payouts (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    period_id BIGINT NOT NULL REFERENCES periods(id),
    recipient_id BIGINT NOT NULL REFERENCES users(id),
    amount NUMERIC(18,2) NOT NULL CHECK (amount >= 0),
    paid_at TIMESTAMPTZ,
    status VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'approved', 'cancelled')),
    recorded_by BIGINT NOT NULL REFERENCES users(id),
    second_approved_by BIGINT REFERENCES users(id),
    note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (second_approved_by IS NULL OR second_approved_by <> recorded_by)
);

-- Append-only accounting journal. Corrections must be new reversing/correcting entries.
CREATE TABLE IF NOT EXISTS ledger_entries (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    period_id BIGINT NOT NULL REFERENCES periods(id),
    entry_type VARCHAR(30) NOT NULL
        CHECK (entry_type IN ('contribution', 'payout', 'reversal', 'adjustment')),
    amount NUMERIC(18,2) NOT NULL CHECK (amount <> 0),
    related_contribution_id BIGINT REFERENCES contributions(id),
    related_payout_id BIGINT REFERENCES payouts(id),
    reverses_entry_id BIGINT REFERENCES ledger_entries(id),
    description TEXT NOT NULL,
    created_by BIGINT NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS notifications (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT REFERENCES users(id),
    title VARCHAR(180) NOT NULL,
    body TEXT NOT NULL,
    is_public BOOLEAN NOT NULL DEFAULT FALSE,
    read_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS messages (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sender_id BIGINT NOT NULL REFERENCES users(id),
    recipient_id BIGINT REFERENCES users(id),
    body TEXT NOT NULL,
    is_public BOOLEAN NOT NULL DEFAULT FALSE,
    read_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (is_public = TRUE OR recipient_id IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS audit_events (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    actor_id BIGINT REFERENCES users(id),
    action VARCHAR(100) NOT NULL,
    entity_type VARCHAR(80) NOT NULL,
    entity_id VARCHAR(100),
    details JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_contributions_period_status
    ON contributions(period_id, status);
CREATE INDEX IF NOT EXISTS idx_contributions_member
    ON contributions(member_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ledger_period
    ON ledger_entries(period_id, created_at);
CREATE INDEX IF NOT EXISTS idx_notifications_user
    ON notifications(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_created
    ON audit_events(created_at DESC);

-- Application-level requirements still needed:
-- * Enforce role permissions on every API request (never trust the browser).
-- * Verify file size/type and store receipt files in private object storage.
-- * Use Argon2id/scrypt password hashing and secure, HTTPS-only sessions.
-- * Prevent ledger UPDATE/DELETE with database permissions or immutable triggers.
-- * Ensure a contribution cannot be reviewed by its owner (also enforce in API).
-- * Calculate recipient totals only from approved contributions in the same period.
