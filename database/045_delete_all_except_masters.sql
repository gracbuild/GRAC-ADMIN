/*
  GRAC Control Management - Part 045
  Delete ALL working / transactional / audit data, preserving only master data.

  ---------------------------------------------------------------------------
  WARNING - THIS SCRIPT COMMITS.  THERE IS NO DRY-RUN FLAG AND NO UNDO.
  ---------------------------------------------------------------------------
  Once this runs successfully the deleted rows are gone.  A DELETE cannot be
  rolled back after COMMIT - the only recovery is a database restore.  Take a
  backup before running this in any environment you care about.

  This script also clears the append-only audit tables by temporarily disabling
  their immutability triggers.  That is deliberate (requested), but it means
  this script must NOT be run in production, UAT, audit or any regulated
  environment without formal approval.

  ---------------------------------------------------------------------------
  PRESERVED (master / reference / security / configuration)
  ---------------------------------------------------------------------------
    authority, reference_option, organization, applicability_attribute
    control_domain, control_sub_domain
    evidence_type_master, obligation_type_master, event_type_master
    cm_entity_master, approval_workflow_config
    cm_user, cm_role, cm_user_role, cm_menu, cm_role_permission
    security_role, security_permission, security_role_permission, security_user_role
    assurance_category, assurance_scoring_model, assurance_observation_severity,
    assurance_gap_category, assurance_workflow_template, assurance_workflow_stage,
    assurance_question_type, assurance_sampling_model, assurance_frequency_type,
    assurance_report_template, assurance_starter_template,
    assurance_starter_template_question, sla_master

  ---------------------------------------------------------------------------
  CLEARED (everything else in the GRAC_New schema)
  ---------------------------------------------------------------------------
    Regulatory source .. artifact, artifact_industry_map, artifact_jurisdiction_map,
                         release, statement_classification, source_structure_node,
                         framework_statement
    Control / practice . control, control_keyword, requirement
    Obligation ......... obligation, requirement_obligation,
                         requirement_obligation_evidence, obligation_evidence_type,
                         obligation_requirement_release_map,
                         obligation_state_rule, obligation_execution_spec,
                         obligation_assurance_spec, obligation_event_response,
                         obligation_constraint_rule, obligation_retention_spec,
                         and all obligation_*_evidence_link tables
    Mapping ............ source_control_map, control_requirement_map,
                         framework_statement_control_map,
                         framework_statement_requirement_map
    Governance ......... change_management, change_management_field, change_event,
                         impact_analysis, notification, approval_action,
                         applicability_rule
    Assurance runtime .. assurance_event_occurrence, assurance_checklist_item,
                         assurance_checklist_evidence
    Audit .............. audit_trace, audit_trace_event, audit_trace_detail,
                         transaction_audit, assurance_metadata_version

  The classification is DATA-DRIVEN.  To keep or clear a table, move its name
  between the two INSERT blocks in section 1.  Any table in GRAC_New that is
  not listed as preserved is cleared, so tables added by future migrations are
  covered automatically.

  Safe to re-run.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @schema SYSNAME = N'GRAC_New';

IF SCHEMA_ID(@schema) IS NULL
    THROW 51400, 'Schema GRAC_New does not exist. Check the database before running cleanup.', 1;

PRINT '=== GRAC Control Management - delete all except masters ===';
PRINT 'Database: ' + DB_NAME() + '  |  Started: ' + CONVERT(VARCHAR(30), SYSUTCDATETIME(), 126) + ' UTC';

/* ===========================================================================
   1. Classification
   =========================================================================== */

IF OBJECT_ID('tempdb..#preserve') IS NOT NULL DROP TABLE #preserve;
IF OBJECT_ID('tempdb..#target')   IS NOT NULL DROP TABLE #target;

CREATE TABLE #preserve(table_name SYSNAME NOT NULL PRIMARY KEY);
CREATE TABLE #target(
    object_id   INT      NOT NULL PRIMARY KEY,
    table_name  SYSNAME  NOT NULL,
    full_name   NVARCHAR(300) NOT NULL,
    has_identity BIT     NOT NULL,
    rows_before BIGINT   NULL,
    rows_after  BIGINT   NULL);

INSERT #preserve(table_name) VALUES
    -- Core reference / master
    (N'authority'),
    (N'reference_option'),
    (N'organization'),
    (N'applicability_attribute'),
    (N'control_domain'),
    (N'control_sub_domain'),
    (N'evidence_type_master'),
    (N'obligation_type_master'),
    (N'event_type_master'),
    -- Platform configuration
    (N'cm_entity_master'),
    (N'approval_workflow_config'),
    -- Users, roles, menus, permissions
    (N'cm_user'),
    (N'cm_role'),
    (N'cm_user_role'),
    (N'cm_menu'),
    (N'cm_role_permission'),
    (N'security_role'),
    (N'security_permission'),
    (N'security_role_permission'),
    (N'security_user_role'),
    -- Assurance metadata masters
    (N'assurance_category'),
    (N'assurance_scoring_model'),
    (N'assurance_observation_severity'),
    (N'assurance_gap_category'),
    (N'assurance_workflow_template'),
    (N'assurance_workflow_stage'),
    (N'assurance_question_type'),
    (N'assurance_sampling_model'),
    (N'assurance_frequency_type'),
    (N'assurance_report_template'),
    (N'assurance_starter_template'),
    (N'assurance_starter_template_question'),
    (N'sla_master');

INSERT #target(object_id, table_name, full_name, has_identity)
SELECT t.object_id,
       t.name,
       QUOTENAME(@schema) + N'.' + QUOTENAME(t.name),
       CONVERT(BIT, CASE WHEN EXISTS (SELECT 1 FROM sys.identity_columns ic WHERE ic.object_id = t.object_id) THEN 1 ELSE 0 END)
FROM sys.tables t
WHERE t.schema_id = SCHEMA_ID(@schema)
  AND t.is_ms_shipped = 0
  AND t.name NOT IN (SELECT table_name FROM #preserve);

IF NOT EXISTS (SELECT 1 FROM #target)
BEGIN
    PRINT 'Nothing to clear - every table in the schema is on the preserve list.';
    RETURN;
END;

/* Warn about preserve-list entries that do not exist (typo / older database). */
SELECT N'PRESERVE_ENTRY_NOT_FOUND' AS Notice, p.table_name
FROM #preserve p
WHERE NOT EXISTS (SELECT 1 FROM sys.tables t
                  WHERE t.schema_id = SCHEMA_ID(@schema) AND t.name = p.table_name);

/* ===========================================================================
   2. Safety pre-flight
   Abort if a PRESERVED table has a foreign key pointing at a CLEARED table.
   Deleting the child rows would leave the preserved table orphaned and the
   constraint re-check in section 6 would fail.
   =========================================================================== */

IF EXISTS (
    SELECT 1
    FROM sys.foreign_keys fk
    JOIN sys.tables pt ON pt.object_id = fk.parent_object_id
    JOIN sys.tables rt ON rt.object_id = fk.referenced_object_id
    WHERE pt.schema_id = SCHEMA_ID(@schema)
      AND pt.name IN (SELECT table_name FROM #preserve)
      AND rt.object_id IN (SELECT object_id FROM #target))
BEGIN
    SELECT N'BLOCKING_DEPENDENCY' AS Problem,
           OBJECT_NAME(fk.parent_object_id)     AS PreservedTable,
           OBJECT_NAME(fk.referenced_object_id) AS ClearedTable,
           fk.name                              AS ForeignKeyName
    FROM sys.foreign_keys fk
    JOIN sys.tables pt ON pt.object_id = fk.parent_object_id
    WHERE pt.schema_id = SCHEMA_ID(@schema)
      AND pt.name IN (SELECT table_name FROM #preserve)
      AND fk.referenced_object_id IN (SELECT object_id FROM #target);

    THROW 51401, 'A preserved table references a table marked for clearing. Move one of them between the preserve and clear lists in section 1, then rerun.', 1;
END;

/* ===========================================================================
   3. Pre-delete row counts
   =========================================================================== */

DECLARE @sql NVARCHAR(MAX) = N'';

SELECT @sql = STRING_AGG(
        CAST(N'UPDATE #target SET rows_before = (SELECT COUNT_BIG(1) FROM ' + full_name
             + N') WHERE object_id = ' + CONVERT(NVARCHAR(20), object_id) + N';' AS NVARCHAR(MAX)),
        NCHAR(13) + NCHAR(10))
FROM #target;
EXEC sp_executesql @sql;

SELECT N'TO_BE_CLEARED' AS CleanupAction, table_name AS TableName, rows_before AS [RecordCount]
FROM #target
ORDER BY rows_before DESC, table_name;

SELECT N'TOTAL_ROWS_TO_DELETE' AS Summary, SUM(rows_before) AS [RecordCount] FROM #target;

/* ===========================================================================
   4. Delete
   Foreign keys are switched to NOCHECK for the duration so no delete ordering
   is required; they are re-validated with CHECK in section 6.  Triggers on the
   cleared tables (including the audit immutability triggers) are disabled and
   restored the same way.
   =========================================================================== */

BEGIN TRANSACTION;

    /* 4a. Disable triggers on the tables being cleared. */
    SET @sql = N'';
    SELECT @sql = STRING_AGG(
            CAST(N'DISABLE TRIGGER ' + QUOTENAME(@schema) + N'.' + QUOTENAME(tr.name)
                 + N' ON ' + t.full_name + N';' AS NVARCHAR(MAX)),
            NCHAR(13) + NCHAR(10))
    FROM sys.triggers tr
    JOIN #target t ON t.object_id = tr.parent_id
    WHERE tr.is_disabled = 0;
    IF @sql IS NOT NULL AND LEN(@sql) > 0 EXEC sp_executesql @sql;

    /* 4b. Suspend foreign key enforcement on the tables being cleared.
           Scoped to #target on purpose: foreign keys owned by preserved tables
           are left alone, so a pre-existing data problem in a master table
           cannot abort this cleanup. */
    SET @sql = N'';
    SELECT @sql = STRING_AGG(
            CAST(N'ALTER TABLE ' + t.full_name
                 + N' NOCHECK CONSTRAINT ' + QUOTENAME(fk.name) + N';' AS NVARCHAR(MAX)),
            NCHAR(13) + NCHAR(10))
    FROM sys.foreign_keys fk
    JOIN #target t ON t.object_id = fk.parent_object_id;
    IF @sql IS NOT NULL AND LEN(@sql) > 0 EXEC sp_executesql @sql;

    /* 4c. Delete. */
    SET @sql = N'';
    SELECT @sql = STRING_AGG(CAST(N'DELETE FROM ' + full_name + N';' AS NVARCHAR(MAX)),
                             NCHAR(13) + NCHAR(10))
    FROM #target;
    EXEC sp_executesql @sql;

/* ===========================================================================
   5. Verify inside the transaction
   =========================================================================== */

    SET @sql = N'';
    SELECT @sql = STRING_AGG(
            CAST(N'UPDATE #target SET rows_after = (SELECT COUNT_BIG(1) FROM ' + full_name
                 + N') WHERE object_id = ' + CONVERT(NVARCHAR(20), object_id) + N';' AS NVARCHAR(MAX)),
            NCHAR(13) + NCHAR(10))
    FROM #target;
    EXEC sp_executesql @sql;

    IF EXISTS (SELECT 1 FROM #target WHERE rows_after > 0)
    BEGIN
        SELECT N'STILL_POPULATED' AS Problem, table_name AS TableName, rows_after AS [RecordCount]
        FROM #target WHERE rows_after > 0;
        THROW 51402, 'One or more tables still contain rows after the delete. Transaction rolled back; no data was removed.', 1;
    END;

/* ===========================================================================
   6. Restore constraints and triggers
   =========================================================================== */

    /* 6a. Re-enable and re-validate the foreign keys suspended in 4b.  The
           cleared tables are empty at this point, so validation is a formality
           - but it leaves every constraint TRUSTED for the optimiser. */
    SET @sql = N'';
    SELECT @sql = STRING_AGG(
            CAST(N'ALTER TABLE ' + t.full_name
                 + N' WITH CHECK CHECK CONSTRAINT ' + QUOTENAME(fk.name) + N';' AS NVARCHAR(MAX)),
            NCHAR(13) + NCHAR(10))
    FROM sys.foreign_keys fk
    JOIN #target t ON t.object_id = fk.parent_object_id;
    IF @sql IS NOT NULL AND LEN(@sql) > 0 EXEC sp_executesql @sql;

    /* 6b. Re-enable the triggers disabled in 4a, including the audit
           immutability triggers.  This must succeed - verified in section 8. */
    SET @sql = N'';
    SELECT @sql = STRING_AGG(
            CAST(N'ENABLE TRIGGER ' + QUOTENAME(@schema) + N'.' + QUOTENAME(tr.name)
                 + N' ON ' + t.full_name + N';' AS NVARCHAR(MAX)),
            NCHAR(13) + NCHAR(10))
    FROM sys.triggers tr
    JOIN #target t ON t.object_id = tr.parent_id
    WHERE tr.is_disabled = 1;
    IF @sql IS NOT NULL AND LEN(@sql) > 0 EXEC sp_executesql @sql;

COMMIT TRANSACTION;

PRINT 'Delete committed.';

/* ===========================================================================
   7. Reseed identities
   DBCC CHECKIDENT is not transactional, so it runs after the commit.
   =========================================================================== */

SET @sql = N'';
SELECT @sql = STRING_AGG(
        CAST(N'DBCC CHECKIDENT (''' + @schema + N'.' + table_name + N''', RESEED, 0) WITH NO_INFOMSGS;' AS NVARCHAR(MAX)),
        NCHAR(13) + NCHAR(10))
FROM #target
WHERE has_identity = 1;
IF @sql IS NOT NULL AND LEN(@sql) > 0 EXEC sp_executesql @sql;

PRINT 'Identity columns reseeded to 0.';

/* ===========================================================================
   8. Post-run report
   =========================================================================== */

SELECT N'CLEARED' AS CleanupAction,
       table_name AS TableName,
       rows_before AS RowsDeleted,
       rows_after  AS RowsRemaining
FROM #target
ORDER BY rows_before DESC, table_name;

SELECT N'PRESERVED' AS CleanupAction, p.table_name AS TableName
FROM #preserve p
JOIN sys.tables t ON t.schema_id = SCHEMA_ID(@schema) AND t.name = p.table_name
ORDER BY p.table_name;

/* Any trigger left disabled, or any foreign key left untrusted, is a defect -
   this result set must come back empty. */
SELECT N'TRIGGER_STILL_DISABLED' AS Problem, tr.name AS ObjectName
FROM sys.triggers tr
JOIN sys.tables t ON t.object_id = tr.parent_id
WHERE t.schema_id = SCHEMA_ID(@schema) AND tr.is_disabled = 1
UNION ALL
SELECT N'FOREIGN_KEY_NOT_TRUSTED', fk.name
FROM sys.foreign_keys fk
JOIN #target t ON t.object_id = fk.parent_object_id
WHERE fk.is_disabled = 1 OR fk.is_not_trusted = 1;

SELECT N'COMPLETED' AS CleanupResult,
       SUM(rows_before) AS TotalRowsDeleted,
       CONVERT(VARCHAR(30), SYSUTCDATETIME(), 126) + N' UTC' AS FinishedUtc
FROM #target;

DROP TABLE #preserve;
DROP TABLE #target;
GO

/*
  ---------------------------------------------------------------------------
  POST-RUN NOTES
  ---------------------------------------------------------------------------
  1. Users, roles, menus and role permissions are preserved, so existing
     sign-in credentials continue to work.

  2. Authorities, control domains/sub-domains, evidence types, obligation
     types, event types, assurance metadata masters and the SLA master are
     preserved.  Artifacts and everything below them are gone, so the first
     task after this script is to recreate artifacts and releases.

  3. approval_workflow_config and cm_entity_master are preserved, so the
     maker-checker configuration survives.  change_management is emptied, so
     any change request that was pending approval is gone - it cannot be
     resurrected and the underlying record was never applied.

  4. Audit history (audit_trace, audit_trace_event, audit_trace_detail,
     transaction_audit, assurance_metadata_version) has been erased and the
     immutability triggers re-enabled.  Record this action in your change log:
     the audit tables can no longer evidence what was in the system before
     this script ran.

  5. To preserve audit history on a future run, move these five table names
     from the cleared set into the #preserve INSERT in section 1:
         audit_trace, audit_trace_event, audit_trace_detail,
         transaction_audit, assurance_metadata_version

  6. There is no rollback script.  A committed DELETE is recoverable only from
     a database backup taken before the run.
*/
