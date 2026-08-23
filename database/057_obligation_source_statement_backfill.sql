-- =====================================================================
-- 057 -- Backfill Obligation -> Source Statement mappings
--
-- Why
-- ---
-- 056 gave obligations a source statement map but left it empty, which is
-- correct as a default: an obligation with no statements is unrestricted
-- and keeps appearing on every Practices - Obligation Mapping row, so
-- nothing broke.  It also means the new filter does nothing until somebody
-- populates the map, and populating it by hand for an existing library is
-- not realistic.
--
-- It does not have to be done by hand.  Migration 021 added
-- framework_statement_id to obligation_requirement_release_map, so every
-- Practice-Obligation mapping made since then ALREADY records which
-- statement the obligation was attached to.  That is the same fact 056
-- wants, recorded from the other direction:
--
--     obligation_requirement_release_map
--       (obligation_id, requirement_id, release_id, framework_statement_id)
--                  |
--                  |  project away practice and release, de-duplicate
--                  v
--     obligation_framework_statement_map
--       (obligation_id, framework_statement_id)
--
-- So the backfill is a projection of existing data, not a guess.  An
-- obligation ends up declared against exactly the statements it is already
-- in use against, which is the most defensible starting position: running
-- this script cannot make any current Practice-Obligation mapping
-- un-selectable, because every statement that produced a row here is a
-- statement the obligation is already mapped on.
--
-- What it does NOT do
-- -------------------
-- This is a ONE-TIME CATCH-UP, not a sync.
--
--   * An obligation that ALREADY has at least one active source statement
--     is skipped entirely.  Somebody curated that set on the Obligation
--     Master screen and the backfill has no business adding to it.  This
--     guard is also what makes the script safe to re-run.
--   * Mapping rows created BEFORE migration 021 carry
--     framework_statement_id = NULL.  There is no statement recorded, so
--     nothing can be derived -- those obligations stay unmapped (and
--     therefore unrestricted).  Section 3 lists them so they can be
--     finished by hand if wanted.
--   * Later Practice-Obligation mappings do not flow back here.  Once an
--     obligation has a map, the Obligation Master screen owns it.
--
-- Rows written by this script are stamped entered_by = '057-backfill' so
-- the rollback can remove exactly what it created and nothing a human has
-- touched since.
--
-- Preflight: 056 (obligation_framework_statement_map), 021
--            (obligation_requirement_release_map.framework_statement_id).
--
-- Rollback: database/057_obligation_source_statement_backfill_rollback.sql
--
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('GRAC_New.obligation_framework_statement_map','U') IS NULL
BEGIN
    RAISERROR('057 preflight failed: GRAC_New.obligation_framework_statement_map is missing. Run 056 first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('GRAC_New.obligation_requirement_release_map','framework_statement_id') IS NULL
BEGIN
    RAISERROR('057 preflight failed: obligation_requirement_release_map.framework_statement_id is missing. Run 021 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. Before: what is derivable, and what is not
--
-- Printed before anything is written so the numbers can be compared with
-- section 4 afterwards.  Nothing here modifies data.
-- ---------------------------------------------------------------------
PRINT '--- 057 before ---';
GO

SELECT
    obligations_total =
        (SELECT COUNT(*) FROM GRAC_New.requirement_obligation),
    obligations_already_mapped =
        (SELECT COUNT(DISTINCT obligation_id)
         FROM GRAC_New.obligation_framework_statement_map WHERE status = N'Active'),
    obligations_derivable =
        (SELECT COUNT(DISTINCT m.obligation_id)
         FROM GRAC_New.obligation_requirement_release_map m
         WHERE m.status = N'Active' AND m.framework_statement_id IS NOT NULL),
    pairs_derivable =
        (SELECT COUNT(*) FROM (
            SELECT DISTINCT m.obligation_id, m.framework_statement_id
            FROM GRAC_New.obligation_requirement_release_map m
            WHERE m.status = N'Active' AND m.framework_statement_id IS NOT NULL) d);
GO

-- ---------------------------------------------------------------------
-- 2. The backfill
--
-- One set-based INSERT.  Three things are being enforced at once and each
-- matters:
--
--   * DISTINCT collapses the many (practice, release) rows an obligation
--     has against one statement into the single pair this table stores.
--   * The NOT EXISTS on obligation_framework_statement_map is the re-run
--     guard AND the "leave curated sets alone" guard: it tests the whole
--     obligation, not the pair, so an obligation that already has any
--     active statement is skipped wholesale rather than topped up.
--   * The JOIN to framework_statement is not decoration.  The FK would
--     catch a missing statement, but a statement that exists in a state
--     this application treats as gone (Retired / Inactive) would pass the
--     FK and quietly seed a mapping to something no screen will show.
-- ---------------------------------------------------------------------
INSERT GRAC_New.obligation_framework_statement_map(
    obligation_id, framework_statement_id, status, entered_by)
SELECT DISTINCT
    m.obligation_id,
    m.framework_statement_id,
    N'Active',
    N'057-backfill'
FROM GRAC_New.obligation_requirement_release_map m
JOIN GRAC_New.framework_statement fs
  ON fs.framework_statement_id = m.framework_statement_id
 AND fs.status IN (N'Active', N'Published', N'Draft')
JOIN GRAC_New.requirement_obligation ro
  ON ro.obligation_id = m.obligation_id
WHERE m.status = N'Active'
  AND m.framework_statement_id IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM GRAC_New.obligation_framework_statement_map existing
      WHERE existing.obligation_id = m.obligation_id
        AND existing.status = N'Active');

PRINT CONCAT('057: inserted ', @@ROWCOUNT, ' obligation -> statement mapping row(s).');
GO

-- ---------------------------------------------------------------------
-- 3. What could not be derived
--
-- Obligations that are mapped to a Practice / Release but whose mapping
-- rows predate migration 021 and therefore name no statement.  These are
-- not errors and need no action: an obligation with no source statement
-- stays unrestricted and behaves exactly as it did before 056.  The list
-- exists so the gap is visible rather than assumed, and so somebody can
-- finish them on the Obligation Master screen if the filtering is wanted
-- for them too.
-- ---------------------------------------------------------------------
PRINT '--- 057 not derivable (mapped to a practice, but no statement recorded) ---';
GO

-- Aggregated in a derived table keyed on obligation_id alone, then joined
-- for the label.  Grouping by the name columns directly would put
-- obligation_text -- an NVARCHAR(MAX) -- in the GROUP BY for no reason.
SELECT
    gap.ObligationId,
    Obligation = COALESCE(NULLIF(ro.obligation_name, N''),
                          LEFT(ro.obligation_text, 120)),
    Status = ro.status,
    gap.StatementLessMappings
FROM (
    SELECT m.obligation_id AS ObligationId,
           COUNT(*)        AS StatementLessMappings
    FROM GRAC_New.obligation_requirement_release_map m
    WHERE m.status = N'Active'
      AND m.framework_statement_id IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM GRAC_New.obligation_framework_statement_map existing
          WHERE existing.obligation_id = m.obligation_id
            AND existing.status = N'Active')
    GROUP BY m.obligation_id
) gap
JOIN GRAC_New.requirement_obligation ro ON ro.obligation_id = gap.ObligationId
ORDER BY gap.StatementLessMappings DESC, gap.ObligationId;
GO

-- ---------------------------------------------------------------------
-- 4. After
--
-- unmapped_obligations is expected to be greater than zero and is not a
-- failure: obligations never mapped to a practice have nothing to derive
-- from, and unmapped means unrestricted.
-- ---------------------------------------------------------------------
PRINT '--- 057 after ---';
GO

SELECT
    obligations_total =
        (SELECT COUNT(*) FROM GRAC_New.requirement_obligation),
    obligations_mapped =
        (SELECT COUNT(DISTINCT obligation_id)
         FROM GRAC_New.obligation_framework_statement_map WHERE status = N'Active'),
    unmapped_obligations =
        (SELECT COUNT(*) FROM GRAC_New.requirement_obligation ro
         WHERE NOT EXISTS (
             SELECT 1 FROM GRAC_New.obligation_framework_statement_map m
             WHERE m.obligation_id = ro.obligation_id AND m.status = N'Active')),
    rows_written_by_backfill =
        (SELECT COUNT(*) FROM GRAC_New.obligation_framework_statement_map
         WHERE entered_by = N'057-backfill');
GO

PRINT '057 complete.';
PRINT '  Obligations with a source statement map are now filtered by release on';
PRINT '  Practices - Obligation Mapping.  Obligations still unmapped are unrestricted.';
PRINT '  Re-running this script skips every obligation that already has a map.';
GO

SET NOEXEC OFF;
GO
