-- =====================================================================
-- 033 -- Event-driven Assurance, Phase A: event type taxonomy
--
-- Context
-- -------
-- An Assurance obligation is either SCHEDULED (quarterly, annually) or
-- EVENT DRIVEN (every time a person is onboarded, every time an asset is
-- decommissioned).  For the event-driven case, each occurrence of the event
-- must later produce a checklist of every applicable assurance.
--
-- This migration installs the DEFINITION half of that only:
--
--     * GRAC_New.event_type_master           -- the taxonomy tree
--     * reference_option 'assurance-trigger-modes'
--     * obligation_assurance_spec.trigger_mode     (NEW)
--     * obligation_assurance_spec.event_type_id    (NEW)
--     * dbo.sp_cm_event_type_list            -- cascade read
--     * cm_get_obligation_taxonomy re-emitted with an 'event-types' branch
--
-- The RUNTIME half (occurrences, generated checklists, completion) is
-- deliberately NOT here -- see docs/event-driven-assurance-design.md,
-- Phase B.  The two layers have different governance: definition rides the
-- existing obligation maker-checker bundle, runtime must be direct-write.
--
-- Why a tree and not three columns
-- --------------------------------
-- The obvious model is trigger_mode + event_domain + event_name columns.
-- That breaks the first time someone asks for "Vendor / Contract Signed" --
-- it would need a schema change, a dispatcher change and a front-end change.
-- event_type_master is self-referencing, so every level of the cascade reads
-- from one table and a whole new domain is an INSERT.  No release required.
--
-- subject_entity is the seam that makes Phase B possible: it records WHICH
-- register a given event attaches to, so an occurrence can point at a real
-- record (cm_user 4021).  Without it the runtime layer has nothing to hang on.
--
-- NOTE on the asset domain: this codebase has no asset register yet (only
-- cm_user exists).  Asset event types are seeded as Inactive so they appear
-- in admin but cannot be selected until a register exists.  People events
-- are fully usable today.
--
-- Preflight: 026 (obligation_assurance_spec), 029 (taxonomy dispatcher).
--
-- Rollback: database/033_event_type_taxonomy_rollback.sql
--
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('GRAC_New.obligation_assurance_spec','U') IS NULL
BEGIN
    RAISERROR('033 preflight failed: obligation_assurance_spec is missing. Run 026 first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('dbo.cm_get_obligation_taxonomy','P') IS NULL
BEGIN
    RAISERROR('033 preflight failed: cm_get_obligation_taxonomy is missing. Run 029 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. event_type_master -- self-referencing taxonomy.
--
--    parent_event_type_id NULL  => domain root (People, Asset)
--    parent_event_type_id set   => a concrete event (Onboarding, ...)
--
--    Only LEAF rows are selectable on an assurance spec; roots exist to
--    group them in the cascade.
-- =====================================================================
IF OBJECT_ID('GRAC_New.event_type_master','U') IS NULL
BEGIN
    CREATE TABLE GRAC_New.event_type_master(
        event_type_id        BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_cm_event_type_master PRIMARY KEY,
        parent_event_type_id BIGINT NULL
            CONSTRAINT fk_cm_event_type_parent
                REFERENCES GRAC_New.event_type_master(event_type_id),
        event_code           NVARCHAR(60)  NOT NULL,
        event_name           NVARCHAR(120) NOT NULL,
        description          NVARCHAR(500) NULL,
        -- Which register an occurrence of this event attaches to.  Set on the
        -- domain root and inherited by its children.  NULL on a root means the
        -- domain has no register yet.
        subject_entity       NVARCHAR(100) NULL,
        display_order        INT NOT NULL
            CONSTRAINT df_cm_event_type_display_order DEFAULT 100,
        status               NVARCHAR(30)  NOT NULL
            CONSTRAINT df_cm_event_type_status DEFAULT 'Active',
        entered_by           NVARCHAR(100) NOT NULL
            CONSTRAINT df_cm_event_type_eb DEFAULT 'system',
        entered_dt           DATETIME2(3)  NOT NULL
            CONSTRAINT df_cm_event_type_ed DEFAULT SYSUTCDATETIME(),
        updated_by           NVARCHAR(100) NULL,
        updated_dt           DATETIME2(3)  NULL,
        CONSTRAINT uq_cm_event_type_code UNIQUE(event_code)
    );
    CREATE INDEX ix_cm_event_type_parent
        ON GRAC_New.event_type_master(parent_event_type_id, display_order);
END
GO

-- =====================================================================
-- 2. Seed the taxonomy.  MERGE on event_code so re-running is a no-op and
--    an operator's own additions are never clobbered.
-- =====================================================================
;WITH roots(event_code, event_name, description, subject_entity, display_order, status) AS (
    SELECT N'PEOPLE', N'People', N'Events in the employee / user lifecycle.',   N'cm_user', 10, N'Active'
    UNION ALL
    -- Seeded Inactive: no asset register exists in this database yet, so an
    -- asset event could be selected but never raised.  Flip to Active in the
    -- same release that introduces the register.
    SELECT N'ASSET',  N'Asset',  N'Events in the asset lifecycle.',             NULL,       20, N'Inactive'
)
MERGE GRAC_New.event_type_master AS target
USING roots AS src ON target.event_code = src.event_code
WHEN MATCHED THEN UPDATE SET
    target.event_name     = src.event_name,
    target.description    = src.description,
    target.subject_entity = src.subject_entity,
    target.display_order  = src.display_order,
    target.updated_by     = 'migration-033',
    target.updated_dt     = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT(parent_event_type_id, event_code, event_name, description, subject_entity, display_order, status, entered_by)
    VALUES(NULL, src.event_code, src.event_name, src.description, src.subject_entity, src.display_order, src.status, 'migration-033');
GO

;WITH leaves(parent_code, event_code, event_name, description, display_order, status) AS (
    SELECT N'PEOPLE', N'PEOPLE_ONBOARDING',     N'Onboarding',      N'A person joins the organisation.',       10, N'Active'
    UNION ALL SELECT N'PEOPLE', N'PEOPLE_OFFBOARDING', N'Offboarding',    N'A person leaves the organisation.',      20, N'Active'
    -- Codes amended by migration 042 from ASSET_COMMISSIONED /
    -- ASSET_DECOMMISSIONED to the gerund form, matching PEOPLE_ONBOARDING /
    -- PEOPLE_OFFBOARDING and the subscriber-side event definitions that join
    -- on event_code. Amended HERE too, not just in 042, because this MERGE
    -- matches on event_code: left at the old literals, re-running 033 after
    -- 042 would find no match and INSERT a second, stale pair under ASSET.
    -- Still seeded Inactive -- 042 owns activation.
    UNION ALL SELECT N'ASSET',  N'ASSET_COMMISSIONING',   N'Commissioning',   N'An asset is brought into service.',      10, N'Inactive'
    UNION ALL SELECT N'ASSET',  N'ASSET_DECOMMISSIONING', N'Decommissioning', N'An asset is retired from service.',      20, N'Inactive'
)
MERGE GRAC_New.event_type_master AS target
USING (
    SELECT p.event_type_id AS parent_event_type_id, l.event_code, l.event_name,
           l.description, p.subject_entity, l.display_order, l.status
    FROM leaves l
    JOIN GRAC_New.event_type_master p ON p.event_code = l.parent_code
) AS src ON target.event_code = src.event_code
WHEN MATCHED THEN UPDATE SET
    target.parent_event_type_id = src.parent_event_type_id,
    target.event_name           = src.event_name,
    target.description          = src.description,
    -- children inherit the register from their domain root
    target.subject_entity       = src.subject_entity,
    target.display_order        = src.display_order,
    target.updated_by           = 'migration-033',
    target.updated_dt           = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT(parent_event_type_id, event_code, event_name, description, subject_entity, display_order, status, entered_by)
    VALUES(src.parent_event_type_id, src.event_code, src.event_name, src.description, src.subject_entity, src.display_order, src.status, 'migration-033');
GO

-- =====================================================================
-- 3. Trigger modes.
--
--    A dedicated option group rather than reusing the existing
--    'trigger-types' group: that one is a broader six-value list
--    (Regulatory Change, Incident, Audit Finding, ...) describing what
--    prompted a change.  An assurance trigger MODE is a strict binary and
--    the two lists must be free to evolve apart.
-- =====================================================================
MERGE GRAC_New.reference_option AS target
USING (VALUES
    (N'assurance-trigger-modes', N'Scheduled',   N'Scheduled',    10),
    (N'assurance-trigger-modes', N'EventDriven', N'Event Driven', 20)
) AS src(option_group, option_value, option_label, display_order)
   ON target.option_group = src.option_group AND target.option_value = src.option_value
WHEN MATCHED THEN UPDATE SET
    target.option_label  = src.option_label,
    target.display_order = src.display_order,
    target.status        = N'Active',
    target.updated_by    = 'migration-033',
    target.updated_dt    = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT(option_group, option_value, option_label, display_order, status, entered_by)
    VALUES(src.option_group, src.option_value, src.option_label, src.display_order, N'Active', 'migration-033');
GO

-- =====================================================================
-- 4. Extend obligation_assurance_spec.
--
--    Both columns are nullable: every pre-existing assurance spec predates
--    this feature and must keep working un-classified until an author
--    revisits it.
-- =====================================================================
-- trigger_mode is stored as the CODE, not as an FK to reference_option.
--
-- Two reasons:
--   1. A CHECK constraint may only reference columns in its own row -- SQL
--      Server rejects a subquery with "Msg 1046: Subqueries are not allowed in
--      this context".  Resolving an FK to its option_value inside the CHECK is
--      therefore impossible; keeping the code on the row makes the rule local
--      and enforceable.
--   2. The mode is not really extensible reference data.  Application code
--      branches on exactly these two values, so an admin adding a third option
--      would create a state nothing handles.  The CHECK below makes that
--      impossible by construction.
--
-- reference_option still owns the LABELS the dropdown renders (seeded above);
-- the stored value is the option_value, so the dropdown stays table-driven
-- while the column stays self-validating.
IF COL_LENGTH('GRAC_New.obligation_assurance_spec','trigger_mode') IS NULL
BEGIN
    ALTER TABLE GRAC_New.obligation_assurance_spec
        ADD trigger_mode NVARCHAR(20) NULL;
END
GO

IF COL_LENGTH('GRAC_New.obligation_assurance_spec','event_type_id') IS NULL
BEGIN
    ALTER TABLE GRAC_New.obligation_assurance_spec
        ADD event_type_id BIGINT NULL
            CONSTRAINT fk_cm_assurance_spec_event_type
                REFERENCES GRAC_New.event_type_master(event_type_id);
END
GO

-- Clean up trigger_mode_id if an earlier revision of this script created it.
-- That column was an FK to reference_option and is superseded by trigger_mode.
IF COL_LENGTH('GRAC_New.obligation_assurance_spec','trigger_mode_id') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_cm_assurance_spec_trigger_mode')
        ALTER TABLE GRAC_New.obligation_assurance_spec
            DROP CONSTRAINT fk_cm_assurance_spec_trigger_mode;

    -- Carry any value already captured across to the new column before the
    -- old one goes, so a partially-applied run loses nothing.
    UPDATE s
    SET s.trigger_mode = ro.option_value
    FROM GRAC_New.obligation_assurance_spec s
    JOIN GRAC_New.reference_option ro ON ro.reference_option_id = s.trigger_mode_id
    WHERE s.trigger_mode IS NULL;

    ALTER TABLE GRAC_New.obligation_assurance_spec DROP COLUMN trigger_mode_id;
END
GO

-- Mutual exclusivity, entirely row-local.
--   * both NULL      -> not yet classified (every pre-033 row)
--   * Scheduled      -> must NOT carry an event
--   * EventDriven    -> must carry an event
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_cm_assurance_spec_trigger')
BEGIN
    ALTER TABLE GRAC_New.obligation_assurance_spec WITH CHECK
        ADD CONSTRAINT ck_cm_assurance_spec_trigger CHECK (
               (trigger_mode IS NULL           AND event_type_id IS NULL)
            OR (trigger_mode = N'Scheduled'    AND event_type_id IS NULL)
            OR (trigger_mode = N'EventDriven'  AND event_type_id IS NOT NULL)
        );
END
GO

-- =====================================================================
-- 5. sp_cm_event_type_list
--    Flat projection of the tree.  The front-end builds the cascade from
--    ParentEventTypeId rather than the server pre-nesting it, so one call
--    serves every level.
--
--    @p_include_inactive surfaces the Asset branch for admin screens; the
--    obligation form calls it with 0 and therefore only ever offers domains
--    that can actually be raised.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_event_type_list
    @p_include_inactive BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        e.event_type_id                              AS Id,
        e.event_type_id                              AS EventTypeId,
        e.parent_event_type_id                       AS ParentEventTypeId,
        p.event_code                                 AS ParentEventCode,
        p.event_name                                 AS ParentEventName,
        e.event_code                                 AS EventCode,
        e.event_name                                 AS EventName,
        e.description                                AS Description,
        e.subject_entity                             AS SubjectEntity,
        CAST(CASE WHEN e.parent_event_type_id IS NULL THEN 1 ELSE 0 END AS BIT) AS IsDomain,
        e.display_order                              AS DisplayOrder,
        e.status                                     AS Status
    FROM GRAC_New.event_type_master e
    LEFT JOIN GRAC_New.event_type_master p ON p.event_type_id = e.parent_event_type_id
    WHERE (@p_include_inactive = 1 OR e.status = N'Active')
      -- a leaf whose domain is inactive must not surface on its own
      AND (@p_include_inactive = 1
           OR e.parent_event_type_id IS NULL
           OR p.status = N'Active')
    ORDER BY COALESCE(p.display_order, e.display_order), p.event_name, e.display_order, e.event_name;
END
GO

-- =====================================================================
-- 6. Re-emit cm_get_obligation_taxonomy with an 'event-types' branch.
--    Identical to 029 apart from the new branch, which sits beside
--    'obligation-types' because it likewise needs no obligationId.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.cm_get_obligation_taxonomy
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30)  = N'QUERY',
    @p_id          BIGINT        = 0,
    @p_search      NVARCHAR(250) = N'',
    @p_status      NVARCHAR(30)  = N'',
    @p_payload     NVARCHAR(MAX) = N'{}',
    @p_usr_id      NVARCHAR(100) = N'',
    @p_page        INT           = 1,
    @p_page_size   INT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @p_entity_type = N'obligation-types'
    BEGIN
        EXEC dbo.sp_cm_obligation_type_master_list;
        RETURN;
    END

    -- Event taxonomy for the Assurance trigger cascade (033).  Like
    -- obligation-types this is reference data and carries no obligationId.
    -- @p_status = 'All' opts into inactive rows for admin screens.
    IF @p_entity_type = N'event-types'
    BEGIN
        DECLARE @include_inactive BIT =
            CASE WHEN @p_status IN (N'All', N'Inactive') THEN 1 ELSE 0 END;
        EXEC dbo.sp_cm_event_type_list @p_include_inactive = @include_inactive;
        RETURN;
    END

    DECLARE @obligation_id BIGINT =
        COALESCE(TRY_CAST(JSON_VALUE(@p_payload, '$.obligationId') AS BIGINT), @p_id);

    IF @obligation_id IS NULL OR @obligation_id <= 0
    BEGIN
        RAISERROR('cm_get_obligation_taxonomy: obligationId is required for entity_type %s.', 16, 1, @p_entity_type);
        RETURN;
    END

    IF @p_entity_type = N'obligation-state'
        EXEC dbo.sp_cm_obligation_state_get           @p_obligation_id = @obligation_id, @p_include_inactive = 0;
    ELSE IF @p_entity_type = N'obligation-execution'
        EXEC dbo.sp_cm_obligation_execution_get       @p_obligation_id = @obligation_id, @p_include_inactive = 0;
    ELSE IF @p_entity_type = N'obligation-assurance'
        EXEC dbo.sp_cm_obligation_assurance_get       @p_obligation_id = @obligation_id, @p_include_inactive = 0;
    ELSE IF @p_entity_type = N'obligation-event-response'
        EXEC dbo.sp_cm_obligation_event_response_get  @p_obligation_id = @obligation_id, @p_include_inactive = 0;
    ELSE IF @p_entity_type = N'obligation-constraint'
        EXEC dbo.sp_cm_obligation_constraint_get      @p_obligation_id = @obligation_id, @p_include_inactive = 0;
    ELSE IF @p_entity_type = N'obligation-retention'
        EXEC dbo.sp_cm_obligation_retention_get       @p_obligation_id = @obligation_id, @p_include_inactive = 0;
    ELSE IF @p_entity_type = N'obligation-evidence-links'
        EXEC dbo.sp_cm_obligation_evidence_links_get  @p_obligation_id = @obligation_id, @p_include_inactive = 0;
    ELSE
        RAISERROR('cm_get_obligation_taxonomy: unknown entity_type %s.', 16, 1, @p_entity_type);
END
GO

PRINT '033 complete. event_type_master installed and seeded;';
PRINT '  assurance-trigger-modes reference options added;';
PRINT '  obligation_assurance_spec extended with trigger_mode + event_type_id;';
PRINT '  new read entity type: event-types.';
PRINT '  Asset branch is seeded INACTIVE -- no asset register exists yet.';
PRINT '  Next: 034 updates the assurance get/save procs to carry the new columns.';
GO

SELECT e.event_code EventCode, e.event_name EventName,
       p.event_code ParentCode, e.subject_entity SubjectEntity, e.status Status
FROM GRAC_New.event_type_master e
LEFT JOIN GRAC_New.event_type_master p ON p.event_type_id = e.parent_event_type_id
ORDER BY COALESCE(p.display_order, e.display_order), e.display_order;
GO

-- Re-enable execution: harmless when the preflight passed (NOEXEC was
-- never switched on), essential when it did not.
SET NOEXEC OFF;
GO
