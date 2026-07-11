/*
  GRAC Repository Management - Part 014
  Introduce cm_entity_master and normalize Approval Workflow + Change Management
  to reference modules by entity_id (instead of comparing raw text names).

  Safe to re-run: every block guarded with IF NOT EXISTS / MERGE / column existence checks.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF SCHEMA_ID('GRAC_New') IS NULL
    THROW 51201, 'Schema GRAC_New is missing. Run Repository Management schema scripts first.', 1;

/* ---------------------------------------------------------------------------
   1. Master table.  entity_code is the canonical slug used everywhere in the
      stored procedures and the JS payloads (authorities, artifacts, ...).
      entity_name is the human-readable label shown in dropdowns.
      table_name + route_code are bookkeeping/diagnostic columns.
      is_maker_checker replaces the hard-coded list in cm_manage_repository.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('GRAC_New.cm_entity_master','U') IS NULL
BEGIN
    CREATE TABLE GRAC_New.cm_entity_master(
        entity_id          BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_cm_entity_master PRIMARY KEY,
        entity_code        NVARCHAR(100) NOT NULL CONSTRAINT uq_cm_entity_master_code UNIQUE,
        entity_name        NVARCHAR(200) NOT NULL,
        table_name         NVARCHAR(200) NULL,
        route_code         NVARCHAR(100) NULL,
        is_maker_checker   BIT NOT NULL CONSTRAINT df_cm_entity_master_mc DEFAULT 0,
        display_order      INT NOT NULL CONSTRAINT df_cm_entity_master_order DEFAULT 0,
        status             NVARCHAR(30) NOT NULL CONSTRAINT df_cm_entity_master_status DEFAULT 'Active',
        entered_by         NVARCHAR(100) NOT NULL CONSTRAINT df_cm_entity_master_eb DEFAULT 'system',
        entered_dt         DATETIME2(3) NOT NULL CONSTRAINT df_cm_entity_master_ed DEFAULT SYSUTCDATETIME(),
        updated_by         NVARCHAR(100) NULL,
        updated_dt         DATETIME2(3) NULL,
        CONSTRAINT ck_cm_entity_master_status CHECK(status IN ('Active','Inactive'))
    );
END
GO

/* Seed / upsert the canonical entity set.  Keep entity_code identical to the
   slug used in the JS controller and existing stored procedures so nothing
   downstream needs translation. */
;WITH src AS (
    SELECT * FROM (VALUES
        (N'authorities',                      N'Authority',                          N'GRAC_New.authority',                       N'authorities',                      1, 10),
        (N'artifacts',                        N'Artifact',                           N'GRAC_New.artifact',                        N'artifacts',                        1, 20),
        (N'releases',                         N'Release',                            N'GRAC_New.release',                         N'releases',                         1, 30),
        (N'statement-classifications',        N'Source Classification',              N'GRAC_New.statement_classification',        N'statement-classifications',        1, 40),
        (N'source-structure',                 N'Source Structure',                   N'GRAC_New.source_structure_node',           N'source-structure',                 1, 50),
        (N'framework-statements',             N'Source Statements',                  N'GRAC_New.framework_statement',             N'framework-statements',             1, 60),
        (N'controls',                         N'Control',                            N'GRAC_New.control',                         N'controls',                         1, 70),
        (N'control-domains',                  N'Control Domain',                     N'GRAC_New.control_domain',                  N'control-domains',                  0, 75),
        (N'control-sub-domains',              N'Control Sub Domain',                 N'GRAC_New.control_sub_domain',              N'control-sub-domains',              0, 76),
        (N'requirements',                     N'Practice',                           N'GRAC_New.requirement',                     N'requirements',                     1, 80),
        (N'obligations',                      N'Practice Obligation',                N'GRAC_New.requirement_obligation',          N'obligations',                      1, 90),
        (N'control-requirement-mappings',     N'Control-Requirement Mapping',        N'GRAC_New.control_requirement_map',         N'control-requirement-mappings',     1, 100),
        (N'source-control-mappings',          N'Practices - Statement Mapping',      N'GRAC_New.source_control_map',              N'source-control-mappings',          1, 110),
        (N'applicability-rules',              N'Applicability Rule',                 N'GRAC_New.applicability_rule',              N'applicability-rules',              1, 120),
        (N'user-management',                  N'User Management',                    N'GRAC_New.cm_user',                         N'user-management',                  1, 200),
        (N'role-management',                  N'Role Management',                    N'GRAC_New.cm_role',                         N'role-management',                  1, 210),
        (N'menu-management',                  N'Menu Management',                    N'GRAC_New.cm_menu',                         N'menu-management',                  1, 220),
        (N'role-permissions',                 N'Role Permission',                    N'GRAC_New.cm_role_permission',              N'role-permissions',                 1, 230),
        (N'changes',                          N'Change Event',                       N'GRAC_New.change_event',                    N'changes',                          0, 300),
        (N'impact-analysis',                  N'Impact Analysis',                    N'GRAC_New.impact_analysis',                 N'impact-analysis',                  0, 310),
        (N'notifications',                    N'Notification',                       N'GRAC_New.notification',                    N'notifications',                    0, 320),
        (N'approval-workflow',                N'Approval Workflow Configuration',    N'GRAC_New.approval_workflow_config',        N'approval-workflow',                0, 330)
    ) AS v(entity_code, entity_name, table_name, route_code, is_maker_checker, display_order)
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

/* ---------------------------------------------------------------------------
   2. approval_workflow_config -> add entity_id, backfill, FK, unique index.
      module_name stays as a denormalized display copy (re-synced from master
      on every save) so existing reports / audits keep working.
   --------------------------------------------------------------------------- */
IF NOT EXISTS(SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('GRAC_New.approval_workflow_config') AND name = 'entity_id')
BEGIN
    ALTER TABLE GRAC_New.approval_workflow_config ADD entity_id BIGINT NULL;
END
GO

/* Best-effort backfill: match the old free-text module_name first to entity_code,
   then to entity_name (case-insensitive at the default collation). */
UPDATE awc
SET awc.entity_id = em.entity_id
FROM GRAC_New.approval_workflow_config awc
JOIN GRAC_New.cm_entity_master em
  ON em.entity_code = awc.module_name OR em.entity_name = awc.module_name
WHERE awc.entity_id IS NULL;
GO

/* Surface unmatched rows for the operator running the migration. They should
   either delete the stale row or repoint it to a real module before re-running. */
IF EXISTS(SELECT 1 FROM GRAC_New.approval_workflow_config WHERE entity_id IS NULL)
BEGIN
    PRINT 'WARNING: approval_workflow_config has rows whose module_name does not map to cm_entity_master. They remain with entity_id NULL.';
    SELECT workflow_config_id, module_name FROM GRAC_New.approval_workflow_config WHERE entity_id IS NULL;
END
GO

/* Only add the FK once every existing row has been backfilled. */
IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_cm_awc_entity')
   AND NOT EXISTS(SELECT 1 FROM GRAC_New.approval_workflow_config WHERE entity_id IS NULL)
BEGIN
    ALTER TABLE GRAC_New.approval_workflow_config WITH CHECK
        ADD CONSTRAINT fk_cm_awc_entity FOREIGN KEY (entity_id) REFERENCES GRAC_New.cm_entity_master(entity_id);
END
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name = 'uq_cm_awc_entity' AND object_id = OBJECT_ID('GRAC_New.approval_workflow_config'))
   AND NOT EXISTS(SELECT 1 FROM GRAC_New.approval_workflow_config WHERE entity_id IS NULL)
BEGIN
    CREATE UNIQUE INDEX uq_cm_awc_entity ON GRAC_New.approval_workflow_config(entity_id) WHERE entity_id IS NOT NULL;
END
GO

/* ---------------------------------------------------------------------------
   3. change_management -> add entity_id and backfill from the existing slug
      that's already stored in change_management.entity_type.
   --------------------------------------------------------------------------- */
IF NOT EXISTS(SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('GRAC_New.change_management') AND name = 'entity_id')
BEGIN
    ALTER TABLE GRAC_New.change_management ADD entity_id BIGINT NULL;
END
GO

UPDATE cm
SET cm.entity_id = em.entity_id
FROM GRAC_New.change_management cm
JOIN GRAC_New.cm_entity_master em ON em.entity_code = cm.entity_type
WHERE cm.entity_id IS NULL;
GO

IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_cm_change_management_entity')
BEGIN
    ALTER TABLE GRAC_New.change_management WITH NOCHECK
        ADD CONSTRAINT fk_cm_change_management_entity FOREIGN KEY (entity_id) REFERENCES GRAC_New.cm_entity_master(entity_id);
END
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name = 'ix_cm_change_management_entity_id' AND object_id = OBJECT_ID('GRAC_New.change_management'))
BEGIN
    CREATE INDEX ix_cm_change_management_entity_id ON GRAC_New.change_management(entity_id, status);
END
GO

PRINT 'Migration 014 complete. cm_entity_master is the source of truth for module identity.';
GO
