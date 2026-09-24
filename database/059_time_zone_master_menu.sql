/* ================================================================
   Migration 059 -- Time Zone Master menu + permission seed
   ----------------------------------------------------------------
   Adds the "Time Zone Master" navigation entry under Security
   Administration (alongside User/Role/Menu Management -- it is
   global platform reference data, not something any one
   organisation owns) and wires the standard maker-checker
   permission matrix, following 043_sla_master_menu.sql exactly.

   Backing table/procs are created by 058, which must run first.

   Idempotent: safe to run multiple times.
   Rollback: database/059_time_zone_master_menu_rollback.sql
   ================================================================ */

IF NOT EXISTS (SELECT 1 FROM GRAC_New.cm_menu WHERE menu_code = N'security-administration')
BEGIN
    RAISERROR('059: security-administration parent menu missing. Run 005 first.', 16, 1);
    RETURN;
END
GO

/* Register the Time Zone Master child menu.
   display_order 245 sits between Role Permission Management (240)
   and Change Management (300), inside Security Administration. */
MERGE GRAC_New.cm_menu AS target
USING (
    SELECT p.menu_id AS parent_menu_id,
           N'Time Zone Master' AS menu_name,
           N'time-zone-master' AS menu_code,
           N'Repository/Index?areaKey=time-zone-master' AS route_url,
           245 AS display_order,
           N'clock' AS icon
    FROM GRAC_New.cm_menu p
    WHERE p.menu_code = N'security-administration'
) AS source
ON target.menu_code = source.menu_code
WHEN MATCHED THEN UPDATE SET
    parent_menu_id = source.parent_menu_id,
    menu_name      = source.menu_name,
    route_url      = source.route_url,
    display_order  = source.display_order,
    icon           = source.icon,
    status         = N'Active'
WHEN NOT MATCHED THEN INSERT(parent_menu_id,menu_name,menu_code,route_url,display_order,icon,status,entered_by)
    VALUES(source.parent_menu_id,source.menu_name,source.menu_code,source.route_url,source.display_order,source.icon,N'Active',N'system');
GO

/* Role -> menu permission grid (cm_role_permission). Same matrix as
   SLA Master (043):
     CM_ADMIN    : view + add + edit + inactive + approve
     CM_REVIEWER : view + edit
     CM_APPROVER : view + approve
     CM_USER     : view only */
MERGE GRAC_New.cm_role_permission AS target
USING (
    SELECT r.role_id,
           m.menu_id,
           CAST(1 AS BIT) AS can_view,
           CAST(CASE WHEN r.role_name = 'CM_ADMIN' THEN 1 ELSE 0 END AS BIT) AS can_add,
           CAST(CASE WHEN r.role_name IN ('CM_ADMIN','CM_REVIEWER') THEN 1 ELSE 0 END AS BIT) AS can_edit,
           CAST(CASE WHEN r.role_name = 'CM_ADMIN' THEN 1 ELSE 0 END AS BIT) AS can_inactive,
           CAST(CASE WHEN r.role_name IN ('CM_ADMIN','CM_APPROVER') THEN 1 ELSE 0 END AS BIT) AS can_approve
    FROM GRAC_New.cm_role r
    CROSS JOIN GRAC_New.cm_menu m
    WHERE r.role_name IN ('CM_ADMIN','CM_REVIEWER','CM_APPROVER','CM_USER')
      AND m.menu_code = N'time-zone-master'
) AS source
ON target.role_id = source.role_id AND target.menu_id = source.menu_id
WHEN MATCHED THEN UPDATE SET
    can_view     = source.can_view,
    can_add      = source.can_add,
    can_edit     = source.can_edit,
    can_inactive = source.can_inactive,
    can_approve  = source.can_approve,
    status       = 'Active'
WHEN NOT MATCHED THEN INSERT(role_id,menu_id,can_view,can_add,can_edit,can_inactive,can_approve,status,entered_by)
    VALUES(source.role_id,source.menu_id,source.can_view,source.can_add,source.can_edit,source.can_inactive,source.can_approve,'Active','system');
GO

/* Legacy area-key permissions used by PermissionPolicy in the web tier
   (RepositoryController.Index resolves permissionPolicy.IsAllowed(Roles(),
   screen.Key, action) against these). */
MERGE GRAC_New.security_permission AS target
USING (
    SELECT N'time-zone-master' AS area_key, action_code, N'time-zone-master '+action_code AS permission_name
    FROM (VALUES ('VIEW'),('ADD'),('EDIT'),('INACTIVE'),('DELETE'),('APPROVE'),('REJECT')) a(action_code)
) AS source
ON target.area_key = source.area_key AND target.action_code = source.action_code
WHEN NOT MATCHED THEN INSERT(area_key,action_code,permission_name,entered_by)
    VALUES(source.area_key,source.action_code,source.permission_name,'system');
GO

/* CM_ADMIN -> every time-zone-master permission. */
INSERT GRAC_New.security_role_permission(security_role_id,security_permission_id,entered_by)
SELECT r.security_role_id, p.security_permission_id, 'system'
FROM GRAC_New.security_role r
CROSS JOIN GRAC_New.security_permission p
WHERE r.role_code = 'CM_ADMIN'
  AND p.area_key = 'time-zone-master'
  AND NOT EXISTS (
      SELECT 1 FROM GRAC_New.security_role_permission x
      WHERE x.security_role_id = r.security_role_id
        AND x.security_permission_id = p.security_permission_id);
GO

/* CM_REVIEWER / CM_APPROVER / CM_USER -> VIEW only. */
INSERT GRAC_New.security_role_permission(security_role_id,security_permission_id,entered_by)
SELECT r.security_role_id, p.security_permission_id, 'system'
FROM GRAC_New.security_role r
CROSS JOIN GRAC_New.security_permission p
WHERE r.role_code IN ('CM_REVIEWER','CM_APPROVER','CM_USER')
  AND p.area_key = 'time-zone-master'
  AND p.action_code = 'VIEW'
  AND NOT EXISTS (
      SELECT 1 FROM GRAC_New.security_role_permission x
      WHERE x.security_role_id = r.security_role_id
        AND x.security_permission_id = p.security_permission_id);
GO

/* CM_REVIEWER additionally gets EDIT. */
INSERT GRAC_New.security_role_permission(security_role_id,security_permission_id,entered_by)
SELECT r.security_role_id, p.security_permission_id, 'system'
FROM GRAC_New.security_role r
CROSS JOIN GRAC_New.security_permission p
WHERE r.role_code = 'CM_REVIEWER'
  AND p.area_key = 'time-zone-master'
  AND p.action_code = 'EDIT'
  AND NOT EXISTS (
      SELECT 1 FROM GRAC_New.security_role_permission x
      WHERE x.security_role_id = r.security_role_id
        AND x.security_permission_id = p.security_permission_id);
GO

/* CM_APPROVER additionally gets APPROVE. */
INSERT GRAC_New.security_role_permission(security_role_id,security_permission_id,entered_by)
SELECT r.security_role_id, p.security_permission_id, 'system'
FROM GRAC_New.security_role r
CROSS JOIN GRAC_New.security_permission p
WHERE r.role_code = 'CM_APPROVER'
  AND p.area_key = 'time-zone-master'
  AND p.action_code = 'APPROVE'
  AND NOT EXISTS (
      SELECT 1 FROM GRAC_New.security_role_permission x
      WHERE x.security_role_id = r.security_role_id
        AND x.security_permission_id = p.security_permission_id);
GO

PRINT 'Migration 059_time_zone_master_menu applied.';
GO
