-- =====================================================================
-- 029 Obligation taxonomy dispatcher -- ROLLBACK
--
-- Drops the two dispatcher procs created by 029.  Sub-procs (from 028)
-- remain in place -- roll them back via 028 rollback if desired.
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.cm_get_obligation_taxonomy','P') IS NOT NULL
    DROP PROCEDURE dbo.cm_get_obligation_taxonomy;
GO
IF OBJECT_ID('dbo.cm_manage_obligation_taxonomy','P') IS NOT NULL
    DROP PROCEDURE dbo.cm_manage_obligation_taxonomy;
GO

PRINT '029 obligation taxonomy dispatcher rollback complete.';
GO
