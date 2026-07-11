/*
  GRAC Part 1 - Safe working-data cleanup

  Purpose:
    Clear Part 1 repository working/configuration/transactional data while preserving
    authority and master/lookup/classification data.

  Preserved by this script:
    - GRAC_New.authority
    - GRAC_New.reference_option
    - GRAC_New.control_domain
    - GRAC_New.control_sub_domain
    - GRAC_New.security_* tables
    - GRAC_New.audit_trace (immutable trigger blocks delete by design)
    - GRAC_New.transaction_audit (append-only trigger blocks delete)

  Cleared by this script:
    - Regulatory artifacts and child data
    - Releases
    - Source structure
    - Controls and keywords
    - Requirements
    - Obligations
    - Source/control and control/requirement mappings
    - Applicability rules
    - Change events
    - Impact analysis
    - Notifications
    - Approval actions
    - Audit trace is preserved by default because it has an immutable trigger.
    - Artifact industry/jurisdiction maps

  IMPORTANT:
    This script intentionally ends with ROLLBACK by default.
    Review the count result sets first. To actually commit cleanup, change:
      SET @commit_cleanup = 0
    to:
      SET @commit_cleanup = 1
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @schema SYSNAME = N'GRAC_New';
DECLARE @commit_cleanup BIT = 0; -- REQUIRED: keep 0 for dry-run rollback, set 1 to commit cleanup.

IF SCHEMA_ID(@schema) IS NULL
    THROW 51000, 'Schema GRAC_New does not exist. Check the Part 1 schema name before running cleanup.', 1;

PRINT 'GRAC Part 1 cleanup pre-check. Review counts before enabling commit.';
IF @commit_cleanup = 0
    PRINT 'DRY RUN MODE: @commit_cleanup is 0. The script will ROLLBACK and data will remain.';
ELSE
    PRINT 'COMMIT MODE: @commit_cleanup is 1. The script will permanently delete the listed working data.';

SELECT N'PRESERVED' CleanupAction, N'GRAC_New.authority' TableName, COUNT_BIG(1) [RecordCount] FROM GRAC_New.authority
UNION ALL SELECT N'PRESERVED', N'GRAC_New.reference_option', COUNT_BIG(1) FROM GRAC_New.reference_option
UNION ALL SELECT N'PRESERVED', N'GRAC_New.control_domain', COUNT_BIG(1) FROM GRAC_New.control_domain
UNION ALL SELECT N'PRESERVED', N'GRAC_New.control_sub_domain', COUNT_BIG(1) FROM GRAC_New.control_sub_domain
UNION ALL SELECT N'PRESERVED', N'GRAC_New.security_role', COUNT_BIG(1) FROM GRAC_New.security_role
UNION ALL SELECT N'PRESERVED', N'GRAC_New.security_permission', COUNT_BIG(1) FROM GRAC_New.security_permission
UNION ALL SELECT N'PRESERVED', N'GRAC_New.security_role_permission', COUNT_BIG(1) FROM GRAC_New.security_role_permission
UNION ALL SELECT N'PRESERVED', N'GRAC_New.security_user_role', COUNT_BIG(1) FROM GRAC_New.security_user_role
UNION ALL SELECT N'PRESERVED', N'GRAC_New.audit_trace', COUNT_BIG(1) FROM GRAC_New.audit_trace
UNION ALL SELECT N'PRESERVED', N'GRAC_New.transaction_audit', COUNT_BIG(1) FROM GRAC_New.transaction_audit;

SELECT N'CLEARED' CleanupAction, N'GRAC_New.notification' TableName, COUNT_BIG(1) [RecordCount] FROM GRAC_New.notification
UNION ALL SELECT N'CLEARED', N'GRAC_New.impact_analysis', COUNT_BIG(1) FROM GRAC_New.impact_analysis
UNION ALL SELECT N'CLEARED', N'GRAC_New.change_event', COUNT_BIG(1) FROM GRAC_New.change_event
UNION ALL SELECT N'CLEARED', N'GRAC_New.approval_action', COUNT_BIG(1) FROM GRAC_New.approval_action
UNION ALL SELECT N'CLEARED', N'GRAC_New.obligation', COUNT_BIG(1) FROM GRAC_New.obligation
UNION ALL SELECT N'CLEARED', N'GRAC_New.control_requirement_map', COUNT_BIG(1) FROM GRAC_New.control_requirement_map
UNION ALL SELECT N'CLEARED', N'GRAC_New.source_control_map', COUNT_BIG(1) FROM GRAC_New.source_control_map
UNION ALL SELECT N'CLEARED', N'GRAC_New.applicability_rule', COUNT_BIG(1) FROM GRAC_New.applicability_rule
UNION ALL SELECT N'CLEARED', N'GRAC_New.artifact_industry_map', COUNT_BIG(1) FROM GRAC_New.artifact_industry_map
UNION ALL SELECT N'CLEARED', N'GRAC_New.artifact_jurisdiction_map', COUNT_BIG(1) FROM GRAC_New.artifact_jurisdiction_map
UNION ALL SELECT N'CLEARED', N'GRAC_New.source_structure_node', COUNT_BIG(1) FROM GRAC_New.source_structure_node
UNION ALL SELECT N'CLEARED', N'GRAC_New.release', COUNT_BIG(1) FROM GRAC_New.release
UNION ALL SELECT N'CLEARED', N'GRAC_New.artifact', COUNT_BIG(1) FROM GRAC_New.artifact
UNION ALL SELECT N'CLEARED', N'GRAC_New.control_keyword', COUNT_BIG(1) FROM GRAC_New.control_keyword
UNION ALL SELECT N'CLEARED', N'GRAC_New.control', COUNT_BIG(1) FROM GRAC_New.control
UNION ALL SELECT N'CLEARED', N'GRAC_New.requirement', COUNT_BIG(1) FROM GRAC_New.requirement
UNION ALL SELECT N'CLEARED_OPTIONAL_REVIEW_ONLY', N'GRAC_New.organization', COUNT_BIG(1) FROM GRAC_New.organization;

BEGIN TRANSACTION;

    /*
      Child-to-parent delete order.
      Do not delete master/reference/security/authority/classification tables.
    */

    DELETE FROM GRAC_New.notification;
    DELETE FROM GRAC_New.impact_analysis;
    DELETE FROM GRAC_New.change_event;

    DELETE FROM GRAC_New.approval_action;

    /*
      GRAC_New.audit_trace has an immutable trigger and is preserved by default.
      If this is a disposable development database and you explicitly need to
      clear audit history, run the optional block at the end of this file after
      reviewing the implications.
    */

    DELETE FROM GRAC_New.obligation;
    DELETE FROM GRAC_New.control_requirement_map;
    DELETE FROM GRAC_New.source_control_map;
    DELETE FROM GRAC_New.applicability_rule;

    DELETE FROM GRAC_New.artifact_industry_map;
    DELETE FROM GRAC_New.artifact_jurisdiction_map;

    /*
      Source structure is self-referencing. Delete leaf nodes repeatedly so
      parent-child FK constraints remain satisfied on all SQL Server versions.
    */
    WHILE EXISTS (SELECT 1 FROM GRAC_New.source_structure_node)
    BEGIN
        DELETE n
        FROM GRAC_New.source_structure_node n
        WHERE NOT EXISTS (
            SELECT 1
            FROM GRAC_New.source_structure_node child
            WHERE child.parent_node_id = n.structure_node_id
        );

        IF @@ROWCOUNT = 0
            THROW 51001, 'Unable to delete source structure nodes because a hierarchy cycle or unexpected FK dependency exists.', 1;
    END;

    DELETE FROM GRAC_New.release;
    DELETE FROM GRAC_New.artifact;

    DELETE FROM GRAC_New.control_keyword;
    DELETE FROM GRAC_New.control;

    DELETE FROM GRAC_New.requirement;

    /*
      Optional:
      GRAC_New.organization is not deleted by default because it can be treated
      as a demo/reference organization by some environments. Uncomment only if
      you are certain Part 1 organization rows are disposable in your DB.

      DELETE FROM GRAC_New.organization;
    */

    /*
      Identity reseed only for cleared tables.
      DBCC CHECKIDENT is guarded by OBJECT_ID checks so the script remains safe
      if some optional tables are not present in older databases.
    */
    IF OBJECT_ID(N'GRAC_New.notification', N'U') IS NOT NULL DBCC CHECKIDENT (N'GRAC_New.notification', RESEED, 0) WITH NO_INFOMSGS;
    IF OBJECT_ID(N'GRAC_New.impact_analysis', N'U') IS NOT NULL DBCC CHECKIDENT (N'GRAC_New.impact_analysis', RESEED, 0) WITH NO_INFOMSGS;
    IF OBJECT_ID(N'GRAC_New.change_event', N'U') IS NOT NULL DBCC CHECKIDENT (N'GRAC_New.change_event', RESEED, 0) WITH NO_INFOMSGS;
    IF OBJECT_ID(N'GRAC_New.approval_action', N'U') IS NOT NULL DBCC CHECKIDENT (N'GRAC_New.approval_action', RESEED, 0) WITH NO_INFOMSGS;
    IF OBJECT_ID(N'GRAC_New.obligation', N'U') IS NOT NULL DBCC CHECKIDENT (N'GRAC_New.obligation', RESEED, 0) WITH NO_INFOMSGS;
    IF OBJECT_ID(N'GRAC_New.control_requirement_map', N'U') IS NOT NULL DBCC CHECKIDENT (N'GRAC_New.control_requirement_map', RESEED, 0) WITH NO_INFOMSGS;
    IF OBJECT_ID(N'GRAC_New.source_control_map', N'U') IS NOT NULL DBCC CHECKIDENT (N'GRAC_New.source_control_map', RESEED, 0) WITH NO_INFOMSGS;
    IF OBJECT_ID(N'GRAC_New.applicability_rule', N'U') IS NOT NULL DBCC CHECKIDENT (N'GRAC_New.applicability_rule', RESEED, 0) WITH NO_INFOMSGS;
    IF OBJECT_ID(N'GRAC_New.artifact_industry_map', N'U') IS NOT NULL DBCC CHECKIDENT (N'GRAC_New.artifact_industry_map', RESEED, 0) WITH NO_INFOMSGS;
    IF OBJECT_ID(N'GRAC_New.artifact_jurisdiction_map', N'U') IS NOT NULL DBCC CHECKIDENT (N'GRAC_New.artifact_jurisdiction_map', RESEED, 0) WITH NO_INFOMSGS;
    IF OBJECT_ID(N'GRAC_New.source_structure_node', N'U') IS NOT NULL DBCC CHECKIDENT (N'GRAC_New.source_structure_node', RESEED, 0) WITH NO_INFOMSGS;
    IF OBJECT_ID(N'GRAC_New.release', N'U') IS NOT NULL DBCC CHECKIDENT (N'GRAC_New.release', RESEED, 0) WITH NO_INFOMSGS;
    IF OBJECT_ID(N'GRAC_New.artifact', N'U') IS NOT NULL DBCC CHECKIDENT (N'GRAC_New.artifact', RESEED, 0) WITH NO_INFOMSGS;
    IF OBJECT_ID(N'GRAC_New.control_keyword', N'U') IS NOT NULL DBCC CHECKIDENT (N'GRAC_New.control_keyword', RESEED, 0) WITH NO_INFOMSGS;
    IF OBJECT_ID(N'GRAC_New.control', N'U') IS NOT NULL DBCC CHECKIDENT (N'GRAC_New.control', RESEED, 0) WITH NO_INFOMSGS;
    IF OBJECT_ID(N'GRAC_New.requirement', N'U') IS NOT NULL DBCC CHECKIDENT (N'GRAC_New.requirement', RESEED, 0) WITH NO_INFOMSGS;

    SELECT N'AFTER_DELETE_INSIDE_TRANSACTION' CleanupAction, N'GRAC_New.notification' TableName, COUNT_BIG(1) [RecordCount] FROM GRAC_New.notification
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.impact_analysis', COUNT_BIG(1) FROM GRAC_New.impact_analysis
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.change_event', COUNT_BIG(1) FROM GRAC_New.change_event
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.approval_action', COUNT_BIG(1) FROM GRAC_New.approval_action
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.obligation', COUNT_BIG(1) FROM GRAC_New.obligation
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.control_requirement_map', COUNT_BIG(1) FROM GRAC_New.control_requirement_map
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.source_control_map', COUNT_BIG(1) FROM GRAC_New.source_control_map
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.applicability_rule', COUNT_BIG(1) FROM GRAC_New.applicability_rule
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.artifact_industry_map', COUNT_BIG(1) FROM GRAC_New.artifact_industry_map
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.artifact_jurisdiction_map', COUNT_BIG(1) FROM GRAC_New.artifact_jurisdiction_map
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.source_structure_node', COUNT_BIG(1) FROM GRAC_New.source_structure_node
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.release', COUNT_BIG(1) FROM GRAC_New.release
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.artifact', COUNT_BIG(1) FROM GRAC_New.artifact
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.control_keyword', COUNT_BIG(1) FROM GRAC_New.control_keyword
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.control', COUNT_BIG(1) FROM GRAC_New.control
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.requirement', COUNT_BIG(1) FROM GRAC_New.requirement;

IF @commit_cleanup = 1
BEGIN
    COMMIT TRANSACTION;
    PRINT 'Cleanup committed.';
    SELECT N'COMMITTED' CleanupResult,
           N'Working/configuration data was deleted. Preserved master/audit tables still contain data by design.' Message;
END
ELSE
BEGIN
    ROLLBACK TRANSACTION;
    PRINT 'Cleanup rolled back. Change @commit_cleanup to 1 after reviewing counts.';
    SELECT N'ROLLED_BACK_DRY_RUN' CleanupResult,
           N'No data was deleted because @commit_cleanup is 0. Set @commit_cleanup = 1 and rerun to commit cleanup.' Message;
END;

/*
  OPTIONAL DEVELOPMENT-ONLY AUDIT TRACE RESET

  The product intentionally protects GRAC_New.audit_trace with an immutable
  trigger. Do not run this block in production, UAT, audit, or regulated test
  environments unless formally approved.

  To clear audit_trace in a disposable local/dev database:

  BEGIN TRANSACTION;
      DISABLE TRIGGER GRAC_New.tr_audit_trace_immutable ON GRAC_New.audit_trace;
      DELETE FROM GRAC_New.audit_trace;
      DBCC CHECKIDENT (N'GRAC_New.audit_trace', RESEED, 0) WITH NO_INFOMSGS;
      ENABLE TRIGGER GRAC_New.tr_audit_trace_immutable ON GRAC_New.audit_trace;
  COMMIT TRANSACTION;
*/
