-- =====================================================================
-- 030 ROLLBACK -- restore cm_manage_obligation_taxonomy to the pre-030
-- shape (equivalent to what 029 installed: @p_action only, no payload
-- override).  Re-run 029 after this if you need the original body.
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO
PRINT '030 rollback: re-run 029_obligation_taxonomy_dispatcher.sql to restore the prior dispatcher shape.';
GO
