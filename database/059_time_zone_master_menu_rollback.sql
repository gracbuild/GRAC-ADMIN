/* ================================================================
   Rollback for 059_time_zone_master_menu.sql
   ================================================================ */

DELETE srp
FROM GRAC_New.security_role_permission srp
JOIN GRAC_New.security_permission sp ON sp.security_permission_id = srp.security_permission_id
WHERE sp.area_key = 'time-zone-master';
GO

DELETE FROM GRAC_New.security_permission WHERE area_key = 'time-zone-master';
GO

DELETE crp
FROM GRAC_New.cm_role_permission crp
JOIN GRAC_New.cm_menu m ON m.menu_id = crp.menu_id
WHERE m.menu_code = N'time-zone-master';
GO

DELETE FROM GRAC_New.cm_menu WHERE menu_code = N'time-zone-master';
GO

PRINT 'Migration 059_time_zone_master_menu rolled back.';
GO
