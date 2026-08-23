-- =====================================================================
-- 037 -- Event-driven Assurance, Phase C: auto-raise for People events
--
-- Phase B could raise an event manually.  This migration makes People
-- events raise themselves: creating a user raises PEOPLE_ONBOARDING,
-- deactivating one raises PEOPLE_OFFBOARDING, and each generates its
-- checklist exactly as the manual path does.
--
-- Installs:
--     * reference_option 'assurance-settings' / 'people-autoraise'  (off switch)
--     * GRAC_New.tr_cm_user_assurance_autoraise                     (the hook)
--
-- WHY A TRIGGER AND NOT A BRANCH IN cm_manage_repository
-- ------------------------------------------------------
-- User Management can run under maker-checker.  When it does, a SAVE does
-- NOT write cm_user -- it writes a change_management row and returns; the
-- real INSERT happens later when the checker approves and the payload is
-- replayed with __approvalBypass = 1.
--
-- A hook inside the SAVE branch would therefore fire on the REQUEST, raising
-- a checklist for a user who does not exist yet and may never be approved.
-- A trigger fires when the row actually appears, which is correct under both
-- modes and needs no knowledge of the approval machinery.
--
-- THE TRIGGER MUST NOT BE ABLE TO FAIL
-- ------------------------------------
-- It sits in the write path of user creation.  A compliance-configuration
-- problem must never stop an administrator from creating a user.
--
-- TRY/CATCH is NOT sufficient protection here: the caller sets
-- XACT_ABORT ON, so an error inside a trigger dooms the outer transaction
-- whether or not it is caught.  The only real defence is a body that cannot
-- raise an error, so every statement below is guarded:
--
--   * event types are resolved by JOIN, so a missing or inactive event
--     yields no rows rather than a failed lookup;
--   * an existing Open occurrence is excluded by NOT EXISTS, so the unique
--     index is never violated;
--   * subject_label is LEFT()-truncated -- user_name(200) + login_id(160)
--     can exceed the 300-char column, which would otherwise raise a
--     string-truncation error on a perfectly ordinary long name;
--   * there are no THROWs, no casts and no arithmetic.
--
-- OFF SWITCH
-- ----------
-- reference_option 'assurance-settings' / 'people-autoraise' must be Active
-- for the trigger to do anything.  Set it Inactive to disable auto-raise
-- without dropping the trigger -- an escape hatch worth having for something
-- that sits in the path of every user write.
--
-- Preflight: 035 (runtime tables), 033 (event taxonomy).
--
-- Rollback: database/037_assurance_autoraise_people_rollback.sql
--
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('GRAC_New.assurance_event_occurrence','U') IS NULL
BEGIN
    RAISERROR('037 preflight failed: run 035 (runtime schema) first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Off switch.  Seeded Active: auto-raise is the point of this phase.
-- =====================================================================
MERGE GRAC_New.reference_option AS target
USING (VALUES
    (N'assurance-settings', N'people-autoraise', N'Auto-raise People assurance checklists', 10)
) AS src(option_group, option_value, option_label, display_order)
   ON target.option_group = src.option_group AND target.option_value = src.option_value
WHEN MATCHED THEN UPDATE SET
    target.option_label  = src.option_label,
    target.display_order = src.display_order,
    target.updated_by    = 'migration-037',
    target.updated_dt    = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT(option_group, option_value, option_label, display_order, status, entered_by)
    VALUES(src.option_group, src.option_value, src.option_label, src.display_order, N'Active', 'migration-037');
GO

-- =====================================================================
-- 2. fn_cm_assurance_specs_for_event -- the matching rule, once.
--
--    "Which assurances does this event raise?" is now asked from two places:
--    sp_cm_assurance_occurrence_raise (manual) and the trigger below
--    (automatic).  Writing the rule twice guarantees they drift -- someone
--    adds an applicability filter in Phase D, updates one, and manual and
--    automatic checklists quietly stop matching.
--
--    An inline table-valued function keeps it in one place and still inlines
--    into the caller's plan, so both paths stay set-based.
-- =====================================================================
CREATE OR ALTER FUNCTION GRAC_New.fn_cm_assurance_specs_for_event(@p_event_type_id BIGINT)
RETURNS TABLE
AS
RETURN
(
    SELECT
        s.assurance_spec_id,
        s.obligation_id,
        s.verification_method,
        s.assurance_party,
        s.scope,
        LEFT(COALESCE(ro.obligation_name, ro.obligation_text,
                      CONCAT(N'Obligation #', ro.obligation_id)), 500) AS obligation_name
    FROM GRAC_New.obligation_assurance_spec s
    JOIN GRAC_New.requirement_obligation ro
      ON ro.obligation_id = s.obligation_id
     AND ro.status = N'Active'
    WHERE s.status        = N'Active'
      AND s.trigger_mode  = N'EventDriven'
      AND s.event_type_id = @p_event_type_id
);
GO

-- =====================================================================
-- 3. Manual raise -- INTENTIONALLY NOT EMITTED HERE.
--
--    This section used to re-emit sp_cm_assurance_occurrence_raise so it
--    would use the shared matching rule from section 2.  It no longer does.
--
--    WHY
--    ---
--    Migration 040 owns this procedure.  The copy that used to live here was
--    behind on TWO counts:
--      * the duplicate-raise guard ROLLBACKs, which is illegal inside
--        INSERT ... EXEC (Msg 3916 -- found by 039 check G1); 040 COMMITs.
--      * it predates 038, so it does not compute due_dt from sla_days.
--
--    Every migration here is documented "safe to re-run".  That was true of
--    each file alone but false in combination: re-running 037 by itself
--    silently reverted both 038's SLA work and 040's fix, with nothing to
--    warn the operator.
--
--    One procedure, one owning migration.  040 is the owner.
--
--    Section 2's fn_cm_assurance_specs_for_event is still established here,
--    and 040's body calls it -- so the intent of this section (one shared
--    matching rule) still holds; it is simply applied by 040.
-- =====================================================================

-- =====================================================================
-- 4. The trigger.
--
--    Set-based throughout: cm_user can be written in bulk (imports, role
--    migrations), and a row-at-a-time trigger would silently handle only
--    the first row.
--
--    Onboarding  = a row appears Active, or an existing row becomes Active.
--    Offboarding = a row that was Active stops being Active.
--
--    Re-saving a user with no status change matches neither, so editing a
--    profile does not raise anything.
-- =====================================================================
CREATE OR ALTER TRIGGER GRAC_New.tr_cm_user_assurance_autoraise
ON GRAC_New.cm_user
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Nothing to do when the write touched no rows.
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    -- Off switch.
    IF NOT EXISTS (
        SELECT 1 FROM GRAC_New.reference_option
        WHERE option_group = N'assurance-settings'
          AND option_value = N'people-autoraise'
          AND status = N'Active')
        RETURN;

    -- ---- what should be raised, and for whom -----------------------
    DECLARE @todo TABLE(
        user_id       BIGINT        NOT NULL,
        event_code    NVARCHAR(60)  NOT NULL,
        subject_label NVARCHAR(300) NOT NULL,
        PRIMARY KEY (user_id, event_code));

    -- Onboarding.  deleted is empty for an INSERT, so the LEFT JOIN covers
    -- both "new row" and "reactivated row" without a separate branch.
    INSERT @todo(user_id, event_code, subject_label)
    SELECT i.user_id, N'PEOPLE_ONBOARDING',
           LEFT(CONCAT(i.user_name, N' (', i.login_id, N')'), 300)
    FROM inserted i
    LEFT JOIN deleted d ON d.user_id = i.user_id
    WHERE i.status = N'Active'
      AND (d.user_id IS NULL OR d.status <> N'Active');

    -- Offboarding.  Only ever an UPDATE, so an inner join to deleted is right.
    INSERT @todo(user_id, event_code, subject_label)
    SELECT i.user_id, N'PEOPLE_OFFBOARDING',
           LEFT(CONCAT(i.user_name, N' (', i.login_id, N')'), 300)
    FROM inserted i
    JOIN deleted d ON d.user_id = i.user_id
    WHERE d.status = N'Active'
      AND i.status <> N'Active';

    IF NOT EXISTS (SELECT 1 FROM @todo) RETURN;

    -- ---- raise the occurrences -------------------------------------
    -- Resolved by JOIN: an event type that is missing, inactive, or sits
    -- under an inactive domain simply produces no row.
    DECLARE @raised TABLE(
        occurrence_id BIGINT NOT NULL,
        event_type_id BIGINT NOT NULL);

    INSERT GRAC_New.assurance_event_occurrence(
        event_type_id, subject_entity, subject_record_id, subject_label,
        occurred_dt, raise_source, remarks, status, entered_by)
    OUTPUT inserted.occurrence_id, inserted.event_type_id INTO @raised
    SELECT e.event_type_id, N'cm_user', t.user_id, t.subject_label,
           SYSUTCDATETIME(), N'System',
           N'Raised automatically from User Management.', N'Open', N'system'
    FROM @todo t
    JOIN GRAC_New.event_type_master e
      ON e.event_code = t.event_code
     AND e.status = N'Active'
    JOIN GRAC_New.event_type_master p
      ON p.event_type_id = e.parent_event_type_id
     AND p.status = N'Active'
    -- Never violate ux_cm_assurance_occurrence_open: skip anything already open.
    WHERE NOT EXISTS (
        SELECT 1 FROM GRAC_New.assurance_event_occurrence o
        WHERE o.event_type_id     = e.event_type_id
          AND o.subject_entity    = N'cm_user'
          AND o.subject_record_id = t.user_id
          AND o.status            = N'Open');

    IF NOT EXISTS (SELECT 1 FROM @raised) RETURN;

    -- ---- generate the checklists -----------------------------------
    -- Uses the same fn_cm_assurance_specs_for_event as the manual path, so
    -- automatic and manual checklists can never diverge.
    INSERT GRAC_New.assurance_checklist_item(
        occurrence_id, obligation_id, assurance_spec_id,
        obligation_name_snapshot, verification_method_snapshot,
        assurance_party_snapshot, scope_snapshot,
        status, entered_by)
    SELECT r.occurrence_id, m.obligation_id, m.assurance_spec_id,
           m.obligation_name, m.verification_method,
           m.assurance_party, m.scope,
           N'Pending', N'system'
    FROM @raised r
    CROSS APPLY GRAC_New.fn_cm_assurance_specs_for_event(r.event_type_id) m;
END
GO

PRINT '037 complete. People assurance auto-raise installed.';
PRINT '  Creating or reactivating a user raises PEOPLE_ONBOARDING;';
PRINT '  deactivating one raises PEOPLE_OFFBOARDING.';
PRINT '  Disable without dropping the trigger:';
PRINT '    UPDATE GRAC_New.reference_option SET status = ''Inactive''';
PRINT '    WHERE option_group = ''assurance-settings'' AND option_value = ''people-autoraise'';';
GO

-- Re-enable execution: harmless when the preflight passed (NOEXEC was
-- never switched on), essential when it did not.
SET NOEXEC OFF;
GO
