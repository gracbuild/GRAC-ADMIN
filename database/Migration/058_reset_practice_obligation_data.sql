/* =====================================================================
   058_reset_practice_obligation_data.sql

   Full reset of the Practice and Obligation catalogue, ahead of the
   v1.3 workbook reload (059 - 065).

   WHAT IT CLEARS
   --------------
   GRAC_New:
     requirement                              Practices
     framework_statement_requirement_map      Practice -> Statement links
     control_requirement_map                  Control  -> Practice links
     requirement_obligation                   Obligations (parent)
     obligation_state_rule                    State detail
     obligation_execution_spec                Execution detail
     obligation_assurance_spec                Assurance detail
     obligation_event_response                Event Response detail
     obligation_constraint_rule               Constraint detail
     obligation_retention_spec                Retention detail
     obligation_*_evidence_link  (6 tables)   type -> evidence links
     requirement_obligation_evidence          evidence specs
     obligation_evidence_type                 legacy evidence links (012)
     obligation_framework_statement_map       Obligation -> Statement (056)
     obligation_requirement_release_map       Obligation -> Practice + Release
     obligation                               legacy obligation table (001)
     assurance_event_occurrence               runtime assurance occurrences
     assurance_checklist_item                 runtime checklist items
     assurance_checklist_evidence             runtime checklist evidence
     change_management / change_management_field
                                              open change requests for the
                                              practice + obligation entities
     cm_cascade_deactivation                  cascade log for those entities
     organization                             organization master

   grac_practice (the Practice Management schema, if present on this
   instance):  every table, cleared in foreign-key dependency order.
   That is the "data copied into organizations" -- organization_control,
   organization_requirement, organization_obligation and everything
   hanging off them.  The schema does not live in this repository, so the
   table list is DISCOVERED at run time from sys.foreign_keys rather than
   hard-coded.  If the schema is absent the block is skipped silently.

   WHAT IT PRESERVES
   -----------------
     authority, artifact, release, source_structure_node
     framework_statement            (052 -- 060 maps Practices onto these)
     control, control_domain, control_sub_domain, control_keyword
     reference_option, evidence_type_master, obligation_type_master
     event_type_master, sla_master, assurance_* master tables
     security_*, cm_entity_master
     audit_trace, audit_trace_event, audit_trace_detail, transaction_audit
       -- append-only by trigger; history of the old load stays readable.

   IDENTITY RESEED
   ---------------
   Every cleared table is reseeded to 0, so the reload starts at 1.
   DBCC CHECKIDENT is guarded by OBJECT_ID so the script still runs on a
   database that has not had every migration applied.

   APPEND-ONLY TABLES INSIDE grac_practice
   ---------------------------------------
   Practice Management protects some of its tables with an immutability
   trigger that raises on DELETE -- entity_state_transition_log is one:

       Msg 53501 ... tr_pm_entity_transition_log_immutable
       entity_state_transition_log is append-only and immutable.

   Part 1 handles those without touching the trigger, by using TRUNCATE
   TABLE instead of DELETE.  TRUNCATE is a metadata operation: it does not
   fire DML triggers at all, and it resets the identity seed as a side
   effect.  It is the ordinary way to empty a log table, not a bypass.

   TRUNCATE has one hard restriction -- SQL Server refuses it on a table
   that is the target of ANY foreign key, even when the referencing table
   is empty.  A protected table in that position cannot be cleared either
   way, so the script stops and names the table and its trigger rather
   than half-clearing the schema.  Setting

       DECLARE @allow_disable_immutable_triggers BIT = 1;

   makes Part 1 DISABLE those triggers, DELETE, and re-enable them in the
   same transaction.  That genuinely does defeat an immutability guard, so
   it is off by default and should only be turned on for a UAT or
   development database that is being deliberately reset.

   WHY PART 7 IS DYNAMIC SQL
   -------------------------
   SQL Server compiles a whole batch before it executes any of it, and an
   `IF OBJECT_ID(...) IS NOT NULL` guard does NOT stop that.  A column name
   that is wrong for THIS database therefore fails the entire batch at
   compile time -- "Invalid column name" -- before a single DELETE runs,
   even though the guard would have skipped the statement.

   change_management and cm_cascade_deactivation are the two tables here
   whose shape differs between the migrations that created them:

       change_management       entity_type, record_id
       cm_cascade_deactivation root_entity_type / root_record_id
                               child_entity_type / child_record_id

   So Part 7 builds those DELETEs as strings and runs them through
   sp_executesql, after checking COL_LENGTH for each column it names.  A
   database missing either table, or carrying an older shape, skips the
   statement instead of failing the reset.

   DRY RUN BY DEFAULT
   ------------------
   The script ends in ROLLBACK unless you change

       DECLARE @commit_cleanup BIT = 0;
   to  DECLARE @commit_cleanup BIT = 1;

   Run it once with 0, read the BEFORE / AFTER count result sets, then run
   it again with 1.  This mirrors 010_cleanup_part1_working_data_preserve_masters.sql.

   ORDER
   -----
   058 (this file) -> 059 masters -> 060 practices -> 061 state ->
   062 execution -> 063 assurance -> 064 event response -> 065 constraint.

   FILE ENCODING
   -------------
   UTF-8 with BOM.  Run with: sqlcmd -f 65001 -i 058_reset_practice_obligation_data.sql
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @commit_cleanup BIT = 0;   -- 0 = dry run (ROLLBACK).  1 = commit.

-- Only for a UAT / development reset.  See "APPEND-ONLY TABLES INSIDE
-- grac_practice" in the header before turning this on.
DECLARE @allow_disable_immutable_triggers BIT = 0;

DECLARE @by             NVARCHAR(100) = N'anoop.ps@soffit.in';
DECLARE @sql            NVARCHAR(MAX);
DECLARE @tbl            NVARCHAR(400);
DECLARE @obj            INT;
DECLARE @has_trigger    BIT;
DECLARE @has_inbound_fk BIT;
DECLARE @trg            NVARCHAR(400);
DECLARE @errmsg         NVARCHAR(2048);
DECLARE @rounds         INT;
DECLARE @deleted        BIGINT;
DECLARE @entities       NVARCHAR(MAX) =
    N'N''requirements'', N''obligations'', N''obligation-state'', ' +
    N'N''obligation-execution'', N''obligation-assurance'', ' +
    N'N''obligation-event-response'', N''obligation-constraint'', ' +
    N'N''obligation-retention'', N''obligation-evidence-links'', ' +
    N'N''source-control-mappings'', N''organizations''';

IF SCHEMA_ID(N'GRAC_New') IS NULL
    THROW 50500, 'Schema GRAC_New is missing. Nothing to reset.', 1;

IF @commit_cleanup = 0
    PRINT N'058 DRY RUN. @commit_cleanup = 0 -- the transaction will be ROLLED BACK and nothing is deleted.';
ELSE
    PRINT N'058 COMMIT MODE. @commit_cleanup = 1 -- Practices, Obligations and organization data will be permanently deleted.';

-- ---------------------------------------------------------------
-- BEFORE counts
-- ---------------------------------------------------------------
SELECT N'BEFORE' AS Phase, N'GRAC_New.requirement' AS TableName, COUNT_BIG(1) AS [RowCount] FROM GRAC_New.requirement
UNION ALL SELECT N'BEFORE', N'GRAC_New.requirement_obligation',              COUNT_BIG(1) FROM GRAC_New.requirement_obligation
UNION ALL SELECT N'BEFORE', N'GRAC_New.framework_statement_requirement_map', COUNT_BIG(1) FROM GRAC_New.framework_statement_requirement_map
UNION ALL SELECT N'BEFORE', N'GRAC_New.obligation_requirement_release_map',  COUNT_BIG(1) FROM GRAC_New.obligation_requirement_release_map
UNION ALL SELECT N'BEFORE', N'GRAC_New.requirement_obligation_evidence',     COUNT_BIG(1) FROM GRAC_New.requirement_obligation_evidence
UNION ALL SELECT N'BEFORE', N'GRAC_New.organization',                        COUNT_BIG(1) FROM GRAC_New.organization
UNION ALL SELECT N'PRESERVED', N'GRAC_New.framework_statement',              COUNT_BIG(1) FROM GRAC_New.framework_statement
UNION ALL SELECT N'PRESERVED', N'GRAC_New.reference_option',                 COUNT_BIG(1) FROM GRAC_New.reference_option
UNION ALL SELECT N'PRESERVED', N'GRAC_New.evidence_type_master',             COUNT_BIG(1) FROM GRAC_New.evidence_type_master
UNION ALL SELECT N'PRESERVED', N'GRAC_New.obligation_type_master',           COUNT_BIG(1) FROM GRAC_New.obligation_type_master
UNION ALL SELECT N'PRESERVED', N'GRAC_New.event_type_master',                COUNT_BIG(1) FROM GRAC_New.event_type_master
UNION ALL SELECT N'PRESERVED', N'GRAC_New.control',                          COUNT_BIG(1) FROM GRAC_New.control
UNION ALL SELECT N'PRESERVED', N'GRAC_New.[release]',                        COUNT_BIG(1) FROM GRAC_New.[release];

BEGIN TRY
BEGIN TRANSACTION;

-- =====================================================================
-- PART 1.  grac_practice -- the organization copies.
--
-- Discovered, not hard-coded: the Practice Management schema is deployed
-- from a different repository and its table list is not knowable here.
--
-- ORDER IS SIDESTEPPED, NOT SOLVED
-- --------------------------------
-- An earlier revision of this script drained the schema leaves-first:
-- repeatedly clear every table nothing un-cleared points at.  That works
-- on a dependency tree and fails on a cycle -- and grac_practice has one.
-- Two log tables cleared, then every remaining table was still referenced
-- by another remaining table and the pass made no progress.
--
-- So the order is not computed at all.  Every foreign key into or out of
-- the schema is DISABLED (WITH NOCHECK), the tables are cleared in
-- whatever order sys.tables returns them, and the constraints are then
-- re-enabled WITH CHECK -- which re-validates them, against tables that
-- are now empty, so they come back trusted rather than merely enabled.
--
-- ALTER TABLE is transactional in SQL Server, so a dry run's ROLLBACK
-- puts every constraint back exactly as it was, and so does the CATCH
-- block if anything raises midway.  The constraints are only ever loose
-- inside this transaction.
-- =====================================================================
IF SCHEMA_ID(N'grac_practice') IS NOT NULL
BEGIN
    PRINT N'  grac_practice schema found -- clearing organization copies.';

    IF OBJECT_ID(N'tempdb..#gp') IS NOT NULL DROP TABLE #gp;
    SELECT t.object_id, QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) AS full_name,
           CAST(0 AS BIT) AS done
    INTO #gp
    FROM sys.tables t
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE s.name = N'grac_practice';

    -- ---------------------------------------------------------------
    -- Stage every foreign key that touches the schema, from either end,
    -- then disable them all.  Both ends matter: a key OUT of
    -- grac_practice blocks the delete of the row it points at, and a key
    -- INTO grac_practice from anywhere else blocks these deletes.
    -- ---------------------------------------------------------------
    IF OBJECT_ID(N'tempdb..#gpfk') IS NOT NULL DROP TABLE #gpfk;
    SELECT DISTINCT
           QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id)) + N'.'
         + QUOTENAME(OBJECT_NAME(fk.parent_object_id)) AS child_table,
           QUOTENAME(fk.name)                          AS fk_name
    INTO #gpfk
    FROM sys.foreign_keys fk
    WHERE fk.parent_object_id     IN (SELECT object_id FROM #gp)
       OR fk.referenced_object_id IN (SELECT object_id FROM #gp);

    SET @rounds = (SELECT COUNT(*) FROM #gpfk);
    PRINT CONCAT(N'    Disabling ', @rounds, N' foreign key(s) for the duration of this transaction.');

    DECLARE gpfk_cur CURSOR LOCAL FAST_FORWARD FOR SELECT child_table, fk_name FROM #gpfk;
    OPEN gpfk_cur;
    FETCH NEXT FROM gpfk_cur INTO @tbl, @trg;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'ALTER TABLE ' + @tbl + N' NOCHECK CONSTRAINT ' + @trg + N';';
        EXEC sp_executesql @sql;
        FETCH NEXT FROM gpfk_cur INTO @tbl, @trg;
    END
    CLOSE gpfk_cur;
    DEALLOCATE gpfk_cur;

    -- ---------------------------------------------------------------
    -- Clear every table.  Order no longer matters.
    -- ---------------------------------------------------------------
    BEGIN
        DECLARE gp_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT g.full_name, g.object_id FROM #gp g;

        SET @deleted = 0;
        OPEN gp_cur;
        FETCH NEXT FROM gp_cur INTO @tbl, @obj;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            -- An enabled DELETE trigger means the table may be protected by
            -- an immutability guard.  See the header.
            SET @has_trigger = CASE WHEN EXISTS(
                    SELECT 1 FROM sys.triggers t
                    WHERE t.parent_id = @obj
                      AND t.is_disabled = 0
                      AND (OBJECTPROPERTY(t.object_id, 'ExecIsDeleteTrigger')       = 1
                        OR OBJECTPROPERTY(t.object_id, 'ExecIsInsteadOfTrigger')    = 1))
                THEN 1 ELSE 0 END;

            -- TRUNCATE is refused on any table referenced by a foreign key,
            -- whether or not the referencing table holds rows.
            SET @has_inbound_fk = CASE WHEN EXISTS(
                    SELECT 1 FROM sys.foreign_keys fk WHERE fk.referenced_object_id = @obj)
                THEN 1 ELSE 0 END;

            IF @has_trigger = 0
            BEGIN
                SET @sql = N'DELETE FROM ' + @tbl + N';';
                EXEC sp_executesql @sql;
            END
            ELSE IF @has_inbound_fk = 0
            BEGIN
                -- Append-only log with nothing pointing at it: empty it with
                -- TRUNCATE, which does not fire triggers and reseeds identity.
                SET @sql = N'TRUNCATE TABLE ' + @tbl + N';';
                EXEC sp_executesql @sql;
                PRINT CONCAT(N'    ', @tbl, N' is trigger-protected -- cleared with TRUNCATE (no triggers fired).');
            END
            ELSE IF @allow_disable_immutable_triggers = 1
            BEGIN
                DECLARE trg_cur CURSOR LOCAL FAST_FORWARD FOR
                    SELECT QUOTENAME(OBJECT_SCHEMA_NAME(t.object_id)) + N'.' + QUOTENAME(t.name)
                    FROM sys.triggers t
                    WHERE t.parent_id = @obj AND t.is_disabled = 0;
                OPEN trg_cur;
                FETCH NEXT FROM trg_cur INTO @trg;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    SET @sql = N'DISABLE TRIGGER ' + @trg + N' ON ' + @tbl + N';';
                    EXEC sp_executesql @sql;
                    FETCH NEXT FROM trg_cur INTO @trg;
                END
                CLOSE trg_cur;
                DEALLOCATE trg_cur;

                SET @sql = N'DELETE FROM ' + @tbl + N';';
                EXEC sp_executesql @sql;

                SET @sql = N'ENABLE TRIGGER ALL ON ' + @tbl + N';';
                EXEC sp_executesql @sql;
                PRINT CONCAT(N'    ', @tbl, N' -- triggers disabled, deleted, re-enabled (@allow_disable_immutable_triggers = 1).');
            END
            ELSE
            BEGIN
                SELECT TOP 1 @trg = t.name
                FROM sys.triggers t
                WHERE t.parent_id = @obj AND t.is_disabled = 0;
                -- THROW takes NVARCHAR(2048), not NVARCHAR(MAX).
                SET @errmsg = CONCAT(
                    N'', @tbl, N' is protected by trigger ', @trg,
                    N' and is referenced by a foreign key, so it can be cleared neither with DELETE (the trigger raises) nor with TRUNCATE (SQL Server refuses it on a referenced table). ',
                    N'Set @allow_disable_immutable_triggers = 1 to disable the trigger for the duration of this reset, or clear the table by hand first.');
                THROW 50503, @errmsg, 1;
            END

            SET @deleted = @deleted + 1;
            UPDATE #gp SET done = 1 WHERE full_name = @tbl;
            FETCH NEXT FROM gp_cur INTO @tbl, @obj;
        END
        CLOSE gp_cur;
        DEALLOCATE gp_cur;
    END

    -- ---------------------------------------------------------------
    -- Re-enable the foreign keys.
    --
    -- WITH CHECK, not a bare CHECK: it re-validates the data and marks
    -- the constraint trusted again.  A bare CHECK CONSTRAINT would leave
    -- is_not_trusted = 1, which the query optimiser then has to assume
    -- may be violated.  Validation is free here -- the tables are empty.
    -- ---------------------------------------------------------------
    DECLARE gpfk_cur CURSOR LOCAL FAST_FORWARD FOR SELECT child_table, fk_name FROM #gpfk;
    OPEN gpfk_cur;
    FETCH NEXT FROM gpfk_cur INTO @tbl, @trg;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'ALTER TABLE ' + @tbl + N' WITH CHECK CHECK CONSTRAINT ' + @trg + N';';
        EXEC sp_executesql @sql;
        FETCH NEXT FROM gpfk_cur INTO @tbl, @trg;
    END
    CLOSE gpfk_cur;
    DEALLOCATE gpfk_cur;

    -- Nothing may be left untrusted when this transaction commits.
    IF EXISTS(SELECT 1 FROM sys.foreign_keys fk
              WHERE (fk.parent_object_id     IN (SELECT object_id FROM #gp)
                  OR fk.referenced_object_id IN (SELECT object_id FROM #gp))
                AND (fk.is_disabled = 1 OR fk.is_not_trusted = 1))
    BEGIN
        SET @errmsg = N'One or more grac_practice foreign keys are still disabled or untrusted after the reset. The transaction is being rolled back; no data was cleared.';
        THROW 50504, @errmsg, 1;
    END

    -- Reseed every identity column in the schema.
    --
    -- COMMIT MODE ONLY.  DBCC CHECKIDENT is not transactional: the ROLLBACK
    -- at the end of a dry run restores the rows but NOT the seed, which
    -- would leave the table holding ids above a seed of 0 and make the next
    -- insert collide on the primary key.  See the same guard on Part 9.
    IF @commit_cleanup = 1
    BEGIN
    DECLARE gp_seed CURSOR LOCAL FAST_FORWARD FOR
        SELECT g.full_name
        FROM #gp g
        WHERE EXISTS(SELECT 1 FROM sys.identity_columns ic WHERE ic.object_id = g.object_id);
    OPEN gp_seed;
    FETCH NEXT FROM gp_seed INTO @tbl;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'DBCC CHECKIDENT (''' + REPLACE(@tbl, N'''', N'''''') + N''', RESEED, 0) WITH NO_INFOMSGS;';
        EXEC sp_executesql @sql;
        FETCH NEXT FROM gp_seed INTO @tbl;
    END
    CLOSE gp_seed;
    DEALLOCATE gp_seed;
    END
    ELSE
        PRINT N'    grac_practice identity reseed skipped -- dry run (DBCC CHECKIDENT cannot be rolled back).';

    PRINT CONCAT(N'  grac_practice cleared: ', @deleted, N' table(s); ', @rounds, N' foreign key(s) disabled and re-enabled WITH CHECK.');
END
ELSE
    PRINT N'  grac_practice schema not present on this instance -- skipped.';

-- =====================================================================
-- PART 2.  Assurance runtime (derived from Obligations -- goes first).
-- =====================================================================
IF OBJECT_ID(N'GRAC_New.assurance_checklist_evidence','U') IS NOT NULL DELETE FROM GRAC_New.assurance_checklist_evidence;
IF OBJECT_ID(N'GRAC_New.assurance_checklist_item','U')     IS NOT NULL DELETE FROM GRAC_New.assurance_checklist_item;
IF OBJECT_ID(N'GRAC_New.assurance_event_occurrence','U')   IS NOT NULL DELETE FROM GRAC_New.assurance_event_occurrence;

-- =====================================================================
-- PART 3.  Obligation evidence links, then the evidence specs.
-- =====================================================================
IF OBJECT_ID(N'GRAC_New.obligation_state_evidence_link','U')          IS NOT NULL DELETE FROM GRAC_New.obligation_state_evidence_link;
IF OBJECT_ID(N'GRAC_New.obligation_execution_evidence_link','U')      IS NOT NULL DELETE FROM GRAC_New.obligation_execution_evidence_link;
IF OBJECT_ID(N'GRAC_New.obligation_assurance_evidence_link','U')      IS NOT NULL DELETE FROM GRAC_New.obligation_assurance_evidence_link;
IF OBJECT_ID(N'GRAC_New.obligation_event_response_evidence_link','U') IS NOT NULL DELETE FROM GRAC_New.obligation_event_response_evidence_link;
IF OBJECT_ID(N'GRAC_New.obligation_constraint_evidence_link','U')     IS NOT NULL DELETE FROM GRAC_New.obligation_constraint_evidence_link;
IF OBJECT_ID(N'GRAC_New.obligation_retention_evidence_link','U')      IS NOT NULL DELETE FROM GRAC_New.obligation_retention_evidence_link;
IF OBJECT_ID(N'GRAC_New.obligation_evidence_type','U')                IS NOT NULL DELETE FROM GRAC_New.obligation_evidence_type;
IF OBJECT_ID(N'GRAC_New.requirement_obligation_evidence','U')         IS NOT NULL DELETE FROM GRAC_New.requirement_obligation_evidence;

-- =====================================================================
-- PART 4.  Obligation type detail rows.
-- =====================================================================
IF OBJECT_ID(N'GRAC_New.obligation_state_rule','U')       IS NOT NULL DELETE FROM GRAC_New.obligation_state_rule;
IF OBJECT_ID(N'GRAC_New.obligation_execution_spec','U')   IS NOT NULL DELETE FROM GRAC_New.obligation_execution_spec;
IF OBJECT_ID(N'GRAC_New.obligation_assurance_spec','U')   IS NOT NULL DELETE FROM GRAC_New.obligation_assurance_spec;
IF OBJECT_ID(N'GRAC_New.obligation_event_response','U')   IS NOT NULL DELETE FROM GRAC_New.obligation_event_response;
IF OBJECT_ID(N'GRAC_New.obligation_constraint_rule','U')  IS NOT NULL DELETE FROM GRAC_New.obligation_constraint_rule;
IF OBJECT_ID(N'GRAC_New.obligation_retention_spec','U')   IS NOT NULL DELETE FROM GRAC_New.obligation_retention_spec;

-- =====================================================================
-- PART 5.  Obligation mappings, then the Obligation parents.
-- =====================================================================
IF OBJECT_ID(N'GRAC_New.obligation_framework_statement_map','U') IS NOT NULL DELETE FROM GRAC_New.obligation_framework_statement_map;
IF OBJECT_ID(N'GRAC_New.obligation_requirement_release_map','U') IS NOT NULL DELETE FROM GRAC_New.obligation_requirement_release_map;
IF OBJECT_ID(N'GRAC_New.requirement_obligation','U')             IS NOT NULL DELETE FROM GRAC_New.requirement_obligation;
IF OBJECT_ID(N'GRAC_New.obligation','U')                         IS NOT NULL DELETE FROM GRAC_New.obligation;

-- =====================================================================
-- PART 6.  Practice mappings, then the Practices.
--
-- framework_statement rows themselves are NOT touched -- 052 loaded the
-- 93 Annex A controls and 060 maps the new Practices onto them.
-- =====================================================================
IF OBJECT_ID(N'GRAC_New.framework_statement_requirement_map','U') IS NOT NULL DELETE FROM GRAC_New.framework_statement_requirement_map;
IF OBJECT_ID(N'GRAC_New.control_requirement_map','U')             IS NOT NULL DELETE FROM GRAC_New.control_requirement_map;
IF OBJECT_ID(N'GRAC_New.requirement','U')                         IS NOT NULL DELETE FROM GRAC_New.requirement;

-- =====================================================================
-- PART 7.  Workflow rows that referenced the deleted entities.
--
-- change_management stores entity_type / record_id loosely -- there is no
-- foreign key -- so nothing above removed these.  Left behind they would
-- show as change requests pointing at Practice and Obligation ids that no
-- longer exist.  Only the affected entity types are cleared; change
-- requests for artifacts, releases and controls are untouched.
--
-- cm_cascade_deactivation does NOT have an entity_type column.  Its shape
-- is root_entity_type / root_record_id + child_entity_type /
-- child_record_id, one row per (parent deactivated, child it dragged
-- down).  A row is in scope if EITHER end names one of our entity types.
--
-- Both statements run through sp_executesql, and each column is checked
-- with COL_LENGTH first.  See "WHY PART 7 IS DYNAMIC SQL" in the header:
-- a wrong column name in a plain statement fails the whole batch at
-- compile time, before any of the deletes above get to run, and the
-- OBJECT_ID guard does not prevent it.
-- =====================================================================
IF OBJECT_ID(N'GRAC_New.change_management','U') IS NOT NULL
   AND COL_LENGTH(N'GRAC_New.change_management', N'entity_type') IS NOT NULL
BEGIN
    IF OBJECT_ID(N'GRAC_New.change_management_field','U') IS NOT NULL
       AND COL_LENGTH(N'GRAC_New.change_management_field', N'change_request_id') IS NOT NULL
    BEGIN
        SET @sql = N'
            DELETE f
            FROM GRAC_New.change_management_field f
            JOIN GRAC_New.change_management c ON c.change_request_id = f.change_request_id
            WHERE c.entity_type IN (' + @entities + N');';
        EXEC sp_executesql @sql;
        PRINT CONCAT(N'  change_management_field rows deleted: ', @@ROWCOUNT, N'.');
    END

    SET @sql = N'DELETE FROM GRAC_New.change_management WHERE entity_type IN (' + @entities + N');';
    EXEC sp_executesql @sql;
    PRINT CONCAT(N'  change_management rows deleted: ', @@ROWCOUNT, N'.');
END
ELSE
    PRINT N'  change_management absent or has no entity_type column -- skipped.';

IF OBJECT_ID(N'GRAC_New.cm_cascade_deactivation','U') IS NOT NULL
   AND COL_LENGTH(N'GRAC_New.cm_cascade_deactivation', N'root_entity_type')  IS NOT NULL
   AND COL_LENGTH(N'GRAC_New.cm_cascade_deactivation', N'child_entity_type') IS NOT NULL
BEGIN
    SET @sql = N'
        DELETE FROM GRAC_New.cm_cascade_deactivation
        WHERE root_entity_type  IN (' + @entities + N')
           OR child_entity_type IN (' + @entities + N');';
    EXEC sp_executesql @sql;
    PRINT CONCAT(N'  cm_cascade_deactivation rows deleted: ', @@ROWCOUNT, N'.');
END
ELSE
    PRINT N'  cm_cascade_deactivation absent or has an unexpected shape -- skipped.';

-- =====================================================================
-- PART 8.  Organization master.
--
-- impact_analysis and notification carry a nullable organization_id, so
-- they are blanked rather than deleted -- the change history they belong
-- to is not part of this reset.
-- =====================================================================
IF OBJECT_ID(N'GRAC_New.impact_analysis','U') IS NOT NULL
    UPDATE GRAC_New.impact_analysis SET organization_id = NULL WHERE organization_id IS NOT NULL;
IF OBJECT_ID(N'GRAC_New.notification','U') IS NOT NULL
    UPDATE GRAC_New.notification    SET organization_id = NULL WHERE organization_id IS NOT NULL;

DELETE FROM GRAC_New.organization;

-- =====================================================================
-- PART 9.  Identity reseed -- cleared tables only.
--
-- COMMIT MODE ONLY, and this is not a nicety.  DBCC CHECKIDENT is not a
-- transactional statement: the ROLLBACK at the end of a dry run puts every
-- deleted row back but leaves the seed at 0.  requirement would then still
-- hold requirement_id 1..N while the next IDENTITY value was 1, and the
-- first insert after the dry run would fail on the primary key.
--
-- So a dry run reports what WOULD be deleted and touches no seed at all.
-- =====================================================================
IF @commit_cleanup = 1
BEGIN
IF OBJECT_ID(N'GRAC_New.assurance_checklist_evidence','U')            IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.assurance_checklist_evidence', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.assurance_checklist_item','U')                IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.assurance_checklist_item', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.assurance_event_occurrence','U')              IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.assurance_event_occurrence', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.obligation_state_evidence_link','U')          IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.obligation_state_evidence_link', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.obligation_execution_evidence_link','U')      IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.obligation_execution_evidence_link', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.obligation_assurance_evidence_link','U')      IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.obligation_assurance_evidence_link', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.obligation_event_response_evidence_link','U') IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.obligation_event_response_evidence_link', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.obligation_constraint_evidence_link','U')     IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.obligation_constraint_evidence_link', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.obligation_retention_evidence_link','U')      IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.obligation_retention_evidence_link', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.obligation_evidence_type','U')                IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.obligation_evidence_type', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.requirement_obligation_evidence','U')         IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.requirement_obligation_evidence', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.obligation_state_rule','U')                   IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.obligation_state_rule', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.obligation_execution_spec','U')               IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.obligation_execution_spec', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.obligation_assurance_spec','U')               IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.obligation_assurance_spec', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.obligation_event_response','U')               IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.obligation_event_response', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.obligation_constraint_rule','U')              IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.obligation_constraint_rule', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.obligation_retention_spec','U')               IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.obligation_retention_spec', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.obligation_framework_statement_map','U')      IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.obligation_framework_statement_map', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.obligation_requirement_release_map','U')      IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.obligation_requirement_release_map', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.requirement_obligation','U')                  IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.requirement_obligation', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.obligation','U')                              IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.obligation', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.framework_statement_requirement_map','U')     IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.framework_statement_requirement_map', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.control_requirement_map','U')                 IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.control_requirement_map', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.requirement','U')                             IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.requirement', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.change_management','U')                       IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.change_management', RESEED, 0) WITH NO_INFOMSGS;
IF OBJECT_ID(N'GRAC_New.organization','U')                            IS NOT NULL DBCC CHECKIDENT(N'GRAC_New.organization', RESEED, 0) WITH NO_INFOMSGS;
END
ELSE
    PRINT N'  Identity reseed skipped -- dry run (DBCC CHECKIDENT cannot be rolled back).';

-- ---------------------------------------------------------------
-- AFTER counts, inside the transaction.  In dry-run mode these show what
-- WOULD be left; the ROLLBACK below then restores everything.
-- ---------------------------------------------------------------
SELECT N'AFTER (in transaction)' AS Phase, N'GRAC_New.requirement' AS TableName, COUNT_BIG(1) AS [RowCount] FROM GRAC_New.requirement
UNION ALL SELECT N'AFTER (in transaction)', N'GRAC_New.requirement_obligation',              COUNT_BIG(1) FROM GRAC_New.requirement_obligation
UNION ALL SELECT N'AFTER (in transaction)', N'GRAC_New.framework_statement_requirement_map', COUNT_BIG(1) FROM GRAC_New.framework_statement_requirement_map
UNION ALL SELECT N'AFTER (in transaction)', N'GRAC_New.obligation_requirement_release_map',  COUNT_BIG(1) FROM GRAC_New.obligation_requirement_release_map
UNION ALL SELECT N'AFTER (in transaction)', N'GRAC_New.requirement_obligation_evidence',     COUNT_BIG(1) FROM GRAC_New.requirement_obligation_evidence
UNION ALL SELECT N'AFTER (in transaction)', N'GRAC_New.organization',                        COUNT_BIG(1) FROM GRAC_New.organization
UNION ALL SELECT N'STILL PRESERVED',        N'GRAC_New.framework_statement',                 COUNT_BIG(1) FROM GRAC_New.framework_statement
UNION ALL SELECT N'STILL PRESERVED',        N'GRAC_New.control',                             COUNT_BIG(1) FROM GRAC_New.control
UNION ALL SELECT N'STILL PRESERVED',        N'GRAC_New.[release]',                           COUNT_BIG(1) FROM GRAC_New.[release];

IF @commit_cleanup = 1
BEGIN
    COMMIT TRANSACTION;
    PRINT N'058 COMMITTED. Practices, Obligations and organization data cleared; identities reseeded to 0.';
    PRINT N'Next: run 059_iso27001_v13_masters.sql.';
END
ELSE
BEGIN
    ROLLBACK TRANSACTION;
    PRINT N'058 DRY RUN COMPLETE -- ROLLED BACK, nothing was deleted.';
    PRINT N'Review the count result sets, then set @commit_cleanup = 1 and run again.';
END

END TRY
BEGIN CATCH
    IF CURSOR_STATUS('local','gp_cur')  >= 0 BEGIN CLOSE gp_cur;  DEALLOCATE gp_cur;  END
    IF CURSOR_STATUS('local','gp_seed') >= 0 BEGIN CLOSE gp_seed; DEALLOCATE gp_seed; END
    IF CURSOR_STATUS('local','trg_cur')  >= 0 BEGIN CLOSE trg_cur;  DEALLOCATE trg_cur;  END
    IF CURSOR_STATUS('local','gpfk_cur') >= 0 BEGIN CLOSE gpfk_cur; DEALLOCATE gpfk_cur; END
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH
GO

-- ---------------------------------------------------------------
-- Verification -- run after committing.
--
-- All six must return 0.  Anything else means a table was missed and the
-- reload will collide with leftovers.
-- ---------------------------------------------------------------
SELECT N'requirement'                          AS TableName, COUNT_BIG(1) AS Remaining FROM GRAC_New.requirement
UNION ALL SELECT N'requirement_obligation',                   COUNT_BIG(1) FROM GRAC_New.requirement_obligation
UNION ALL SELECT N'framework_statement_requirement_map',      COUNT_BIG(1) FROM GRAC_New.framework_statement_requirement_map
UNION ALL SELECT N'obligation_requirement_release_map',       COUNT_BIG(1) FROM GRAC_New.obligation_requirement_release_map
UNION ALL SELECT N'requirement_obligation_evidence',          COUNT_BIG(1) FROM GRAC_New.requirement_obligation_evidence
UNION ALL SELECT N'organization',                             COUNT_BIG(1) FROM GRAC_New.organization;
GO

-- Confirm the identity seeds are back to 0, so the reload starts at 1.
SELECT OBJECT_SCHEMA_NAME(ic.object_id) + N'.' + OBJECT_NAME(ic.object_id) AS TableName,
       ic.name AS IdentityColumn,
       CONVERT(BIGINT, ic.last_value) AS LastValue
FROM sys.identity_columns ic
WHERE ic.object_id IN (
      OBJECT_ID(N'GRAC_New.requirement'),
      OBJECT_ID(N'GRAC_New.requirement_obligation'),
      OBJECT_ID(N'GRAC_New.framework_statement_requirement_map'),
      OBJECT_ID(N'GRAC_New.obligation_requirement_release_map'),
      OBJECT_ID(N'GRAC_New.requirement_obligation_evidence'),
      OBJECT_ID(N'GRAC_New.organization'))
ORDER BY TableName;
GO

-- What is left in grac_practice, if the schema exists here.  Expect 0 rows
-- in every table.
IF SCHEMA_ID(N'grac_practice') IS NOT NULL
BEGIN
    SELECT s.name AS SchemaName, t.name AS TableName, SUM(p.rows) AS Remaining
    FROM sys.tables t
    JOIN sys.schemas s    ON s.schema_id = t.schema_id
    JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
    WHERE s.name = N'grac_practice'
    GROUP BY s.name, t.name
    ORDER BY t.name;
END
GO
