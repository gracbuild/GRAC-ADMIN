/* ================================================================
   Rollback for 058_time_zone_master_table_and_procs.sql
   Drops procs and the time_zone_master table (and its seed rows
   with it).
   ================================================================ */

IF OBJECT_ID('dbo.cm_manage_time_zone_master','P') IS NOT NULL DROP PROCEDURE dbo.cm_manage_time_zone_master;
GO
IF OBJECT_ID('dbo.cm_get_time_zone_master','P')    IS NOT NULL DROP PROCEDURE dbo.cm_get_time_zone_master;
GO

IF OBJECT_ID('GRAC_New.time_zone_master','U') IS NOT NULL DROP TABLE GRAC_New.time_zone_master;
GO

PRINT 'Migration 058_time_zone_master_table_and_procs rolled back.';
GO
