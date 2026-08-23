-- =====================================================================
-- 039 -- SMOKE TEST for migrations 031-038
--
-- NOT A MIGRATION.  Every block rolls itself back, so this is safe to run
-- on any environment including production.
--
-- WHY EACH CHECK OWNS ITS OWN TRANSACTION
-- ---------------------------------------
-- The first version of this script used one transaction for everything and
-- failed with:
--
--     Msg 3930 -- The current transaction cannot be committed and cannot
--     support operations that write to the log file.
--
-- Several checks deliberately provoke an error (Fail without remarks,
-- duplicate raise).  Those errors are raised inside procedures that
-- SET XACT_ABORT ON, which DOOMS the enclosing transaction -- XACT_STATE
-- becomes -1.  Catching the error does not un-doom it: every later write,
-- including INSERTs into the results table variable, then fails with 3930.
--
-- So each check runs in its own transaction, and every CATCH block rolls
-- back BEFORE recording its result.  @results is a table variable, which
-- survives rollback, so the report is intact at the end.
--
-- Checks:
--   A. Objects exist                     (031-038 installed)
--   B. GOVERNANCE: runtime entities are is_maker_checker = 0
--   C. Event taxonomy seeded as intended (People Active, Asset Inactive)
--   D. CHECK rejects a half-classified assurance spec
--   E. Raise generates a checklist, with snapshots and a computed due date
--   F. SNAPSHOT FREEZE: editing the rule does not rewrite a raised checklist
--   G. Duplicate raise is blocked with a usable message, not a raw 2601
--   H. Fail without remarks is rejected
--   I. Completing the last item closes the occurrence
--   J. GOVERNANCE: completion writes NO change_management row
--   K. Auto-raise fires on user creation
--   L. Auto-raise CANNOT block user creation when the event is misconfigured
--
-- B, F, J and L are load-bearing.  If any reads FAIL, the design intent has
-- been lost somewhere in implementation.
--
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT OFF;
GO

DECLARE @results TABLE(
    seq      INT IDENTITY(1,1),
    check_id NVARCHAR(4),
    name     NVARCHAR(200),
    outcome  NVARCHAR(10),
    detail   NVARCHAR(500));

-- Shared lookups.  Read-only, no transaction needed.
DECLARE @onboarding_id    BIGINT = (SELECT event_type_id FROM GRAC_New.event_type_master WHERE event_code = N'PEOPLE_ONBOARDING');
DECLARE @assurance_type_id BIGINT = (SELECT obligation_type_id FROM GRAC_New.obligation_type_master WHERE type_code = N'Assurance');
DECLARE @active_status_id BIGINT = (SELECT TOP 1 reference_option_id FROM GRAC_New.reference_option
                                    WHERE option_group = 'status-active' AND option_value = 'Active');
DECLARE @subject_user     BIGINT = (SELECT TOP 1 user_id FROM GRAC_New.cm_user ORDER BY user_id);

-- Working variables, declared once (T-SQL hoists DECLARE to batch scope,
-- so re-declaring the same name lower down is a compile error).
DECLARE @ob_id BIGINT, @spec_id BIGINT, @occ_id BIGINT, @item_id BIGINT,
        @ob_b BIGINT, @new_user BIGINT, @guard_user BIGINT,
        @cm_before INT, @errno INT, @errmsg NVARCHAR(400);

DECLARE @raise TABLE(Id BIGINT, OccurrenceId BIGINT, ChecklistItemCount INT,
                     EventName NVARCHAR(120), SubjectLabel NVARCHAR(300));

-- =====================================================================
-- A / B / C -- pure reads.  No transaction.
-- =====================================================================
INSERT @results(check_id, name, outcome, detail)
SELECT 'A1', 'event_type_master exists',
       CASE WHEN OBJECT_ID('GRAC_New.event_type_master','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, 'migration 033';

INSERT @results(check_id, name, outcome, detail)
SELECT 'A2', 'runtime tables exist',
       CASE WHEN OBJECT_ID('GRAC_New.assurance_event_occurrence','U') IS NOT NULL
             AND OBJECT_ID('GRAC_New.assurance_checklist_item','U') IS NOT NULL
             AND OBJECT_ID('GRAC_New.assurance_checklist_evidence','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END, 'migration 035';

INSERT @results(check_id, name, outcome, detail)
SELECT 'A3', 'shared matching function exists',
       CASE WHEN OBJECT_ID('GRAC_New.fn_cm_assurance_specs_for_event','IF') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
       'migration 037 -- one matching rule for manual and auto paths';

INSERT @results(check_id, name, outcome, detail)
SELECT 'A4', 'auto-raise trigger exists',
       CASE WHEN OBJECT_ID('GRAC_New.tr_cm_user_assurance_autoraise','TR') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, 'migration 037';

INSERT @results(check_id, name, outcome, detail)
SELECT 'A5', 'sla_days column exists',
       CASE WHEN COL_LENGTH('GRAC_New.obligation_assurance_spec','sla_days') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, 'migration 038';

INSERT @results(check_id, name, outcome, detail)
SELECT 'A6', 'change_management bundle columns exist',
       CASE WHEN COL_LENGTH('GRAC_New.change_management','bundle_id') IS NOT NULL
             AND COL_LENGTH('GRAC_New.change_management','bundle_seq') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END, 'migration 031';

INSERT @results(check_id, name, outcome, detail)
SELECT 'B1', 'runtime entities are is_maker_checker = 0',
       CASE WHEN EXISTS (SELECT 1 FROM GRAC_New.cm_entity_master WHERE entity_code = N'assurance-occurrences')
             AND NOT EXISTS (SELECT 1 FROM GRAC_New.cm_entity_master
                             WHERE entity_code IN (N'assurance-occurrences', N'assurance-checklist')
                               AND is_maker_checker <> 0)
            THEN 'PASS' ELSE 'FAIL' END, 'LOAD-BEARING: completion must be direct write';

INSERT @results(check_id, name, outcome, detail)
SELECT 'C1', 'People domain active with cm_user register',
       CASE WHEN EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                         WHERE event_code = N'PEOPLE' AND status = N'Active' AND subject_entity = N'cm_user')
            THEN 'PASS' ELSE 'FAIL' END, '';

INSERT @results(check_id, name, outcome, detail)
SELECT 'C2', 'Asset domain seeded INACTIVE (no register exists yet)',
       CASE WHEN EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                         WHERE event_code = N'ASSET' AND status = N'Inactive')
            THEN 'PASS' ELSE 'FAIL' END, 'deliberate -- an asset event could be selected but never raised';

INSERT @results(check_id, name, outcome, detail)
SELECT 'C3', 'People leaves inherit cm_user from their domain',
       CASE WHEN NOT EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                             WHERE event_code IN (N'PEOPLE_ONBOARDING', N'PEOPLE_OFFBOARDING')
                               AND (subject_entity <> N'cm_user' OR subject_entity IS NULL))
            THEN 'PASS' ELSE 'FAIL' END, '';

-- =====================================================================
-- D -- CHECK rejects a half-classified spec.
--
--    Each attempt gets its OWN obligation: obligation_assurance_spec has a
--    unique index on (obligation_id) WHERE status='Active', so reusing one
--    would trip THAT (2601) instead of the CHECK (547) and pass for the
--    wrong reason.  ERROR_NUMBER is asserted for the same reason.
-- =====================================================================
BEGIN TRY
    BEGIN TRAN d1;
    INSERT GRAC_New.requirement_obligation(obligation_name, obligation_text, obligation_type_id, status_id, status, entered_by)
    VALUES(N'SMOKE D1', N'SMOKE D1', @assurance_type_id, @active_status_id, N'Active', N'smoke-039');
    SET @ob_b = SCOPE_IDENTITY();

    INSERT GRAC_New.obligation_assurance_spec(obligation_id, verification_method, trigger_mode, event_type_id, status, entered_by)
    VALUES(@ob_b, N'invalid', N'EventDriven', NULL, N'Active', N'smoke-039');

    IF @@TRANCOUNT > 0 ROLLBACK TRAN d1;
    INSERT @results(check_id, name, outcome, detail)
    VALUES('D1', 'CHECK rejects EventDriven with no event', 'FAIL', 'the insert was allowed');
END TRY
BEGIN CATCH
    SET @errno = ERROR_NUMBER();
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT @results(check_id, name, outcome, detail)
    SELECT 'D1', 'CHECK rejects EventDriven with no event',
           CASE WHEN @errno = 547 THEN 'PASS' ELSE 'FAIL' END,
           CASE WHEN @errno = 547 THEN 'ck_cm_assurance_spec_trigger held'
                ELSE CONCAT(N'wrong constraint fired, error ', @errno) END;
END CATCH

BEGIN TRY
    BEGIN TRAN d2;
    INSERT GRAC_New.requirement_obligation(obligation_name, obligation_text, obligation_type_id, status_id, status, entered_by)
    VALUES(N'SMOKE D2', N'SMOKE D2', @assurance_type_id, @active_status_id, N'Active', N'smoke-039');
    SET @ob_b = SCOPE_IDENTITY();

    INSERT GRAC_New.obligation_assurance_spec(obligation_id, verification_method, trigger_mode, event_type_id, status, entered_by)
    VALUES(@ob_b, N'invalid', N'Scheduled', @onboarding_id, N'Active', N'smoke-039');

    IF @@TRANCOUNT > 0 ROLLBACK TRAN d2;
    INSERT @results(check_id, name, outcome, detail)
    VALUES('D2', 'CHECK rejects Scheduled carrying an event', 'FAIL', 'the insert was allowed');
END TRY
BEGIN CATCH
    SET @errno = ERROR_NUMBER();
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT @results(check_id, name, outcome, detail)
    SELECT 'D2', 'CHECK rejects Scheduled carrying an event',
           CASE WHEN @errno = 547 THEN 'PASS' ELSE 'FAIL' END,
           CASE WHEN @errno = 547 THEN 'ck_cm_assurance_spec_trigger held'
                ELSE CONCAT(N'wrong constraint fired, error ', @errno) END;
END CATCH

-- =====================================================================
-- E / F / I / J -- the happy path.  No expected errors, so one transaction
-- covers them and the state carries between checks.
-- =====================================================================
IF @subject_user IS NULL
    INSERT @results(check_id, name, outcome, detail)
    VALUES('E0', 'a cm_user row exists to use as a subject', 'FAIL', 'cm_user is empty -- E, F, I, J, G, H skipped');
ELSE
BEGIN
    BEGIN TRY
        BEGIN TRAN happy;

        INSERT GRAC_New.requirement_obligation(obligation_name, obligation_text, obligation_type_id, status_id, status, entered_by)
        VALUES(N'SMOKE Onboarding check', N'SMOKE Onboarding check', @assurance_type_id, @active_status_id, N'Active', N'smoke-039');
        SET @ob_id = SCOPE_IDENTITY();

        INSERT GRAC_New.obligation_assurance_spec(
            obligation_id, verification_method, scope, assurance_party, trigger_mode, event_type_id, sla_days, status, entered_by)
        VALUES(@ob_id, N'ORIGINAL wording', N'All new joiners', N'HR', N'EventDriven', @onboarding_id, 7, N'Active', N'smoke-039');
        SET @spec_id = SCOPE_IDENTITY();

        DELETE @raise;
        INSERT @raise
        EXEC dbo.sp_cm_assurance_occurrence_raise
             @p_event_type_id = @onboarding_id, @p_subject_entity = N'cm_user',
             @p_subject_record_id = @subject_user, @p_occurred_dt = '2026-01-10T00:00:00',
             @p_usr_id = N'smoke-039';

        SELECT @occ_id = OccurrenceId FROM @raise;
        SELECT @item_id = checklist_item_id FROM GRAC_New.assurance_checklist_item
        WHERE occurrence_id = @occ_id AND obligation_id = @ob_id;

        INSERT @results(check_id, name, outcome, detail)
        SELECT 'E1', 'raise generated a checklist item',
               CASE WHEN @item_id IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, '';

        INSERT @results(check_id, name, outcome, detail)
        SELECT 'E2', 'wording was snapshotted onto the item',
               CASE WHEN EXISTS (SELECT 1 FROM GRAC_New.assurance_checklist_item
                                 WHERE checklist_item_id = @item_id AND verification_method_snapshot = N'ORIGINAL wording')
                    THEN 'PASS' ELSE 'FAIL' END, '';

        INSERT @results(check_id, name, outcome, detail)
        SELECT 'E3', 'due_dt = occurred_dt + sla_days',
               CASE WHEN EXISTS (SELECT 1 FROM GRAC_New.assurance_checklist_item
                                 WHERE checklist_item_id = @item_id AND CAST(due_dt AS DATE) = '2026-01-17')
                    THEN 'PASS' ELSE 'FAIL' END, 'SLA 7 days from 2026-01-10';

        -- F: editing the rule must not rewrite the raised checklist.
        UPDATE GRAC_New.obligation_assurance_spec
        SET verification_method = N'EDITED wording', sla_days = 99
        WHERE assurance_spec_id = @spec_id;

        INSERT @results(check_id, name, outcome, detail)
        SELECT 'F1', 'editing the rule does NOT change a raised checklist',
               CASE WHEN EXISTS (SELECT 1 FROM GRAC_New.assurance_checklist_item
                                 WHERE checklist_item_id = @item_id
                                   AND verification_method_snapshot = N'ORIGINAL wording'
                                   AND CAST(due_dt AS DATE) = '2026-01-17')
                    THEN 'PASS' ELSE 'FAIL' END, 'LOAD-BEARING: audit history must not be rewritten';

        -- I / J: completion closes the occurrence and raises no change request.
        SET @cm_before = (SELECT COUNT(1) FROM GRAC_New.change_management);

        EXEC dbo.sp_cm_assurance_checklist_complete
             @p_checklist_item_id = @item_id, @p_response_value = N'Pass', @p_usr_id = N'smoke-039';

        INSERT @results(check_id, name, outcome, detail)
        SELECT 'I1', 'completing the last item closes the occurrence',
               CASE WHEN EXISTS (SELECT 1 FROM GRAC_New.assurance_event_occurrence
                                 WHERE occurrence_id = @occ_id AND status = N'Completed')
                    THEN 'PASS' ELSE 'FAIL' END, '';

        INSERT @results(check_id, name, outcome, detail)
        SELECT 'J1', 'completion wrote NO change_management row',
               CASE WHEN (SELECT COUNT(1) FROM GRAC_New.change_management) = @cm_before THEN 'PASS' ELSE 'FAIL' END,
               'LOAD-BEARING: runtime layer must bypass maker-checker';

        IF @@TRANCOUNT > 0 ROLLBACK TRAN happy;
    END TRY
    BEGIN CATCH
        SET @errno = ERROR_NUMBER(); SET @errmsg = LEFT(ERROR_MESSAGE(), 380);
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT @results(check_id, name, outcome, detail)
        VALUES('E/F/I/J', 'happy path completed without error', 'FAIL', CONCAT(N'error ', @errno, N': ', @errmsg));
    END CATCH

    -- =================================================================
    -- H -- Fail without remarks is rejected.
    --      Own transaction: the THROW dooms it (the proc sets XACT_ABORT ON).
    -- =================================================================
    BEGIN TRY
        BEGIN TRAN h1;
        INSERT GRAC_New.requirement_obligation(obligation_name, obligation_text, obligation_type_id, status_id, status, entered_by)
        VALUES(N'SMOKE H1', N'SMOKE H1', @assurance_type_id, @active_status_id, N'Active', N'smoke-039');
        SET @ob_id = SCOPE_IDENTITY();

        INSERT GRAC_New.obligation_assurance_spec(
            obligation_id, verification_method, trigger_mode, event_type_id, status, entered_by)
        VALUES(@ob_id, N'H1 method', N'EventDriven', @onboarding_id, N'Active', N'smoke-039');

        DELETE @raise;
        INSERT @raise
        EXEC dbo.sp_cm_assurance_occurrence_raise
             @p_event_type_id = @onboarding_id, @p_subject_entity = N'cm_user',
             @p_subject_record_id = @subject_user, @p_usr_id = N'smoke-039';
        SELECT @occ_id = OccurrenceId FROM @raise;
        SELECT @item_id = checklist_item_id FROM GRAC_New.assurance_checklist_item
        WHERE occurrence_id = @occ_id AND obligation_id = @ob_id;

        EXEC dbo.sp_cm_assurance_checklist_complete
             @p_checklist_item_id = @item_id, @p_response_value = N'Fail',
             @p_remarks = NULL, @p_usr_id = N'smoke-039';

        IF @@TRANCOUNT > 0 ROLLBACK TRAN h1;
        INSERT @results(check_id, name, outcome, detail)
        VALUES('H1', 'Fail without remarks is rejected', 'FAIL', 'it was accepted');
    END TRY
    BEGIN CATCH
        SET @errno = ERROR_NUMBER(); SET @errmsg = LEFT(ERROR_MESSAGE(), 380);
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT @results(check_id, name, outcome, detail)
        SELECT 'H1', 'Fail without remarks is rejected',
               CASE WHEN @errno = 52914 THEN 'PASS' ELSE 'FAIL' END, @errmsg;
    END CATCH

    -- =================================================================
    -- G -- duplicate raise blocked.  Own transaction for the same reason:
    --      the proc issues an unnamed ROLLBACK and then THROWs.
    -- =================================================================
    BEGIN TRY
        BEGIN TRAN g1;
        INSERT GRAC_New.requirement_obligation(obligation_name, obligation_text, obligation_type_id, status_id, status, entered_by)
        VALUES(N'SMOKE G1', N'SMOKE G1', @assurance_type_id, @active_status_id, N'Active', N'smoke-039');
        SET @ob_id = SCOPE_IDENTITY();

        INSERT GRAC_New.obligation_assurance_spec(
            obligation_id, verification_method, trigger_mode, event_type_id, status, entered_by)
        VALUES(@ob_id, N'G1 method', N'EventDriven', @onboarding_id, N'Active', N'smoke-039');

        DELETE @raise;
        INSERT @raise
        EXEC dbo.sp_cm_assurance_occurrence_raise
             @p_event_type_id = @onboarding_id, @p_subject_entity = N'cm_user',
             @p_subject_record_id = @subject_user, @p_usr_id = N'smoke-039';

        -- second raise for the same event + subject must be refused
        DELETE @raise;
        INSERT @raise
        EXEC dbo.sp_cm_assurance_occurrence_raise
             @p_event_type_id = @onboarding_id, @p_subject_entity = N'cm_user',
             @p_subject_record_id = @subject_user, @p_usr_id = N'smoke-039';

        IF @@TRANCOUNT > 0 ROLLBACK TRAN g1;
        INSERT @results(check_id, name, outcome, detail)
        VALUES('G1', 'duplicate raise is blocked', 'FAIL', 'a second open occurrence was created');
    END TRY
    BEGIN CATCH
        SET @errno = ERROR_NUMBER(); SET @errmsg = LEFT(ERROR_MESSAGE(), 380);
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT @results(check_id, name, outcome, detail)
        SELECT 'G1', 'duplicate raise is blocked',
               CASE WHEN @errno = 52905 THEN 'PASS' ELSE 'FAIL' END, @errmsg;
    END CATCH
END

-- =====================================================================
-- K -- auto-raise fires on user creation.
-- =====================================================================
BEGIN TRY
    BEGIN TRAN k1;
    INSERT GRAC_New.requirement_obligation(obligation_name, obligation_text, obligation_type_id, status_id, status, entered_by)
    VALUES(N'SMOKE K auto', N'SMOKE K auto', @assurance_type_id, @active_status_id, N'Active', N'smoke-039');
    SET @ob_id = SCOPE_IDENTITY();

    INSERT GRAC_New.obligation_assurance_spec(
        obligation_id, verification_method, trigger_mode, event_type_id, status, entered_by)
    VALUES(@ob_id, N'K method', N'EventDriven', @onboarding_id, N'Active', N'smoke-039');

    INSERT GRAC_New.cm_user(user_name, login_id, email, password_hash, status, entered_by)
    VALUES(N'SMOKE Autoraise User', N'smoke.autoraise.039', N'smoke.autoraise.039@example.invalid',
           N'x', N'Active', N'smoke-039');
    SET @new_user = SCOPE_IDENTITY();

    INSERT @results(check_id, name, outcome, detail)
    SELECT 'K1', 'creating a user auto-raised an onboarding checklist',
           CASE WHEN EXISTS (SELECT 1 FROM GRAC_New.assurance_event_occurrence
                             WHERE subject_entity = N'cm_user' AND subject_record_id = @new_user
                               AND event_type_id = @onboarding_id AND raise_source = N'System')
                THEN 'PASS' ELSE 'FAIL' END, 'migration 037 trigger';

    UPDATE GRAC_New.cm_user SET email = N'changed.039@example.invalid' WHERE user_id = @new_user;

    INSERT @results(check_id, name, outcome, detail)
    SELECT 'K2', 'editing that user raised nothing further',
           CASE WHEN (SELECT COUNT(1) FROM GRAC_New.assurance_event_occurrence
                      WHERE subject_record_id = @new_user AND subject_entity = N'cm_user') = 1
                THEN 'PASS' ELSE 'FAIL' END, 'status unchanged, so no new event';

    IF @@TRANCOUNT > 0 ROLLBACK TRAN k1;
END TRY
BEGIN CATCH
    SET @errno = ERROR_NUMBER(); SET @errmsg = LEFT(ERROR_MESSAGE(), 380);
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT @results(check_id, name, outcome, detail)
    VALUES('K1', 'creating a user auto-raised an onboarding checklist', 'FAIL', CONCAT(N'error ', @errno, N': ', @errmsg));
END CATCH

-- =====================================================================
-- L -- THE CRITICAL ONE.
--      With the onboarding event deactivated, creating a user must still
--      succeed.  If this FAILS, the trigger can break User Management.
-- =====================================================================
BEGIN TRY
    BEGIN TRAN l1;
    UPDATE GRAC_New.event_type_master SET status = N'Inactive' WHERE event_type_id = @onboarding_id;

    INSERT GRAC_New.cm_user(user_name, login_id, email, password_hash, status, entered_by)
    VALUES(N'SMOKE Guard User', N'smoke.guard.039', N'smoke.guard.039@example.invalid',
           N'x', N'Active', N'smoke-039');
    SET @guard_user = SCOPE_IDENTITY();

    INSERT @results(check_id, name, outcome, detail)
    SELECT 'L1', 'user creation SUCCEEDS when the event is misconfigured',
           CASE WHEN @guard_user IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
           'LOAD-BEARING: the trigger must never block User Management';

    INSERT @results(check_id, name, outcome, detail)
    SELECT 'L2', 'and nothing was raised for that user',
           CASE WHEN NOT EXISTS (SELECT 1 FROM GRAC_New.assurance_event_occurrence
                                 WHERE subject_record_id = @guard_user AND subject_entity = N'cm_user')
                THEN 'PASS' ELSE 'FAIL' END, '';

    IF @@TRANCOUNT > 0 ROLLBACK TRAN l1;
END TRY
BEGIN CATCH
    SET @errno = ERROR_NUMBER(); SET @errmsg = LEFT(ERROR_MESSAGE(), 380);
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT @results(check_id, name, outcome, detail)
    VALUES('L1', 'user creation SUCCEEDS when the event is misconfigured', 'FAIL',
           CONCAT(N'THE TRIGGER BLOCKED USER CREATION -- error ', @errno, N': ', @errmsg));
END CATCH

-- =====================================================================
-- Report.
-- =====================================================================
IF @@TRANCOUNT > 0 ROLLBACK;

SELECT seq AS [#], check_id AS [Check], outcome AS Result, name AS Assertion, detail AS Detail
FROM @results ORDER BY seq;

SELECT SUM(CASE WHEN outcome = 'PASS' THEN 1 ELSE 0 END) AS Passed,
       SUM(CASE WHEN outcome = 'FAIL' THEN 1 ELSE 0 END) AS Failed,
       CASE WHEN SUM(CASE WHEN outcome = 'FAIL' THEN 1 ELSE 0 END) = 0
            THEN 'ALL CHECKS PASSED'
            ELSE 'FAILURES PRESENT -- read the FAIL rows above' END AS Verdict
FROM @results;
GO

PRINT '';
PRINT '039 smoke test finished. Every block rolled itself back.';
PRINT 'B1, F1, J1 and L1 are load-bearing -- if any read FAIL, do not deploy.';
GO
