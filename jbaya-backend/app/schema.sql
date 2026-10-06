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

-- ---------------------------------------------------------------
-- Phase 1 additions (ALTER ... IF NOT EXISTS keeps existing databases working)

ALTER TABLE employees ADD COLUMN IF NOT EXISTS daily_target_iqd NUMERIC(14,2);

ALTER TABLE bills ADD COLUMN IF NOT EXISTS photo_path TEXT;
ALTER TABLE bills ADD COLUMN IF NOT EXISTS ocr_reading NUMERIC(14,3);

ALTER TABLE reconciliations ADD COLUMN IF NOT EXISTS denominations JSONB;
ALTER TABLE reconciliations ADD COLUMN IF NOT EXISTS resolution_status VARCHAR(20) NOT NULL DEFAULT 'none_needed';
ALTER TABLE reconciliations ADD COLUMN IF NOT EXISTS resolution_action VARCHAR(30);
ALTER TABLE reconciliations ADD COLUMN IF NOT EXISTS resolution_note TEXT;
ALTER TABLE reconciliations ADD COLUMN IF NOT EXISTS resolved_by INT REFERENCES employees(id);
ALTER TABLE reconciliations ADD COLUMN IF NOT EXISTS resolved_at TIMESTAMPTZ;
ALTER TABLE reconciliations ADD COLUMN IF NOT EXISTS deposit_id INT;

-- Supervisor -> bank. Finance verifies against the bank statement.
CREATE TABLE IF NOT EXISTS bank_deposits (
    id                  SERIAL PRIMARY KEY,
    supervisor_id       INT NOT NULL REFERENCES employees(id),
    amount              NUMERIC(14,2) NOT NULL,      -- amount written on the bank slip
    expected_amount     NUMERIC(14,2) NOT NULL,      -- cash the supervisor counted from collectors
    difference          NUMERIC(14,2) NOT NULL,      -- amount - expected
    bank_name           TEXT NOT NULL,
    slip_number         VARCHAR(60) NOT NULL,
    slip_photo_path     TEXT NOT NULL,
    status              VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','verified','rejected')),
    finance_note        TEXT,
    verified_by         INT REFERENCES employees(id),
    verified_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS sos_alerts (
    id                  SERIAL PRIMARY KEY,
    employee_id         INT NOT NULL REFERENCES employees(id),
    lat                 DOUBLE PRECISION,
    lng                 DOUBLE PRECISION,
    gps_accuracy_m      REAL,
    note                TEXT,
    status              VARCHAR(20) NOT NULL DEFAULT 'open' CHECK (status IN ('open','acknowledged','closed')),
    acknowledged_by     INT REFERENCES employees(id),
    acknowledged_at     TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE reconciliations ADD COLUMN IF NOT EXISTS settled_cash NUMERIC(14,2);
-- reconciliations made before Phase 1: the counted cash is what the supervisor holds
UPDATE reconciliations SET settled_cash = counted_cash WHERE settled_cash IS NULL AND resolution_status = 'none_needed';

-- ---------------------------------------------------------------
-- Phase 2: live tracking, two-factor login, broadcast messages

CREATE TABLE IF NOT EXISTS location_pings (
    id              BIGSERIAL PRIMARY KEY,
    employee_id     INT NOT NULL REFERENCES employees(id),
    lat             DOUBLE PRECISION NOT NULL,
    lng             DOUBLE PRECISION NOT NULL,
    accuracy_m      REAL,
    speed_mps       REAL,
    is_mocked       BOOLEAN NOT NULL DEFAULT FALSE,
    inside_sector   BOOLEAN,
    recorded_at     TIMESTAMPTZ NOT NULL,      -- phone time of the fix
    received_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_pings_employee_time ON location_pings(employee_id, recorded_at DESC);

CREATE TABLE IF NOT EXISTS login_challenges (
    id              SERIAL PRIMARY KEY,
    employee_id     INT NOT NULL REFERENCES employees(id),
    code_hash       TEXT NOT NULL,
    expires_at      TIMESTAMPTZ NOT NULL,
    attempts        INT NOT NULL DEFAULT 0,
    max_attempts    INT NOT NULL,
    status          VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','verified','expired','locked','superseded')),
    ip              TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS messages (
    id              SERIAL PRIMARY KEY,
    sender_id       INT NOT NULL REFERENCES employees(id),
    recipient_id    INT REFERENCES employees(id),     -- NULL = broadcast
    audience        VARCHAR(20) NOT NULL DEFAULT 'one' CHECK (audience IN ('one','all','collectors','supervisors')),
    body            TEXT NOT NULL,
    priority        VARCHAR(10) NOT NULL DEFAULT 'normal' CHECK (priority IN ('normal','urgent')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS message_reads (
    message_id      INT NOT NULL REFERENCES messages(id),
    employee_id     INT NOT NULL REFERENCES employees(id),
    read_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (message_id, employee_id)
);

-- ---------------------------------------------------------------
-- Phase 3: HR

ALTER TABLE employees ADD COLUMN IF NOT EXISTS job_title TEXT;
ALTER TABLE employees ADD COLUMN IF NOT EXISTS department TEXT;
ALTER TABLE employees ADD COLUMN IF NOT EXISTS hire_date DATE;
ALTER TABLE employees ADD COLUMN IF NOT EXISTS contract_end DATE;
ALTER TABLE employees ADD COLUMN IF NOT EXISTS national_id_no VARCHAR(40);
ALTER TABLE employees ADD COLUMN IF NOT EXISTS birth_date DATE;
ALTER TABLE employees ADD COLUMN IF NOT EXISTS home_address TEXT;
ALTER TABLE employees ADD COLUMN IF NOT EXISTS emergency_contact TEXT;
ALTER TABLE employees ADD COLUMN IF NOT EXISTS base_salary NUMERIC(14,2) NOT NULL DEFAULT 0;
ALTER TABLE employees ADD COLUMN IF NOT EXISTS allowance_transport NUMERIC(14,2) NOT NULL DEFAULT 0;
ALTER TABLE employees ADD COLUMN IF NOT EXISTS allowance_phone NUMERIC(14,2) NOT NULL DEFAULT 0;
ALTER TABLE employees ADD COLUMN IF NOT EXISTS allowance_risk NUMERIC(14,2) NOT NULL DEFAULT 0;
ALTER TABLE employees ADD COLUMN IF NOT EXISTS payment_method TEXT;          -- e.g. 'نقداً', 'كي كارد 1234'
ALTER TABLE employees ADD COLUMN IF NOT EXISTS hr_notes TEXT;

CREATE TABLE IF NOT EXISTS employee_documents (
    id              SERIAL PRIMARY KEY,
    employee_id     INT NOT NULL REFERENCES employees(id),
    doc_type        VARCHAR(30) NOT NULL,     -- national_id, contract, guarantee, certificate, other
    title           TEXT NOT NULL,
    file_path       TEXT,
    expires_on      DATE,
    uploaded_by     INT REFERENCES employees(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS attendance (
    id                  SERIAL PRIMARY KEY,
    employee_id         INT NOT NULL REFERENCES employees(id),
    work_date           DATE NOT NULL,
    check_in_at         TIMESTAMPTZ NOT NULL,
    check_in_lat        DOUBLE PRECISION,
    check_in_lng        DOUBLE PRECISION,
    check_in_photo      TEXT,
    check_in_inside     BOOLEAN,
    late_minutes        INT NOT NULL DEFAULT 0,
    check_out_at        TIMESTAMPTZ,
    check_out_lat       DOUBLE PRECISION,
    check_out_lng       DOUBLE PRECISION,
    check_out_photo     TEXT,
    worked_minutes      INT,
    flags               JSONB NOT NULL DEFAULT '[]'::jsonb,
    UNIQUE (employee_id, work_date)
);

CREATE TABLE IF NOT EXISTS leave_requests (
    id                  SERIAL PRIMARY KEY,
    employee_id         INT NOT NULL REFERENCES employees(id),
    leave_type          VARCHAR(20) NOT NULL CHECK (leave_type IN ('annual','sick','emergency','unpaid')),
    start_date          DATE NOT NULL,
    end_date            DATE NOT NULL,
    days                INT NOT NULL,
    reason              TEXT,
    attachment_path     TEXT,
    status              VARCHAR(20) NOT NULL CHECK (status IN ('pending_supervisor','pending_hr','approved','rejected','cancelled')),
    supervisor_id       INT REFERENCES employees(id),
    supervisor_at       TIMESTAMPTZ,
    hr_id               INT REFERENCES employees(id),
    hr_at               TIMESTAMPTZ,
    decision_note       TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_leave_employee ON leave_requests(employee_id, start_date);

CREATE TABLE IF NOT EXISTS expense_claims (
    id                  SERIAL PRIMARY KEY,
    employee_id         INT NOT NULL REFERENCES employees(id),
    category            VARCHAR(20) NOT NULL CHECK (category IN ('fuel','phone','transport','repair','other')),
    amount              NUMERIC(14,2) NOT NULL CHECK (amount > 0),
    expense_date        DATE NOT NULL,
    description         TEXT,
    receipt_path        TEXT,
    status              VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','paid')),
    decided_by          INT REFERENCES employees(id),
    decided_at          TIMESTAMPTZ,
    decision_note       TEXT,
    payslip_id          INT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS payroll_runs (
    id                  SERIAL PRIMARY KEY,
    period              CHAR(7) UNIQUE NOT NULL,          -- 'YYYY-MM'
    status              VARCHAR(20) NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','approved','paid')),
    totals              JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_by          INT REFERENCES employees(id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    approved_by         INT REFERENCES employees(id),
    approved_at         TIMESTAMPTZ,
    paid_by             INT REFERENCES employees(id),
    paid_at             TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS payslips (
    id                  SERIAL PRIMARY KEY,
    run_id              INT NOT NULL REFERENCES payroll_runs(id),
    employee_id         INT NOT NULL REFERENCES employees(id),
    gross               NUMERIC(14,2) NOT NULL,
    deductions          NUMERIC(14,2) NOT NULL,
    net                 NUMERIC(14,2) NOT NULL,
    lines               JSONB NOT NULL,                   -- [{kind: earning/deduction, code, label, amount, detail}]
    stats               JSONB NOT NULL DEFAULT '{}'::jsonb,
    UNIQUE (run_id, employee_id)
);

CREATE TABLE IF NOT EXISTS appraisals (
    id                  SERIAL PRIMARY KEY,
    employee_id         INT NOT NULL REFERENCES employees(id),
    period              CHAR(7) NOT NULL,
    metrics             JSONB NOT NULL,
    auto_score          NUMERIC(5,1) NOT NULL,
    supervisor_rating   INT CHECK (supervisor_rating BETWEEN 1 AND 5),
    supervisor_note     TEXT,
    final_score         NUMERIC(5,1) NOT NULL,
    recommendation      TEXT NOT NULL,
    rated_by            INT REFERENCES employees(id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (employee_id, period)
);

CREATE TABLE IF NOT EXISTS custody_items (
    id                  SERIAL PRIMARY KEY,
    employee_id         INT NOT NULL REFERENCES employees(id),
    item_type           VARCHAR(20) NOT NULL CHECK (item_type IN ('phone','meter_reader','printer','vehicle','uniform','cash_bag','other')),
    description         TEXT NOT NULL,
    serial_no           VARCHAR(80),
    value_iqd           NUMERIC(14,2) NOT NULL DEFAULT 0,
    status              VARCHAR(20) NOT NULL DEFAULT 'assigned' CHECK (status IN ('assigned','returned','lost')),
    assigned_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    assigned_by         INT REFERENCES employees(id),
    returned_at         TIMESTAMPTZ,
    return_note         TEXT
);

CREATE TABLE IF NOT EXISTS disciplinary_actions (
    id                  SERIAL PRIMARY KEY,
    employee_id         INT NOT NULL REFERENCES employees(id),
    action_type         VARCHAR(20) NOT NULL CHECK (action_type IN ('verbal_warning','written_warning','final_warning','penalty','suspension')),
    reason              TEXT NOT NULL,
    penalty_iqd         NUMERIC(14,2) NOT NULL DEFAULT 0,
    effective_date      DATE NOT NULL,
    issued_by           INT REFERENCES employees(id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS job_openings (
    id                  SERIAL PRIMARY KEY,
    title               TEXT NOT NULL,
    role                VARCHAR(20) NOT NULL DEFAULT 'collector',
    sector_code         VARCHAR(30),
    positions           INT NOT NULL DEFAULT 1,
    description         TEXT,
    status              VARCHAR(20) NOT NULL DEFAULT 'open' CHECK (status IN ('open','closed')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS applicants (
    id                  SERIAL PRIMARY KEY,
    opening_id          INT NOT NULL REFERENCES job_openings(id),
    full_name           TEXT NOT NULL,
    phone               VARCHAR(20),
    notes               TEXT,
    stage               VARCHAR(20) NOT NULL DEFAULT 'applied' CHECK (stage IN ('applied','interview','test','offer','hired','rejected')),
    score               INT,
    hired_employee_id   INT REFERENCES employees(id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS training_courses (
    id                  SERIAL PRIMARY KEY,
    title               TEXT NOT NULL,
    description         TEXT,
    mandatory_for       VARCHAR(20),            -- role that must complete it (e.g. collector), NULL = optional
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS training_records (
    id                  SERIAL PRIMARY KEY,
    course_id           INT NOT NULL REFERENCES training_courses(id),
    employee_id         INT NOT NULL REFERENCES employees(id),
    status              VARCHAR(20) NOT NULL DEFAULT 'assigned' CHECK (status IN ('assigned','completed')),
    score               INT,
    completed_at        TIMESTAMPTZ,
    UNIQUE (course_id, employee_id)
);
