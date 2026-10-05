-- Jbaya collection system schema (idempotent: safe to run on every startup)

CREATE TABLE IF NOT EXISTS sectors (
    id              SERIAL PRIMARY KEY,
    code            VARCHAR(30) UNIQUE NOT NULL,          -- e.g. 'S-01'
    name            TEXT NOT NULL,                        -- e.g. 'قاطع 1 - المنصور'
    mahalla         VARCHAR(20),                          -- e.g. '600'
    polygon         JSONB NOT NULL,                       -- [[lat, lng], [lat, lng], ...]
    active          BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS employees (
    id              SERIAL PRIMARY KEY,
    employee_code   VARCHAR(30) UNIQUE NOT NULL,          -- e.g. 'JB-0492'
    full_name       TEXT NOT NULL,
    role            VARCHAR(20) NOT NULL CHECK (role IN ('collector','supervisor','finance','command','hr','admin')),
    password_hash   TEXT NOT NULL,
    phone           VARCHAR(20),                          -- normalized 9647XXXXXXXXX
    sector_id       INT REFERENCES sectors(id),
    supervisor_id   INT REFERENCES employees(id),
    active          BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS tariffs (
    property_class      VARCHAR(20) PRIMARY KEY CHECK (property_class IN ('Household','Business','Industrial','Agricultural')),
    unit_rate           NUMERIC(12,2) NOT NULL,           -- IQD per m3 consumed
    monthly_estimate    NUMERIC(12,2) NOT NULL,           -- IQD per 30 days when no reading is possible
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS citizens (
    id                  SERIAL PRIMARY KEY,
    full_name           TEXT NOT NULL,
    whatsapp_phone      VARCHAR(20) NOT NULL,             -- normalized 9647XXXXXXXXX
    phone_verified_at   TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_citizens_phone ON citizens(whatsapp_phone);

CREATE SEQUENCE IF NOT EXISTS property_code_seq START 1;

CREATE TABLE IF NOT EXISTS properties (
    id              SERIAL PRIMARY KEY,
    property_code   VARCHAR(20) UNIQUE NOT NULL,          -- 'BGD-000001'
    citizen_id      INT NOT NULL REFERENCES citizens(id),
    sector_id       INT NOT NULL REFERENCES sectors(id),
    address         TEXT NOT NULL,
    property_class  VARCHAR(20) NOT NULL REFERENCES tariffs(property_class),
    lat             DOUBLE PRECISION NOT NULL,
    lng             DOUBLE PRECISION NOT NULL,
    gps_accuracy_m  REAL,
    meter_serial    VARCHAR(50),
    meter_status    VARCHAR(20) NOT NULL DEFAULT 'working' CHECK (meter_status IN ('working','none','broken')),
    status          VARCHAR(20) NOT NULL DEFAULT 'pending_otp' CHECK (status IN ('pending_otp','active','suspended')),
    flags           JSONB NOT NULL DEFAULT '[]'::jsonb,
    registered_by   INT NOT NULL REFERENCES employees(id),
    registered_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    activated_at    TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_properties_sector ON properties(sector_id);

-- Every confirmed meter reading. The latest one is the "previous" reading for the next visit.
CREATE TABLE IF NOT EXISTS meter_readings (
    id              SERIAL PRIMARY KEY,
    property_id     INT NOT NULL REFERENCES properties(id),
    bill_id         INT,
    reading         NUMERIC(14,3) NOT NULL,
    reading_type    VARCHAR(20) NOT NULL CHECK (reading_type IN ('baseline','actual','rebaseline')),
    photo_url       TEXT,
    taken_by        INT NOT NULL REFERENCES employees(id),
    taken_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_readings_property ON meter_readings(property_id, taken_at DESC);

CREATE TABLE IF NOT EXISTS bills (
    id                  SERIAL PRIMARY KEY,
    property_id         INT NOT NULL REFERENCES properties(id),
    collector_id        INT NOT NULL REFERENCES employees(id),
    visit_type          VARCHAR(20) NOT NULL CHECK (visit_type IN ('first_visit','periodic')),
    billing_method      VARCHAR(20) NOT NULL CHECK (billing_method IN ('reading','estimate')),
    previous_reading    NUMERIC(14,3),
    current_reading     NUMERIC(14,3),
    consumption         NUMERIC(14,3),
    unit_rate           NUMERIC(12,2),
    period_days         INT NOT NULL,
    gov_amount          NUMERIC(14,2) NOT NULL,
    company_fee         NUMERIC(14,2) NOT NULL,
    total_amount        NUMERIC(14,2) NOT NULL,
    status              VARCHAR(20) NOT NULL CHECK (status IN ('pending_approval','blocked_review','awaiting_otp','paid','cancelled')),
    flags               JSONB NOT NULL DEFAULT '[]'::jsonb,
    review_note         TEXT,
    reviewed_by         INT REFERENCES employees(id),
    reviewed_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    paid_at             TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_bills_property ON bills(property_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bills_collector ON bills(collector_id, paid_at);

CREATE SEQUENCE IF NOT EXISTS receipt_no_seq START 100000;

CREATE TABLE IF NOT EXISTS receipts (
    id                      SERIAL PRIMARY KEY,
    receipt_no              VARCHAR(20) UNIQUE NOT NULL,   -- 'RCP-100000'
    bill_id                 INT UNIQUE NOT NULL REFERENCES bills(id),
    property_id             INT NOT NULL REFERENCES properties(id),
    collector_id            INT NOT NULL REFERENCES employees(id),
    gov_amount              NUMERIC(14,2) NOT NULL,
    company_fee             NUMERIC(14,2) NOT NULL,
    total_amount            NUMERIC(14,2) NOT NULL,
    verification_method     VARCHAR(20) NOT NULL CHECK (verification_method IN ('otp','master_code')),
    reconciliation_id       INT,
    issued_at               TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_receipts_collector ON receipts(collector_id, issued_at);

-- OTP challenges. Only an HMAC of the code is stored; the plain code only ever goes to WhatsApp.
CREATE TABLE IF NOT EXISTS otp_challenges (
    id              SERIAL PRIMARY KEY,
    purpose         VARCHAR(20) NOT NULL CHECK (purpose IN ('registration','payment')),
    property_id     INT NOT NULL REFERENCES properties(id),
    bill_id         INT REFERENCES bills(id),
    phone           VARCHAR(20) NOT NULL,
    code_hash       TEXT NOT NULL,
    expires_at      TIMESTAMPTZ NOT NULL,
    attempts        INT NOT NULL DEFAULT 0,
    max_attempts    INT NOT NULL,
    status          VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','verified','expired','locked','superseded')),
    created_by      INT NOT NULL REFERENCES employees(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    verified_at     TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_otp_property ON otp_challenges(property_id, created_at DESC);

CREATE TABLE IF NOT EXISTS master_code_uses (
    id              SERIAL PRIMARY KEY,
    collector_id    INT NOT NULL REFERENCES employees(id),
    property_id     INT NOT NULL REFERENCES properties(id),
    bill_id         INT REFERENCES bills(id),
    purpose         VARCHAR(20) NOT NULL CHECK (purpose IN ('registration','payment')),
    reason          TEXT NOT NULL,
    window_index    BIGINT NOT NULL,
    used_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_master_uses_collector ON master_code_uses(collector_id, used_at);

CREATE TABLE IF NOT EXISTS reconciliations (
    id                  SERIAL PRIMARY KEY,
    collector_id        INT NOT NULL REFERENCES employees(id),
    supervisor_id       INT NOT NULL REFERENCES employees(id),
    counted_cash        NUMERIC(14,2) NOT NULL,
    expected_cash       NUMERIC(14,2) NOT NULL,
    difference          NUMERIC(14,2) NOT NULL,       -- counted - expected (negative = shortage)
    receipts_count      INT NOT NULL,
    status              VARCHAR(20) NOT NULL CHECK (status IN ('matched','shortage','surplus')),
    note                TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS whatsapp_messages (
    id              SERIAL PRIMARY KEY,
    phone           VARCHAR(20) NOT NULL,
    template        VARCHAR(60) NOT NULL,
    preview         TEXT,                             -- never contains the OTP code
    status          VARCHAR(20) NOT NULL,             -- sent / failed / console
    provider_id     TEXT,
    error           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Tamper-evident audit log: each row hashes the previous row's hash.
CREATE TABLE IF NOT EXISTS audit_log (
    id              BIGSERIAL PRIMARY KEY,
    actor_id        INT,
    action          VARCHAR(60) NOT NULL,
    entity          VARCHAR(40),
    entity_id       TEXT,
    details         JSONB NOT NULL DEFAULT '{}'::jsonb,
    prev_hash       TEXT,
    hash            TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------
-- Legacy tables kept so the old /sync, /survey and IoT endpoints keep working
CREATE TABLE IF NOT EXISTS field_collections (
    id SERIAL PRIMARY KEY,
    serial_number VARCHAR(50),
    mahalla VARCHAR(50),
    house_address TEXT,
    reading_value FLOAT,
    collection_path VARCHAR(50),
    collector_id VARCHAR(50),
    timestamp TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS smart_meter_telemetry (
    time TIMESTAMPTZ NOT NULL,
    serial_number VARCHAR(50),
    flow_rate FLOAT,
    battery_voltage FLOAT,
    tamper_flag BOOLEAN
);
