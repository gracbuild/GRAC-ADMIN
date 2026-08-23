-- =====================================================================
-- 035 -- Event-driven Assurance, Phase B: runtime schema
--
-- 033/034 installed the DEFINITION half: an Assurance obligation can be
-- classified as event-driven and pointed at a leaf event type.  This
-- migration installs the RUNTIME half -- what actually happens when the
-- event occurs.
--
--     assurance_event_occurrence    one row per real event
--     assurance_checklist_item      one row per (occurrence x applicable rule)
--     assurance_checklist_evidence  proof attached to a completed item
--
-- GOVERNANCE -- the decision this whole design turns on
-- ----------------------------------------------------
-- These three tables are DIRECT WRITE.  They are registered in
-- cm_entity_master with is_maker_checker = 0 on purpose.
--
-- Routing checklist completion through change_management would mean every
-- new employee generates one approval request per applicable assurance.
-- Seven onboarding checks x fifty hires a month is 350 approval rows that
-- a checker must clear before anything is considered done -- the queue
-- becomes unusable within weeks and the approval signal is destroyed.
--
-- The rules themselves stay governed (they ride the obligation bundle from
-- 031/032).  Recording that a rule was carried out is operational data, not
-- policy, and is governed by permission plus an immutable audit trail.
--
-- SNAPSHOTTING
-- ------------
-- assurance_checklist_item copies the verification method and assurance
-- party from the spec AT GENERATION TIME.  This is an audit system: a
-- checklist completed in 2026 must still show what was actually asked, even
-- after the obligation is edited in 2027.  Joining live to the obligation
-- would let a rule edit silently rewrite history.  The FKs are kept for
-- traceability; the text is frozen.
--
-- Decisions confirmed 2026-07-29:
--   * One result per obligation (Pass / Fail / Not Applicable + remarks +
--     evidence).  NOT per-question -- a child response table can be added
--     later without disturbing anything saved by then.
--   * No assignment routing.  Anyone holding the permission may complete an
--     item; completed_by records who actually did.  assurance_party travels
--     as a snapshot hint of who was expected to act.
--
-- Preflight: 033 (event_type_master + spec columns).
--
-- Rollback: database/035_assurance_runtime_schema_rollback.sql
--
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('GRAC_New.event_type_master','U') IS NULL
BEGIN
    RAISERROR('035 preflight failed: event_type_master is missing. Run 033 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. assurance_event_occurrence
--
--    subject_entity / subject_record_id form a POLYMORPHIC pointer -- the
--    register a given event attaches to comes from event_type_master, and
--    there is no single FK target (today cm_user; later asset, vendor).
--    Deliberately not an FK: a real FK would need one nullable column per
--    register and a CHECK that exactly one is set, which does not scale as
--    domains are added by INSERT.
--
--    subject_label is denormalized on purpose.  The checklist must still
--    read correctly after the underlying user is renamed or deactivated --
--    and after the register row is deleted entirely.
-- =====================================================================
IF OBJECT_ID('GRAC_New.assurance_event_occurrence','U') IS NULL
BEGIN
    CREATE TABLE GRAC_New.assurance_event_occurrence(
        occurrence_id     BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_cm_assurance_occurrence PRIMARY KEY,
        event_type_id     BIGINT NOT NULL
            CONSTRAINT fk_cm_assurance_occurrence_event
                REFERENCES GRAC_New.event_type_master(event_type_id),
        subject_entity    NVARCHAR(100) NOT NULL,
        subject_record_id BIGINT        NOT NULL,
        subject_label     NVARCHAR(300) NOT NULL,
        occurred_dt       DATETIME2(3)  NOT NULL
            CONSTRAINT df_cm_assurance_occurrence_dt DEFAULT SYSUTCDATETIME(),
        raise_source      NVARCHAR(20)  NOT NULL
            CONSTRAINT df_cm_assurance_occurrence_src DEFAULT 'Manual',
        remarks           NVARCHAR(MAX) NULL,
        status            NVARCHAR(30)  NOT NULL
            CONSTRAINT df_cm_assurance_occurrence_status DEFAULT 'Open',
        entered_by        NVARCHAR(100) NOT NULL
            CONSTRAINT df_cm_assurance_occurrence_eb DEFAULT 'system',
        entered_dt        DATETIME2(3)  NOT NULL
            CONSTRAINT df_cm_assurance_occurrence_ed DEFAULT SYSUTCDATETIME(),
        updated_by        NVARCHAR(100) NULL,
        updated_dt        DATETIME2(3)  NULL,
        CONSTRAINT ck_cm_assurance_occurrence_status
            CHECK(status IN ('Open','Completed','Cancelled')),
        CONSTRAINT ck_cm_assurance_occurrence_source
            CHECK(raise_source IN ('Manual','System'))
    );

    -- Idempotency: the same event for the same subject must not be raisable
    -- twice while one is still Open.  Filtered so a genuine second
    -- onboarding of a rehired person is still allowed once the first is
    -- closed.
    CREATE UNIQUE INDEX ux_cm_assurance_occurrence_open
        ON GRAC_New.assurance_event_occurrence(event_type_id, subject_entity, subject_record_id)
        WHERE status = 'Open';

    CREATE INDEX ix_cm_assurance_occurrence_lookup
        ON GRAC_New.assurance_event_occurrence(status, occurred_dt DESC)
        INCLUDE (event_type_id, subject_label);
END
GO

-- =====================================================================
-- 2. assurance_checklist_item
--
--    One per (occurrence x assurance obligation that matched the event).
-- =====================================================================
IF OBJECT_ID('GRAC_New.assurance_checklist_item','U') IS NULL
BEGIN
    CREATE TABLE GRAC_New.assurance_checklist_item(
        checklist_item_id   BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_cm_assurance_checklist_item PRIMARY KEY,
        occurrence_id       BIGINT NOT NULL
            CONSTRAINT fk_cm_checklist_item_occurrence
                REFERENCES GRAC_New.assurance_event_occurrence(occurrence_id),
        obligation_id       BIGINT NOT NULL
            CONSTRAINT fk_cm_checklist_item_obligation
                REFERENCES GRAC_New.requirement_obligation(obligation_id),
        assurance_spec_id   BIGINT NULL
            CONSTRAINT fk_cm_checklist_item_spec
                REFERENCES GRAC_New.obligation_assurance_spec(assurance_spec_id),

        -- Frozen at generation time.  See the SNAPSHOTTING note in the header.
        obligation_name_snapshot      NVARCHAR(500) NOT NULL,
        verification_method_snapshot  NVARCHAR(500) NOT NULL,
        assurance_party_snapshot      NVARCHAR(250) NULL,
        scope_snapshot                NVARCHAR(500) NULL,

        due_dt              DATETIME2(3)  NULL,
        status              NVARCHAR(30)  NOT NULL
            CONSTRAINT df_cm_checklist_item_status DEFAULT 'Pending',
        response_value      NVARCHAR(20)  NULL,
        remarks             NVARCHAR(MAX) NULL,
        completed_by        NVARCHAR(100) NULL,
        completed_dt        DATETIME2(3)  NULL,
        entered_by          NVARCHAR(100) NOT NULL
            CONSTRAINT df_cm_checklist_item_eb DEFAULT 'system',
        entered_dt          DATETIME2(3)  NOT NULL
            CONSTRAINT df_cm_checklist_item_ed DEFAULT SYSUTCDATETIME(),
        updated_by          NVARCHAR(100) NULL,
        updated_dt          DATETIME2(3)  NULL,

        CONSTRAINT ck_cm_checklist_item_status
            CHECK(status IN ('Pending','Completed')),
        CONSTRAINT ck_cm_checklist_item_response
            CHECK(response_value IS NULL OR response_value IN ('Pass','Fail','Not Applicable')),
        -- A completed item must carry a result and who recorded it; a pending
        -- item must carry none of that.  Keeps half-finished rows impossible.
        CONSTRAINT ck_cm_checklist_item_completion CHECK(
               (status = 'Pending'   AND response_value IS NULL
                                     AND completed_by IS NULL AND completed_dt IS NULL)
            OR (status = 'Completed' AND response_value IS NOT NULL
                                     AND completed_by IS NOT NULL AND completed_dt IS NOT NULL)
        ),
        -- One item per rule per occurrence.
        CONSTRAINT uq_cm_checklist_item_occurrence_obligation
            UNIQUE(occurrence_id, obligation_id)
    );

    CREATE INDEX ix_cm_checklist_item_occurrence
        ON GRAC_New.assurance_checklist_item(occurrence_id, status);
    CREATE INDEX ix_cm_checklist_item_pending
        ON GRAC_New.assurance_checklist_item(status, due_dt)
        INCLUDE (occurrence_id, obligation_name_snapshot);
END
GO

-- =====================================================================
-- 3. assurance_checklist_evidence
--    Proof attached to an item.  Stores a pointer, not the bytes -- file
--    storage is outside this schema's concern.
-- =====================================================================
IF OBJECT_ID('GRAC_New.assurance_checklist_evidence','U') IS NULL
BEGIN
    CREATE TABLE GRAC_New.assurance_checklist_evidence(
        checklist_evidence_id BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_cm_checklist_evidence PRIMARY KEY,
        checklist_item_id     BIGINT NOT NULL
            CONSTRAINT fk_cm_checklist_evidence_item
                REFERENCES GRAC_New.assurance_checklist_item(checklist_item_id),
        evidence_type_id      INT NULL
            CONSTRAINT fk_cm_checklist_evidence_type
                REFERENCES GRAC_New.evidence_type_master(evidence_type_id),
        file_name             NVARCHAR(300) NULL,
        file_reference        NVARCHAR(500) NULL,
        remarks               NVARCHAR(MAX) NULL,
        status                NVARCHAR(30)  NOT NULL
            CONSTRAINT df_cm_checklist_evidence_status DEFAULT 'Active',
        entered_by            NVARCHAR(100) NOT NULL
            CONSTRAINT df_cm_checklist_evidence_eb DEFAULT 'system',
        entered_dt            DATETIME2(3)  NOT NULL
            CONSTRAINT df_cm_checklist_evidence_ed DEFAULT SYSUTCDATETIME(),
        updated_by            NVARCHAR(100) NULL,
        updated_dt            DATETIME2(3)  NULL
    );

    CREATE INDEX ix_cm_checklist_evidence_item
        ON GRAC_New.assurance_checklist_evidence(checklist_item_id, status);
END
GO

-- =====================================================================
-- 4. Register the runtime entities.
--
--    is_maker_checker = 0 is the load-bearing value here -- see the
--    GOVERNANCE note in the header.  Do not flip these to 1 without
--    understanding that it puts every checklist completion into the
--    approval queue.
-- =====================================================================
;WITH src(entity_code, entity_name, table_name, route_code, is_maker_checker, display_order) AS (
    SELECT N'assurance-occurrences', N'Event Checklists',
           N'GRAC_New.assurance_event_occurrence', N'assurance-occurrences', 0, 96
    UNION ALL
    SELECT N'assurance-checklist', N'Event Checklist Items',
           N'GRAC_New.assurance_checklist_item', N'assurance-checklist', 0, 97
)
MERGE GRAC_New.cm_entity_master AS target
USING src ON target.entity_code = src.entity_code
WHEN MATCHED THEN UPDATE SET
    target.entity_name      = src.entity_name,
    target.table_name       = src.table_name,
    target.route_code       = src.route_code,
    target.is_maker_checker = src.is_maker_checker,
    target.display_order    = src.display_order,
    target.status           = 'Active',
    target.updated_by       = 'migration-035',
    target.updated_dt       = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT(entity_code, entity_name, table_name, route_code, is_maker_checker, display_order, status, entered_by)
    VALUES(src.entity_code, src.entity_name, src.table_name, src.route_code, src.is_maker_checker, src.display_order, 'Active', 'migration-035');
GO

-- =====================================================================
-- 5. Sidebar menu row under Repository Management.
--    Only the occurrence list gets a menu entry; checklist items are
--    reached by drilling into an occurrence.
-- =====================================================================
;WITH menu_src(menu_code, parent_code, menu_name, route_url, display_order, icon) AS (
    SELECT N'assurance-occurrences', N'control-management', N'Event Checklists',
           N'Repository/Index?areaKey=assurance-occurrences', 96, N'clipboard-check'
)
MERGE GRAC_New.cm_menu AS target
USING (
    SELECT m.menu_code, p.menu_id parent_menu_id, m.menu_name, m.route_url, m.display_order, m.icon
    FROM menu_src m
    LEFT JOIN GRAC_New.cm_menu p ON p.menu_code = m.parent_code
) AS source ON target.menu_code = source.menu_code
WHEN MATCHED THEN UPDATE SET
    target.parent_menu_id = source.parent_menu_id,
    target.menu_name      = source.menu_name,
    target.route_url      = source.route_url,
    target.display_order  = source.display_order,
    target.icon           = source.icon,
    target.status         = 'Active',
    target.updated_by     = 'migration-035',
    target.updated_dt     = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT(parent_menu_id, menu_name, menu_code, route_url, display_order, icon, status, entered_by)
    VALUES(source.parent_menu_id, source.menu_name, source.menu_code, source.route_url, source.display_order, source.icon, 'Active', 'migration-035');
GO

-- Grant CM_ADMIN full permission so the screen is reachable immediately.
-- Other roles must be granted explicitly via Role Permission Management.
INSERT GRAC_New.cm_role_permission(role_id, menu_id, can_view, can_add, can_edit, can_inactive, can_approve, status, entered_by)
SELECT r.role_id, m.menu_id, 1, 1, 1, 1, 1, 'Active', 'migration-035'
FROM GRAC_New.cm_role r
JOIN GRAC_New.cm_menu m ON m.menu_code = N'assurance-occurrences'
WHERE r.role_name = 'CM_ADMIN'
  AND NOT EXISTS (SELECT 1 FROM GRAC_New.cm_role_permission x
                  WHERE x.role_id = r.role_id AND x.menu_id = m.menu_id);
GO

PRINT '035 complete. Assurance runtime schema installed:';
PRINT '  assurance_event_occurrence / assurance_checklist_item / assurance_checklist_evidence';
PRINT '  registered in cm_entity_master with is_maker_checker = 0 (direct write, by design);';
PRINT '  Event Checklists menu row added under Repository Management.';
PRINT '  Next: 036 installs the raise / complete procedures.';
GO

-- Re-enable execution: harmless when the preflight passed (NOEXEC was
-- never switched on), essential when it did not.
SET NOEXEC OFF;
GO
