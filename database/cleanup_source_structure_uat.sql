/*
  ==========================================================================
  Cleanup script: Source Structure layer and below
  Target database: Grac_NewPhase_UAT
  Schema:          GRAC_New
  ==========================================================================

  Preserves (untouched):
    GRAC_New.authority
    GRAC_New.artifact
    GRAC_New.artifact_industry_map
    GRAC_New.artifact_jurisdiction_map
    GRAC_New.release
    GRAC_New.statement_classification        -- release-scoped, not under source-structure
    GRAC_New.control                         -- master
    GRAC_New.control_domain                  -- master
    GRAC_New.control_sub_domain              -- master
    GRAC_New.control_keyword                 -- master
    GRAC_New.evidence_type_master            -- master
    GRAC_New.reference_option                -- master
    GRAC_New.organization                    -- master
    GRAC_New.cm_user/cm_role/cm_menu/...     -- security masters
    GRAC_New.cm_entity_master                -- module master
    GRAC_New.approval_workflow_config        -- workflow config
    GRAC_New.audit_trace / audit_trace_event / audit_trace_detail
                                             -- immutable triggers prevent delete
    GRAC_New.transaction_audit               -- immutable trigger prevents delete
    GRAC_New.change_management /
    GRAC_New.change_management_field /
    GRAC_New.approval_action                 -- historical workflow trail kept

  Deletes (child first → parent last):
    1.  GRAC_New.requirement_obligation_evidence       -- Obligation Evidence
    2.  GRAC_New.requirement_obligation                -- Requirement Obligation
    3.  GRAC_New.obligation_evidence_type              -- legacy obligation evidence
    4.  GRAC_New.obligation                            -- legacy obligation table
    5.  GRAC_New.framework_statement_requirement_map   -- Requirement-Statement Mapping
    6.  GRAC_New.framework_statement_control_map       -- (FK on framework_statement, must clear)
    7.  GRAC_New.control_requirement_map               -- (FK on requirement, must clear)
    8.  GRAC_New.source_control_map                    -- (FK on source_structure_node, must clear)
    9.  GRAC_New.framework_statement                   -- Framework Statements
    10. GRAC_New.requirement                           -- Requirements
    11. GRAC_New.source_structure_node                 -- Source Structure (self-FK; deleted in one statement)

  After delete, IDENTITY values are reseeded so the next insert begins at 1.

  IMPORTANT: this script defaults to DRY-RUN.  It executes everything inside
  a transaction and ROLLS BACK at the end.  Review the "BEFORE" and
  "AFTER_DELETE_INSIDE_TRANSACTION" result sets, then change:

      SET @commit_cleanup = 0;
  to:
      SET @commit_cleanup = 1;

  ...and re-run.  Only then are rows permanently removed.
*/

USE Grac_NewPhase_UAT;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @schema SYSNAME = N'GRAC_New';
DECLARE @commit_cleanup BIT = 0;   -- 0 = dry-run (ROLLBACK), 1 = commit
DECLARE @reset_identity BIT = 1;   -- 1 = reseed identity to 0, 0 = leave identity values where they are

IF SCHEMA_ID(@schema) IS NULL
    THROW 60001, 'Schema GRAC_New does not exist in this database. Check the target.', 1;

PRINT 'Database in scope: ' + DB_NAME();
PRINT 'Schema in scope  : ' + @schema;
IF @commit_cleanup = 0
    PRINT 'MODE: DRY-RUN. The script will ROLLBACK at the end. No rows will be permanently deleted.';
ELSE
    PRINT 'MODE: COMMIT. The listed tables will be permanently emptied.';

PRINT N'';
PRINT N'================ BEFORE (current row counts) ================';

SELECT N'PRESERVED' Action, N'GRAC_New.authority'                       TableName, COUNT_BIG(1) [RowCount] FROM GRAC_New.authority
UNION ALL SELECT N'PRESERVED', N'GRAC_New.artifact',                       COUNT_BIG(1) FROM GRAC_New.artifact
UNION ALL SELECT N'PRESERVED', N'GRAC_New.release',                        COUNT_BIG(1) FROM GRAC_New.release
UNION ALL SELECT N'PRESERVED', N'GRAC_New.statement_classification',       COUNT_BIG(1) FROM GRAC_New.statement_classification
UNION ALL SELECT N'PRESERVED', N'GRAC_New.control',                        COUNT_BIG(1) FROM GRAC_New.control
UNION ALL SELECT N'CLEARED',   N'GRAC_New.requirement_obligation_evidence',COUNT_BIG(1) FROM GRAC_New.requirement_obligation_evidence
UNION ALL SELECT N'CLEARED',   N'GRAC_New.requirement_obligation',         COUNT_BIG(1) FROM GRAC_New.requirement_obligation
UNION ALL SELECT N'CLEARED',   N'GRAC_New.obligation_evidence_type',       COUNT_BIG(1) FROM GRAC_New.obligation_evidence_type
UNION ALL SELECT N'CLEARED',   N'GRAC_New.obligation',                     COUNT_BIG(1) FROM GRAC_New.obligation
UNION ALL SELECT N'CLEARED',   N'GRAC_New.framework_statement_requirement_map', COUNT_BIG(1) FROM GRAC_New.framework_statement_requirement_map
UNION ALL SELECT N'CLEARED',   N'GRAC_New.framework_statement_control_map',COUNT_BIG(1) FROM GRAC_New.framework_statement_control_map
UNION ALL SELECT N'CLEARED',   N'GRAC_New.control_requirement_map',        COUNT_BIG(1) FROM GRAC_New.control_requirement_map
UNION ALL SELECT N'CLEARED',   N'GRAC_New.source_control_map',             COUNT_BIG(1) FROM GRAC_New.source_control_map
UNION ALL SELECT N'CLEARED',   N'GRAC_New.framework_statement',            COUNT_BIG(1) FROM GRAC_New.framework_statement
UNION ALL SELECT N'CLEARED',   N'GRAC_New.requirement',                    COUNT_BIG(1) FROM GRAC_New.requirement
UNION ALL SELECT N'CLEARED',   N'GRAC_New.source_structure_node',          COUNT_BIG(1) FROM GRAC_New.source_structure_node
ORDER BY Action DESC, TableName;

BEGIN TRANSACTION;

BEGIN TRY
    /* ---------- Delete in dependency order (child → parent) ---------- */

    -- (1) Evidence rows on the active obligation model.
    DELETE FROM GRAC_New.requirement_obligation_evidence;

    -- (2) Active obligations (FK target of #1).
    DELETE FROM GRAC_New.requirement_obligation;

    -- (3) Legacy evidence rows tied to the legacy obligation table.
    DELETE FROM GRAC_New.obligation_evidence_type;

    -- (4) Legacy obligation table itself.
    DELETE FROM GRAC_New.obligation;

    -- (5) Requirement-Statement mapping (FK on framework_statement + requirement).
    DELETE FROM GRAC_New.framework_statement_requirement_map;

    -- (6) Framework Statement-Control mapping (FK on framework_statement).
    --     Must clear before framework_statement.
    DELETE FROM GRAC_New.framework_statement_control_map;

    -- (7) Control-Requirement mapping (FK on requirement).  Must clear before requirement.
    DELETE FROM GRAC_New.control_requirement_map;

    -- (8) Source Structure-Control mapping (FK on source_structure_node).
    --     Must clear before source_structure_node.
    DELETE FROM GRAC_New.source_control_map;

    -- (9) Framework Statements (FK on source_structure_node + statement_classification).
    DELETE FROM GRAC_New.framework_statement;

    -- (10) Requirements.
    DELETE FROM GRAC_New.requirement;

    -- (11) Source Structure nodes.  The table self-references via parent_node_id
    --      but SQL Server validates FK constraints at the *end* of the statement,
    --      so a single DELETE of every row is allowed.
    DELETE FROM GRAC_New.source_structure_node;

    /* ---------- Reseed identity values to 0 ---------- */
    IF @reset_identity = 1
    BEGIN
        IF OBJECT_ID(N'GRAC_New.requirement_obligation_evidence', N'U') IS NOT NULL
            DBCC CHECKIDENT (N'GRAC_New.requirement_obligation_evidence', RESEED, 0) WITH NO_INFOMSGS;
        IF OBJECT_ID(N'GRAC_New.requirement_obligation', N'U') IS NOT NULL
            DBCC CHECKIDENT (N'GRAC_New.requirement_obligation', RESEED, 0) WITH NO_INFOMSGS;
        IF OBJECT_ID(N'GRAC_New.obligation_evidence_type', N'U') IS NOT NULL
            DBCC CHECKIDENT (N'GRAC_New.obligation_evidence_type', RESEED, 0) WITH NO_INFOMSGS;
        IF OBJECT_ID(N'GRAC_New.obligation', N'U') IS NOT NULL
            DBCC CHECKIDENT (N'GRAC_New.obligation', RESEED, 0) WITH NO_INFOMSGS;
        IF OBJECT_ID(N'GRAC_New.framework_statement_requirement_map', N'U') IS NOT NULL
            DBCC CHECKIDENT (N'GRAC_New.framework_statement_requirement_map', RESEED, 0) WITH NO_INFOMSGS;
        IF OBJECT_ID(N'GRAC_New.framework_statement_control_map', N'U') IS NOT NULL
            DBCC CHECKIDENT (N'GRAC_New.framework_statement_control_map', RESEED, 0) WITH NO_INFOMSGS;
        IF OBJECT_ID(N'GRAC_New.control_requirement_map', N'U') IS NOT NULL
            DBCC CHECKIDENT (N'GRAC_New.control_requirement_map', RESEED, 0) WITH NO_INFOMSGS;
        IF OBJECT_ID(N'GRAC_New.source_control_map', N'U') IS NOT NULL
            DBCC CHECKIDENT (N'GRAC_New.source_control_map', RESEED, 0) WITH NO_INFOMSGS;
        IF OBJECT_ID(N'GRAC_New.framework_statement', N'U') IS NOT NULL
            DBCC CHECKIDENT (N'GRAC_New.framework_statement', RESEED, 0) WITH NO_INFOMSGS;
        IF OBJECT_ID(N'GRAC_New.requirement', N'U') IS NOT NULL
            DBCC CHECKIDENT (N'GRAC_New.requirement', RESEED, 0) WITH NO_INFOMSGS;
        IF OBJECT_ID(N'GRAC_New.source_structure_node', N'U') IS NOT NULL
            DBCC CHECKIDENT (N'GRAC_New.source_structure_node', RESEED, 0) WITH NO_INFOMSGS;
    END

    PRINT N'';
    PRINT N'============= AFTER DELETE (still inside transaction) =============';

    SELECT N'AFTER_DELETE_INSIDE_TRANSACTION' Action, N'GRAC_New.requirement_obligation_evidence' TableName, COUNT_BIG(1) [RowCount] FROM GRAC_New.requirement_obligation_evidence
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.requirement_obligation',              COUNT_BIG(1) FROM GRAC_New.requirement_obligation
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.obligation_evidence_type',            COUNT_BIG(1) FROM GRAC_New.obligation_evidence_type
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.obligation',                          COUNT_BIG(1) FROM GRAC_New.obligation
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.framework_statement_requirement_map', COUNT_BIG(1) FROM GRAC_New.framework_statement_requirement_map
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.framework_statement_control_map',     COUNT_BIG(1) FROM GRAC_New.framework_statement_control_map
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.control_requirement_map',             COUNT_BIG(1) FROM GRAC_New.control_requirement_map
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.source_control_map',                  COUNT_BIG(1) FROM GRAC_New.source_control_map
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.framework_statement',                 COUNT_BIG(1) FROM GRAC_New.framework_statement
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.requirement',                         COUNT_BIG(1) FROM GRAC_New.requirement
    UNION ALL SELECT N'AFTER_DELETE_INSIDE_TRANSACTION', N'GRAC_New.source_structure_node',               COUNT_BIG(1) FROM GRAC_New.source_structure_node
    UNION ALL SELECT N'PRESERVED_CHECK', N'GRAC_New.authority',                       COUNT_BIG(1) FROM GRAC_New.authority
    UNION ALL SELECT N'PRESERVED_CHECK', N'GRAC_New.artifact',                        COUNT_BIG(1) FROM GRAC_New.artifact
    UNION ALL SELECT N'PRESERVED_CHECK', N'GRAC_New.release',                         COUNT_BIG(1) FROM GRAC_New.release
    UNION ALL SELECT N'PRESERVED_CHECK', N'GRAC_New.statement_classification',        COUNT_BIG(1) FROM GRAC_New.statement_classification
    UNION ALL SELECT N'PRESERVED_CHECK', N'GRAC_New.control',                         COUNT_BIG(1) FROM GRAC_New.control
    ORDER BY Action DESC, TableName;

    IF @commit_cleanup = 1
    BEGIN
        COMMIT TRANSACTION;
        PRINT N'COMMITTED. Source Structure layer has been permanently cleared.';
    END
    ELSE
    BEGIN
        ROLLBACK TRANSACTION;
        PRINT N'DRY-RUN: ROLLED BACK. No rows were permanently removed. Set @commit_cleanup = 1 and re-run to apply.';
    END
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    PRINT N'Cleanup failed. Transaction rolled back.';
    THROW;
END CATCH
GO

PRINT N'';
PRINT N'============= FINAL row counts (after commit/rollback) =============';

SELECT N'FINAL' Action, N'GRAC_New.requirement_obligation_evidence' TableName, COUNT_BIG(1) [RowCount] FROM GRAC_New.requirement_obligation_evidence
UNION ALL SELECT N'FINAL', N'GRAC_New.requirement_obligation',              COUNT_BIG(1) FROM GRAC_New.requirement_obligation
UNION ALL SELECT N'FINAL', N'GRAC_New.obligation_evidence_type',            COUNT_BIG(1) FROM GRAC_New.obligation_evidence_type
UNION ALL SELECT N'FINAL', N'GRAC_New.obligation',                          COUNT_BIG(1) FROM GRAC_New.obligation
UNION ALL SELECT N'FINAL', N'GRAC_New.framework_statement_requirement_map', COUNT_BIG(1) FROM GRAC_New.framework_statement_requirement_map
UNION ALL SELECT N'FINAL', N'GRAC_New.framework_statement_control_map',     COUNT_BIG(1) FROM GRAC_New.framework_statement_control_map
UNION ALL SELECT N'FINAL', N'GRAC_New.control_requirement_map',             COUNT_BIG(1) FROM GRAC_New.control_requirement_map
UNION ALL SELECT N'FINAL', N'GRAC_New.source_control_map',                  COUNT_BIG(1) FROM GRAC_New.source_control_map
UNION ALL SELECT N'FINAL', N'GRAC_New.framework_statement',                 COUNT_BIG(1) FROM GRAC_New.framework_statement
UNION ALL SELECT N'FINAL', N'GRAC_New.requirement',                         COUNT_BIG(1) FROM GRAC_New.requirement
UNION ALL SELECT N'FINAL', N'GRAC_New.source_structure_node',               COUNT_BIG(1) FROM GRAC_New.source_structure_node
UNION ALL SELECT N'PRESERVED', N'GRAC_New.authority',                       COUNT_BIG(1) FROM GRAC_New.authority
UNION ALL SELECT N'PRESERVED', N'GRAC_New.artifact',                        COUNT_BIG(1) FROM GRAC_New.artifact
UNION ALL SELECT N'PRESERVED', N'GRAC_New.release',                         COUNT_BIG(1) FROM GRAC_New.release
UNION ALL SELECT N'PRESERVED', N'GRAC_New.statement_classification',        COUNT_BIG(1) FROM GRAC_New.statement_classification
UNION ALL SELECT N'PRESERVED', N'GRAC_New.control',                         COUNT_BIG(1) FROM GRAC_New.control
ORDER BY Action DESC, TableName;
GO
