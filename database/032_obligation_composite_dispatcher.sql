-- =====================================================================
-- 032 -- Obligation Composite dispatcher (Phase 2)
--
-- Context
-- -------
-- Phase 3 merges "Obligation Master" and "Manage Obligation Type Details"
-- into ONE page with ONE Save button.  That single Save writes several
-- logically distinct sub-entities:
--
--     obligations                 master row (name, frequency, retention,
--                                 keywords, evidence requirements)
--     obligation-type-assignment  the discriminator on the master
--     obligation-<type>           typed detail (state / execution / ...)
--     obligation-evidence-links   0..n M:M evidence attachments
--
-- Architecture decisions (confirmed 2026-07-28):
--   * One change_management row PER SUB-ENTITY  -- granular audit history.
--   * Approved / rejected ATOMICALLY as a bundle -- no partial application.
--   * The bundle inherits the MASTER's approval mode.
--   * The legacy 'obligations' entity type and its payload contract are
--     LEFT COMPLETELY UNTOUCHED.  Any existing caller keeps working.
--     This is a NEW, additive entity type: 'obligation-composite'.
--
-- Why a standalone proc and not a branch in cm_manage_repository
-- --------------------------------------------------------------
-- cm_manage_repository is a 3300+ line dispatcher.  Adding a composite
-- branch there would mean re-emitting the whole procedure on every future
-- change to this feature and would put bundle logic in the middle of the
-- single-row flow.  A standalone proc mirrors the existing bifurcation
-- already established by cm_manage_assurance_repository and
-- cm_manage_obligation_taxonomy.
--
-- Payload contract (@p_payload)
-- -----------------------------
--   {
--     "obligationName":        "...",              -- required
--     "executionFrequencyId":  1,
--     "retentionRequirement":  "...",
--     "remarks":               "...",
--     "keywords":              ["a","b"],          -- array or CSV string
--     "status":                "Active",
--     "evidenceRequirements":  [ { evidenceTypeId, frequencyId,
--                                  retentionRequirement, remarks } ],
--     "obligationTypeCode":    "State",            -- required, 1 of 7
--     "typedDetailId":         0,                  -- 0 = insert
--     "typedDetail":           { ...type-specific fields... },
--     "evidenceLinks":         [ { obligationEvidenceId, remarks } ]
--   }
--
-- @p_id is the obligation_id (0 for a new obligation).
--
-- Actions: SAVE (only).
--
-- Late binding for NEW obligations
-- --------------------------------
-- When @p_id = 0 the obligation_id does not exist at submit time, so the
-- dependent sub-entity rows are emitted with obligationId = 0.  031's
-- sp_cm_change_bundle_approve back-fills the real id into each dependent
-- row's payload after the master applies.  That is what makes
-- "create everything in one Save" work under maker-checker.
--
-- Preflight: 031 (bundle columns + procs), 028-030 (taxonomy procs).
--
-- Rollback: database/032_obligation_composite_dispatcher_rollback.sql
--
-- Safe to re-run (CREATE OR ALTER).  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF COL_LENGTH('GRAC_New.change_management','bundle_id') IS NULL
BEGIN
    RAISERROR('032 preflight failed: change_management.bundle_id is missing. Run 031 first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('dbo.sp_cm_change_bundle_approve','P') IS NULL
BEGIN
    RAISERROR('032 preflight failed: sp_cm_change_bundle_approve is missing. Run 031 first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('dbo.cm_manage_obligation_taxonomy','P') IS NULL
BEGIN
    RAISERROR('032 preflight failed: cm_manage_obligation_taxonomy is missing. Run 028-030 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_cm_obligation_composite_type_entity
--    Maps a taxonomy type code to the entity_type slug that owns its
--    typed detail.  'Evidence' has no typed-detail table -- standalone
--    Evidence obligations express themselves through the master's
--    evidenceRequirements collection -- so it returns NULL.
-- =====================================================================
CREATE OR ALTER FUNCTION dbo.fn_cm_obligation_type_entity(@p_type_code NVARCHAR(40))
RETURNS NVARCHAR(100)
AS
BEGIN
    RETURN CASE @p_type_code
        WHEN N'State'         THEN N'obligation-state'
        WHEN N'Execution'     THEN N'obligation-execution'
        WHEN N'Assurance'     THEN N'obligation-assurance'
        WHEN N'EventResponse' THEN N'obligation-event-response'
        WHEN N'Constraint'    THEN N'obligation-constraint'
        WHEN N'Retention'     THEN N'obligation-retention'
        ELSE NULL   -- 'Evidence' and anything unrecognised
    END;
END
GO

-- =====================================================================
-- 2. cm_manage_obligation_composite
--    Signature mirrors cm_manage_repository / cm_manage_obligation_taxonomy
--    so the service layer routes without knowing the underlying shape.
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

    SELECT COALESCE(NULLIF(@p_id, 0), 0) AS Id,
           @bundle_id                    AS BundleId,
           N'Pending Approval'           AS Status,
           @seq - 1                      AS SubEntityCount;
END
GO

PRINT '032 complete. cm_manage_obligation_composite installed.';
PRINT '  New entity type: obligation-composite (SAVE only).';
PRINT '  Legacy ''obligations'' entity type and payload contract unchanged.';
PRINT '  Service layer must route obligation-composite to this proc';
PRINT '  (RegulatoryRepositoryService.ObligationCompositeEntities).';
GO

-- Re-enable execution: harmless when the preflight passed (NOEXEC was
-- never switched on), essential when it did not.
SET NOEXEC OFF;
GO
