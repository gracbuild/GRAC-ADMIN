/* ================================================================
   Migration 044 -- SLA Master table, procs and seed
   ----------------------------------------------------------------
   Creates GRAC_New.sla_master (process/classification -> SLA
   duration + thresholds) and its dedicated dispatcher procs
   cm_get_sla_master / cm_manage_sla_master.  Routed by
   Api.Services.RegulatoryRepositoryService so the existing
   cm_get_repository / cm_manage_repository stay untouched.

   Seed loads the 38 rows from Obligation Definition.xlsx (Sheet2).

   Rollback: database/044_sla_master_table_and_procs_rollback.sql
   ================================================================ */

/* ------------------------------------------------------------------
   1. Table
   ------------------------------------------------------------------
   sla_code is auto-formatted as 'SLA-###' from sla_id via a computed
   column so callers never invent codes and the sequence stays stable.
   Uniqueness on (process_code, classification) enforces one Active
   SLA per pair -- deactivating one lets you create a replacement.
   ------------------------------------------------------------------ */
IF OBJECT_ID('GRAC_New.sla_master','U') IS NULL
BEGIN
    CREATE TABLE GRAC_New.sla_master(
        sla_id             BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        sla_code           AS (N'SLA-' + RIGHT(N'000' + CONVERT(NVARCHAR(10), sla_id), 3)) PERSISTED,
        process_code       NVARCHAR(80)  NOT NULL,
        classification     NVARCHAR(20)  NOT NULL,
        duration_value     INT           NOT NULL,
        duration_unit      NVARCHAR(10)  NOT NULL,
        time_basis         NVARCHAR(30)  NOT NULL,
        warning_pct        DECIMAL(5,2)  NOT NULL CONSTRAINT df_sla_master_warning     DEFAULT (75.00),
        escalation_pct     DECIMAL(5,2)  NOT NULL CONSTRAINT df_sla_master_escalation  DEFAULT (90.00),
        effective_from     DATE          NULL,
        remarks            NVARCHAR(500) NULL,
        status             NVARCHAR(20)  NOT NULL CONSTRAINT df_sla_master_status      DEFAULT (N'Active'),
        entered_by         NVARCHAR(100) NOT NULL CONSTRAINT df_sla_master_entered_by  DEFAULT (N'system'),
        entered_dt         DATETIME2(3)  NOT NULL CONSTRAINT df_sla_master_entered_dt  DEFAULT (SYSUTCDATETIME()),
        updated_by         NVARCHAR(100) NULL,
        updated_dt         DATETIME2(3)  NULL,

        CONSTRAINT ck_sla_master_classification CHECK (classification IN (N'Critical', N'High', N'Standard')),
        CONSTRAINT ck_sla_master_duration_unit  CHECK (duration_unit  IN (N'Hours', N'Days')),
        CONSTRAINT ck_sla_master_time_basis     CHECK (time_basis     IN (N'Business Hours', N'Business Days', N'Business Day', N'Calendar Days')),
        CONSTRAINT ck_sla_master_status         CHECK (status         IN (N'Active', N'Inactive')),
        CONSTRAINT ck_sla_master_duration       CHECK (duration_value > 0 AND duration_value <= 3650),
        CONSTRAINT ck_sla_master_thresholds     CHECK (warning_pct > 0 AND escalation_pct <= 100 AND warning_pct < escalation_pct)
    );
END
GO

/* Enforce one Active SLA per (process, classification).  A filtered
   unique index means an Inactive row does not block re-creating the
   pair with fresh values. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'uq_sla_master_process_class_active' AND object_id = OBJECT_ID('GRAC_New.sla_master'))
BEGIN
    CREATE UNIQUE INDEX uq_sla_master_process_class_active
        ON GRAC_New.sla_master(process_code, classification)
        WHERE status = N'Active';
END
GO

/* ------------------------------------------------------------------
   2. cm_get_sla_master
   ------------------------------------------------------------------
   Two shapes:
     * @p_id = 0  ->  list view (respects @p_search / @p_status)
     * @p_id > 0  ->  single record for the edit / view form
   Column names mirror the RepositoryScreen.All columns so the
   generic Manage grid renders without a bespoke mapper.
   ------------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE dbo.cm_get_sla_master
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30)  = N'',
    @p_id          BIGINT        = 0,
    @p_search      NVARCHAR(250) = N'',
    @p_status      NVARCHAR(30)  = N'',
    @p_payload     NVARCHAR(MAX) = N'{}',
    @p_usr_id      NVARCHAR(100) = N''
AS
BEGIN
    SET NOCOUNT ON;

    IF @p_entity_type <> N'sla-master'
    BEGIN
        ;THROW 50001, N'Unsupported repository area', 1;
    END

    SELECT sla_id           AS Id,
           sla_code         AS SlaCode,
           process_code     AS Process,
           classification   AS Classification,
           duration_value   AS DurationValue,
           duration_unit    AS DurationUnit,
           CONVERT(NVARCHAR(30), duration_value) + N' ' + duration_unit AS Duration,
           time_basis       AS TimeBasis,
           warning_pct      AS WarningPct,
           escalation_pct   AS EscalationPct,
           effective_from   AS EffectiveFrom,
           remarks          AS Remarks,
           status           AS Status,
           entered_by       AS EnteredBy,
           entered_dt       AS EnteredDt,
           updated_by       AS UpdatedBy,
           updated_dt       AS UpdatedDt
    FROM GRAC_New.sla_master
    WHERE (@p_id = 0 OR sla_id = @p_id)
      AND (NULLIF(@p_status, N'') IS NULL OR status = @p_status)
      AND (NULLIF(@p_search, N'') IS NULL
           OR sla_code       LIKE N'%' + @p_search + N'%'
           OR process_code   LIKE N'%' + @p_search + N'%'
           OR classification LIKE N'%' + @p_search + N'%')
    ORDER BY process_code,
             CASE classification WHEN N'Critical' THEN 1 WHEN N'High' THEN 2 ELSE 3 END,
             sla_id;
END
GO

/* ------------------------------------------------------------------
   3. cm_manage_sla_master
   ------------------------------------------------------------------
   Actions:
     ADD       -> insert (payload requires process / classification / duration / basis)
     EDIT      -> update duration, thresholds, remarks, effective date
     INACTIVE  -> soft-delete (status = Inactive); remarks required as reason
     ACTIVATE  -> flip Inactive back to Active (respects unique-per-pair index)

   Audit columns (entered_by/dt, updated_by/dt) are set by the proc so
   the web layer never has to send them.
   ------------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE dbo.cm_manage_sla_master
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30),
    @p_id          BIGINT        = 0,
    @p_search      NVARCHAR(250) = N'',
    @p_status      NVARCHAR(30)  = N'',
    @p_payload     NVARCHAR(MAX) = N'{}',
    @p_usr_id      NVARCHAR(100) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @p_entity_type <> N'sla-master'
    BEGIN
        ;THROW 50001, N'Unsupported repository area', 1;
    END

    IF NULLIF(@p_usr_id, N'') IS NULL SET @p_usr_id = N'system';

    DECLARE
        @process_code   NVARCHAR(80)  = JSON_VALUE(@p_payload, N'$.processCode'),
        @classification NVARCHAR(20)  = JSON_VALUE(@p_payload, N'$.classification'),
        @duration_value INT           = TRY_CAST(JSON_VALUE(@p_payload, N'$.durationValue') AS INT),
        @duration_unit  NVARCHAR(10)  = JSON_VALUE(@p_payload, N'$.durationUnit'),
        @time_basis     NVARCHAR(30)  = JSON_VALUE(@p_payload, N'$.timeBasis'),
        @warning_pct    DECIMAL(5,2)  = TRY_CAST(JSON_VALUE(@p_payload, N'$.warningPct')    AS DECIMAL(5,2)),
        @escalation_pct DECIMAL(5,2)  = TRY_CAST(JSON_VALUE(@p_payload, N'$.escalationPct') AS DECIMAL(5,2)),
        @effective_from DATE          = TRY_CAST(JSON_VALUE(@p_payload, N'$.effectiveFrom') AS DATE),
        @remarks        NVARCHAR(500) = JSON_VALUE(@p_payload, N'$.remarks'),
        @status_in      NVARCHAR(20)  = COALESCE(JSON_VALUE(@p_payload, N'$.status'), N'Active');

    DECLARE @action NVARCHAR(30) = UPPER(ISNULL(@p_action, N''));

    /* Gateway Save posts Action='SAVE' for both create and update -- resolve
       to ADD (new row) or EDIT (existing row) here so the switch below
       stays readable. */
    IF @action = N'SAVE'
        SET @action = CASE WHEN ISNULL(@p_id, 0) = 0 THEN N'ADD' ELSE N'EDIT' END;

    IF @action = N'ADD'
    BEGIN
        IF NULLIF(@process_code, N'') IS NULL
        BEGIN
            ;THROW 50201, N'Process is required.', 1;
        END
        IF NULLIF(@classification, N'') IS NULL
        BEGIN
            ;THROW 50202, N'Classification is required.', 1;
        END
        IF @duration_value IS NULL
        BEGIN
            ;THROW 50203, N'Duration value is required.', 1;
        END
        IF NULLIF(@duration_unit, N'') IS NULL
        BEGIN
            ;THROW 50204, N'Duration unit is required.', 1;
        END
        IF NULLIF(@time_basis, N'') IS NULL
        BEGIN
            ;THROW 50205, N'Time basis is required.', 1;
        END

        INSERT GRAC_New.sla_master(process_code, classification, duration_value, duration_unit,
                                   time_basis, warning_pct, escalation_pct, effective_from,
                                   remarks, status, entered_by)
        VALUES(@process_code, @classification, @duration_value, @duration_unit,
               @time_basis, COALESCE(@warning_pct, 75.00), COALESCE(@escalation_pct, 90.00),
               @effective_from, @remarks, @status_in, @p_usr_id);

        SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Id;
        RETURN;
    END

    IF @action = N'EDIT'
    BEGIN
        IF @p_id IS NULL OR @p_id = 0
        BEGIN
            ;THROW 50206, N'SLA id is required for edit.', 1;
        END

        UPDATE GRAC_New.sla_master
        SET duration_value = COALESCE(@duration_value, duration_value),
            duration_unit  = COALESCE(NULLIF(@duration_unit, N''), duration_unit),
            time_basis     = COALESCE(NULLIF(@time_basis, N''), time_basis),
            warning_pct    = COALESCE(@warning_pct, warning_pct),
            escalation_pct = COALESCE(@escalation_pct, escalation_pct),
            effective_from = COALESCE(@effective_from, effective_from),
            remarks        = COALESCE(@remarks, remarks),
            status         = COALESCE(NULLIF(@status_in, N''), status),
            updated_by     = @p_usr_id,
            updated_dt     = SYSUTCDATETIME()
        WHERE sla_id = @p_id;

        SELECT @p_id AS Id;
        RETURN;
    END

    IF @action IN (N'INACTIVE', N'INACTIVATE', N'DELETE', N'RETIRE')
    BEGIN
        IF @p_id IS NULL OR @p_id = 0
        BEGIN
            ;THROW 50207, N'SLA id is required for deactivate.', 1;
        END
        /* RETIRE is the row-level "Inactive" from the Manage grid, which
           calls /Repository/{entity}/{id}/retire with an empty payload.
           A form-driven INACTIVE (from the SlaMaster inactive-mode form)
           carries a mandatory deactivation reason.  Enforce remarks only
           in the form-driven path so the grid-level flow doesn't 500. */
        IF @action <> N'RETIRE' AND NULLIF(@remarks, N'') IS NULL
        BEGIN
            ;THROW 50208, N'Deactivation reason (remarks) is required.', 1;
        END

        UPDATE GRAC_New.sla_master
        SET status     = N'Inactive',
            remarks    = COALESCE(NULLIF(@remarks, N''), remarks),
            updated_by = @p_usr_id,
            updated_dt = SYSUTCDATETIME()
        WHERE sla_id = @p_id;

        SELECT @p_id AS Id;
        RETURN;
    END

    IF @action IN (N'ACTIVATE', N'REACTIVATE')
    BEGIN
        IF @p_id IS NULL OR @p_id = 0
        BEGIN
            ;THROW 50209, N'SLA id is required for activate.', 1;
        END

        UPDATE GRAC_New.sla_master
        SET status     = N'Active',
            updated_by = @p_usr_id,
            updated_dt = SYSUTCDATETIME()
        WHERE sla_id = @p_id;

        SELECT @p_id AS Id;
        RETURN;
    END

    ;THROW 50210, N'Unsupported action for sla-master.', 1;
END
GO

/* ------------------------------------------------------------------
   4. Seed -- 38 rows from Obligation Definition.xlsx (Sheet2).
   ------------------------------------------------------------------
   Idempotent MERGE on (process_code, classification) so re-running
   the migration does not duplicate rows or blow away edits.  Numeric
   columns are refreshed on match to keep the workbook as the source
   of truth until real data flows in.
   ------------------------------------------------------------------ */
MERGE GRAC_New.sla_master AS target
USING (VALUES
    (N'Gap Analysis',          N'Critical',  2,  N'Days',  N'Business Days'),
    (N'Gap Analysis',          N'High',      3,  N'Days',  N'Business Days'),
    (N'Gap Analysis',          N'Standard',  5,  N'Days',  N'Business Days'),
    (N'Gap Remediation',       N'Critical',  15, N'Days',  N'Business Days'),
    (N'Gap Remediation',       N'High',      30, N'Days',  N'Business Days'),
    (N'Gap Remediation',       N'Standard',  60, N'Days',  N'Business Days'),
    (N'Risk Assessment',       N'Critical',  2,  N'Days',  N'Business Days'),
    (N'Risk Assessment',       N'High',      5,  N'Days',  N'Business Days'),
    (N'Risk Assessment',       N'Standard',  10, N'Days',  N'Business Days'),
    (N'Risk Treatment',        N'Critical',  30, N'Days',  N'Business Days'),
    (N'Risk Treatment',        N'High',      60, N'Days',  N'Business Days'),
    (N'Risk Treatment',        N'Standard',  90, N'Days',  N'Business Days'),
    (N'Exception Approval',    N'Critical',  2,  N'Days',  N'Business Days'),
    (N'Exception Approval',    N'High',      3,  N'Days',  N'Business Days'),
    (N'Exception Approval',    N'Standard',  5,  N'Days',  N'Business Days'),
    (N'Exception Action',      N'Critical',  15, N'Days',  N'Business Days'),
    (N'Exception Action',      N'High',      30, N'Days',  N'Business Days'),
    (N'Exception Action',      N'Standard',  60, N'Days',  N'Business Days'),
    (N'Exception Review',      N'Critical',  2,  N'Days',  N'Business Days'),
    (N'Exception Review',      N'Standard',  5,  N'Days',  N'Business Days'),
    (N'Task Execution',        N'Critical',  5,  N'Days',  N'Business Days'),
    (N'Task Execution',        N'High',      10, N'Days',  N'Business Days'),
    (N'Task Execution',        N'Standard',  30, N'Days',  N'Business Days'),
    (N'Continuous Assurance',  N'Critical',  2,  N'Days',  N'Business Days'),
    (N'Continuous Assurance',  N'High',      5,  N'Days',  N'Business Days'),
    (N'Continuous Assurance',  N'Standard',  10, N'Days',  N'Business Days'),
    (N'Event Assurance',       N'Critical',  4,  N'Hours', N'Business Hours'),
    (N'Event Assurance',       N'High',      8,  N'Hours', N'Business Hours'),
    (N'Event Assurance',       N'Standard',  1,  N'Days',  N'Business Day'),
    (N'Obligation Fulfilment', N'Critical',  5,  N'Days',  N'Calendar Days'),
    (N'Obligation Fulfilment', N'High',      10, N'Days',  N'Calendar Days'),
    (N'Obligation Fulfilment', N'Standard',  15, N'Days',  N'Calendar Days'),
    (N'Custom Task',           N'Critical',  4,  N'Hours', N'Business Hours'),
    (N'Custom Task',           N'High',      2,  N'Days',  N'Business Days'),
    (N'Custom Task',           N'Standard',  5,  N'Days',  N'Business Days'),
    (N'Periodic Review',       N'Critical',  5,  N'Days',  N'Business Days'),
    (N'Periodic Review',       N'High',      10, N'Days',  N'Business Days'),
    (N'Periodic Review',       N'Standard',  30, N'Days',  N'Business Days')
) AS source(process_code, classification, duration_value, duration_unit, time_basis)
ON target.process_code = source.process_code AND target.classification = source.classification
WHEN MATCHED AND target.status = N'Active' THEN UPDATE SET
    duration_value = source.duration_value,
    duration_unit  = source.duration_unit,
    time_basis     = source.time_basis,
    warning_pct    = 75.00,
    escalation_pct = 90.00,
    updated_by     = N'migration-044',
    updated_dt     = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(process_code, classification, duration_value, duration_unit,
                             time_basis, warning_pct, escalation_pct, status, entered_by)
    VALUES(source.process_code, source.classification, source.duration_value, source.duration_unit,
           source.time_basis, 75.00, 90.00, N'Active', N'migration-044');
GO

PRINT 'Migration 044_sla_master_table_and_procs applied.';
GO
