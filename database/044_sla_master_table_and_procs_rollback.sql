/* ================================================================
   Rollback for 044_sla_master_table_and_procs.sql
   Drops procs, unique index and the sla_master table.
   ================================================================ */

IF OBJECT_ID('dbo.cm_manage_sla_master','P') IS NOT NULL DROP PROCEDURE dbo.cm_manage_sla_master;
GO
IF OBJECT_ID('dbo.cm_get_sla_master','P')    IS NOT NULL DROP PROCEDURE dbo.cm_get_sla_master;
GO

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'uq_sla_master_process_class_active' AND object_id = OBJECT_ID('GRAC_New.sla_master'))
    DROP INDEX uq_sla_master_process_class_active ON GRAC_New.sla_master;
GO

IF OBJECT_ID('GRAC_New.sla_master','U') IS NOT NULL DROP TABLE GRAC_New.sla_master;
GO

PRINT 'Migration 044_sla_master_table_and_procs rolled back.';
GO
