-- =====================================================================
-- 046 -- Obligation Master: auto self-approval for the composite bundle
--
-- Problem
-- -------
-- Obligation Master (the merged Phase 3 page) saves through the
-- 'obligation-composite' entity type, which the service routes to
-- dbo.cm_manage_obligation_composite (032) instead of
-- dbo.cm_manage_repository.
--
-- cm_manage_repository has supported auto self-approval since 017:
-- when the module's approval_workflow_config row has
-- self_approval_allowed = 1 AND the API confirms the maker also holds
-- APPROVE on that area (signalled by injecting __autoApproveAllowed = 1
-- into the payload), the change is applied straight away and the
-- change_management row is stamped 'Auto Approved'.
--
-- The composite dispatcher never implemented that branch.  It reads
-- is_maker_checker / approval_required / __approvalBypass only, ignores
-- both self_approval_allowed and __autoApproveAllowed, and always
-- returns a hardcoded 'Pending Approval'.  Net effect: turning on Self
-- Approval for Obligations had no effect on Obligation Master saves.
--
-- The API tier was already correct -- RepositoryController aliases
-- 'obligation-composite' to the 'obligations' permission area and
-- injects __autoApproveAllowed -- so this is a database-only fix.
--
-- Fix
-- ---
-- 1. sp_cm_change_bundle_approve (031) gains four OPTIONAL parameters so
--    it can be driven as an auto-approval as well as a checker approval:
--        @p_status_override   -- 'Auto Approved' instead of 'Approved'
--        @p_action_label      -- 'AUTO_APPROVE'  instead of 'APPROVE'
--        @p_suppress_result   -- let the caller own the result set
--        @p_applied_record_id -- OUTPUT, the master's applied id
--    Every parameter defaults to the 031 behaviour, so the existing
--    checker-driven callers in 002 are byte-for-byte unchanged.
--
-- 2. cm_manage_obligation_composite (032) gains a PATH B2 branch after
--    the bundle is committed: when self_approval_allowed = 1 AND
--    __autoApproveAllowed = 1 it approves its own bundle through that
--    same procedure and returns Status = 'Auto Approved' with the real
--    applied obligation id.
--
-- Why reuse the bundle approve procedure rather than skip the bundle
-- -----------------------------------------------------------------
-- The change_management rows ARE the audit record -- an auto-approved
-- obligation must still show a full field-level history, exactly like
-- the single-row path in cm_manage_repository does.  Reusing
-- sp_cm_change_bundle_approve also inherits the atomic apply, the
-- late-binding of a brand-new obligation_id into the dependent rows,
-- and the self-approval guard, so there is exactly ONE apply path.
--
-- Behaviour when auto-approval cannot be applied
-- ----------------------------------------------
-- The bundle is committed BEFORE the auto-approve attempt, so a failure
-- inside the apply degrades to the pre-046 outcome: the request stays
-- Pending Approval for a checker to action.  The maker never loses work.
-- The reason is written to approval_action as 'AUTO_APPROVE_FAILED'
-- against the master change request, so it is auditable, not silent.
--
-- Not changed
-- -----------
--   * cm_manage_obligation_composite's parameter list (the C# service
--     binds a fixed set of @p_* parameters).
--   * The 'obligations' entity type and its payload contract.
--   * PATH A (maker-checker off / checker replaying with bypass).
--   * Any web or API code.  obligation-master-form.js already treats any
--     status other than 'Pending Approval' as an applied save.
--
-- Preflight: 017 (Auto Approved status), 031 (bundle procs),
--            032 (composite dispatcher).
--
-- Rollback: database/046_obligation_composite_auto_approve_rollback.sql
--
-- Safe to re-run (CREATE OR ALTER).  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('dbo.sp_cm_change_bundle_approve','P') IS NULL
BEGIN
    RAISERROR('046 preflight failed: sp_cm_change_bundle_approve is missing. Run 031 first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('dbo.cm_manage_obligation_composite','P') IS NULL
BEGIN
    RAISERROR('046 preflight failed: cm_manage_obligation_composite is missing. Run 032 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- 017 widened ck_cm_chg_status to accept 'Auto Approved'.  Without it the
-- UPDATE inside the auto-approve branch would fail on the constraint.
IF NOT EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE name = 'ck_cm_chg_status'
      AND parent_object_id = OBJECT_ID('GRAC_New.change_management')
      AND [definition] LIKE '%Auto Approved%')
BEGIN
    RAISERROR('046 preflight failed: change_management.ck_cm_chg_status does not allow ''Auto Approved''. Run 017 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_cm_change_bundle_approve -- re-emitted from 031 with the four
--    optional parameters described above.  Body is otherwise identical.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_change_bundle_approve
    @p_bundle_id         UNIQUEIDENTIFIER,
    @p_usr_id            NVARCHAR(100),
    @p_comments          NVARCHAR(MAX) = NULL,
    -- 046 additions.  All optional; omitting them reproduces 031 behaviour
    -- byte for byte, so the checker-driven callers in 002 are unaffected.
    @p_status_override   NVARCHAR(40)  = NULL,   -- 'Auto Approved' for the self-approval path
    @p_action_label      NVARCHAR(30)  = NULL,   -- 'AUTO_APPROVE'  for the audit trail
    @p_suppress_result   BIT           = 0,      -- 1 = caller owns the result set
    @p_applied_record_id BIGINT        = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @p_bundle_id IS NULL
        THROW 50070, 'A valid bundle identifier is required.', 1;

    -- Guard the override against ck_cm_chg_status so a bad caller fails here
    -- with a clear message rather than mid-loop on a constraint violation.
    -- 50115 is deliberately OUTSIDE 50008-50110: that band is mapped to
    -- user-facing validation text in RegulatoryRepositoryService, and this is
    -- an internal contract violation, not something a maker can cause or fix.
    IF @p_status_override IS NOT NULL AND @p_status_override NOT IN (N'Approved', N'Auto Approved')
        THROW 50115, 'Unsupported bundle approval status. Use Approved or Auto Approved.', 1;

    DECLARE @final_status NVARCHAR(40) = COALESCE(NULLIF(@p_status_override, N''), N'Approved');
    DECLARE @final_action NVARCHAR(30) = COALESCE(NULLIF(@p_action_label, N''), N'APPROVE');

    BEGIN TRAN;

    -- Lock every row in the bundle for the duration so a concurrent
    -- checker cannot action the same bundle in parallel.
    DECLARE @pending_count INT =
        (SELECT COUNT(1) FROM GRAC_New.change_management WITH (UPDLOCK, HOLDLOCK)
         WHERE bundle_id = @p_bundle_id AND status = N'Pending Approval');

    IF @pending_count = 0
    BEGIN
        ROLLBACK;
        THROW 50071, 'This bundle has no pending change requests to approve.', 1;
    END

    -- Master row = lowest bundle_seq.  Its module drives the self-approval
    -- rule for the whole bundle.
    DECLARE @master_entity_type NVARCHAR(100), @master_maker NVARCHAR(100);
    SELECT TOP 1 @master_entity_type = entity_type, @master_maker = maker_user
    FROM GRAC_New.change_management
    WHERE bundle_id = @p_bundle_id AND status = N'Pending Approval'
    ORDER BY bundle_seq, change_request_id;

    DECLARE @master_entity_id BIGINT =
        (SELECT TOP 1 entity_id FROM GRAC_New.cm_entity_master
         WHERE entity_code = @master_entity_type AND status = N'Active');

    DECLARE @self_approval_allowed BIT = COALESCE((
        SELECT TOP 1 awc.self_approval_allowed
        FROM GRAC_New.approval_workflow_config awc
        WHERE awc.status = N'Active' AND awc.entity_id = @master_entity_id), 0);

    IF @self_approval_allowed = 0 AND @master_maker = @p_usr_id
    BEGIN
        ROLLBACK;
        THROW 50027, 'Self approval is not allowed for this module.', 1;
    END

    -- Materialise the work list BEFORE applying anything.  We mutate
    -- change_management.status inside the loop, and the selection predicate
    -- filters on that same column -- iterating a live cursor over it would
    -- be reading a set that changes underneath us.  A snapshot in a table
    -- variable makes the iteration order and membership deterministic.
    DECLARE @work TABLE(
        ordinal        INT IDENTITY(1,1) PRIMARY KEY,
        change_request_id BIGINT NOT NULL,
        bundle_seq        INT NULL);

    INSERT @work(change_request_id, bundle_seq)
    SELECT change_request_id, bundle_seq
    FROM GRAC_New.change_management
    WHERE bundle_id = @p_bundle_id AND status = N'Pending Approval'
    ORDER BY bundle_seq, change_request_id;

    DECLARE @ordinal INT = 1,
            @work_count INT = (SELECT COUNT(1) FROM @work),
            @cr_id BIGINT,
            @applied_id BIGINT,
            @master_applied_id BIGINT = NULL;

    WHILE @ordinal <= @work_count
    BEGIN
        SELECT @cr_id = change_request_id FROM @work WHERE ordinal = @ordinal;

        -- Bind dependent rows to the master that was just created.  Rows
        -- authored in the same Save as a NEW master carry obligationId <= 0
        -- because the id did not exist yet at submit time.
        IF @master_applied_id IS NOT NULL
        BEGIN
            UPDATE GRAC_New.change_management
            SET proposed_data_json =
                    JSON_MODIFY(proposed_data_json, '$.obligationId', @master_applied_id)
            WHERE change_request_id = @cr_id
              AND COALESCE(TRY_CAST(JSON_VALUE(proposed_data_json, '$.obligationId') AS BIGINT), 0) <= 0;
        END

        SET @applied_id = NULL;
        EXEC dbo.sp_cm_change_bundle_apply_row
             @p_change_request_id = @cr_id,
             @p_checker_user      = @p_usr_id,
             @p_checker_comments  = @p_comments,
             @p_applied_record_id = @applied_id OUTPUT;

        UPDATE GRAC_New.change_management
        SET status            = @final_status,
            applied_record_id = COALESCE(@applied_id, applied_record_id),
            checker_user      = @p_usr_id,
            checked_dt        = SYSUTCDATETIME(),
            checker_comments  = @p_comments,
            updated_by        = @p_usr_id,
            updated_dt        = SYSUTCDATETIME()
        WHERE change_request_id = @cr_id;

        INSERT GRAC_New.approval_action(entity_type, entity_id, action_type, comments, entered_by)
        VALUES (N'change-management', @cr_id, @final_action, @p_comments, @p_usr_id);

        -- Capture the master's applied id from the FIRST row in bundle_seq
        -- order.  Keyed off the ordinal rather than "first non-null" so a
        -- master whose dispatcher returns NULL cannot silently promote a
        -- later row into the master slot.
        IF @ordinal = 1 SET @master_applied_id = @applied_id;

        SET @ordinal = @ordinal + 1;
    END

    COMMIT;

    SET @p_applied_record_id = @master_applied_id;

    -- The composite dispatcher owns its own single-row contract and cannot
    -- afford a second result set ahead of it, so it suppresses this one and
    -- reads the applied id from the OUTPUT parameter instead.
    IF @p_suppress_result = 0
        SELECT @p_bundle_id       AS BundleId,
               @pending_count     AS ApprovedCount,
               @master_applied_id AS AppliedRecordId;
END
GO

-- =====================================================================
-- 2. cm_manage_obligation_composite -- re-emitted from 032 with PATH B2.
--    Everything above the final COMMIT is identical to 032.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.cm_manage_obligation_composite
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

    IF NULLIF(@p_usr_id, N'') IS NULL SET @p_usr_id = N'system';

    -- The browser gateway hardcodes Action='SAVE'; honour a tunnelled
    -- $._action for symmetry with 030, though SAVE is the only action here.
    DECLARE @effective_action NVARCHAR(30) =
        COALESCE(NULLIF(JSON_VALUE(@p_payload, '$._action'), N''), @p_action);

    IF @effective_action NOT IN (N'SAVE', N'')
        THROW 50080, 'obligation-composite supports the SAVE action only.', 1;

    IF ISJSON(@p_payload) <> 1
        THROW 50081, 'A valid JSON payload is required.', 1;

    -- ------------------------------------------------------------------
    -- Validate the pieces that must be right before ANY row is written.
    -- Failing here means the maker sees one clean error instead of a
    -- half-emitted bundle.
    -- ------------------------------------------------------------------
    DECLARE @obligation_name NVARCHAR(500) =
        NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload, '$.obligationName'))), N'');
    IF @obligation_name IS NULL
        THROW 50064, 'Obligation Name is required.', 1;

    DECLARE @type_code NVARCHAR(40) =
        NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload, '$.obligationTypeCode'))), N'');
    IF @type_code IS NULL
        THROW 50082, 'Obligation Type is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM GRAC_New.obligation_type_master
                   WHERE type_code = @type_code AND status = N'Active')
        THROW 50083, 'Invalid Obligation Type selected.', 1;

    DECLARE @typed_entity NVARCHAR(100) = dbo.fn_cm_obligation_type_entity(@type_code);
    DECLARE @typed_detail NVARCHAR(MAX) = JSON_QUERY(@p_payload, '$.typedDetail');
    DECLARE @typed_detail_id BIGINT =
        COALESCE(TRY_CONVERT(BIGINT, JSON_VALUE(@p_payload, '$.typedDetailId')), 0);

    -- A type that owns a typed-detail table must actually carry one.
    IF @typed_entity IS NOT NULL AND @typed_detail IS NULL
        THROW 50084, 'Typed detail is required for the selected Obligation Type.', 1;

    DECLARE @evidence_links NVARCHAR(MAX) = JSON_QUERY(@p_payload, '$.evidenceLinks');

    -- ------------------------------------------------------------------
    -- Build the MASTER sub-payload.  Deliberately reconstructed key by key
    -- rather than passing @p_payload through, so composite-only fields
    -- (obligationTypeCode / typedDetail / evidenceLinks) never leak into
    -- the legacy 'obligations' contract.
    -- ------------------------------------------------------------------
    -- NOTE: FOR JSON is not permitted inside a DECLARE initializer subquery
    -- (Msg 102, "Incorrect syntax near ';'").  Declare first, assign with
    -- SELECT.  The same applies to every FOR JSON assignment below.
    DECLARE @master_payload NVARCHAR(MAX);
    SELECT @master_payload = (
        SELECT
            @obligation_name                                            AS obligationName,
            TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.executionFrequencyId'), N'')) AS executionFrequencyId,
            NULLIF(JSON_VALUE(@p_payload,'$.retentionRequirement'), N'') AS retentionRequirement,
            JSON_VALUE(@p_payload,'$.remarks')                          AS remarks,
            COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.status'), N''), N'Active') AS status
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    -- Re-attach the collection / free-form members that FOR JSON PATH
    -- cannot express inline.
    IF JSON_QUERY(@p_payload, '$.keywords') IS NOT NULL
        SET @master_payload = JSON_MODIFY(@master_payload, '$.keywords',
                                          JSON_QUERY(@p_payload, '$.keywords'));
    ELSE IF NULLIF(JSON_VALUE(@p_payload, '$.keywords'), N'') IS NOT NULL
        SET @master_payload = JSON_MODIFY(@master_payload, '$.keywords',
                                          JSON_VALUE(@p_payload, '$.keywords'));

    IF JSON_QUERY(@p_payload, '$.evidenceRequirements') IS NOT NULL
        SET @master_payload = JSON_MODIFY(@master_payload, '$.evidenceRequirements',
                                          JSON_QUERY(@p_payload, '$.evidenceRequirements'));

    -- ------------------------------------------------------------------
    -- Approval mode.  Decision 3: the bundle inherits the MASTER's mode,
    -- so every lookup below is against entity_code = 'obligations'.
    -- ------------------------------------------------------------------
    DECLARE @approval_bypass BIT =
        CASE WHEN JSON_VALUE(@p_payload,'$.__approvalBypass') IN ('1','true','True') THEN 1 ELSE 0 END;

    DECLARE @master_entity_id BIGINT =
        (SELECT TOP 1 entity_id FROM GRAC_New.cm_entity_master
         WHERE entity_code = N'obligations' AND status = N'Active');

    DECLARE @maker_checker_entity BIT = COALESCE(
        (SELECT TOP 1 is_maker_checker FROM GRAC_New.cm_entity_master
         WHERE entity_id = @master_entity_id), 1);

    DECLARE @approval_required BIT = COALESCE(
        (SELECT TOP 1 approval_required FROM GRAC_New.approval_workflow_config
         WHERE status = N'Active' AND entity_id = @master_entity_id), 1);

    DECLARE @routes_through_bundle BIT =
        CASE WHEN @maker_checker_entity = 1 AND @approval_bypass = 0 AND @approval_required = 1
             THEN 1 ELSE 0 END;

    -- ==================================================================
    -- PATH A -- direct apply (maker-checker off, or checker replaying an
    -- already-approved bundle with __approvalBypass=1).
    -- ==================================================================
    IF @routes_through_bundle = 0
    BEGIN
        BEGIN TRAN;

        DECLARE @apply_master NVARCHAR(MAX) =
            JSON_MODIFY(@master_payload, '$.__approvalBypass', 1);

        DECLARE @master_result TABLE(Id BIGINT);
        INSERT @master_result(Id)
        EXEC dbo.cm_manage_repository
             @p_entity_type = N'obligations',
             @p_action      = N'SAVE',
             @p_id          = @p_id,
             @p_search      = N'',
             @p_status      = N'',
             @p_payload     = @apply_master,
             @p_usr_id      = @p_usr_id;

        DECLARE @obligation_id BIGINT = (SELECT TOP 1 Id FROM @master_result);
        IF @obligation_id IS NULL OR @obligation_id <= 0
        BEGIN
            ROLLBACK;
            THROW 50085, 'The Obligation master could not be saved.', 1;
        END

        -- Type assignment.
        -- Two scalars: built with JSON_MODIFY rather than FOR JSON, which
        -- keeps it unambiguous and avoids the initializer restriction.
        DECLARE @assign_payload NVARCHAR(MAX) =
            JSON_MODIFY(JSON_MODIFY(N'{}', '$.obligationId', @obligation_id),
                        '$.typeCode', @type_code);
        EXEC dbo.cm_manage_obligation_taxonomy
             @p_entity_type = N'obligation-type-assignment',
             @p_action      = N'ASSIGN_TYPE',
             @p_id          = 0,
             @p_search      = N'',
             @p_status      = N'',
             @p_payload     = @assign_payload,
             @p_usr_id      = @p_usr_id;

        -- Typed detail.
        IF @typed_entity IS NOT NULL
        BEGIN
            DECLARE @detail_payload NVARCHAR(MAX) =
                JSON_MODIFY(@typed_detail, '$.obligationId', @obligation_id);
            EXEC dbo.cm_manage_obligation_taxonomy
                 @p_entity_type = @typed_entity,
                 @p_action      = N'SAVE',
                 @p_id          = @typed_detail_id,
                 @p_search      = N'',
                 @p_status      = N'',
                 @p_payload     = @detail_payload,
                 @p_usr_id      = @p_usr_id;
        END

        -- Evidence links.
        IF @evidence_links IS NOT NULL
        BEGIN
            DECLARE @link_payload NVARCHAR(MAX);
            DECLARE link_cur CURSOR LOCAL FAST_FORWARD FOR
                SELECT JSON_MODIFY(j.[value], '$.obligationId', @obligation_id)
                FROM OPENJSON(@evidence_links) j
                WHERE TRY_CONVERT(BIGINT, JSON_VALUE(j.[value],'$.obligationEvidenceId')) IS NOT NULL;
            OPEN link_cur;
            FETCH NEXT FROM link_cur INTO @link_payload;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC dbo.cm_manage_obligation_taxonomy
                     @p_entity_type = N'obligation-evidence-links',
                     @p_action      = N'ATTACH',
                     @p_id          = 0,
                     @p_search      = N'',
                     @p_status      = N'',
                     @p_payload     = @link_payload,
                     @p_usr_id      = @p_usr_id;
                FETCH NEXT FROM link_cur INTO @link_payload;
            END
            CLOSE link_cur;
            DEALLOCATE link_cur;
        END

        COMMIT;

        SELECT @obligation_id AS Id,
               CAST(NULL AS UNIQUEIDENTIFIER) AS BundleId,
               N'Applied' AS Status;
        RETURN;
    END

    -- ==================================================================
    -- PATH B -- emit a bundle of per-sub-entity change requests.
    -- Nothing is applied; the checker's Approve on the bundle applies all
    -- rows atomically via sp_cm_change_bundle_approve.
    -- ==================================================================
    DECLARE @bundle_id UNIQUEIDENTIFIER = NEWID();
    DECLARE @change_action NVARCHAR(30) = CASE WHEN @p_id = 0 THEN N'Add' ELSE N'Edit' END;
    DECLARE @seq INT = 1;
    DECLARE @cr_id BIGINT;

    BEGIN TRAN;

    -- --- seq 1: the MASTER row -------------------------------------
    DECLARE @before_master NVARCHAR(MAX) = NULL;
    DECLARE @record_reference NVARCHAR(300) = @obligation_name;

    IF @p_id > 0
        SELECT @before_master = (
            SELECT obligation_name        AS obligationName,
                   execution_frequency_id AS executionFrequencyId,
                   retention_requirement  AS retentionRequirement,
                   remarks,
                   COALESCE(keywords, N'') AS keywords,
                   status
            FROM GRAC_New.requirement_obligation
            WHERE obligation_id = @p_id
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    INSERT GRAC_New.change_management(
        module_name, entity_type, entity_id, action_type, record_id, record_reference,
        old_data_json, proposed_data_json, maker_user, entered_by, bundle_id, bundle_seq)
    VALUES(
        N'obligations', N'obligations', @master_entity_id, @change_action,
        NULLIF(@p_id, 0), @record_reference,
        @before_master, @master_payload, @p_usr_id, @p_usr_id, @bundle_id, @seq);

    SET @cr_id = SCOPE_IDENTITY();

    -- Field-level diff for the master, so the checker screen can show
    -- "what changed" the same way it does for single-row requests.
    -- Both branches are wrapped in BEGIN / END.  The ELSE branch opens with a
    -- CTE, and `ELSE ;WITH ...` is a syntax error: ELSE must be followed by a
    -- statement, and a bare `;` is not one (Msg 102, "Incorrect syntax near
    -- ';'").  BEGIN / END gives the CTE a block to live in, so no leading
    -- statement terminator is needed.
    IF @change_action = N'Add'
    BEGIN
        INSERT GRAC_New.change_management_field(change_request_id, field_name, old_value, new_value)
        SELECT @cr_id,
               CASE [key]
                   WHEN N'obligationName'       THEN N'Obligation Name'
                   WHEN N'executionFrequencyId' THEN N'Execution Frequency'
                   WHEN N'retentionRequirement' THEN N'Retention Period'
                   WHEN N'status'               THEN N'Status'
                   ELSE UPPER(LEFT([key],1)) + SUBSTRING([key], 2, 200)
               END,
               NULL, CONVERT(NVARCHAR(MAX), [value])
        FROM OPENJSON(@master_payload)
        WHERE LEFT([key], 2) <> N'__';
    END
    ELSE
    BEGIN
        WITH before_values AS (
            SELECT [key], CONVERT(NVARCHAR(MAX), [value]) old_value
            FROM OPENJSON(COALESCE(@before_master, N'{}')) WHERE LEFT([key],2) <> N'__'
        ),
        after_values AS (
            SELECT [key], CONVERT(NVARCHAR(MAX), [value]) new_value
            FROM OPENJSON(@master_payload) WHERE LEFT([key],2) <> N'__'
        )
        INSERT GRAC_New.change_management_field(change_request_id, field_name, old_value, new_value)
        SELECT @cr_id,
               CASE COALESCE(a.[key], b.[key])
                   WHEN N'obligationName'       THEN N'Obligation Name'
                   WHEN N'executionFrequencyId' THEN N'Execution Frequency'
                   WHEN N'retentionRequirement' THEN N'Retention Period'
                   WHEN N'status'               THEN N'Status'
                   ELSE UPPER(LEFT(COALESCE(a.[key], b.[key]),1))
                        + SUBSTRING(COALESCE(a.[key], b.[key]), 2, 200)
               END,
               b.old_value, a.new_value
        FROM after_values a
        FULL OUTER JOIN before_values b ON b.[key] = a.[key]
        WHERE ISNULL(b.old_value, N'') <> ISNULL(a.new_value, N'');
    END

    SET @seq = @seq + 1;

    -- --- seq 2: TYPE ASSIGNMENT ------------------------------------
    -- obligationId is 0 for a new master; 031's approve routine
    -- back-fills the real id before this row is applied.
    DECLARE @assign_cr_payload NVARCHAR(MAX) =
        JSON_MODIFY(JSON_MODIFY(N'{}', '$.obligationId', @p_id),
                    '$.typeCode', @type_code);

    DECLARE @before_type NVARCHAR(MAX) = NULL;
    IF @p_id > 0
        SELECT @before_type = (
            SELECT COALESCE(t.type_code, N'') AS typeCode
            FROM GRAC_New.requirement_obligation o
            LEFT JOIN GRAC_New.obligation_type_master t
                   ON t.obligation_type_id = o.obligation_type_id
            WHERE o.obligation_id = @p_id
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    INSERT GRAC_New.change_management(
        module_name, entity_type, entity_id, action_type, record_id, record_reference,
        old_data_json, proposed_data_json, maker_user, entered_by, bundle_id, bundle_seq)
    VALUES(
        N'obligations', N'obligation-type-assignment', @master_entity_id, @change_action,
        NULLIF(@p_id, 0), CONCAT(@record_reference, N' / Type'),
        @before_type, @assign_cr_payload, @p_usr_id, @p_usr_id, @bundle_id, @seq);

    SET @cr_id = SCOPE_IDENTITY();
    INSERT GRAC_New.change_management_field(change_request_id, field_name, old_value, new_value)
    VALUES(@cr_id, N'Obligation Type', JSON_VALUE(@before_type, '$.typeCode'), @type_code);

    SET @seq = @seq + 1;

    -- --- seq 3: TYPED DETAIL ---------------------------------------
    IF @typed_entity IS NOT NULL
    BEGIN
        DECLARE @detail_cr_payload NVARCHAR(MAX) =
            JSON_MODIFY(@typed_detail, '$.obligationId', @p_id);

        INSERT GRAC_New.change_management(
            module_name, entity_type, entity_id, action_type, record_id, record_reference,
            old_data_json, proposed_data_json, maker_user, entered_by, bundle_id, bundle_seq)
        VALUES(
            N'obligations', @typed_entity, @master_entity_id,
            CASE WHEN @typed_detail_id = 0 THEN N'Add' ELSE N'Edit' END,
            NULLIF(@typed_detail_id, 0),
            CONCAT(@record_reference, N' / ', @type_code),
            NULL, @detail_cr_payload, @p_usr_id, @p_usr_id, @bundle_id, @seq);

        SET @cr_id = SCOPE_IDENTITY();
        INSERT GRAC_New.change_management_field(change_request_id, field_name, old_value, new_value)
        SELECT @cr_id,
               UPPER(LEFT([key],1)) + SUBSTRING([key], 2, 200),
               NULL, CONVERT(NVARCHAR(MAX), [value])
        FROM OPENJSON(@detail_cr_payload)
        WHERE LEFT([key], 2) <> N'__' AND [key] <> N'obligationId';

        SET @seq = @seq + 1;
    END

    -- --- seq 4..n: EVIDENCE LINKS ----------------------------------
    IF @evidence_links IS NOT NULL
    BEGIN
        DECLARE @links TABLE(
            ordinal INT IDENTITY(1,1) PRIMARY KEY,
            link_payload NVARCHAR(MAX) NOT NULL,
            evidence_id  BIGINT NOT NULL);

        INSERT @links(link_payload, evidence_id)
        SELECT JSON_MODIFY(j.[value], '$.obligationId', @p_id),
               TRY_CONVERT(BIGINT, JSON_VALUE(j.[value], '$.obligationEvidenceId'))
        FROM OPENJSON(@evidence_links) j
        WHERE TRY_CONVERT(BIGINT, JSON_VALUE(j.[value], '$.obligationEvidenceId')) IS NOT NULL;

        DECLARE @li INT = 1,
                @li_count INT = (SELECT COUNT(1) FROM @links),
                @li_payload NVARCHAR(MAX),
                @li_evidence BIGINT;

        WHILE @li <= @li_count
        BEGIN
            SELECT @li_payload = link_payload, @li_evidence = evidence_id
            FROM @links WHERE ordinal = @li;

            INSERT GRAC_New.change_management(
                module_name, entity_type, entity_id, action_type, record_id, record_reference,
                old_data_json, proposed_data_json, maker_user, entered_by, bundle_id, bundle_seq)
            VALUES(
                N'obligations', N'obligation-evidence-links', @master_entity_id, N'Add',
                NULL, CONCAT(@record_reference, N' / Evidence #', @li_evidence),
                NULL, @li_payload, @p_usr_id, @p_usr_id, @bundle_id, @seq);

            SET @cr_id = SCOPE_IDENTITY();
            INSERT GRAC_New.change_management_field(change_request_id, field_name, old_value, new_value)
            VALUES(@cr_id, N'Evidence Spec', NULL, CONVERT(NVARCHAR(MAX), @li_evidence));

            SET @seq = @seq + 1;
            SET @li  = @li + 1;
        END
    END

    COMMIT;

    -- ==================================================================
    -- PATH B2 -- auto self-approval (046).
    --
    -- cm_manage_repository has had this shortcut since 017: when the
    -- module's workflow row has self_approval_allowed = 1 AND the API has
    -- confirmed the maker also holds APPROVE on the area (signalled via
    -- __autoApproveAllowed), the change is applied immediately instead of
    -- parking as 'Pending Approval'.  The composite dispatcher never
    -- implemented it, so Obligation Master ignored Self Approval entirely.
    --
    -- We deliberately auto-approve AFTER the bundle is committed rather
    -- than skipping the bundle: the change_management rows are the audit
    -- record, and sp_cm_change_bundle_approve already owns the atomic
    -- apply, the late-binding of obligationId into dependent rows, and the
    -- self-approval guard.  Reusing it keeps exactly one apply path.
    -- ==================================================================
    DECLARE @workflow_self_approval BIT = COALESCE(
        (SELECT TOP 1 self_approval_allowed FROM GRAC_New.approval_workflow_config
         WHERE status = N'Active' AND entity_id = @master_entity_id), 0);

    DECLARE @auto_approve_allowed BIT =
        CASE WHEN JSON_VALUE(@p_payload, '$.__autoApproveAllowed') IN ('1','true','True')
             THEN 1 ELSE 0 END;

    DECLARE @auto_applied_id BIGINT = NULL;

    IF @workflow_self_approval = 1 AND @auto_approve_allowed = 1
    BEGIN
        BEGIN TRY
            EXEC dbo.sp_cm_change_bundle_approve
                 @p_bundle_id         = @bundle_id,
                 @p_usr_id            = @p_usr_id,
                 @p_comments          = N'Auto-approved: Self Approval is enabled and the maker holds APPROVE permission for this module.',
                 @p_status_override   = N'Auto Approved',
                 @p_action_label      = N'AUTO_APPROVE',
                 @p_suppress_result   = 1,
                 @p_applied_record_id = @auto_applied_id OUTPUT;

            SELECT COALESCE(NULLIF(@auto_applied_id, 0), NULLIF(@p_id, 0), 0) AS Id,
                   @bundle_id            AS BundleId,
                   N'Auto Approved'      AS Status,
                   @seq - 1              AS SubEntityCount;
            RETURN;
        END TRY
        BEGIN CATCH
            -- Graceful degradation.  The bundle is already committed, so a
            -- failure here costs the maker nothing: the request simply stays
            -- Pending Approval and a checker can action it the normal way --
            -- which is precisely the pre-046 behaviour.  Throwing instead
            -- would surface an error for work that WAS saved.  The reason is
            -- recorded against the master row so the failure is auditable
            -- rather than silent.
            IF @@TRANCOUNT > 0 ROLLBACK;

            INSERT GRAC_New.approval_action(entity_type, entity_id, action_type, comments, entered_by)
            SELECT TOP 1 N'change-management', change_request_id, N'AUTO_APPROVE_FAILED',
                   LEFT(CONCAT(N'Auto self-approval could not be applied; the bundle remains Pending Approval. ',
                               ERROR_MESSAGE()), 1000),
                   @p_usr_id
            FROM GRAC_New.change_management
            WHERE bundle_id = @bundle_id
            ORDER BY bundle_seq, change_request_id;
        END CATCH
    END

    SELECT COALESCE(NULLIF(@p_id, 0), 0) AS Id,
           @bundle_id                    AS BundleId,
           N'Pending Approval'           AS Status,
           @seq - 1                      AS SubEntityCount;
END
GO

PRINT '046 complete.';
PRINT '  sp_cm_change_bundle_approve now accepts an optional status override,';
PRINT '  action label, result suppression flag and applied-id OUTPUT.';
PRINT '  cm_manage_obligation_composite now honours Self Approval:';
PRINT '  self_approval_allowed = 1 + __autoApproveAllowed = 1 applies the';
PRINT '  bundle immediately and returns Status = Auto Approved.';
GO

-- Re-enable execution: harmless when the preflight passed (NOEXEC was
-- never switched on), essential when it did not.
SET NOEXEC OFF;
GO
