-- =====================================================================
-- 027 -- Obligation Taxonomy (Phase 1: DATA MIGRATION)
--
-- Depends on 026_obligation_taxonomy_schema.sql having been applied first.
--
-- This script performs three additive data operations.  No rows are
-- deleted; no columns are dropped.
--
--   Step 1: Seed obligation_type_master with the 7 atomic types.
--
--   Step 2: Back-fill obligation_type_id = 'Execution' on every existing
--           requirement_obligation row that has no type yet.  Rationale:
--           the pre-taxonomy model treated obligations as "something
--           executed on a schedule that produces evidence" -- that is
--           semantically 'Execution' in the new taxonomy.
--
--   Step 3: For every existing (obligation_id, obligation_evidence_id)
--           pair in requirement_obligation_evidence, create an equivalent
--           row in obligation_execution_evidence_link so the M:M model
--           reflects what today's 1:M model asserts.  Tagged
--           entered_by='migration-027' for auditability and rollback.
--
--   Step 4: For every requirement_obligation row whose retention_requirement
--           is non-empty, seed one obligation_retention_spec row capturing
--           the retention text as retained_object='General'.  This is a
--           coarse first-pass so retention data isn't lost -- sir / SMEs
--           can refine per obligation later.
--
-- Note: Nothing here classifies existing obligations as State, Constraint,
-- Assurance, Event Response, or standalone Evidence.  Those are semantic
-- classifications the SME must make; the migration only preserves what
-- the pre-taxonomy schema unambiguously encoded (Execution + implicit
-- Retention).
--
-- Rollback: database/027_obligation_taxonomy_migration_rollback.sql
--
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('GRAC_New.obligation_type_master','U') IS NULL
    THROW 52700, '027 preflight failed: run 026_obligation_taxonomy_schema.sql first.', 1;
GO
IF OBJECT_ID('GRAC_New.obligation_execution_evidence_link','U') IS NULL
    THROW 52701, '027 preflight failed: obligation_execution_evidence_link missing.  Run 026 first.', 1;
GO
IF OBJECT_ID('GRAC_New.obligation_retention_spec','U') IS NULL
    THROW 52702, '027 preflight failed: obligation_retention_spec missing.  Run 026 first.', 1;
GO
IF COL_LENGTH('GRAC_New.requirement_obligation','obligation_type_id') IS NULL
    THROW 52703, '027 preflight failed: requirement_obligation.obligation_type_id missing.  Run 026 first.', 1;
GO

-- =====================================================================
-- Step 1: Seed obligation_type_master (7 atomic types).
-- =====================================================================
;WITH seed(type_code, type_name, description, display_order) AS (
    SELECT N'State',         N'State',
           N'What must be or continue to be true (e.g. password length >= 12).', 10 UNION ALL
    SELECT N'Execution',     N'Execution',
           N'What must be done and when (scheduled or triggered action).', 20 UNION ALL
    SELECT N'Assurance',     N'Assurance',
           N'What must be verified and when (audit / review / test).', 30 UNION ALL
    SELECT N'EventResponse', N'Event Response',
           N'If X occurs, what must happen and by when (SLA-bound response).', 40 UNION ALL
    SELECT N'Constraint',    N'Constraint',
           N'What boundary or prohibition must never be violated.', 50 UNION ALL
    SELECT N'Evidence',      N'Evidence',
           N'What proves fulfilment (standalone evidence obligation).', 60 UNION ALL
    SELECT N'Retention',     N'Retention',
           N'What must be preserved and for how long.', 70
)
MERGE GRAC_New.obligation_type_master AS tgt
USING seed AS src
    ON tgt.type_code = src.type_code
WHEN MATCHED THEN UPDATE SET
    tgt.type_name     = src.type_name,
    tgt.description   = src.description,
    tgt.display_order = src.display_order,
    tgt.status        = N'Active',
    tgt.updated_by    = N'migration-027',
    tgt.updated_dt    = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT(type_code, type_name, description, display_order, status, entered_by)
    VALUES(src.type_code, src.type_name, src.description, src.display_order, N'Active', N'migration-027');
GO

-- =====================================================================
-- Step 2: Back-fill obligation_type_id = 'Execution' on legacy rows.
--         Only rows that currently have NULL are touched -- if sir has
--         already re-classified some obligations by hand, they are left
--         alone.
-- =====================================================================
DECLARE @exec_type_id BIGINT =
    (SELECT obligation_type_id FROM GRAC_New.obligation_type_master
     WHERE type_code = N'Execution');

IF @exec_type_id IS NULL
    THROW 52704, '027 Step 2 failed: Execution type_code not found in obligation_type_master after seed.', 1;

UPDATE GRAC_New.requirement_obligation
SET obligation_type_id = @exec_type_id,
    updated_by = N'migration-027',
    updated_dt = SYSUTCDATETIME()
WHERE obligation_type_id IS NULL
  AND status = N'Active';
GO

-- =====================================================================
-- Step 3: Back-fill obligation_execution_evidence_link from every
--         existing active (obligation_id, obligation_evidence_id) pair
--         in requirement_obligation_evidence.
--         Skipped if the link already exists (re-run safe).
-- =====================================================================
INSERT INTO GRAC_New.obligation_execution_evidence_link(
    obligation_id, obligation_evidence_id, remarks, status, entered_by
)
SELECT
    e.obligation_id,
    e.obligation_evidence_id,
    N'Auto-linked by migration-027 from legacy 1:M model.',
    N'Active',
    N'migration-027'
FROM GRAC_New.requirement_obligation_evidence e
JOIN GRAC_New.requirement_obligation o
    ON o.obligation_id = e.obligation_id AND o.status = N'Active'
WHERE e.obligation_id IS NOT NULL
  AND e.status = N'Active'
  AND NOT EXISTS(
        SELECT 1 FROM GRAC_New.obligation_execution_evidence_link l
        WHERE l.obligation_id          = e.obligation_id
          AND l.obligation_evidence_id = e.obligation_evidence_id
          AND l.status                 = N'Active'
  );
GO

-- =====================================================================
-- Step 4: For every requirement_obligation whose retention_requirement
--         is non-empty, seed one coarse obligation_retention_spec row.
--         retained_object is defaulted to 'General' -- SMEs refine later.
--         Skipped if a retention spec already exists for that obligation.
-- =====================================================================
INSERT INTO GRAC_New.obligation_retention_spec(
    obligation_id, retained_object, remarks, status, entered_by
)
SELECT
    o.obligation_id,
    N'General',
    o.retention_requirement,
    N'Active',
    N'migration-027'
FROM GRAC_New.requirement_obligation o
WHERE o.status = N'Active'
  AND NULLIF(LTRIM(RTRIM(o.retention_requirement)), N'') IS NOT NULL
  AND NOT EXISTS(
        SELECT 1 FROM GRAC_New.obligation_retention_spec r
        WHERE r.obligation_id = o.obligation_id
          AND r.status        = N'Active'
  );
GO

-- =====================================================================
-- Sanity report.
-- =====================================================================
SELECT 'obligation_type_master rows'                          AS Item, COUNT_BIG(1) AS [Count]
FROM GRAC_New.obligation_type_master
UNION ALL
SELECT 'requirement_obligation rows with obligation_type_id back-filled',
       COUNT_BIG(1) FROM GRAC_New.requirement_obligation WHERE obligation_type_id IS NOT NULL
UNION ALL
SELECT 'requirement_obligation rows still un-classified (obligation_type_id IS NULL)',
       COUNT_BIG(1) FROM GRAC_New.requirement_obligation WHERE obligation_type_id IS NULL
UNION ALL
SELECT 'obligation_execution_evidence_link rows created by migration-027',
       COUNT_BIG(1) FROM GRAC_New.obligation_execution_evidence_link WHERE entered_by = N'migration-027'
UNION ALL
SELECT 'obligation_retention_spec rows seeded by migration-027',
       COUNT_BIG(1) FROM GRAC_New.obligation_retention_spec WHERE entered_by = N'migration-027';
GO

PRINT '027 obligation taxonomy migration complete.  Review sanity counts above.';
PRINT 'Phase 2 (consumer procs, API, UI in both Control Management and Practice Management) not yet applied.';
GO
