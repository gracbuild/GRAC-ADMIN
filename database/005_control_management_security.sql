/*
  ControlManagement security metadata and append-only transaction audit.
  Keep user identity external to this module; map the enterprise user key to roles.
*/
IF OBJECT_ID('GRAC_New.security_role','U') IS NULL CREATE TABLE GRAC_New.security_role(
 security_role_id BIGINT IDENTITY PRIMARY KEY, role_code NVARCHAR(80) NOT NULL UNIQUE, role_name NVARCHAR(200) NOT NULL,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active', entered_by NVARCHAR(100) NOT NULL, entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL);
GO
IF OBJECT_ID('GRAC_New.security_permission','U') IS NULL CREATE TABLE GRAC_New.security_permission(
 security_permission_id BIGINT IDENTITY PRIMARY KEY, area_key NVARCHAR(100) NOT NULL, action_code NVARCHAR(30) NOT NULL,
 permission_name NVARCHAR(200) NOT NULL, status NVARCHAR(30) NOT NULL DEFAULT 'Active', entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL,
 CONSTRAINT uq_cm_security_permission UNIQUE(area_key,action_code));
GO
IF OBJECT_ID('GRAC_New.security_role_permission','U') IS NULL CREATE TABLE GRAC_New.security_role_permission(
 security_role_permission_id BIGINT IDENTITY PRIMARY KEY, security_role_id BIGINT NOT NULL REFERENCES GRAC_New.security_role(security_role_id),
 security_permission_id BIGINT NOT NULL REFERENCES GRAC_New.security_permission(security_permission_id), status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL, entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL,
 CONSTRAINT uq_cm_security_role_permission UNIQUE(security_role_id,security_permission_id));
GO
IF OBJECT_ID('GRAC_New.security_user_role','U') IS NULL CREATE TABLE GRAC_New.security_user_role(
 security_user_role_id BIGINT IDENTITY PRIMARY KEY, external_user_key NVARCHAR(160) NOT NULL,
 security_role_id BIGINT NOT NULL REFERENCES GRAC_New.security_role(security_role_id), status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL, entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL,
 CONSTRAINT uq_cm_security_user_role UNIQUE(external_user_key,security_role_id));
GO
IF OBJECT_ID('GRAC_New.transaction_audit','U') IS NULL CREATE TABLE GRAC_New.transaction_audit(
 transaction_audit_id BIGINT IDENTITY PRIMARY KEY, correlation_id NVARCHAR(80) NOT NULL, user_key NVARCHAR(160) NULL,
 area_key NVARCHAR(100) NOT NULL, action_code NVARCHAR(30) NOT NULL, result_code NVARCHAR(30) NOT NULL,
 client_address NVARCHAR(80) NULL, detail_json NVARCHAR(MAX) NULL, entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME());
GO

MERGE GRAC_New.security_role AS target
USING (VALUES ('CM_ADMIN','Repository Management Administrator'),('CM_REVIEWER','Repository Management Reviewer'),('CM_APPROVER','Repository Management Approver'))
 AS source(role_code,role_name)
ON target.role_code=source.role_code
WHEN NOT MATCHED THEN INSERT(role_code,role_name,entered_by) VALUES(source.role_code,source.role_name,'system');
GO
DECLARE @areas TABLE(area_key NVARCHAR(100));
INSERT @areas VALUES ('authorities'),('artifacts'),('releases'),('source-structure'),('framework-statements'),('controls'),('control-domains'),('control-sub-domains'),('control-similar'),('control-tree'),('requirements'),('obligations'),
 ('control-requirement-mappings'),('source-control-mappings'),('applicability-rules'),('changes'),
 ('impact-analysis'),('notifications'),('change-management'),('approval-workflow'),('audit-trace'),('lookups');
MERGE GRAC_New.security_permission AS target
USING (SELECT area_key,action_code,area_key+' '+action_code permission_name FROM @areas CROSS JOIN (VALUES ('VIEW'),('ADD'),('EDIT'),('DELETE'),('APPROVE'),('REJECT')) action(action_code)) AS source
ON target.area_key=source.area_key AND target.action_code=source.action_code
WHEN NOT MATCHED THEN INSERT(area_key,action_code,permission_name,entered_by) VALUES(source.area_key,source.action_code,source.permission_name,'system');
GO
INSERT GRAC_New.security_role_permission(security_role_id,security_permission_id,entered_by)
SELECT r.security_role_id,p.security_permission_id,'system' FROM GRAC_New.security_role r CROSS JOIN GRAC_New.security_permission p
WHERE r.role_code='CM_ADMIN' AND NOT EXISTS(SELECT 1 FROM GRAC_New.security_role_permission x WHERE x.security_role_id=r.security_role_id AND x.security_permission_id=p.security_permission_id);
INSERT GRAC_New.security_role_permission(security_role_id,security_permission_id,entered_by)
SELECT r.security_role_id,p.security_permission_id,'system' FROM GRAC_New.security_role r CROSS JOIN GRAC_New.security_permission p
WHERE r.role_code IN ('CM_REVIEWER','CM_APPROVER') AND p.action_code='VIEW'
 AND NOT EXISTS(SELECT 1 FROM GRAC_New.security_role_permission x WHERE x.security_role_id=r.security_role_id AND x.security_permission_id=p.security_permission_id);
GO
CREATE OR ALTER TRIGGER GRAC_New.tr_transaction_audit_immutable ON GRAC_New.transaction_audit INSTEAD OF UPDATE, DELETE AS
BEGIN THROW 50005,'Transaction audit is immutable',1; END;
GO

IF OBJECT_ID('GRAC_New.cm_user','U') IS NULL CREATE TABLE GRAC_New.cm_user(
 user_id BIGINT IDENTITY PRIMARY KEY,
 user_name NVARCHAR(200) NOT NULL,
 login_id NVARCHAR(160) NOT NULL UNIQUE,
 email NVARCHAR(250) NOT NULL UNIQUE,
 password_hash NVARCHAR(500) NOT NULL,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 remarks NVARCHAR(MAX) NULL,
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL);
GO
IF OBJECT_ID('GRAC_New.cm_role','U') IS NULL CREATE TABLE GRAC_New.cm_role(
 role_id BIGINT IDENTITY PRIMARY KEY,
 role_name NVARCHAR(100) NOT NULL UNIQUE,
 description NVARCHAR(500) NULL,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL);
GO
IF OBJECT_ID('GRAC_New.cm_menu','U') IS NULL CREATE TABLE GRAC_New.cm_menu(
 menu_id BIGINT IDENTITY PRIMARY KEY,
 parent_menu_id BIGINT NULL REFERENCES GRAC_New.cm_menu(menu_id),
 menu_name NVARCHAR(200) NOT NULL,
 menu_code NVARCHAR(100) NOT NULL UNIQUE,
 route_url NVARCHAR(300) NULL,
 display_order INT NOT NULL DEFAULT 0,
 icon NVARCHAR(80) NULL,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL);
GO
IF OBJECT_ID('GRAC_New.cm_role_permission','U') IS NULL CREATE TABLE GRAC_New.cm_role_permission(
 role_permission_id BIGINT IDENTITY PRIMARY KEY,
 role_id BIGINT NOT NULL REFERENCES GRAC_New.cm_role(role_id),
 menu_id BIGINT NOT NULL REFERENCES GRAC_New.cm_menu(menu_id),
 can_view BIT NOT NULL DEFAULT 0,
 can_add BIT NOT NULL DEFAULT 0,
 can_edit BIT NOT NULL DEFAULT 0,
 can_inactive BIT NOT NULL DEFAULT 0,
 can_approve BIT NOT NULL DEFAULT 0,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_cm_role_permission UNIQUE(role_id,menu_id));
GO
IF OBJECT_ID('GRAC_New.cm_user_role','U') IS NULL CREATE TABLE GRAC_New.cm_user_role(
 user_role_id BIGINT IDENTITY PRIMARY KEY,
 user_id BIGINT NOT NULL REFERENCES GRAC_New.cm_user(user_id),
 role_id BIGINT NOT NULL REFERENCES GRAC_New.cm_role(role_id),
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_cm_user_role UNIQUE(user_id,role_id));
GO

MERGE GRAC_New.cm_role AS target
USING (VALUES
 ('CM_ADMIN','Repository Management Administrator'),
 ('CM_REVIEWER','Repository Management Reviewer'),
 ('CM_APPROVER','Repository Management Approver'),
 ('CM_USER','Repository Management User')) AS source(role_name,description)
ON target.role_name=source.role_name
WHEN MATCHED THEN UPDATE SET description=source.description,status='Active'
WHEN NOT MATCHED THEN INSERT(role_name,description,status,entered_by) VALUES(source.role_name,source.description,'Active','system');
GO

DECLARE @cmMenus TABLE(menu_code NVARCHAR(100), parent_code NVARCHAR(100), menu_name NVARCHAR(200), route_url NVARCHAR(300), display_order INT, icon NVARCHAR(80));
INSERT @cmMenus VALUES
 ('control-management',NULL,'Repository Management',NULL,10,'shield-alt'),
 ('authorities','control-management','Authority','Repository/Index?areaKey=authorities',20,'building'),
 ('artifacts','control-management','Artifacts','Repository/Index?areaKey=artifacts',30,'file-text'),
 ('releases','control-management','Releases','Repository/Index?areaKey=releases',40,'tags'),
 ('statement-classifications','control-management','Source Classification','Repository/Index?areaKey=statement-classifications',45,'layer-group'),
 ('source-structure','control-management','Source Structure','Repository/Index?areaKey=source-structure',50,'diagram-project'),
 ('framework-statements','control-management','Source Statements','Repository/Index?areaKey=framework-statements',60,'file-lines'),
 ('requirements','control-management','Practices','Repository/Index?areaKey=requirements',70,'list-check'),
 ('obligations','control-management','Practice Obligations','Repository/Index?areaKey=obligations',80,'calendar-check'),
 ('source-control-mappings','control-management','Practices - Statement Mapping','Repository/Index?areaKey=source-control-mappings',90,'sitemap'),
 ('security-administration',NULL,'Security Administration',NULL,200,'user-shield'),
 ('user-management','security-administration','User Management','Repository/Index?areaKey=user-management',210,'users'),
 ('role-management','security-administration','Role Management','Repository/Index?areaKey=role-management',220,'user-tag'),
 ('menu-management','security-administration','Menu Management','Repository/Index?areaKey=menu-management',230,'bars'),
 ('role-permissions','security-administration','Role Permission Management','Repository/Index?areaKey=role-permissions',240,'key'),
 ('change-management','control-management','Change Management','Repository/Index?areaKey=change-management',300,'code-branch'),
 ('approval-workflow','security-administration','Approval Workflow Configuration','Repository/Index?areaKey=approval-workflow',310,'user-check'),
 ('audit-trace','control-management','Audit Traceability','Repository/Index?areaKey=audit-trace',320,'clock-rotate-left');

MERGE GRAC_New.cm_menu AS target
USING (
 SELECT m.menu_code,p.menu_id parent_menu_id,m.menu_name,m.route_url,m.display_order,m.icon
 FROM @cmMenus m
 LEFT JOIN GRAC_New.cm_menu p ON p.menu_code=m.parent_code
) AS source
ON target.menu_code=source.menu_code
WHEN MATCHED THEN UPDATE SET parent_menu_id=source.parent_menu_id,menu_name=source.menu_name,route_url=source.route_url,display_order=source.display_order,icon=source.icon
WHEN NOT MATCHED THEN INSERT(parent_menu_id,menu_name,menu_code,route_url,display_order,icon,status,entered_by)
VALUES(source.parent_menu_id,source.menu_name,source.menu_code,source.route_url,source.display_order,source.icon,'Active','system');
GO

DECLARE @adminHash NVARCHAR(500)='210000.bvcTyB6+OH6t0fS0fubDug==.AlnAWwvGWbT9GC2huSWQ1Run3iqYoicCeOctdBVDV6M=';
DECLARE @checkerHash NVARCHAR(500)='210000.37p6TFbU2jNGmEA8x7opbw==.VUfIQIjkM10bbijbxnMXI9TBuFUKG57sUthYLTYz1+w=';
IF NOT EXISTS(SELECT 1 FROM GRAC_New.cm_user WHERE login_id='admin@grac.local')
 INSERT GRAC_New.cm_user(user_name,login_id,email,password_hash,status,remarks,entered_by) VALUES('Control Admin','admin@grac.local','admin@grac.local',@adminHash,'Active','Seeded local administrator','system');
IF NOT EXISTS(SELECT 1 FROM GRAC_New.cm_user WHERE login_id='checker@grac.local')
 INSERT GRAC_New.cm_user(user_name,login_id,email,password_hash,status,remarks,entered_by) VALUES('Control Checker','checker@grac.local','checker@grac.local',@checkerHash,'Active','Seeded local checker','system');
GO

INSERT GRAC_New.cm_user_role(user_id,role_id,entered_by)
SELECT u.user_id,r.role_id,'system'
FROM GRAC_New.cm_user u CROSS JOIN GRAC_New.cm_role r
WHERE ((u.login_id='admin@grac.local' AND r.role_name='CM_ADMIN') OR (u.login_id='checker@grac.local' AND r.role_name='CM_APPROVER'))
  AND NOT EXISTS(SELECT 1 FROM GRAC_New.cm_user_role x WHERE x.user_id=u.user_id AND x.role_id=r.role_id);
GO

MERGE GRAC_New.cm_role_permission AS target
USING (
 SELECT r.role_id,m.menu_id,
        CAST(1 AS BIT) can_view,
        CAST(CASE WHEN r.role_name='CM_ADMIN' THEN 1 ELSE 0 END AS BIT) can_add,
        CAST(CASE WHEN r.role_name='CM_ADMIN' THEN 1 ELSE 0 END AS BIT) can_edit,
        CAST(CASE WHEN r.role_name='CM_ADMIN' THEN 1 ELSE 0 END AS BIT) can_inactive,
        CAST(CASE WHEN r.role_name IN ('CM_ADMIN','CM_APPROVER') AND m.menu_code IN ('change-management','approval-workflow','role-permissions') THEN 1 ELSE 0 END AS BIT) can_approve
 FROM GRAC_New.cm_role r
 CROSS JOIN GRAC_New.cm_menu m
 WHERE r.role_name IN ('CM_ADMIN','CM_REVIEWER','CM_APPROVER','CM_USER')
) AS source
ON target.role_id=source.role_id AND target.menu_id=source.menu_id
WHEN MATCHED THEN UPDATE SET can_view=source.can_view,can_add=source.can_add,can_edit=source.can_edit,can_inactive=source.can_inactive,can_approve=source.can_approve,status='Active'
WHEN NOT MATCHED THEN INSERT(role_id,menu_id,can_view,can_add,can_edit,can_inactive,can_approve,status,entered_by)
VALUES(source.role_id,source.menu_id,source.can_view,source.can_add,source.can_edit,source.can_inactive,source.can_approve,'Active','system');
GO
