-- =====================================================================
-- 031 -- Change Management: atomic approval bundles
--
-- Context
-- -------
-- Phase 3 merges "Obligation Master" and "Manage Obligation Type Details"
-- into a single page.  One Save click will then write several logically
-- distinct sub-entities:
--
--     obligations                 (master row)
--     obligation-type-assignment  (discriminator on the master)
--     obligation-<type>           (typed detail: state / execution / ...)
--     obligation-evidence-links   (0..n M:M attachments)
--
-- Architecture decision (confirmed 2026-07-28):
--   * ONE change_management row PER SUB-ENTITY -- preserves granular audit
--     history ("who approved the retention change specifically").
--   * Those rows are tied together by a BUNDLE and approved / rejected
--     ATOMICALLY -- the checker sees one card, one Approve button, and the
--     database applies all rows or none.  This prevents the half-configured
--     obligation state (master Approved + typed detail Rejected) that the
--     whole merge exists to eliminate.
--   * The bundle inherits the MASTER's approval mode.  If the master entity
--     is configured for auto-approval, the entire bundle auto-approves.
--
-- Why a NEW column and not parent_change_request_id
-- -------------------------------------------------
-- parent_change_request_id already encodes a DIFFERENT concept: the
-- Authority -> Artifact -> Release hierarchical dependency, where a child
-- cannot apply until the parent's applied_record_id exists, and rejecting
-- a parent cascade-rejects its children (see cm_manage_repository around
-- the 'change-management' branch).  A bundle is a PEER grouping, not a
-- hierarchy.  Conflating them would break the existing cascade logic.
-- bundle_id is therefore orthogonal and nullable -- every existing
-- single-row flow keeps working with bundle_id = NULL.
--
-- Adds (all guarded / idempotent):
--   * change_management.bundle_id  UNIQUEIDENTIFIER NULL
--   * ix_cm_change_management_bundle  (filtered)
--   * dbo.sp_cm_change_bundle_apply_row   -- internal: routes one CR to the
--                                            right manage dispatcher
--   * dbo.sp_cm_change_bundle_approve     -- atomic approve of a bundle
--   * dbo.sp_cm_change_bundle_reject      -- atomic reject of a bundle
--   * dbo.sp_cm_change_bundle_send_back   -- atomic send-back of a bundle
--   * dbo.sp_cm_change_bundle_list        -- checker queue, grouped
--
-- Does NOT touch
--   * cm_manage_repository        -- master flow stays single-row
--   * cm_manage_obligation_taxonomy
--   * the 17 typed sub-procs from 028
--   * any existing UI / API code
--   Phase 2 (obligation-composite dispatcher) is what starts EMITTING
--   bundled rows.  This migration only makes bundles possible and
--   approvable.  Applying 031 alone changes no existing behaviour.
--
-- Preflight: 002 (change_management table) and 014 (entity_id column).
--
-- Rollback: database/031_change_management_bundle_rollback.sql
--
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('GRAC_New.change_management','U') IS NULL
BEGIN
    RAISERROR('031 preflight failed: GRAC_New.change_management is missing. Run 002 first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('GRAC_New.change_management','entity_id') IS NULL
BEGIN
    RAISERROR('031 preflight failed: change_management.entity_id is missing. Run 014 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- Soft preflight.  sp_cm_change_bundle_apply_row routes obligation taxonomy
-- entity types to cm_manage_obligation_taxonomy.  SQL Server resolves that
-- name lazily, so 031 installs cleanly without it -- but approving a bundle
-- containing typed-detail rows would fail at runtime.  Warn, do not block:
-- 031 is still useful on its own for non-taxonomy bundles.
IF OBJECT_ID('dbo.cm_manage_obligation_taxonomy','P') IS NULL
BEGIN
    PRINT 'WARNING: dbo.cm_manage_obligation_taxonomy not found (migrations 029/030).';
    PRINT '         031 will install, but approving a bundle that contains typed';
    PRINT '         obligation detail rows will fail until 028-030 are applied.';
END
GO

-- =====================================================================
-- 1. bundle_id column + filtered index.
--    NULL = standalone change request (all pre-031 behaviour).
-- =====================================================================
IF COL_LENGTH('GRAC_New.change_management','bundle_id') IS NULL
BEGIN
    ALTER TABLE GRAC_New.change_management ADD bundle_id UNIQUEIDENTIFIER NULL;
END
GO

-- bundle_seq orders application within a bundle.  Master must apply before
-- typed detail (which carries obligationId), and typed detail before the
-- evidence links that reference it.  Lower number applies first.
IF COL_LENGTH('GRAC_New.change_management','bundle_seq') IS NULL
BEGIN
    ALTER TABLE GRAC_New.change_management ADD bundle_seq INT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_cm_change_management_bundle'
                 AND object_id = OBJECT_ID('GRAC_New.change_management'))
BEGIN
    EXEC(N'CREATE INDEX ix_cm_change_management_bundle
             ON GRAC_New.change_management(bundle_id, bundle_seq)
             INCLUDE (status, entity_type, action_type, record_id)
             WHERE bundle_id IS NOT NULL');
END
GO

-- =====================================================================
-- 2. sp_cm_change_bundle_apply_row
--    Internal helper.  Applies ONE pending change_management row by
--    routing to the correct manage dispatcher, mirroring exactly what the
--    single-row APPROVE path in cm_manage_repository does:
--      * inject __approvalBypass = 1 so the dispatcher writes directly
--        instead of raising another change request
--      * stamp maker / checker provenance into $.remarks
--      * capture the applied record id
--
--    Routing rule: obligation taxonomy entity types go to
--    cm_manage_obligation_taxonomy; everything else to cm_manage_repository.
--    This mirrors the service-layer bifurcation documented in 029.
--
--    NOTE: no transaction here on purpose -- the CALLER owns the TX so the
--    whole bundle commits or rolls back as one unit.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_change_bundle_apply_row
    @p_change_request_id BIGINT,
    @p_checker_user      NVARCHAR(100),
    @p_checker_comments  NVARCHAR(MAX) = NULL,
    @p_applied_record_id BIGINT        = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @entity_type  NVARCHAR(100),
            @action_type  NVARCHAR(30),
            @record_id    BIGINT,
            @payload      NVARCHAR(MAX),
            @maker_user   NVARCHAR(100),
            @status       NVARCHAR(40);

    SELECT @status      = status,
           @entity_type = entity_type,
           @action_type = CASE action_type WHEN N'Inactive' THEN N'RETIRE' ELSE N'SAVE' END,
           @record_id   = COALESCE(record_id, 0),
           @payload     = proposed_data_json,
           @maker_user  = maker_user
    FROM GRAC_New.change_management
    WHERE change_request_id = @p_change_request_id;

    IF @status IS NULL
        THROW 50006, 'A valid change request identifier is required', 1;
    IF @status <> N'Pending Approval'
        THROW 50007, 'Only pending change requests can be actioned', 1;

    -- Same payload decoration as the single-row APPROVE path.
    DECLARE @apply_payload NVARCHAR(MAX) =
        JSON_MODIFY(COALESCE(@payload, N'{}'), '$.__approvalBypass', 1);

    SET @apply_payload = JSON_MODIFY(@apply_payload, '$.remarks',
        CONCAT(N'Maker: ', @maker_user, N'; Checker: ', @p_checker_user,
               CASE WHEN @p_checker_comments IS NULL THEN N''
                    ELSE CONCAT(N'; Comments: ', @p_checker_comments) END));

    DECLARE @apply_result TABLE(Id BIGINT);

    -- Routing has THREE branches, not two, because the taxonomy sub-procs
    -- installed by 028 do not share a single result shape:
    --
    --   sp_cm_obligation_<type>_save        -> SELECT @new_id AS Id      (1 col)
    --   sp_cm_obligation_type_assign        -> ObligationId, ObligationTypeId (2 cols)
    --   sp_cm_obligation_evidence_link_attach -> ObligationId, ObligationEvidenceId,
    --                                            TypeCode                (3 cols)
    --   sp_cm_obligation_evidence_link_detach -> DetachedCount           (1 col, not an id)
    --
    -- INSERT ... EXEC requires the result set to match the target table
    -- exactly, so capturing an id is only valid for the single-column
    -- "Id" shapes.  For the others we EXEC without capture and leave
    -- applied_record_id NULL -- those sub-entities are identified by their
    -- parent obligation, not by a surrogate id the checker needs.
    IF @entity_type IN (N'obligation-state', N'obligation-execution',
                        N'obligation-assurance', N'obligation-event-response',
                        N'obligation-constraint', N'obligation-retention')
    BEGIN
        INSERT @apply_result(Id)
        EXEC dbo.cm_manage_obligation_taxonomy
             @p_entity_type = @entity_type,
             @p_action      = @action_type,
             @p_id          = @record_id,
             @p_search      = N'',
             @p_status      = N'',
             @p_payload     = @apply_payload,
             @p_usr_id      = @p_checker_user;
    END
    ELSE IF @entity_type IN (N'obligation-type-assignment', N'obligation-evidence-links',
                             N'obligation-types')
    BEGIN
        -- Multi-column / non-id result shapes: apply without capturing.
        EXEC dbo.cm_manage_obligation_taxonomy
             @p_entity_type = @entity_type,
             @p_action      = @action_type,
             @p_id          = @record_id,
             @p_search      = N'',
             @p_status      = N'',
             @p_payload     = @apply_payload,
             @p_usr_id      = @p_checker_user;
    END
    ELSE
    BEGIN
        INSERT @apply_result(Id)
        EXEC dbo.cm_manage_repository
             @p_entity_type = @entity_type,
             @p_action      = @action_type,
             @p_id          = @record_id,
             @p_search      = N'',
             @p_status      = N'',
             @p_payload     = @apply_payload,
             @p_usr_id      = @p_checker_user;
    END

    SET @p_applied_record_id = (SELECT TOP 1 Id FROM @apply_result);
END
GO

-- =====================================================================
-- 3. sp_cm_change_bundle_approve
--    Atomic approve.  Applies every Pending row in the bundle in
--    bundle_seq order inside ONE transaction.  Any failure rolls the whole
--    bundle back -- no partial application, ever.
--
--    Self-approval check uses the MASTER row's entity (lowest bundle_seq),
--    consistent with "bundle inherits master's approval mode".
--
--    Late-binding: rows created before the master exists carry
--    obligationId = 0 / NULL.  After the master row applies we back-fill
--    its applied_record_id into each subsequent row's payload so typed
--    detail and evidence links attach to the right parent.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_change_bundle_approve
    @p_bundle_id UNIQUEIDENTIFIER,
    @p_usr_id    NVARCHAR(100),
    @p_comments  NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @p_bundle_id IS NULL
        THROW 50070, 'A valid bundle identifier is required.', 1;

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
        SET status            = N'Approved',
            applied_record_id = COALESCE(@applied_id, applied_record_id),
            checker_user      = @p_usr_id,
            checked_dt        = SYSUTCDATETIME(),
            checker_comments  = @p_comments,
            updated_by        = @p_usr_id,
            updated_dt        = SYSUTCDATETIME()
        WHERE change_request_id = @cr_id;

        INSERT GRAC_New.approval_action(entity_type, entity_id, action_type, comments, entered_by)
        VALUES (N'change-management', @cr_id, N'APPROVE', @p_comments, @p_usr_id);

        -- Capture the master's applied id from the FIRST row in bundle_seq
        -- order.  Keyed off the ordinal rather than "first non-null" so a
        -- master whose dispatcher returns NULL cannot silently promote a
        -- later row into the master slot.
        IF @ordinal = 1 SET @master_applied_id = @applied_id;

        SET @ordinal = @ordinal + 1;
    END

    COMMIT;

    SELECT @p_bundle_id      AS BundleId,
           @pending_count    AS ApprovedCount,
           @master_applied_id AS AppliedRecordId;
END
GO

-- =====================================================================
-- 4. sp_cm_change_bundle_reject
--    Atomic reject.  Nothing is applied; every pending row in the bundle
--    moves to Rejected together.  Checker comments are mandatory, matching
--    the single-row REJECT rule.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_change_bundle_reject
    @p_bundle_id UNIQUEIDENTIFIER,
    @p_usr_id    NVARCHAR(100),
    @p_comments  NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @p_bundle_id IS NULL
        THROW 50070, 'A valid bundle identifier is required.', 1;
    IF NULLIF(LTRIM(RTRIM(@p_comments)), N'') IS NULL
        THROW 50026, 'Checker comments are mandatory.', 1;

    BEGIN TRAN;

    DECLARE @pending_count INT =
        (SELECT COUNT(1) FROM GRAC_New.change_management WITH (UPDLOCK, HOLDLOCK)
         WHERE bundle_id = @p_bundle_id AND status = N'Pending Approval');

    IF @pending_count = 0
    BEGIN
        ROLLBACK;
        THROW 50072, 'This bundle has no pending change requests to reject.', 1;
    END

    INSERT GRAC_New.approval_action(entity_type, entity_id, action_type, comments, entered_by)
    SELECT N'change-management', change_request_id, N'REJECT', @p_comments, @p_usr_id
    FROM GRAC_New.change_management
    WHERE bundle_id = @p_bundle_id AND status = N'Pending Approval';

    UPDATE GRAC_New.change_management
    SET status           = N'Rejected',
        checker_user     = @p_usr_id,
        checked_dt       = SYSUTCDATETIME(),
        checker_comments = @p_comments,
        updated_by       = @p_usr_id,
        updated_dt       = SYSUTCDATETIME()
    WHERE bundle_id = @p_bundle_id AND status = N'Pending Approval';

    COMMIT;

    SELECT @p_bundle_id AS BundleId, @pending_count AS RejectedCount;
END
GO

-- =====================================================================
-- 5. sp_cm_change_bundle_send_back
--    Atomic send-back to the maker.  Same shape as reject but the terminal
--    status is 'Sent Back' so the maker can revise and resubmit.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_change_bundle_send_back
    @p_bundle_id UNIQUEIDENTIFIER,
    @p_usr_id    NVARCHAR(100),
    @p_comments  NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @p_bundle_id IS NULL
        THROW 50070, 'A valid bundle identifier is required.', 1;
    IF NULLIF(LTRIM(RTRIM(@p_comments)), N'') IS NULL
        THROW 50026, 'Checker comments are mandatory.', 1;

    BEGIN TRAN;

    DECLARE @pending_count INT =
        (SELECT COUNT(1) FROM GRAC_New.change_management WITH (UPDLOCK, HOLDLOCK)
         WHERE bundle_id = @p_bundle_id AND status = N'Pending Approval');

    IF @pending_count = 0
    BEGIN
        ROLLBACK;
        THROW 50073, 'This bundle has no pending change requests to send back.', 1;
    END

    INSERT GRAC_New.approval_action(entity_type, entity_id, action_type, comments, entered_by)
    SELECT N'change-management', change_request_id, N'SEND_BACK', @p_comments, @p_usr_id
    FROM GRAC_New.change_management
    WHERE bundle_id = @p_bundle_id AND status = N'Pending Approval';

    UPDATE GRAC_New.change_management
    SET status           = N'Sent Back',
        checker_user     = @p_usr_id,
        checked_dt       = SYSUTCDATETIME(),
        checker_comments = @p_comments,
        updated_by       = @p_usr_id,
        updated_dt       = SYSUTCDATETIME()
    WHERE bundle_id = @p_bundle_id AND status = N'Pending Approval';

    COMMIT;

    SELECT @p_bundle_id AS BundleId, @pending_count AS SentBackCount;
END
GO

-- =====================================================================
-- 6. sp_cm_change_bundle_list
--    Checker-queue projection.  One row per BUNDLE (not per sub-entity) so
--    the approval screen can render a single card.  Sub-entity detail is
--    available by querying change_management on bundle_id, or via the
--    SubEntities JSON column returned here.
--
--    @p_bundle_id NULL  -> list all bundles matching @p_status
--    @p_bundle_id given -> single bundle with full sub-entity detail
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_change_bundle_list
    @p_bundle_id UNIQUEIDENTIFIER = NULL,
    @p_status    NVARCHAR(40)     = N'Pending Approval'
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        b.bundle_id                          AS BundleId,
        MIN(b.change_request_id)             AS FirstChangeRequestId,
        MIN(b.change_request_no)             AS BundleReference,
        MAX(b.module_name)                   AS ModuleName,
        COUNT(1)                             AS SubEntityCount,
        MIN(b.maker_user)                    AS MakerUser,
        MIN(b.submitted_dt)                  AS SubmittedDt,
        MAX(b.checker_user)                  AS CheckerUser,
        MAX(b.checked_dt)                    AS CheckedDt,
        MAX(b.checker_comments)              AS CheckerComments,
        MAX(b.status)                        AS Status,
        -- The master row (lowest bundle_seq) supplies the human-readable
        -- reference the checker sees on the card.
        (SELECT TOP 1 m.record_reference
         FROM GRAC_New.change_management m
         WHERE m.bundle_id = b.bundle_id
         ORDER BY m.bundle_seq, m.change_request_id) AS RecordReference,
        (SELECT TOP 1 m.action_type
         FROM GRAC_New.change_management m
         WHERE m.bundle_id = b.bundle_id
         ORDER BY m.bundle_seq, m.change_request_id) AS ActionType,
        (SELECT s.change_request_id AS ChangeRequestId,
                s.change_request_no AS ChangeRequestNo,
                s.entity_type       AS EntityType,
                s.action_type       AS ActionType,
                s.record_id         AS RecordId,
                s.record_reference  AS RecordReference,
                s.bundle_seq        AS BundleSeq,
                s.status            AS Status
         FROM GRAC_New.change_management s
         WHERE s.bundle_id = b.bundle_id
         ORDER BY s.bundle_seq, s.change_request_id
         FOR JSON PATH)                      AS SubEntitiesJson
    FROM GRAC_New.change_management b
    WHERE b.bundle_id IS NOT NULL
      AND (@p_bundle_id IS NULL OR b.bundle_id = @p_bundle_id)
      AND (@p_status = N'' OR b.status = @p_status)
    GROUP BY b.bundle_id
    ORDER BY MIN(b.submitted_dt) DESC;
END
GO

PRINT '031 complete. change_management.bundle_id + bundle_seq installed;';
PRINT '  bundle approve / reject / send-back / list procedures created.';
PRINT '  No existing behaviour changed -- bundle_id is NULL for every legacy row.';
PRINT '  Phase 2 (obligation-composite dispatcher) starts emitting bundled rows.';
GO

-- Re-enable execution: harmless when the preflight passed (NOEXEC was
-- never switched on), essential when it did not.
SET NOEXEC OFF;
GO
