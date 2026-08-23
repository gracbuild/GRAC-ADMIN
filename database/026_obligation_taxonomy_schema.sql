-- =====================================================================
-- 026 -- Obligation Taxonomy (Phase 1: SCHEMA)
--
-- Introduces the 7-type atomic obligation taxonomy frozen by architecture
-- review on 2026-07-27:
--
--   State           -- what must be/continue to be true
--   Execution       -- what must be done and when
--   Assurance       -- what must be verified and when
--   EventResponse   -- if X occurs, what must happen and by when
--   Constraint      -- what boundary/prohibition must never be violated
--   Evidence        -- what proves fulfilment
--   Retention       -- what must be preserved and for how long
--
-- Design decisions (all confirmed by sir):
--   1. State and Constraint are SEPARATE types (not polarity flag).
--   2. Evidence is CROSS-CUTTING: any obligation of any type can attach one
--      or more evidence specs. Standalone Evidence obligations are just the
--      special case where obligation_type = 'Evidence'.
--   3. Obligation <-> Evidence is MANY-TO-MANY (one rule may have multiple
--      proofs; one proof may cover multiple rules).
--   4. Evidence spec is a REUSABLE standalone entity.  Physical table
--      GRAC_New.requirement_obligation_evidence keeps its name in this
--      phase (rename would break every consumer proc in Control Management
--      AND Practice Management).  Its obligation_id is made nullable so
--      detached / reusable specs are possible; six per-type link tables
--      provide the M:M bridge.  A future migration may physically rename
--      once all consumers move to the new links.
--   5. Discriminator column obligation_type_id lives on requirement_obligation
--      with FK to a new obligation_type_master lookup.
--
-- Adds (all guarded / idempotent):
--   * GRAC_New.obligation_type_master                (7-row lookup)
--   * requirement_obligation.obligation_type_id      (nullable, FK)
--   * requirement_obligation_evidence.obligation_id  -> NULL allowed
--   * GRAC_New.obligation_state_rule
--   * GRAC_New.obligation_execution_spec
--   * GRAC_New.obligation_assurance_spec
--   * GRAC_New.obligation_event_response
--   * GRAC_New.obligation_constraint_rule
--   * GRAC_New.obligation_retention_spec
--   * GRAC_New.obligation_state_evidence_link
--   * GRAC_New.obligation_execution_evidence_link
--   * GRAC_New.obligation_assurance_evidence_link
--   * GRAC_New.obligation_event_response_evidence_link
--   * GRAC_New.obligation_constraint_evidence_link
--   * GRAC_New.obligation_retention_evidence_link
--
-- Data migration lives in 027_obligation_taxonomy_migration.sql (separate
-- script for reviewability -- run 026 before 027).
--
-- Rollback: database/026_obligation_taxonomy_schema_rollback.sql
--
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF SCHEMA_ID('GRAC_New') IS NULL
    THROW 52600, 'Schema GRAC_New is missing. Run Control Management schema scripts first.', 1;
GO

IF OBJECT_ID('GRAC_New.requirement_obligation','U') IS NULL
    THROW 52601, 'GRAC_New.requirement_obligation is missing. Run 001 schema and 019 decouple first.', 1;
GO

IF OBJECT_ID('GRAC_New.requirement_obligation_evidence','U') IS NULL
    THROW 52602, 'GRAC_New.requirement_obligation_evidence is missing. Run 001 schema first.', 1;
GO

-- =====================================================================
-- 1. obligation_type_master -- the 7 atomic types.
-- =====================================================================
IF OBJECT_ID('GRAC_New.obligation_type_master','U') IS NULL
BEGIN
    CREATE TABLE GRAC_New.obligation_type_master(
        obligation_type_id  BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_cm_obligation_type_master PRIMARY KEY,
        type_code           NVARCHAR(40)  NOT NULL,
        type_name           NVARCHAR(120) NOT NULL,
        description         NVARCHAR(500) NULL,
        display_order       INT NOT NULL
            CONSTRAINT df_cm_obligation_type_master_display_order DEFAULT 100,
        status              NVARCHAR(30)  NOT NULL
            CONSTRAINT df_cm_obligation_type_master_status DEFAULT 'Active',
        entered_by          NVARCHAR(100) NOT NULL
            CONSTRAINT df_cm_obligation_type_master_eb DEFAULT 'system',
        entered_dt          DATETIME2(3)  NOT NULL
            CONSTRAINT df_cm_obligation_type_master_ed DEFAULT SYSUTCDATETIME(),
        updated_by          NVARCHAR(100) NULL,
        updated_dt          DATETIME2(3)  NULL,
        CONSTRAINT uq_cm_obligation_type_code UNIQUE(type_code)
    );
END
GO

-- =====================================================================
-- 2. requirement_obligation.obligation_type_id -- discriminator.
--    Nullable in Phase 1 so 027 back-fill can classify existing rows
--    without violating a NOT NULL constraint on rollback.
-- =====================================================================
IF COL_LENGTH('GRAC_New.requirement_obligation','obligation_type_id') IS NULL
BEGIN
    ALTER TABLE GRAC_New.requirement_obligation
        ADD obligation_type_id BIGINT NULL
            CONSTRAINT fk_cm_requirement_obligation_type
                REFERENCES GRAC_New.obligation_type_master(obligation_type_id);
END
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes
              WHERE name = 'ix_cm_requirement_obligation_type_status'
                AND object_id = OBJECT_ID('GRAC_New.requirement_obligation'))
    CREATE INDEX ix_cm_requirement_obligation_type_status
        ON GRAC_New.requirement_obligation(obligation_type_id, status);
GO

-- =====================================================================
-- 3. requirement_obligation_evidence.obligation_id -> NULLable.
--    Existing rows keep their owner; new detached / reusable specs may
--    leave it NULL and be linked only via the per-type link tables.
--    Guarded so it is a no-op on re-run.
-- =====================================================================
IF EXISTS(SELECT 1 FROM sys.columns
          WHERE object_id = OBJECT_ID('GRAC_New.requirement_obligation_evidence')
            AND name = 'obligation_id'
            AND is_nullable = 0)
BEGIN
    ALTER TABLE GRAC_New.requirement_obligation_evidence
        ALTER COLUMN obligation_id BIGINT NULL;
END
GO

-- =====================================================================
-- 4. Per-type detail tables (6).  Evidence is NOT a separate detail
--    table -- the physical evidence storage stays in
--    requirement_obligation_evidence; standalone Evidence obligations
--    just have obligation_type_id = 'Evidence' and their rows live in
--    that existing table (linked via obligation_id).
-- =====================================================================

-- 4a. State: positive parametric assertion.
IF OBJECT_ID('GRAC_New.obligation_state_rule','U') IS NULL
CREATE TABLE GRAC_New.obligation_state_rule(
    state_rule_id     BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_cm_obligation_state_rule PRIMARY KEY,
    obligation_id     BIGINT NOT NULL
        CONSTRAINT fk_cm_obligation_state_rule_obligation
            REFERENCES GRAC_New.requirement_obligation(obligation_id),
    attribute         NVARCHAR(250) NOT NULL,     -- e.g. 'password.length'
    operator          NVARCHAR(30)  NOT NULL,     -- '>=', '=', 'in', 'contains', ...
    value             NVARCHAR(500) NOT NULL,     -- e.g. '12', 'true', 'AES-256'
    unit              NVARCHAR(50)  NULL,         -- 'characters', 'days', ...
    tolerance         NVARCHAR(200) NULL,
    remarks           NVARCHAR(MAX) NULL,
    status            NVARCHAR(30)  NOT NULL
        CONSTRAINT df_cm_obligation_state_rule_status DEFAULT 'Active',
    entered_by        NVARCHAR(100) NOT NULL
        CONSTRAINT df_cm_obligation_state_rule_eb DEFAULT 'system',
    entered_dt        DATETIME2(3)  NOT NULL
        CONSTRAINT df_cm_obligation_state_rule_ed DEFAULT SYSUTCDATETIME(),
    updated_by        NVARCHAR(100) NULL,
    updated_dt        DATETIME2(3)  NULL
);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes
              WHERE name='ux_cm_obligation_state_rule_active'
                AND object_id=OBJECT_ID('GRAC_New.obligation_state_rule'))
    CREATE UNIQUE INDEX ux_cm_obligation_state_rule_active
        ON GRAC_New.obligation_state_rule(obligation_id)
        WHERE status='Active';
GO

-- 4b. Execution: what must be done and when.
IF OBJECT_ID('GRAC_New.obligation_execution_spec','U') IS NULL
CREATE TABLE GRAC_New.obligation_execution_spec(
    execution_spec_id       BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_cm_obligation_execution_spec PRIMARY KEY,
    obligation_id           BIGINT NOT NULL
        CONSTRAINT fk_cm_obligation_execution_spec_obligation
            REFERENCES GRAC_New.requirement_obligation(obligation_id),
    action                  NVARCHAR(1000) NOT NULL,
    execution_frequency_id  BIGINT NULL
        CONSTRAINT fk_cm_obligation_execution_spec_freq
            REFERENCES GRAC_New.reference_option(reference_option_id),
    trigger_condition       NVARCHAR(500) NULL,
    responsible_party       NVARCHAR(250) NULL,
    due_within              NVARCHAR(120) NULL,
    remarks                 NVARCHAR(MAX) NULL,
    status                  NVARCHAR(30)  NOT NULL
        CONSTRAINT df_cm_obligation_execution_spec_status DEFAULT 'Active',
    entered_by              NVARCHAR(100) NOT NULL
        CONSTRAINT df_cm_obligation_execution_spec_eb DEFAULT 'system',
    entered_dt              DATETIME2(3)  NOT NULL
        CONSTRAINT df_cm_obligation_execution_spec_ed DEFAULT SYSUTCDATETIME(),
    updated_by              NVARCHAR(100) NULL,
    updated_dt              DATETIME2(3)  NULL
);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes
              WHERE name='ux_cm_obligation_execution_spec_active'
                AND object_id=OBJECT_ID('GRAC_New.obligation_execution_spec'))
    CREATE UNIQUE INDEX ux_cm_obligation_execution_spec_active
        ON GRAC_New.obligation_execution_spec(obligation_id)
        WHERE status='Active';
GO

-- 4c. Assurance: what must be verified and how.
IF OBJECT_ID('GRAC_New.obligation_assurance_spec','U') IS NULL
CREATE TABLE GRAC_New.obligation_assurance_spec(
    assurance_spec_id       BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_cm_obligation_assurance_spec PRIMARY KEY,
    obligation_id           BIGINT NOT NULL
        CONSTRAINT fk_cm_obligation_assurance_spec_obligation
            REFERENCES GRAC_New.requirement_obligation(obligation_id),
    verification_method     NVARCHAR(500) NOT NULL,
    scope                   NVARCHAR(500) NULL,
    assurance_frequency_id  BIGINT NULL
        CONSTRAINT fk_cm_obligation_assurance_spec_freq
            REFERENCES GRAC_New.reference_option(reference_option_id),
    assurance_party         NVARCHAR(250) NULL,
    remarks                 NVARCHAR(MAX) NULL,
    status                  NVARCHAR(30)  NOT NULL
        CONSTRAINT df_cm_obligation_assurance_spec_status DEFAULT 'Active',
    entered_by              NVARCHAR(100) NOT NULL
        CONSTRAINT df_cm_obligation_assurance_spec_eb DEFAULT 'system',
    entered_dt              DATETIME2(3)  NOT NULL
        CONSTRAINT df_cm_obligation_assurance_spec_ed DEFAULT SYSUTCDATETIME(),
    updated_by              NVARCHAR(100) NULL,
    updated_dt              DATETIME2(3)  NULL
);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes
              WHERE name='ux_cm_obligation_assurance_spec_active'
                AND object_id=OBJECT_ID('GRAC_New.obligation_assurance_spec'))
    CREATE UNIQUE INDEX ux_cm_obligation_assurance_spec_active
        ON GRAC_New.obligation_assurance_spec(obligation_id)
        WHERE status='Active';
GO

-- 4d. Event Response: if X occurs, do Y within SLA.
IF OBJECT_ID('GRAC_New.obligation_event_response','U') IS NULL
CREATE TABLE GRAC_New.obligation_event_response(
    event_response_id  BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_cm_obligation_event_response PRIMARY KEY,
    obligation_id      BIGINT NOT NULL
        CONSTRAINT fk_cm_obligation_event_response_obligation
            REFERENCES GRAC_New.requirement_obligation(obligation_id),
    trigger_event      NVARCHAR(500)  NOT NULL,
    response_action    NVARCHAR(1000) NOT NULL,
    sla_value          INT           NULL,
    sla_unit           NVARCHAR(30)  NULL,   -- 'Hours','Days','Weeks','Months'
    escalation_path    NVARCHAR(500) NULL,
    remarks            NVARCHAR(MAX) NULL,
    status             NVARCHAR(30)  NOT NULL
        CONSTRAINT df_cm_obligation_event_response_status DEFAULT 'Active',
    entered_by         NVARCHAR(100) NOT NULL
        CONSTRAINT df_cm_obligation_event_response_eb DEFAULT 'system',
    entered_dt         DATETIME2(3)  NOT NULL
        CONSTRAINT df_cm_obligation_event_response_ed DEFAULT SYSUTCDATETIME(),
    updated_by         NVARCHAR(100) NULL,
    updated_dt         DATETIME2(3)  NULL,
    CONSTRAINT ck_cm_obligation_event_response_sla_unit
        CHECK (sla_unit IS NULL OR sla_unit IN (N'Hours',N'Days',N'Weeks',N'Months',N'Years'))
);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes
              WHERE name='ux_cm_obligation_event_response_active'
                AND object_id=OBJECT_ID('GRAC_New.obligation_event_response'))
    CREATE UNIQUE INDEX ux_cm_obligation_event_response_active
        ON GRAC_New.obligation_event_response(obligation_id)
        WHERE status='Active';
GO

-- 4e. Constraint: prohibition rule.  Table name deliberately
--     NOT 'obligation_constraint' to avoid confusion with the SQL
--     CONSTRAINT keyword in casual reads.
IF OBJECT_ID('GRAC_New.obligation_constraint_rule','U') IS NULL
CREATE TABLE GRAC_New.obligation_constraint_rule(
    constraint_rule_id     BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_cm_obligation_constraint_rule PRIMARY KEY,
    obligation_id          BIGINT NOT NULL
        CONSTRAINT fk_cm_obligation_constraint_rule_obligation
            REFERENCES GRAC_New.requirement_obligation(obligation_id),
    prohibited_condition   NVARCHAR(1000) NOT NULL,
    scope                  NVARCHAR(500)  NULL,
    exception_policy       NVARCHAR(500)  NULL,
    remarks                NVARCHAR(MAX)  NULL,
    status                 NVARCHAR(30)   NOT NULL
        CONSTRAINT df_cm_obligation_constraint_rule_status DEFAULT 'Active',
    entered_by             NVARCHAR(100)  NOT NULL
        CONSTRAINT df_cm_obligation_constraint_rule_eb DEFAULT 'system',
    entered_dt             DATETIME2(3)   NOT NULL
        CONSTRAINT df_cm_obligation_constraint_rule_ed DEFAULT SYSUTCDATETIME(),
    updated_by             NVARCHAR(100)  NULL,
    updated_dt             DATETIME2(3)   NULL
);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes
              WHERE name='ux_cm_obligation_constraint_rule_active'
                AND object_id=OBJECT_ID('GRAC_New.obligation_constraint_rule'))
    CREATE UNIQUE INDEX ux_cm_obligation_constraint_rule_active
        ON GRAC_New.obligation_constraint_rule(obligation_id)
        WHERE status='Active';
GO

-- 4f. Retention: what must be preserved and for how long.
IF OBJECT_ID('GRAC_New.obligation_retention_spec','U') IS NULL
CREATE TABLE GRAC_New.obligation_retention_spec(
    retention_spec_id      BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_cm_obligation_retention_spec PRIMARY KEY,
    obligation_id          BIGINT NOT NULL
        CONSTRAINT fk_cm_obligation_retention_spec_obligation
            REFERENCES GRAC_New.requirement_obligation(obligation_id),
    retained_object        NVARCHAR(500) NOT NULL,
    min_retention_value    INT           NULL,
    min_retention_unit     NVARCHAR(30)  NULL,   -- 'Days','Months','Years'
    max_retention_value    INT           NULL,
    max_retention_unit     NVARCHAR(30)  NULL,
    disposal_policy        NVARCHAR(500) NULL,
    remarks                NVARCHAR(MAX) NULL,
    status                 NVARCHAR(30)  NOT NULL
        CONSTRAINT df_cm_obligation_retention_spec_status DEFAULT 'Active',
    entered_by             NVARCHAR(100) NOT NULL
        CONSTRAINT df_cm_obligation_retention_spec_eb DEFAULT 'system',
    entered_dt             DATETIME2(3)  NOT NULL
        CONSTRAINT df_cm_obligation_retention_spec_ed DEFAULT SYSUTCDATETIME(),
    updated_by             NVARCHAR(100) NULL,
    updated_dt             DATETIME2(3)  NULL,
    CONSTRAINT ck_cm_obligation_retention_min_unit
        CHECK (min_retention_unit IS NULL OR min_retention_unit IN (N'Days',N'Weeks',N'Months',N'Years')),
    CONSTRAINT ck_cm_obligation_retention_max_unit
        CHECK (max_retention_unit IS NULL OR max_retention_unit IN (N'Days',N'Weeks',N'Months',N'Years'))
);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes
              WHERE name='ux_cm_obligation_retention_spec_active'
                AND object_id=OBJECT_ID('GRAC_New.obligation_retention_spec'))
    CREATE UNIQUE INDEX ux_cm_obligation_retention_spec_active
        ON GRAC_New.obligation_retention_spec(obligation_id)
        WHERE status='Active';
GO

-- =====================================================================
-- 5. Per-type Evidence link tables (6).  Each is an M:M bridge between
--    an obligation of that type and an evidence spec row in the existing
--    requirement_obligation_evidence table.  This enables:
--      * One obligation to point to multiple evidence specs (many proofs)
--      * One evidence spec to be referenced by many obligations across
--        multiple types (reusable spec)
--
--    Note: We store obligation_evidence_id (the physical PK of
--    requirement_obligation_evidence).  When the physical rename to
--    obligation_evidence_spec eventually happens, only the FK target
--    reference needs updating -- column names stay stable.
-- =====================================================================

-- 5a. State evidence link.
IF OBJECT_ID('GRAC_New.obligation_state_evidence_link','U') IS NULL
CREATE TABLE GRAC_New.obligation_state_evidence_link(
    state_evidence_link_id  BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_cm_obligation_state_evidence_link PRIMARY KEY,
    obligation_id           BIGINT NOT NULL
        CONSTRAINT fk_cm_obligation_state_evidence_link_obligation
            REFERENCES GRAC_New.requirement_obligation(obligation_id),
    obligation_evidence_id  BIGINT NOT NULL
        CONSTRAINT fk_cm_obligation_state_evidence_link_evidence
            REFERENCES GRAC_New.requirement_obligation_evidence(obligation_evidence_id),
    remarks                 NVARCHAR(500) NULL,
    status                  NVARCHAR(30)  NOT NULL
        CONSTRAINT df_cm_obligation_state_evidence_link_status DEFAULT 'Active',
    entered_by              NVARCHAR(100) NOT NULL
        CONSTRAINT df_cm_obligation_state_evidence_link_eb DEFAULT 'system',
    entered_dt              DATETIME2(3)  NOT NULL
        CONSTRAINT df_cm_obligation_state_evidence_link_ed DEFAULT SYSUTCDATETIME(),
    updated_by              NVARCHAR(100) NULL,
    updated_dt              DATETIME2(3)  NULL
);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes
              WHERE name='ux_cm_obligation_state_evidence_link_active'
                AND object_id=OBJECT_ID('GRAC_New.obligation_state_evidence_link'))
    CREATE UNIQUE INDEX ux_cm_obligation_state_evidence_link_active
        ON GRAC_New.obligation_state_evidence_link(obligation_id, obligation_evidence_id)
        WHERE status='Active';
GO

-- 5b. Execution evidence link.
IF OBJECT_ID('GRAC_New.obligation_execution_evidence_link','U') IS NULL
CREATE TABLE GRAC_New.obligation_execution_evidence_link(
    execution_evidence_link_id  BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_cm_obligation_execution_evidence_link PRIMARY KEY,
    obligation_id               BIGINT NOT NULL
        CONSTRAINT fk_cm_obligation_execution_evidence_link_obligation
            REFERENCES GRAC_New.requirement_obligation(obligation_id),
    obligation_evidence_id      BIGINT NOT NULL
        CONSTRAINT fk_cm_obligation_execution_evidence_link_evidence
            REFERENCES GRAC_New.requirement_obligation_evidence(obligation_evidence_id),
    remarks                     NVARCHAR(500) NULL,
    status                      NVARCHAR(30)  NOT NULL
        CONSTRAINT df_cm_obligation_execution_evidence_link_status DEFAULT 'Active',
    entered_by                  NVARCHAR(100) NOT NULL
        CONSTRAINT df_cm_obligation_execution_evidence_link_eb DEFAULT 'system',
    entered_dt                  DATETIME2(3)  NOT NULL
        CONSTRAINT df_cm_obligation_execution_evidence_link_ed DEFAULT SYSUTCDATETIME(),
    updated_by                  NVARCHAR(100) NULL,
    updated_dt                  DATETIME2(3)  NULL
);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes
              WHERE name='ux_cm_obligation_execution_evidence_link_active'
                AND object_id=OBJECT_ID('GRAC_New.obligation_execution_evidence_link'))
    CREATE UNIQUE INDEX ux_cm_obligation_execution_evidence_link_active
        ON GRAC_New.obligation_execution_evidence_link(obligation_id, obligation_evidence_id)
        WHERE status='Active';
GO

-- 5c. Assurance evidence link.
IF OBJECT_ID('GRAC_New.obligation_assurance_evidence_link','U') IS NULL
CREATE TABLE GRAC_New.obligation_assurance_evidence_link(
    assurance_evidence_link_id  BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_cm_obligation_assurance_evidence_link PRIMARY KEY,
    obligation_id               BIGINT NOT NULL
        CONSTRAINT fk_cm_obligation_assurance_evidence_link_obligation
            REFERENCES GRAC_New.requirement_obligation(obligation_id),
    obligation_evidence_id      BIGINT NOT NULL
        CONSTRAINT fk_cm_obligation_assurance_evidence_link_evidence
            REFERENCES GRAC_New.requirement_obligation_evidence(obligation_evidence_id),
    remarks                     NVARCHAR(500) NULL,
    status                      NVARCHAR(30)  NOT NULL
        CONSTRAINT df_cm_obligation_assurance_evidence_link_status DEFAULT 'Active',
    entered_by                  NVARCHAR(100) NOT NULL
        CONSTRAINT df_cm_obligation_assurance_evidence_link_eb DEFAULT 'system',
    entered_dt                  DATETIME2(3)  NOT NULL
        CONSTRAINT df_cm_obligation_assurance_evidence_link_ed DEFAULT SYSUTCDATETIME(),
    updated_by                  NVARCHAR(100) NULL,
    updated_dt                  DATETIME2(3)  NULL
);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes
              WHERE name='ux_cm_obligation_assurance_evidence_link_active'
                AND object_id=OBJECT_ID('GRAC_New.obligation_assurance_evidence_link'))
    CREATE UNIQUE INDEX ux_cm_obligation_assurance_evidence_link_active
        ON GRAC_New.obligation_assurance_evidence_link(obligation_id, obligation_evidence_id)
        WHERE status='Active';
GO

-- 5d. Event Response evidence link.
IF OBJECT_ID('GRAC_New.obligation_event_response_evidence_link','U') IS NULL
CREATE TABLE GRAC_New.obligation_event_response_evidence_link(
    event_response_evidence_link_id  BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_cm_obligation_event_response_evidence_link PRIMARY KEY,
    obligation_id                    BIGINT NOT NULL
        CONSTRAINT fk_cm_obligation_event_response_evidence_link_obligation
            REFERENCES GRAC_New.requirement_obligation(obligation_id),
    obligation_evidence_id           BIGINT NOT NULL
        CONSTRAINT fk_cm_obligation_event_response_evidence_link_evidence
            REFERENCES GRAC_New.requirement_obligation_evidence(obligation_evidence_id),
    remarks                          NVARCHAR(500) NULL,
    status                           NVARCHAR(30)  NOT NULL
        CONSTRAINT df_cm_obligation_event_response_evidence_link_status DEFAULT 'Active',
    entered_by                       NVARCHAR(100) NOT NULL
        CONSTRAINT df_cm_obligation_event_response_evidence_link_eb DEFAULT 'system',
    entered_dt                       DATETIME2(3)  NOT NULL
        CONSTRAINT df_cm_obligation_event_response_evidence_link_ed DEFAULT SYSUTCDATETIME(),
    updated_by                       NVARCHAR(100) NULL,
    updated_dt                       DATETIME2(3)  NULL
);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes
              WHERE name='ux_cm_obligation_event_response_evidence_link_active'
                AND object_id=OBJECT_ID('GRAC_New.obligation_event_response_evidence_link'))
    CREATE UNIQUE INDEX ux_cm_obligation_event_response_evidence_link_active
        ON GRAC_New.obligation_event_response_evidence_link(obligation_id, obligation_evidence_id)
        WHERE status='Active';
GO

-- 5e. Constraint evidence link.
IF OBJECT_ID('GRAC_New.obligation_constraint_evidence_link','U') IS NULL
CREATE TABLE GRAC_New.obligation_constraint_evidence_link(
    constraint_evidence_link_id  BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_cm_obligation_constraint_evidence_link PRIMARY KEY,
    obligation_id                BIGINT NOT NULL
        CONSTRAINT fk_cm_obligation_constraint_evidence_link_obligation
            REFERENCES GRAC_New.requirement_obligation(obligation_id),
    obligation_evidence_id       BIGINT NOT NULL
        CONSTRAINT fk_cm_obligation_constraint_evidence_link_evidence
            REFERENCES GRAC_New.requirement_obligation_evidence(obligation_evidence_id),
    remarks                      NVARCHAR(500) NULL,
    status                       NVARCHAR(30)  NOT NULL
        CONSTRAINT df_cm_obligation_constraint_evidence_link_status DEFAULT 'Active',
    entered_by                   NVARCHAR(100) NOT NULL
        CONSTRAINT df_cm_obligation_constraint_evidence_link_eb DEFAULT 'system',
    entered_dt                   DATETIME2(3)  NOT NULL
        CONSTRAINT df_cm_obligation_constraint_evidence_link_ed DEFAULT SYSUTCDATETIME(),
    updated_by                   NVARCHAR(100) NULL,
    updated_dt                   DATETIME2(3)  NULL
);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes
              WHERE name='ux_cm_obligation_constraint_evidence_link_active'
                AND object_id=OBJECT_ID('GRAC_New.obligation_constraint_evidence_link'))
    CREATE UNIQUE INDEX ux_cm_obligation_constraint_evidence_link_active
        ON GRAC_New.obligation_constraint_evidence_link(obligation_id, obligation_evidence_id)
        WHERE status='Active';
GO

-- 5f. Retention evidence link.
IF OBJECT_ID('GRAC_New.obligation_retention_evidence_link','U') IS NULL
CREATE TABLE GRAC_New.obligation_retention_evidence_link(
    retention_evidence_link_id  BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_cm_obligation_retention_evidence_link PRIMARY KEY,
    obligation_id               BIGINT NOT NULL
        CONSTRAINT fk_cm_obligation_retention_evidence_link_obligation
            REFERENCES GRAC_New.requirement_obligation(obligation_id),
    obligation_evidence_id      BIGINT NOT NULL
        CONSTRAINT fk_cm_obligation_retention_evidence_link_evidence
            REFERENCES GRAC_New.requirement_obligation_evidence(obligation_evidence_id),
    remarks                     NVARCHAR(500) NULL,
    status                      NVARCHAR(30)  NOT NULL
        CONSTRAINT df_cm_obligation_retention_evidence_link_status DEFAULT 'Active',
    entered_by                  NVARCHAR(100) NOT NULL
        CONSTRAINT df_cm_obligation_retention_evidence_link_eb DEFAULT 'system',
    entered_dt                  DATETIME2(3)  NOT NULL
        CONSTRAINT df_cm_obligation_retention_evidence_link_ed DEFAULT SYSUTCDATETIME(),
    updated_by                  NVARCHAR(100) NULL,
    updated_dt                  DATETIME2(3)  NULL
);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes
              WHERE name='ux_cm_obligation_retention_evidence_link_active'
                AND object_id=OBJECT_ID('GRAC_New.obligation_retention_evidence_link'))
    CREATE UNIQUE INDEX ux_cm_obligation_retention_evidence_link_active
        ON GRAC_New.obligation_retention_evidence_link(obligation_id, obligation_evidence_id)
        WHERE status='Active';
GO

PRINT '026 obligation taxonomy schema installed.  Run 027 for data migration.';
GO
