/*
  GRAC Repository Management - Part 020
  Front-end and master support for the new Obligation Master + Obligation
  Mapping screens.  Adds the new module to cm_entity_master and a sidebar
  menu row under Repository Management.

  This script does NOT change cm_user / cm_role_permission.  An admin must
  grant View/Add/Edit/Inactive/Approve on the new 'obligation-mappings' menu
  via Access Administration -> Role Permission Management.

  Safe to re-run.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF SCHEMA_ID('GRAC_New') IS NULL
    THROW 51801, 'Schema GRAC_New is missing. Run Repository Management schema scripts first.', 1;

/* 1. cm_entity_master row for the new entity ----------------------------- */
;WITH src AS (
    SELECT N'obligation-mappings' AS entity_code,
           N'Obligation Mapping'  AS entity_name,
           N'GRAC_New.obligation_requirement_release_map' AS table_name,
           N'obligation-mappings' AS route_code,
           1                      AS is_maker_checker,
           95                     AS display_order
)
MERGE GRAC_New.cm_entity_master AS target
USING src ON target.entity_code = src.entity_code
WHEN MATCHED THEN UPDATE SET
    target.entity_name      = src.entity_name,
    target.table_name       = src.table_name,
    target.route_code       = src.route_code,
    target.is_maker_checker = src.is_maker_checker,
    target.display_order    = src.display_order,
    target.status           = 'Active',
    target.updated_by       = 'system',
    target.updated_dt       = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(entity_code, entity_name, table_name, route_code, is_maker_checker, display_order, status, entered_by)
    VALUES(src.entity_code, src.entity_name, src.table_name, src.route_code, src.is_maker_checker, src.display_order, 'Active', 'system');
GO

/* 2. Sidebar menu row under Repository Management ------------------------ */
;WITH menu_src AS (
    SELECT N'obligation-mappings' AS menu_code,
           N'control-management'  AS parent_code,
           N'Practices - Obligation Mapping' AS menu_name,
           N'Repository/Index?areaKey=obligation-mappings' AS route_url,
           95 AS display_order,
           N'list-tree' AS icon
)
MERGE GRAC_New.cm_menu AS target
USING (
    SELECT m.menu_code, p.menu_id parent_menu_id, m.menu_name, m.route_url, m.display_order, m.icon
    FROM menu_src m
    LEFT JOIN GRAC_New.cm_menu p ON p.menu_code = m.parent_code
) AS source
ON target.menu_code = source.menu_code
WHEN MATCHED THEN UPDATE SET
    target.parent_menu_id = source.parent_menu_id,
    target.menu_name      = source.menu_name,
    target.route_url      = source.route_url,
    target.display_order  = source.display_order,
    target.icon           = source.icon,
    target.status         = 'Active',
    target.updated_by     = 'system',
    target.updated_dt     = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(parent_menu_id, menu_name, menu_code, route_url, display_order, icon, status, entered_by)
    VALUES(source.parent_menu_id, source.menu_name, source.menu_code, source.route_url, source.display_order, source.icon, 'Active', 'system');
GO

/* 3. Re-label the existing 'obligations' module + menu as the master view */
UPDATE GRAC_New.cm_entity_master
SET entity_name      = N'Obligation Master',
    table_name       = N'GRAC_New.requirement_obligation',
    route_code       = N'obligations',
    is_maker_checker = 1,
    updated_by       = 'system',
    updated_dt       = SYSUTCDATETIME()
WHERE entity_code = N'obligations';
GO

UPDATE GRAC_New.cm_menu
SET menu_name = N'Obligation Master',
    icon      = N'calendar-check',
    updated_by = 'system',
    updated_dt = SYSUTCDATETIME()
WHERE menu_code = N'obligations';
GO

/* 4. Grant the CM_ADMIN role full permission on the new menu so it shows
      up immediately for the seeded admin.  Other roles must be granted
      through Role Permission Management explicitly. */
INSERT GRAC_New.cm_role_permission(role_id, menu_id, can_view, can_add, can_edit, can_inactive, can_approve, status, entered_by)
SELECT r.role_id, m.menu_id, 1, 1, 1, 1, 1, 'Active', 'system'
FROM GRAC_New.cm_role r
JOIN GRAC_New.cm_menu m ON m.menu_code = N'obligation-mappings'
WHERE r.role_name = 'CM_ADMIN'
  AND NOT EXISTS (SELECT 1 FROM GRAC_New.cm_role_permission x
                  WHERE x.role_id = r.role_id AND x.menu_id = m.menu_id);
GO

PRINT 'Migration 020 complete. obligation-mappings entity + menu installed.';
GO
