/* ================================================================
   Migration 043 -- SLA Master menu + permission seed
   ----------------------------------------------------------------
   Adds the "SLA Master" navigation entry under Assurance Management
   and wires the standard maker-checker permission matrix so the
   Views/Repository/SlaMasterForm view is reachable from the sidebar.

   Backing table (sla_master) and its procedures are NOT created by
   this migration -- this file only wires the UI menu + role
   permissions.  The form loads and menu renders regardless; API
   wiring lands in a follow-up migration once schema is finalised.

   Idempotent: safe to run multiple times.  Rollback file:
   database/043_sla_master_menu_rollback.sql
   ================================================================ */

/* Ensure the Assurance Management parent exists.  If migration 024
   was already applied this is a no-op; if this migration is run in
   an environment where 024 has not been executed, we create the
   parent so the child MERGE below has something to attach to. */
IF NOT EXISTS (SELECT 1 FROM GRAC_New.cm_menu WHERE menu_code=N'assurance-management')
BEGIN
    INSERT GRAC_New.cm_menu(parent_menu_id,menu_name,menu_code,route_url,display_order,icon,status,entered_by)
    VALUES(NULL, N'Assurance Management', N'assurance-management', NULL, 400, N'clipboard-check', N'Active', N'system');
END
GO

/* Register the SLA Master child menu.
   display_order 455 sits between Workflow Templates (450) and
   Question Types (460) so the sidebar reads logically:
   Workflow Templates -> SLA Master -> Question Types. */
MERGE GRAC_New.cm_menu AS target
USING (
    SELECT p.menu_id AS parent_menu_id,
           N'SLA Master' AS menu_name,
           N'sla-master' AS menu_code,
           N'Repository/Index?areaKey=sla-master' AS route_url,
           455 AS display_order,
           N'stopwatch' AS icon
    FROM GRAC_New.cm_menu p
    WHERE p.menu_code = N'assurance-management'
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

/* Role -> menu permission grid (cm_role_permission).
   Mirrors the pattern used for the Assurance Management children in
   migration 024:
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
      AND m.menu_code = N'sla-master'
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

/* Legacy area-key permissions used by PermissionPolicy in the web tier.
   Grants VIEW/ADD/EDIT/INACTIVE against 'sla-master' so
   RepositoryController.SlaMaster's requiredAction switch resolves. */
MERGE GRAC_New.security_permission AS target
USING (
    SELECT N'sla-master' AS area_key, action_code, N'sla-master '+action_code AS permission_name
    FROM (VALUES ('VIEW'),('ADD'),('EDIT'),('INACTIVE'),('DELETE'),('APPROVE'),('REJECT')) a(action_code)
) AS source
ON target.area_key = source.area_key AND target.action_code = source.action_code
WHEN NOT MATCHED THEN INSERT(area_key,action_code,permission_name,entered_by)
    VALUES(source.area_key,source.action_code,source.permission_name,'system');
GO

/* CM_ADMIN -> every sla-master permission. */
INSERT GRAC_New.security_role_permission(security_role_id,security_permission_id,entered_by)
SELECT r.security_role_id, p.security_permission_id, 'system'
FROM GRAC_New.security_role r
CROSS JOIN GRAC_New.security_permission p
WHERE r.role_code = 'CM_ADMIN'
  AND p.area_key = 'sla-master'
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
  AND p.area_key = 'sla-master'
  AND p.action_code = 'VIEW'
  AND NOT EXISTS (
      SELECT 1 FROM GRAC_New.security_role_permission x
      WHERE x.security_role_id = r.security_role_id
        AND x.security_permission_id = p.security_permission_id);
GO

/* CM_REVIEWER additionally gets EDIT to submit changes for review. */
INSERT GRAC_New.security_role_permission(security_role_id,security_permission_id,entered_by)
SELECT r.security_role_id, p.security_permission_id, 'system'
FROM GRAC_New.security_role r
CROSS JOIN GRAC_New.security_permission p
WHERE r.role_code = 'CM_REVIEWER'
  AND p.area_key = 'sla-master'
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
  AND p.area_key = 'sla-master'
  AND p.action_code = 'APPROVE'
  AND NOT EXISTS (
      SELECT 1 FROM GRAC_New.security_role_permission x
      WHERE x.security_role_id = r.security_role_id
        AND x.security_permission_id = p.security_permission_id);
GO

PRINT 'Migration 043_sla_master_menu applied.';
GO
