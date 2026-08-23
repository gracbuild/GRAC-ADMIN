/* ================================================================
   Rollback for 043_sla_master_menu.sql
   Removes the SLA Master menu entry, its cm_role_permission rows,
   its security_role_permission rows and its security_permission
   rows.  Leaves the Assurance Management parent intact.
   ================================================================ */

DELETE srp
FROM GRAC_New.security_role_permission srp
JOIN GRAC_New.security_permission sp ON sp.security_permission_id = srp.security_permission_id
WHERE sp.area_key = 'sla-master';
GO

DELETE FROM GRAC_New.security_permission WHERE area_key = 'sla-master';
GO

DELETE crp
FROM GRAC_New.cm_role_permission crp
JOIN GRAC_New.cm_menu m ON m.menu_id = crp.menu_id
WHERE m.menu_code = N'sla-master';
GO

DELETE FROM GRAC_New.cm_menu WHERE menu_code = N'sla-master';
GO

PRINT 'Migration 043_sla_master_menu rolled back.';
GO
