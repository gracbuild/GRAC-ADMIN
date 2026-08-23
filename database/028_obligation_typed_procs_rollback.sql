-- =====================================================================
-- 028 Obligation typed procs -- ROLLBACK
--
-- Drops the 17 stored procedures created by 028_obligation_typed_procs.sql.
-- Schema (tables) is untouched -- that is 026's responsibility.
--
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.sp_cm_obligation_type_master_list','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_obligation_type_master_list;
GO
IF OBJECT_ID('dbo.sp_cm_obligation_type_assign','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_obligation_type_assign;
GO

IF OBJECT_ID('dbo.sp_cm_obligation_state_get','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_obligation_state_get;
GO
IF OBJECT_ID('dbo.sp_cm_obligation_state_save','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_obligation_state_save;
GO

IF OBJECT_ID('dbo.sp_cm_obligation_execution_get','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_obligation_execution_get;
GO
IF OBJECT_ID('dbo.sp_cm_obligation_execution_save','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_obligation_execution_save;
GO

IF OBJECT_ID('dbo.sp_cm_obligation_assurance_get','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_obligation_assurance_get;
GO
IF OBJECT_ID('dbo.sp_cm_obligation_assurance_save','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_obligation_assurance_save;
GO

IF OBJECT_ID('dbo.sp_cm_obligation_event_response_get','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_obligation_event_response_get;
GO
IF OBJECT_ID('dbo.sp_cm_obligation_event_response_save','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_obligation_event_response_save;
GO

IF OBJECT_ID('dbo.sp_cm_obligation_constraint_get','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_obligation_constraint_get;
GO
IF OBJECT_ID('dbo.sp_cm_obligation_constraint_save','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_obligation_constraint_save;
GO

IF OBJECT_ID('dbo.sp_cm_obligation_retention_get','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_obligation_retention_get;
GO
IF OBJECT_ID('dbo.sp_cm_obligation_retention_save','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_obligation_retention_save;
GO

IF OBJECT_ID('dbo.sp_cm_obligation_evidence_links_get','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_obligation_evidence_links_get;
GO
IF OBJECT_ID('dbo.sp_cm_obligation_evidence_link_attach','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_obligation_evidence_link_attach;
GO
IF OBJECT_ID('dbo.sp_cm_obligation_evidence_link_detach','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_obligation_evidence_link_detach;
GO

PRINT '028 obligation typed procs rollback complete.';
GO
