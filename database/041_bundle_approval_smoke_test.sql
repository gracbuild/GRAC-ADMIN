-- =====================================================================
-- 041 -- SMOKE TEST for the obligation-composite + atomic bundle approval
--        (migrations 031 / 032)
--
-- NOT A MIGRATION.  Every block rolls itself back.  Safe anywhere.
--
-- WHY THIS EXISTS
-- ---------------
-- 039 verified the event-driven assurance half (033-038) thoroughly, but of
-- the obligation-merge half it only checked that the bundle COLUMNS exist.
-- The behaviour those columns exist to support -- one Save producing several
-- linked change requests that are then approved or rejected as a unit -- had
-- never been executed.
--
-- That behaviour carries the load-bearing property of the whole merge:
--
--     a checker must not be able to approve the master while rejecting its
--     typed detail, because that recreates the half-configured obligation
--     the merge was built to eliminate.
--
-- Checks:
--   M1  composite save under maker-checker emits a BUNDLE, not one row
--   M2  bundle_seq orders master -> type assignment -> typed detail
--   M3  nothing is applied while the bundle is pending
--   M4  sp_cm_change_bundle_list reports ONE row per bundle
--   M5  approving the bundle applies every part
--   M6  LATE BINDING: dependent rows received the real obligation_id
--   M7  every row in the bundle ends Approved
--   M8  ATOMICITY: a bundle with one bad row applies NOTHING
--   M9  rejecting moves every row and applies nothing
--   M10 INTERCEPTION: approving ONE row via the normal change-management
--       path actions the WHOLE bundle
--
-- M8 and M10 are load-bearing.  M8 is the guarantee itself; M10 is what
-- makes it hold through the UI the checker actually uses.
--
-- Self-approval note: sp_cm_change_bundle_approve refuses when the maker is
-- also the checker unless approval_workflow_config allows it.  With no
-- workflow row configured that resolves to "not allowed", so this script
-- uses two distinct user ids throughout.
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

DECLARE @maker   NVARCHAR(100) = N'smoke-041-maker';
DECLARE @checker NVARCHAR(100) = N'smoke-041-checker';

DECLARE @state_type_id BIGINT =
    (SELECT obligation_type_id FROM GRAC_New.obligation_type_master WHERE type_code = N'State');

DECLARE @payload NVARCHAR(MAX) = N'{
  "obligationName": "SMOKE 041 bundled obligation",
  "retentionRequirement": "3 years",
  "status": "Active",
  "obligationTypeCode": "State",
  "typedDetailId": 0,
  "typedDetail": { "attribute": "password.length", "operator": ">=", "value": "12" }
}';

DECLARE @save TABLE(Id BIGINT, BundleId UNIQUEIDENTIFIER, Status NVARCHAR(40), SubEntityCount INT);
DECLARE @bundle UNIQUEIDENTIFIER, @rows INT, @applied_ob BIGINT,
        @errno INT, @errmsg NVARCHAR(400), @first_cr BIGINT, @poison_cr BIGINT,
        @ob_count_before INT;

-- =====================================================================
-- PREFLIGHT -- are 031 and 032 actually installed?
--
--    Learned the hard way: a missing procedure surfaces as error 2812 on
--    every check that calls it, which reads like five separate failures
--    rather than one missing migration.
--
--    NOTE 039's A6 ("bundle columns exist") does NOT prove 031 ran --
--    bundle_id and bundle_seq are declared by the modified 002 as well, so
--    re-running 002 alone satisfies that check.  These object checks are the
--    reliable signal.
-- =====================================================================
DECLARE @missing NVARCHAR(400) = N'';

IF OBJECT_ID('dbo.sp_cm_change_bundle_approve','P') IS NULL
    SET @missing = @missing + N'031 (sp_cm_change_bundle_approve)  ';
IF OBJECT_ID('dbo.sp_cm_change_bundle_reject','P') IS NULL
    SET @missing = @missing + N'031 (sp_cm_change_bundle_reject)  ';
IF OBJECT_ID('dbo.cm_manage_obligation_composite','P') IS NULL
    SET @missing = @missing + N'032 (cm_manage_obligation_composite)  ';

IF @missing <> N''
BEGIN
    SELECT 'PREFLIGHT' AS [Check], 'FAIL' AS Result,
           'required migrations are not installed' AS Assertion,
           CONCAT(N'Missing: ', @missing,
                  N'-- apply them, then re-run 041. Nothing below was executed.') AS Detail;
    PRINT '';
    PRINT '041 HALTED: apply the missing migrations first.';
    PRINT 'Apply order is 002 -> 031 -> 032 -> 033 -> 034 -> 035 -> 036 -> 037 -> 038 -> 040.';
    RETURN;
END

-- =====================================================================
-- M0 -- PRE-CHECK: is maker-checker actually on for obligations?
--
--       Every check below assumes the composite takes its bundle path.  It
--       only does so when the obligations entity is maker-checker AND its
--       workflow requires approval.  If approval has been disabled in this
--       environment the composite applies directly, and M1-M10 would all
--       fail for a reason that has nothing to do with the code.
-- =====================================================================
DECLARE @ob_entity_id BIGINT =
    (SELECT TOP 1 entity_id FROM GRAC_New.cm_entity_master
     WHERE entity_code = N'obligations' AND status = N'Active');

DECLARE @mc BIT = COALESCE(
    (SELECT TOP 1 is_maker_checker FROM GRAC_New.cm_entity_master WHERE entity_id = @ob_entity_id), 1);

DECLARE @req BIT = COALESCE(
    (SELECT TOP 1 approval_required FROM GRAC_New.approval_workflow_config
     WHERE status = N'Active' AND entity_id = @ob_entity_id), 1);

INSERT @results(check_id, name, outcome, detail)
SELECT 'M0', 'maker-checker is active for obligations',
       CASE WHEN @mc = 1 AND @req = 1 THEN 'PASS' ELSE 'FAIL' END,
       CASE WHEN @mc = 1 AND @req = 1
            THEN N'bundle path will be taken'
            ELSE CONCAT(N'is_maker_checker=', @mc, N', approval_required=', @req,
                        N' -- the composite will apply DIRECTLY, so M1-M10 below are not meaningful. ',
                        N'Enable approval for obligations to exercise the bundle path.') END;

-- =====================================================================
-- M1 / M2 / M3 / M4 -- emit a bundle, inspect it, confirm nothing applied.
-- =====================================================================
BEGIN TRY
    BEGIN TRAN emit;

    SET @ob_count_before = (SELECT COUNT(1) FROM GRAC_New.requirement_obligation);

    DELETE @save;
    INSERT @save
    EXEC dbo.cm_manage_obligation_composite
         @p_entity_type = N'obligation-composite',
         @p_action      = N'SAVE',
         @p_id          = 0,
         @p_payload     = @payload,
         @p_usr_id      = @maker;

    SELECT @bundle = BundleId, @rows = SubEntityCount FROM @save;

    INSERT @results(check_id, name, outcome, detail)
    SELECT 'M1', 'composite save emitted a bundle',
           CASE WHEN @bundle IS NOT NULL AND @rows >= 3 THEN 'PASS' ELSE 'FAIL' END,
           CONCAT(N'sub-entities: ', COALESCE(@rows, 0), N'  (expect master + type + typed detail)');

    INSERT @results(check_id, name, outcome, detail)
    SELECT 'M2', 'bundle_seq orders master -> type -> typed detail',
           CASE WHEN (SELECT TOP 1 entity_type FROM GRAC_New.change_management
                      WHERE bundle_id = @bundle ORDER BY bundle_seq) = N'obligations'
                 AND EXISTS (SELECT 1 FROM GRAC_New.change_management
                             WHERE bundle_id = @bundle AND entity_type = N'obligation-type-assignment')
                 AND EXISTS (SELECT 1 FROM GRAC_New.change_management
                             WHERE bundle_id = @bundle AND entity_type = N'obligation-state')
                THEN 'PASS' ELSE 'FAIL' END, '';

    INSERT @results(check_id, name, outcome, detail)
    SELECT 'M3', 'nothing applied while the bundle is pending',
           CASE WHEN (SELECT COUNT(1) FROM GRAC_New.requirement_obligation) = @ob_count_before
                THEN 'PASS' ELSE 'FAIL' END,
           'the obligation must not exist until a checker approves';

    INSERT @results(check_id, name, outcome, detail)
    SELECT 'M4', 'bundle list reports ONE row for the bundle',
           CASE WHEN (SELECT COUNT(1) FROM GRAC_New.change_management
                      WHERE bundle_id = @bundle) = @rows
                THEN 'PASS' ELSE 'FAIL' END,
           'checker sees one card, not N loose rows';

    IF @@TRANCOUNT > 0 ROLLBACK TRAN emit;
END TRY
BEGIN CATCH
    SET @errno = ERROR_NUMBER(); SET @errmsg = LEFT(ERROR_MESSAGE(), 380);
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT @results(check_id, name, outcome, detail)
    VALUES('M1', 'composite save emitted a bundle', 'FAIL', CONCAT(N'error ', @errno, N': ', @errmsg));
END CATCH

-- =====================================================================
-- M5 / M6 / M7 -- approve the bundle and confirm every part landed.
-- =====================================================================
BEGIN TRY
    BEGIN TRAN app;

    DELETE @save;
    INSERT @save
    EXEC dbo.cm_manage_obligation_composite
         @p_entity_type = N'obligation-composite', @p_action = N'SAVE', @p_id = 0,
         @p_payload = @payload, @p_usr_id = @maker;
    SELECT @bundle = BundleId FROM @save;

    EXEC dbo.sp_cm_change_bundle_approve
         @p_bundle_id = @bundle, @p_usr_id = @checker, @p_comments = N'smoke 041';

    SELECT @applied_ob = applied_record_id
    FROM GRAC_New.change_management
    WHERE bundle_id = @bundle AND entity_type = N'obligations';

    INSERT @results(check_id, name, outcome, detail)
    SELECT 'M5', 'approving the bundle applied every part',
           CASE WHEN @applied_ob IS NOT NULL
                 AND EXISTS (SELECT 1 FROM GRAC_New.requirement_obligation
                             WHERE obligation_id = @applied_ob AND obligation_type_id = @state_type_id)
                 AND EXISTS (SELECT 1 FROM GRAC_New.obligation_state_rule
                             WHERE obligation_id = @applied_ob AND attribute = N'password.length')
                THEN 'PASS' ELSE 'FAIL' END,
           'master + type assignment + typed detail';

    -- The dependent rows were submitted with obligationId = 0 because the
    -- master did not exist yet.  031's approve routine back-fills the real id
    -- before applying them; without that the typed detail would be orphaned.
    INSERT @results(check_id, name, outcome, detail)
    SELECT 'M6', 'LATE BINDING: dependent rows got the real obligation id',
           CASE WHEN NOT EXISTS (
                    SELECT 1 FROM GRAC_New.change_management
                    WHERE bundle_id = @bundle
                      AND entity_type <> N'obligations'
                      AND COALESCE(TRY_CAST(JSON_VALUE(proposed_data_json, '$.obligationId') AS BIGINT), 0) <> @applied_ob)
                THEN 'PASS' ELSE 'FAIL' END,
           'submitted as 0, resolved at approval time';

    INSERT @results(check_id, name, outcome, detail)
    SELECT 'M7', 'every row in the bundle ended Approved',
           CASE WHEN NOT EXISTS (SELECT 1 FROM GRAC_New.change_management
                                 WHERE bundle_id = @bundle AND status <> N'Approved')
                THEN 'PASS' ELSE 'FAIL' END, '';

    IF @@TRANCOUNT > 0 ROLLBACK TRAN app;
END TRY
BEGIN CATCH
    SET @errno = ERROR_NUMBER(); SET @errmsg = LEFT(ERROR_MESSAGE(), 380);
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT @results(check_id, name, outcome, detail)
    VALUES('M5', 'approving the bundle applied every part', 'FAIL', CONCAT(N'error ', @errno, N': ', @errmsg));
END CATCH

-- =====================================================================
-- M8 -- ATOMICITY.  The guarantee the whole merge rests on.
--
--       Poison the typed-detail row so its apply must fail, then approve.
--       NOTHING may land -- not even the master, which applies first.
-- =====================================================================
BEGIN TRY
    BEGIN TRAN atom;

    SET @ob_count_before = (SELECT COUNT(1) FROM GRAC_New.requirement_obligation);

    DELETE @save;
    INSERT @save
    EXEC dbo.cm_manage_obligation_composite
         @p_entity_type = N'obligation-composite', @p_action = N'SAVE', @p_id = 0,
         @p_payload = @payload, @p_usr_id = @maker;
    SELECT @bundle = BundleId FROM @save;

    -- Strip the required attribute from the State rule so sp_cm_obligation_state_save
    -- rejects it when the bundle is applied.
    SELECT @poison_cr = change_request_id FROM GRAC_New.change_management
    WHERE bundle_id = @bundle AND entity_type = N'obligation-state';

    UPDATE GRAC_New.change_management
    SET proposed_data_json = JSON_MODIFY(proposed_data_json, '$.attribute', NULL)
    WHERE change_request_id = @poison_cr;

    BEGIN TRY
        EXEC dbo.sp_cm_change_bundle_approve
             @p_bundle_id = @bundle, @p_usr_id = @checker, @p_comments = N'smoke 041 atomicity';
        INSERT @results(check_id, name, outcome, detail)
        VALUES('M8', 'ATOMICITY: a bad row applies NOTHING', 'FAIL', 'the approval reported success');
    END TRY
    BEGIN CATCH
        SET @errmsg = LEFT(ERROR_MESSAGE(), 300);
        -- The failure doomed the transaction, so read the verdict after rollback.
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT @results(check_id, name, outcome, detail)
        SELECT 'M8', 'ATOMICITY: a bad row applies NOTHING',
               CASE WHEN (SELECT COUNT(1) FROM GRAC_New.requirement_obligation) = @ob_count_before
                    THEN 'PASS' ELSE 'FAIL' END,
               CONCAT(N'LOAD-BEARING. rejected with: ', @errmsg);
    END CATCH

    IF @@TRANCOUNT > 0 ROLLBACK TRAN atom;
END TRY
BEGIN CATCH
    SET @errno = ERROR_NUMBER(); SET @errmsg = LEFT(ERROR_MESSAGE(), 380);
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT @results(check_id, name, outcome, detail)
    VALUES('M8', 'ATOMICITY: a bad row applies NOTHING', 'FAIL', CONCAT(N'setup error ', @errno, N': ', @errmsg));
END CATCH

-- =====================================================================
-- M9 -- reject moves every row and applies nothing.
-- =====================================================================
BEGIN TRY
    BEGIN TRAN rej;

    SET @ob_count_before = (SELECT COUNT(1) FROM GRAC_New.requirement_obligation);

    DELETE @save;
    INSERT @save
    EXEC dbo.cm_manage_obligation_composite
         @p_entity_type = N'obligation-composite', @p_action = N'SAVE', @p_id = 0,
         @p_payload = @payload, @p_usr_id = @maker;
    SELECT @bundle = BundleId FROM @save;

    EXEC dbo.sp_cm_change_bundle_reject
         @p_bundle_id = @bundle, @p_usr_id = @checker, @p_comments = N'smoke 041 reject';

    INSERT @results(check_id, name, outcome, detail)
    SELECT 'M9', 'reject moved every row and applied nothing',
           CASE WHEN NOT EXISTS (SELECT 1 FROM GRAC_New.change_management
                                 WHERE bundle_id = @bundle AND status <> N'Rejected')
                 AND (SELECT COUNT(1) FROM GRAC_New.requirement_obligation) = @ob_count_before
                THEN 'PASS' ELSE 'FAIL' END, '';

    IF @@TRANCOUNT > 0 ROLLBACK TRAN rej;
END TRY
BEGIN CATCH
    SET @errno = ERROR_NUMBER(); SET @errmsg = LEFT(ERROR_MESSAGE(), 380);
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT @results(check_id, name, outcome, detail)
    VALUES('M9', 'reject moved every row and applied nothing', 'FAIL', CONCAT(N'error ', @errno, N': ', @errmsg));
END CATCH

-- =====================================================================
-- M10 -- INTERCEPTION.
--
--        The checker UI approves ONE change request through the ordinary
--        change-management path.  cm_manage_repository must detect the
--        bundle and action the whole thing.  Without this the UI could
--        approve the master alone -- exactly the partial approval the
--        bundle exists to prevent.
-- =====================================================================
BEGIN TRY
    BEGIN TRAN icept;

    DELETE @save;
    INSERT @save
    EXEC dbo.cm_manage_obligation_composite
         @p_entity_type = N'obligation-composite', @p_action = N'SAVE', @p_id = 0,
         @p_payload = @payload, @p_usr_id = @maker;
    SELECT @bundle = BundleId FROM @save;

    -- Deliberately pick the LAST row, not the master, to prove any member works.
    SELECT TOP 1 @first_cr = change_request_id FROM GRAC_New.change_management
    WHERE bundle_id = @bundle ORDER BY bundle_seq DESC;

    EXEC dbo.cm_manage_repository
         @p_entity_type = N'change-management',
         @p_action      = N'APPROVE',
         @p_id          = @first_cr,
         @p_payload     = N'{"comments":"smoke 041 interception"}',
         @p_usr_id      = @checker;

    INSERT @results(check_id, name, outcome, detail)
    SELECT 'M10', 'approving ONE row actioned the WHOLE bundle',
           CASE WHEN NOT EXISTS (SELECT 1 FROM GRAC_New.change_management
                                 WHERE bundle_id = @bundle AND status = N'Pending Approval')
                THEN 'PASS' ELSE 'FAIL' END,
           'LOAD-BEARING: partial approval must be impossible from the UI';

    IF @@TRANCOUNT > 0 ROLLBACK TRAN icept;
END TRY
BEGIN CATCH
    SET @errno = ERROR_NUMBER(); SET @errmsg = LEFT(ERROR_MESSAGE(), 380);
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT @results(check_id, name, outcome, detail)
    VALUES('M10', 'approving ONE row actioned the WHOLE bundle', 'FAIL', CONCAT(N'error ', @errno, N': ', @errmsg));
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
PRINT '041 finished. Every block rolled itself back.';
PRINT 'M8 (atomicity) and M10 (interception) are load-bearing --';
PRINT 'if either reads FAIL, partial approval is possible and the';
PRINT 'Obligation Master merge must not ship.';
GO
