-- =====================================================================
-- 057 rollback -- undo the Obligation -> Source Statement backfill
--
-- Deletes only the rows 057 created and only while they are still exactly
-- as it created them:
--
--     entered_by = '057-backfill'  AND  updated_dt IS NULL
--
-- The updated_dt guard is the important half.  A maker who opened the
-- Obligation Master screen and re-saved has taken ownership of that map --
-- cm_manage_repository stamps updated_by / updated_dt on every row it
-- reactivates or deactivates.  Deleting those would throw away a human
-- decision to undo a machine one.  Such rows are reported below and left
-- in place; remove them by hand only if that is genuinely intended.
--
-- Deactivated rows (status <> 'Active') are also left alone: something
-- explicitly turned them off, and deleting them would silently make them
-- eligible for a future re-run of the backfill.
--
-- After this runs, every obligation it had seeded is unmapped again, which
-- means unrestricted -- it reappears on every Practices - Obligation
-- Mapping row.  No practice-obligation mapping is affected either way:
-- this table only filters the picker, it never stores a mapping.
--
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('GRAC_New.obligation_framework_statement_map','U') IS NULL
BEGIN
    PRINT '057 rollback: GRAC_New.obligation_framework_statement_map does not exist. Nothing to do.';
    SET NOEXEC ON;
END
GO

PRINT '--- 057 rollback: backfilled rows a human has since edited (kept) ---';
GO

SELECT
    kept.ObligationId,
    Obligation = COALESCE(NULLIF(ro.obligation_name, N''),
                          LEFT(ro.obligation_text, 120)),
    kept.KeptRows
FROM (
    SELECT m.obligation_id AS ObligationId, COUNT(*) AS KeptRows
    FROM GRAC_New.obligation_framework_statement_map m
    WHERE m.entered_by = N'057-backfill'
      AND (m.updated_dt IS NOT NULL OR m.status <> N'Active')
    GROUP BY m.obligation_id
) kept
JOIN GRAC_New.requirement_obligation ro ON ro.obligation_id = kept.ObligationId
ORDER BY kept.KeptRows DESC, kept.ObligationId;
GO

DELETE FROM GRAC_New.obligation_framework_statement_map
WHERE entered_by = N'057-backfill'
  AND updated_dt IS NULL
  AND status = N'Active';

PRINT CONCAT('057 rollback: deleted ', @@ROWCOUNT, ' untouched backfill row(s).');
GO

SELECT
    remaining_backfill_rows =
        (SELECT COUNT(*) FROM GRAC_New.obligation_framework_statement_map
         WHERE entered_by = N'057-backfill'),
    obligations_still_mapped =
        (SELECT COUNT(DISTINCT obligation_id)
         FROM GRAC_New.obligation_framework_statement_map WHERE status = N'Active');
GO

SET NOEXEC OFF;
GO
