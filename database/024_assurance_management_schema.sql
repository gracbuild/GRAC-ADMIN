/*
  GRAC Assurance Management (Phase 1 - Admin / Authority Control Module).
  Publishes reusable assurance metadata that organizations subscribe to.

  Design principles:
  - Schema, naming, PK and audit conventions mirror GRAC_New masters
    (BIGINT IDENTITY primary keys, status column, entered_/updated_ audit).
  - Every published-metadata item participates in a Draft -> Review ->
    Approved -> Published -> Retired lifecycle stamped in <table>.lifecycle_status
    and versioned by <table>.version_no.  A dedicated *_version table keeps
    an immutable snapshot history so downstream Practice Module subscriptions
    always reference an approved, published version.
  - Rerunnable: every CREATE / MERGE is guarded so the script can be applied
    to any environment without conflict.
*/

/* -----------------------------------------------------------
   1. Assurance Categories
   ----------------------------------------------------------- */
IF OBJECT_ID('GRAC_New.assurance_category','U') IS NULL CREATE TABLE GRAC_New.assurance_category(
 assurance_category_id BIGINT IDENTITY PRIMARY KEY,
 category_code NVARCHAR(80) NOT NULL,
 category_name NVARCHAR(200) NOT NULL,
 description NVARCHAR(MAX) NULL,
 version_no NVARCHAR(40) NOT NULL DEFAULT '1.0',
 lifecycle_status NVARCHAR(30) NOT NULL DEFAULT 'Draft',
 is_active BIT NOT NULL DEFAULT 1,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 display_order INT NOT NULL DEFAULT 0,
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_assurance_category_code UNIQUE(category_code));
GO

/* -----------------------------------------------------------
   2. Scoring Models
   ----------------------------------------------------------- */
IF OBJECT_ID('GRAC_New.assurance_scoring_model','U') IS NULL CREATE TABLE GRAC_New.assurance_scoring_model(
 scoring_model_id BIGINT IDENTITY PRIMARY KEY,
 model_code NVARCHAR(80) NOT NULL,
 model_name NVARCHAR(200) NOT NULL,
 description NVARCHAR(MAX) NULL,
 formula_definition NVARCHAR(MAX) NULL,
 formula_type NVARCHAR(60) NOT NULL DEFAULT 'Configuration',
 rating_scale NVARCHAR(MAX) NULL,
 pass_threshold DECIMAL(9,2) NULL,
 version_no NVARCHAR(40) NOT NULL DEFAULT '1.0',
 lifecycle_status NVARCHAR(30) NOT NULL DEFAULT 'Draft',
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_assurance_scoring_model_code UNIQUE(model_code));
GO

/* -----------------------------------------------------------
   3. Observation Severity
   ----------------------------------------------------------- */
IF OBJECT_ID('GRAC_New.assurance_observation_severity','U') IS NULL CREATE TABLE GRAC_New.assurance_observation_severity(
 observation_severity_id BIGINT IDENTITY PRIMARY KEY,
 severity_code NVARCHAR(80) NOT NULL,
 severity_name NVARCHAR(200) NOT NULL,
 description NVARCHAR(MAX) NULL,
 severity_rank INT NOT NULL DEFAULT 0,
 color_code NVARCHAR(20) NULL,
 version_no NVARCHAR(40) NOT NULL DEFAULT '1.0',
 lifecycle_status NVARCHAR(30) NOT NULL DEFAULT 'Draft',
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_assurance_observation_severity_code UNIQUE(severity_code));
GO

/* -----------------------------------------------------------
   4. Gap Categories
   ----------------------------------------------------------- */
IF OBJECT_ID('GRAC_New.assurance_gap_category','U') IS NULL CREATE TABLE GRAC_New.assurance_gap_category(
 gap_category_id BIGINT IDENTITY PRIMARY KEY,
 gap_code NVARCHAR(80) NOT NULL,
 gap_name NVARCHAR(200) NOT NULL,
 description NVARCHAR(MAX) NULL,
 display_order INT NOT NULL DEFAULT 0,
 version_no NVARCHAR(40) NOT NULL DEFAULT '1.0',
 lifecycle_status NVARCHAR(30) NOT NULL DEFAULT 'Draft',
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_assurance_gap_category_code UNIQUE(gap_code));
GO

/* -----------------------------------------------------------
   5. Workflow Templates + Stages
   ----------------------------------------------------------- */
IF OBJECT_ID('GRAC_New.assurance_workflow_template','U') IS NULL CREATE TABLE GRAC_New.assurance_workflow_template(
 workflow_template_id BIGINT IDENTITY PRIMARY KEY,
 template_code NVARCHAR(80) NOT NULL,
 template_name NVARCHAR(200) NOT NULL,
 description NVARCHAR(MAX) NULL,
 sla_hours INT NULL,
 escalation_rule NVARCHAR(MAX) NULL,
 version_no NVARCHAR(40) NOT NULL DEFAULT '1.0',
 lifecycle_status NVARCHAR(30) NOT NULL DEFAULT 'Draft',
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_assurance_workflow_template_code UNIQUE(template_code));
GO

IF OBJECT_ID('GRAC_New.assurance_workflow_stage','U') IS NULL CREATE TABLE GRAC_New.assurance_workflow_stage(
 workflow_stage_id BIGINT IDENTITY PRIMARY KEY,
 workflow_template_id BIGINT NOT NULL REFERENCES GRAC_New.assurance_workflow_template(workflow_template_id),
 stage_order INT NOT NULL DEFAULT 0,
 stage_name NVARCHAR(200) NOT NULL,
 stage_type NVARCHAR(60) NOT NULL DEFAULT 'Review',
 approval_rule NVARCHAR(MAX) NULL,
 escalation_rule NVARCHAR(MAX) NULL,
 sla_hours INT NULL,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_assurance_workflow_stage UNIQUE(workflow_template_id, stage_order));
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_assurance_workflow_stage_template' AND object_id=OBJECT_ID('GRAC_New.assurance_workflow_stage'))
 EXEC(N'CREATE INDEX ix_assurance_workflow_stage_template ON GRAC_New.assurance_workflow_stage(workflow_template_id,stage_order,status)');
GO

/* -----------------------------------------------------------
   6. Question Types
   ----------------------------------------------------------- */
IF OBJECT_ID('GRAC_New.assurance_question_type','U') IS NULL CREATE TABLE GRAC_New.assurance_question_type(
 question_type_id BIGINT IDENTITY PRIMARY KEY,
 question_code NVARCHAR(80) NOT NULL,
 question_name NVARCHAR(200) NOT NULL,
 description NVARCHAR(MAX) NULL,
 requires_evidence BIT NOT NULL DEFAULT 0,
 answer_shape NVARCHAR(60) NULL,
 display_order INT NOT NULL DEFAULT 0,
 version_no NVARCHAR(40) NOT NULL DEFAULT '1.0',
 lifecycle_status NVARCHAR(30) NOT NULL DEFAULT 'Draft',
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_assurance_question_type_code UNIQUE(question_code));
GO

/* -----------------------------------------------------------
   7. Sampling Models
   ----------------------------------------------------------- */
IF OBJECT_ID('GRAC_New.assurance_sampling_model','U') IS NULL CREATE TABLE GRAC_New.assurance_sampling_model(
 sampling_model_id BIGINT IDENTITY PRIMARY KEY,
 sampling_code NVARCHAR(80) NOT NULL,
 sampling_name NVARCHAR(200) NOT NULL,
 description NVARCHAR(MAX) NULL,
 methodology NVARCHAR(MAX) NULL,
 version_no NVARCHAR(40) NOT NULL DEFAULT '1.0',
 lifecycle_status NVARCHAR(30) NOT NULL DEFAULT 'Draft',
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_assurance_sampling_model_code UNIQUE(sampling_code));
GO

/* -----------------------------------------------------------
   8. Frequency Types
   ----------------------------------------------------------- */
IF OBJECT_ID('GRAC_New.assurance_frequency_type','U') IS NULL CREATE TABLE GRAC_New.assurance_frequency_type(
 frequency_type_id BIGINT IDENTITY PRIMARY KEY,
 frequency_code NVARCHAR(80) NOT NULL,
 frequency_name NVARCHAR(200) NOT NULL,
 description NVARCHAR(MAX) NULL,
 interval_days INT NULL,
 display_order INT NOT NULL DEFAULT 0,
 version_no NVARCHAR(40) NOT NULL DEFAULT '1.0',
 lifecycle_status NVARCHAR(30) NOT NULL DEFAULT 'Draft',
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_assurance_frequency_type_code UNIQUE(frequency_code));
GO

/* -----------------------------------------------------------
   9. Report Templates
   ----------------------------------------------------------- */
IF OBJECT_ID('GRAC_New.assurance_report_template','U') IS NULL CREATE TABLE GRAC_New.assurance_report_template(
 report_template_id BIGINT IDENTITY PRIMARY KEY,
 template_code NVARCHAR(80) NOT NULL,
 template_name NVARCHAR(200) NOT NULL,
 description NVARCHAR(MAX) NULL,
 report_scope NVARCHAR(120) NULL,
 layout_definition NVARCHAR(MAX) NULL,
 version_no NVARCHAR(40) NOT NULL DEFAULT '1.0',
 lifecycle_status NVARCHAR(30) NOT NULL DEFAULT 'Draft',
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_assurance_report_template_code UNIQUE(template_code));
GO

/* -----------------------------------------------------------
   10. Starter Assurance Templates
   Bundles reusable metadata into a ready-to-subscribe template.
   Organization-specific values NEVER live here.
   ----------------------------------------------------------- */
IF OBJECT_ID('GRAC_New.assurance_starter_template','U') IS NULL CREATE TABLE GRAC_New.assurance_starter_template(
 starter_template_id BIGINT IDENTITY PRIMARY KEY,
 template_code NVARCHAR(80) NOT NULL,
 template_name NVARCHAR(200) NOT NULL,
 description NVARCHAR(MAX) NULL,
 assurance_category_id BIGINT NULL REFERENCES GRAC_New.assurance_category(assurance_category_id),
 scoring_model_id BIGINT NULL REFERENCES GRAC_New.assurance_scoring_model(scoring_model_id),
 workflow_template_id BIGINT NULL REFERENCES GRAC_New.assurance_workflow_template(workflow_template_id),
 sampling_model_id BIGINT NULL REFERENCES GRAC_New.assurance_sampling_model(sampling_model_id),
 frequency_type_id BIGINT NULL REFERENCES GRAC_New.assurance_frequency_type(frequency_type_id),
 report_template_id BIGINT NULL REFERENCES GRAC_New.assurance_report_template(report_template_id),
 version_no NVARCHAR(40) NOT NULL DEFAULT '1.0',
 lifecycle_status NVARCHAR(30) NOT NULL DEFAULT 'Draft',
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_assurance_starter_template_code UNIQUE(template_code));
GO

/* Question-type mapping on a starter template (many-to-many). */
IF OBJECT_ID('GRAC_New.assurance_starter_template_question','U') IS NULL CREATE TABLE GRAC_New.assurance_starter_template_question(
 starter_template_question_id BIGINT IDENTITY PRIMARY KEY,
 starter_template_id BIGINT NOT NULL REFERENCES GRAC_New.assurance_starter_template(starter_template_id),
 question_type_id BIGINT NOT NULL REFERENCES GRAC_New.assurance_question_type(question_type_id),
 display_order INT NOT NULL DEFAULT 0,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_assurance_starter_template_question UNIQUE(starter_template_id,question_type_id));
GO

/* -----------------------------------------------------------
   11. Version snapshot table
   Immutable snapshot of every lifecycle transition for any of the
   metadata items above.  Used by the Version History screen and by
   Phase 2 subscription lookups to bind to a specific published version.
   ----------------------------------------------------------- */
IF OBJECT_ID('GRAC_New.assurance_metadata_version','U') IS NULL CREATE TABLE GRAC_New.assurance_metadata_version(
 metadata_version_id BIGINT IDENTITY PRIMARY KEY,
 entity_type NVARCHAR(100) NOT NULL,
 entity_id BIGINT NOT NULL,
 version_no NVARCHAR(40) NOT NULL,
 lifecycle_status NVARCHAR(30) NOT NULL,
 previous_status NVARCHAR(30) NULL,
 snapshot_json NVARCHAR(MAX) NULL,
 remarks NVARCHAR(MAX) NULL,
 action_code NVARCHAR(40) NOT NULL,
 published_dt DATETIME2 NULL,
 retired_dt DATETIME2 NULL,
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME());
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_assurance_metadata_version_entity' AND object_id=OBJECT_ID('GRAC_New.assurance_metadata_version'))
 EXEC(N'CREATE INDEX ix_assurance_metadata_version_entity ON GRAC_New.assurance_metadata_version(entity_type,entity_id,entered_dt DESC)');
GO
IF NOT EXISTS(SELECT 1 FROM sys.triggers WHERE name='tr_assurance_metadata_version_immutable')
 EXEC(N'CREATE TRIGGER GRAC_New.tr_assurance_metadata_version_immutable ON GRAC_New.assurance_metadata_version INSTEAD OF UPDATE, DELETE AS BEGIN THROW 50060,''Assurance version history is immutable'',1; END;');
GO

/* -----------------------------------------------------------
   Seed data
   Draft rows are seeded as Published so admins can showcase the
   reusable metadata immediately; every downstream lifecycle change
   creates a new snapshot in assurance_metadata_version.
   ----------------------------------------------------------- */

/* 2.1 Assurance categories */
MERGE GRAC_New.assurance_category AS target
USING (VALUES
 (N'INT_AUDIT',            N'Internal Audit',                        N'Standard internal audit engagements.',                                       1),
 (N'IS_AUDIT',             N'Information Systems Audit',             N'Assurance over IT systems, applications and controls.',                       2),
 (N'RBIA',                 N'Risk Based Internal Audit',             N'Risk based internal audit programs.',                                        3),
 (N'COMP_REVIEW',          N'Compliance Review',                     N'Assurance over regulatory and internal compliance.',                          4),
 (N'MGMT_REVIEW',          N'Management Review',                     N'Reviews commissioned by management for governance and performance.',           5),
 (N'SELF_ASSESS',          N'Self Assessment',                       N'Control and process self assessments.',                                      6),
 (N'VENDOR_ASSESS',        N'Vendor Assessment',                     N'Vendor and supplier assurance engagements.',                                 7),
 (N'THIRD_PARTY_ASSESS',   N'Third Party Assessment',                N'Broader third party risk and compliance assessments.',                       8),
 (N'REG_INSPECTION',       N'Regulatory Inspection',                 N'Inspections triggered by a regulator or supervisor.',                        9),
 (N'CONT_ASSURANCE',       N'Continuous Assurance',                  N'Continuous or automated assurance monitoring.',                              10),
 (N'EVENT_DRIVEN',         N'Event Driven Assurance',                N'Assurance triggered by an event or trigger.',                                11),
 (N'OPS_REVIEW',           N'Operational Review',                    N'Operational and process reviews.',                                           12),
 (N'PROC_AUDIT',           N'Process Audit',                         N'Process audits with a defined scope.',                                       13),
 (N'TECH_AUDIT',           N'Technology Audit',                      N'Technology or infrastructure audits.',                                       14),
 (N'CUSTOM',               N'Custom Assurance',                      N'Custom assurance engagements not covered by other categories.',              15)
) AS source(category_code,category_name,description,display_order)
ON target.category_code=source.category_code
WHEN MATCHED THEN UPDATE SET category_name=source.category_name,description=source.description,display_order=source.display_order,lifecycle_status=N'Published',status=N'Active',updated_by=N'system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(category_code,category_name,description,display_order,lifecycle_status,status,entered_by)
VALUES(source.category_code,source.category_name,source.description,source.display_order,N'Published',N'Active',N'system');
GO

/* 2.2 Scoring models */
MERGE GRAC_New.assurance_scoring_model AS target
USING (VALUES
 (N'PASS_FAIL',      N'Pass / Fail',         N'Binary pass or fail evaluation.',                              N'PassFail',       N'Pass;Fail',                     100.00),
 (N'PERCENTAGE',     N'Percentage',          N'Percentage based scoring.',                                    N'Percentage',     N'0-100',                         70.00),
 (N'WEIGHTED',       N'Weighted Score',      N'Weighted average of section scores.',                          N'WeightedAvg',    N'0-100',                         70.00),
 (N'RISK_SCORE',     N'Risk Score',          N'Risk scoring by inherent and residual risk factors.',          N'RiskMatrix',     N'Low;Medium;High;Critical',      NULL),
 (N'MATURITY',       N'Maturity Score',      N'Capability maturity model scoring.',                           N'Maturity',       N'0-5',                           3.00),
 (N'COMP_SCORE',     N'Compliance Score',    N'Compliance percentage across obligations.',                    N'Compliance',     N'0-100',                         80.00)
) AS source(model_code,model_name,description,formula_type,rating_scale,pass_threshold)
ON target.model_code=source.model_code
WHEN MATCHED THEN UPDATE SET model_name=source.model_name,description=source.description,formula_type=source.formula_type,rating_scale=source.rating_scale,pass_threshold=source.pass_threshold,lifecycle_status=N'Published',status=N'Active',updated_by=N'system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(model_code,model_name,description,formula_type,rating_scale,pass_threshold,lifecycle_status,status,entered_by)
VALUES(source.model_code,source.model_name,source.description,source.formula_type,source.rating_scale,source.pass_threshold,N'Published',N'Active',N'system');
GO

/* 2.3 Observation severity */
MERGE GRAC_New.assurance_observation_severity AS target
USING (VALUES
 (N'CRITICAL',       N'Critical',        N'Critical observations requiring immediate remediation.',   1, N'#c92a2a'),
 (N'HIGH',           N'High',            N'High severity observations requiring urgent remediation.', 2, N'#e8590c'),
 (N'MEDIUM',         N'Medium',          N'Medium severity observations tracked for remediation.',    3, N'#f59f00'),
 (N'LOW',            N'Low',             N'Low severity observations for monitoring.',                4, N'#2f9e44'),
 (N'INFORMATIONAL',  N'Informational',   N'Informational only, no remediation required.',             5, N'#1c7ed6')
) AS source(severity_code,severity_name,description,severity_rank,color_code)
ON target.severity_code=source.severity_code
WHEN MATCHED THEN UPDATE SET severity_name=source.severity_name,description=source.description,severity_rank=source.severity_rank,color_code=source.color_code,lifecycle_status=N'Published',status=N'Active',updated_by=N'system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(severity_code,severity_name,description,severity_rank,color_code,lifecycle_status,status,entered_by)
VALUES(source.severity_code,source.severity_name,source.description,source.severity_rank,source.color_code,N'Published',N'Active',N'system');
GO

/* 2.4 Gap categories */
MERGE GRAC_New.assurance_gap_category AS target
USING (VALUES
 (N'IMPL',           N'Implementation Gap',      N'Gap in control implementation or execution.',                          1),
 (N'COMPLIANCE',     N'Compliance Gap',          N'Gap against a specific regulation or standard.',                       2),
 (N'DOC',            N'Documentation Gap',       N'Gap in policies, procedures or evidence documentation.',               3),
 (N'TECH',           N'Technology Gap',          N'Gap in technology capability or configuration.',                       4),
 (N'EVIDENCE',       N'Evidence Gap',            N'Missing or inadequate evidence.',                                     5),
 (N'VENDOR',         N'Vendor Gap',              N'Third party or vendor related gap.',                                  6),
 (N'CONFIG',         N'Configuration Gap',       N'System or platform configuration deficiency.',                        7),
 (N'PROCESS',        N'Process Gap',             N'Process design or process operating deficiency.',                     8),
 (N'POLICY',         N'Policy Gap',              N'Policy design or policy coverage deficiency.',                        9)
) AS source(gap_code,gap_name,description,display_order)
ON target.gap_code=source.gap_code
WHEN MATCHED THEN UPDATE SET gap_name=source.gap_name,description=source.description,display_order=source.display_order,lifecycle_status=N'Published',status=N'Active',updated_by=N'system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(gap_code,gap_name,description,display_order,lifecycle_status,status,entered_by)
VALUES(source.gap_code,source.gap_name,source.description,source.display_order,N'Published',N'Active',N'system');
GO

/* 2.5 Workflow templates + stages */
MERGE GRAC_New.assurance_workflow_template AS target
USING (VALUES
 (N'SINGLE_REVIEWER',        N'Single Reviewer',                   N'Reviewed by one reviewer, no approver.',                                24),
 (N'MAKER_REVIEWER',         N'Maker to Reviewer',                 N'Maker submits, one reviewer approves.',                                 48),
 (N'MAKER_REVIEWER_APPROVER',N'Maker to Reviewer to Approver',     N'Maker, reviewer and final approver.',                                   72),
 (N'MULTI_LEVEL',            N'Multi-Level Approval',              N'Multi-level approval, typically maker + 2 approvers.',                  96)
) AS source(template_code,template_name,description,sla_hours)
ON target.template_code=source.template_code
WHEN MATCHED THEN UPDATE SET template_name=source.template_name,description=source.description,sla_hours=source.sla_hours,lifecycle_status=N'Published',status=N'Active',updated_by=N'system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(template_code,template_name,description,sla_hours,lifecycle_status,status,entered_by)
VALUES(source.template_code,source.template_name,source.description,source.sla_hours,N'Published',N'Active',N'system');
GO

MERGE GRAC_New.assurance_workflow_stage AS target
USING (
 SELECT wt.workflow_template_id,v.stage_order,v.stage_name,v.stage_type,v.sla_hours
 FROM (VALUES
  (N'SINGLE_REVIEWER',         1,N'Review',   N'Review',   24),
  (N'MAKER_REVIEWER',          1,N'Prepare',  N'Maker',    24),
  (N'MAKER_REVIEWER',          2,N'Review',   N'Review',   24),
  (N'MAKER_REVIEWER_APPROVER', 1,N'Prepare',  N'Maker',    24),
  (N'MAKER_REVIEWER_APPROVER', 2,N'Review',   N'Review',   24),
  (N'MAKER_REVIEWER_APPROVER', 3,N'Approve',  N'Approver', 24),
  (N'MULTI_LEVEL',             1,N'Prepare',  N'Maker',    24),
  (N'MULTI_LEVEL',             2,N'Review',   N'Review',   24),
  (N'MULTI_LEVEL',             3,N'Approve L1',N'Approver',24),
  (N'MULTI_LEVEL',             4,N'Approve L2',N'Approver',24)
 ) v(template_code,stage_order,stage_name,stage_type,sla_hours)
 JOIN GRAC_New.assurance_workflow_template wt ON wt.template_code=v.template_code
) AS source
ON target.workflow_template_id=source.workflow_template_id AND target.stage_order=source.stage_order
WHEN MATCHED THEN UPDATE SET stage_name=source.stage_name,stage_type=source.stage_type,sla_hours=source.sla_hours,status=N'Active',updated_by=N'system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(workflow_template_id,stage_order,stage_name,stage_type,sla_hours,status,entered_by)
VALUES(source.workflow_template_id,source.stage_order,source.stage_name,source.stage_type,source.sla_hours,N'Active',N'system');
GO

/* 2.6 Question types */
MERGE GRAC_New.assurance_question_type AS target
USING (VALUES
 (N'YES_NO',       N'Yes / No',           N'Binary Yes/No response.',                       N'Boolean',    0, 1),
 (N'MCQ',          N'Multiple Choice',    N'Multiple choice question with predefined options.', N'Choice',  0, 2),
 (N'TEXT',         N'Text',               N'Free text response.',                          N'Text',       0, 3),
 (N'NUMERIC',      N'Numeric',            N'Numeric response.',                            N'Number',     0, 4),
 (N'DATE',         N'Date',               N'Date response.',                               N'Date',       0, 5),
 (N'RATING',       N'Rating',             N'Rating scale response.',                       N'Rating',     0, 6),
 (N'OBSERVATION',  N'Observation Only',   N'Captures an observation without a scored answer.', N'Observation', 0, 7),
 (N'EVIDENCE',     N'Evidence Upload',    N'Evidence upload requirement.',                 N'Evidence',   1, 8),
 (N'CHECKLIST',    N'Checklist Item',     N'Checklist item response.',                     N'Checklist',  0, 9)
) AS source(question_code,question_name,description,answer_shape,requires_evidence,display_order)
ON target.question_code=source.question_code
WHEN MATCHED THEN UPDATE SET question_name=source.question_name,description=source.description,answer_shape=source.answer_shape,requires_evidence=source.requires_evidence,display_order=source.display_order,lifecycle_status=N'Published',status=N'Active',updated_by=N'system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(question_code,question_name,description,answer_shape,requires_evidence,display_order,lifecycle_status,status,entered_by)
VALUES(source.question_code,source.question_name,source.description,source.answer_shape,source.requires_evidence,source.display_order,N'Published',N'Active',N'system');
GO

/* 2.7 Sampling models */
MERGE GRAC_New.assurance_sampling_model AS target
USING (VALUES
 (N'COMPLETE',     N'Complete Population',  N'Test the complete population.'),
 (N'RANDOM',       N'Random Sampling',      N'Simple random sampling.'),
 (N'RISK_BASED',   N'Risk Based',           N'Risk-based sample selection.'),
 (N'STATISTICAL', N'Statistical',           N'Statistical sampling with confidence intervals.'),
 (N'PERCENTAGE',   N'Percentage Based',     N'Sample based on percentage of the population.'),
 (N'MANUAL',       N'Manual Selection',     N'Manual sample selection by reviewer.')
) AS source(sampling_code,sampling_name,description)
ON target.sampling_code=source.sampling_code
WHEN MATCHED THEN UPDATE SET sampling_name=source.sampling_name,description=source.description,lifecycle_status=N'Published',status=N'Active',updated_by=N'system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(sampling_code,sampling_name,description,lifecycle_status,status,entered_by)
VALUES(source.sampling_code,source.sampling_name,source.description,N'Published',N'Active',N'system');
GO

/* 2.8 Frequency types */
MERGE GRAC_New.assurance_frequency_type AS target
USING (VALUES
 (N'DAILY',       N'Daily',        N'Daily execution.',        1,   1),
 (N'WEEKLY',      N'Weekly',       N'Weekly execution.',       7,   2),
 (N'MONTHLY',     N'Monthly',      N'Monthly execution.',      30,  3),
 (N'QUARTERLY',   N'Quarterly',    N'Quarterly execution.',    90,  4),
 (N'HALF_YEARLY', N'Half-Yearly',  N'Half-yearly execution.',  180, 5),
 (N'ANNUAL',      N'Annual',       N'Annual execution.',       365, 6),
 (N'EVENT_DRIVEN',N'Event Driven', N'Executed on a triggering event.', NULL, 7),
 (N'CONTINUOUS',  N'Continuous',   N'Continuous execution.',   NULL, 8),
 (N'ON_DEMAND',   N'On Demand',    N'Executed on demand.',     NULL, 9)
) AS source(frequency_code,frequency_name,description,interval_days,display_order)
ON target.frequency_code=source.frequency_code
WHEN MATCHED THEN UPDATE SET frequency_name=source.frequency_name,description=source.description,interval_days=source.interval_days,display_order=source.display_order,lifecycle_status=N'Published',status=N'Active',updated_by=N'system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(frequency_code,frequency_name,description,interval_days,display_order,lifecycle_status,status,entered_by)
VALUES(source.frequency_code,source.frequency_name,source.description,source.interval_days,source.display_order,N'Published',N'Active',N'system');
GO

/* 2.9 Report templates */
MERGE GRAC_New.assurance_report_template AS target
USING (VALUES
 (N'EXEC_SUMMARY',      N'Executive Summary',        N'Executive summary report template.',            N'Executive'),
 (N'IA_REPORT',         N'Internal Audit Report',    N'Standard internal audit report template.',      N'Engagement'),
 (N'COMP_REPORT',       N'Compliance Review',        N'Compliance review report template.',            N'Engagement'),
 (N'VENDOR_REPORT',     N'Vendor Assessment',        N'Vendor assessment report template.',            N'Engagement'),
 (N'OBS_REGISTER',      N'Observation Register',     N'Observation register listing all observations.', N'Register'),
 (N'GAP_SUMMARY',       N'Gap Summary',              N'Summary of gaps identified during assurance.',  N'Register'),
 (N'MGMT_DASHBOARD',    N'Management Dashboard',     N'Management dashboard report layout.',           N'Dashboard')
) AS source(template_code,template_name,description,report_scope)
ON target.template_code=source.template_code
WHEN MATCHED THEN UPDATE SET template_name=source.template_name,description=source.description,report_scope=source.report_scope,lifecycle_status=N'Published',status=N'Active',updated_by=N'system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(template_code,template_name,description,report_scope,lifecycle_status,status,entered_by)
VALUES(source.template_code,source.template_name,source.description,source.report_scope,N'Published',N'Active',N'system');
GO

/* 2.10 Starter templates */
MERGE GRAC_New.assurance_starter_template AS target
USING (
 SELECT v.template_code,v.template_name,v.description,
        cat.assurance_category_id,sm.scoring_model_id,wt.workflow_template_id,
        samp.sampling_model_id,fr.frequency_type_id,rt.report_template_id
 FROM (VALUES
  (N'ISO27001_IA', N'ISO 27001 Internal Audit',   N'Starter template for ISO 27001 internal audits.',              N'IS_AUDIT',       N'COMP_SCORE', N'MAKER_REVIEWER_APPROVER',N'RISK_BASED',   N'ANNUAL',       N'IA_REPORT'),
  (N'RBI_IS_AUDIT',N'RBI Information Systems Audit',N'Starter template for RBI-mandated IS audits.',               N'IS_AUDIT',       N'COMP_SCORE', N'MAKER_REVIEWER_APPROVER',N'RISK_BASED',   N'ANNUAL',       N'IA_REPORT'),
  (N'VENDOR_STD', N'Vendor Assessment',           N'Starter template for standard vendor assessments.',            N'VENDOR_ASSESS',  N'MATURITY',   N'MAKER_REVIEWER',         N'PERCENTAGE',   N'ANNUAL',       N'VENDOR_REPORT'),
  (N'DPDP_READY', N'DPDP Readiness Assessment',   N'Starter template for DPDP Act readiness assessments.',         N'COMP_REVIEW',    N'COMP_SCORE', N'MAKER_REVIEWER_APPROVER',N'COMPLETE',     N'ON_DEMAND',    N'COMP_REPORT')
 ) v(template_code,template_name,description,category_code,scoring_code,workflow_code,sampling_code,frequency_code,report_code)
 LEFT JOIN GRAC_New.assurance_category cat ON cat.category_code=v.category_code
 LEFT JOIN GRAC_New.assurance_scoring_model sm ON sm.model_code=v.scoring_code
 LEFT JOIN GRAC_New.assurance_workflow_template wt ON wt.template_code=v.workflow_code
 LEFT JOIN GRAC_New.assurance_sampling_model samp ON samp.sampling_code=v.sampling_code
 LEFT JOIN GRAC_New.assurance_frequency_type fr ON fr.frequency_code=v.frequency_code
 LEFT JOIN GRAC_New.assurance_report_template rt ON rt.template_code=v.report_code
) AS source
ON target.template_code=source.template_code
WHEN MATCHED THEN UPDATE SET template_name=source.template_name,description=source.description,
 assurance_category_id=source.assurance_category_id,scoring_model_id=source.scoring_model_id,
 workflow_template_id=source.workflow_template_id,sampling_model_id=source.sampling_model_id,
 frequency_type_id=source.frequency_type_id,report_template_id=source.report_template_id,
 lifecycle_status=N'Published',status=N'Active',updated_by=N'system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(template_code,template_name,description,assurance_category_id,scoring_model_id,workflow_template_id,sampling_model_id,frequency_type_id,report_template_id,lifecycle_status,status,entered_by)
VALUES(source.template_code,source.template_name,source.description,source.assurance_category_id,source.scoring_model_id,source.workflow_template_id,source.sampling_model_id,source.frequency_type_id,source.report_template_id,N'Published',N'Active',N'system');
GO

/* -----------------------------------------------------------
   3. Menu + Role Permissions
   Register the "Assurance Management" parent menu and its Phase 1
   child menus alongside existing GRAC menus.  Existing menus and
   permissions are left untouched.
   ----------------------------------------------------------- */
/* --------------------------------------------------------------
   IMPORTANT.  cm_menu grouping is done via parent_menu_id which
   references cm_menu.menu_id.  MERGE evaluates the LEFT JOIN over
   the source rows against the TARGET's initial state, so a MERGE
   that inserts a parent and its children in one shot leaves every
   child with parent_menu_id=NULL on first run.  Split into two
   statements: (1) upsert the parent, (2) upsert the children with
   the now-resolved parent_menu_id.
   -------------------------------------------------------------- */

/* Step 1 - upsert the Assurance Management parent menu. */
MERGE GRAC_New.cm_menu AS target
USING (VALUES
 (N'assurance-management', N'Assurance Management', CAST(NULL AS NVARCHAR(300)), 400, N'clipboard-check')
) AS source(menu_code,menu_name,route_url,display_order,icon)
ON target.menu_code=source.menu_code
WHEN MATCHED THEN UPDATE SET parent_menu_id=NULL,menu_name=source.menu_name,route_url=source.route_url,display_order=source.display_order,icon=source.icon,status=N'Active'
WHEN NOT MATCHED THEN INSERT(parent_menu_id,menu_name,menu_code,route_url,display_order,icon,status,entered_by)
VALUES(NULL,source.menu_name,source.menu_code,source.route_url,source.display_order,source.icon,N'Active',N'system');
GO

/* Step 2 - upsert Assurance Management children.  Parent is guaranteed
   to exist by the previous step, so the LEFT JOIN resolves parent_menu_id. */
DECLARE @assMenus TABLE(menu_code NVARCHAR(100),parent_code NVARCHAR(100),menu_name NVARCHAR(200),route_url NVARCHAR(300),display_order INT,icon NVARCHAR(80));
INSERT @assMenus VALUES
 (N'assurance-categories',        N'assurance-management', N'Assurance Categories',          N'Repository/Index?areaKey=assurance-categories',        410, N'list-check'),
 (N'assurance-scoring-models',    N'assurance-management', N'Scoring Models',                N'Repository/Index?areaKey=assurance-scoring-models',    420, N'chart-simple'),
 (N'assurance-severity',          N'assurance-management', N'Observation Severity',          N'Repository/Index?areaKey=assurance-severity',          430, N'triangle-exclamation'),
 (N'assurance-gap-categories',    N'assurance-management', N'Gap Categories',                N'Repository/Index?areaKey=assurance-gap-categories',    440, N'circle-exclamation'),
 (N'assurance-workflow-templates',N'assurance-management', N'Workflow Templates',            N'Repository/Index?areaKey=assurance-workflow-templates',450, N'diagram-project'),
 (N'assurance-question-types',    N'assurance-management', N'Question Types',                N'Repository/Index?areaKey=assurance-question-types',    460, N'circle-question'),
 (N'assurance-sampling-models',   N'assurance-management', N'Sampling Models',               N'Repository/Index?areaKey=assurance-sampling-models',   470, N'shuffle'),
 (N'assurance-frequency-types',   N'assurance-management', N'Frequency Types',               N'Repository/Index?areaKey=assurance-frequency-types',   480, N'calendar-days'),
 (N'assurance-report-templates',  N'assurance-management', N'Report Templates',              N'Repository/Index?areaKey=assurance-report-templates',  490, N'file-lines'),
 (N'assurance-starter-templates', N'assurance-management', N'Starter Assurance Templates',   N'Repository/Index?areaKey=assurance-starter-templates', 500, N'copy'),
 (N'assurance-version-history',   N'assurance-management', N'Version History',               N'Repository/Index?areaKey=assurance-version-history',   510, N'clock-rotate-left');

MERGE GRAC_New.cm_menu AS target
USING (
 SELECT m.menu_code,p.menu_id parent_menu_id,m.menu_name,m.route_url,m.display_order,m.icon
 FROM @assMenus m
 JOIN GRAC_New.cm_menu p ON p.menu_code=m.parent_code
) AS source
ON target.menu_code=source.menu_code
WHEN MATCHED THEN UPDATE SET parent_menu_id=source.parent_menu_id,menu_name=source.menu_name,route_url=source.route_url,display_order=source.display_order,icon=source.icon,status=N'Active'
WHEN NOT MATCHED THEN INSERT(parent_menu_id,menu_name,menu_code,route_url,display_order,icon,status,entered_by)
VALUES(source.parent_menu_id,source.menu_name,source.menu_code,source.route_url,source.display_order,source.icon,N'Active',N'system');
GO

/* Role permission matrix for the new menus.
   - CM_ADMIN     : full access (view/add/edit/inactive/approve).
   - CM_APPROVER  : view + approve (approves publish/retire).
   - CM_REVIEWER  : view + edit (submit for review).
   - CM_USER      : view only. */
MERGE GRAC_New.cm_role_permission AS target
USING (
 SELECT r.role_id,m.menu_id,
   CAST(1 AS BIT) can_view,
   CAST(CASE WHEN r.role_name='CM_ADMIN' THEN 1 ELSE 0 END AS BIT) can_add,
   CAST(CASE WHEN r.role_name IN ('CM_ADMIN','CM_REVIEWER') THEN 1 ELSE 0 END AS BIT) can_edit,
   CAST(CASE WHEN r.role_name='CM_ADMIN' THEN 1 ELSE 0 END AS BIT) can_inactive,
   CAST(CASE WHEN r.role_name IN ('CM_ADMIN','CM_APPROVER') THEN 1 ELSE 0 END AS BIT) can_approve
 FROM GRAC_New.cm_role r
 CROSS JOIN GRAC_New.cm_menu m
 WHERE r.role_name IN ('CM_ADMIN','CM_REVIEWER','CM_APPROVER','CM_USER')
   AND m.menu_code IN (
     'assurance-management','assurance-categories','assurance-scoring-models',
     'assurance-severity','assurance-gap-categories','assurance-workflow-templates',
     'assurance-question-types','assurance-sampling-models','assurance-frequency-types',
     'assurance-report-templates','assurance-starter-templates','assurance-version-history')
) AS source
ON target.role_id=source.role_id AND target.menu_id=source.menu_id
WHEN MATCHED THEN UPDATE SET can_view=source.can_view,can_add=source.can_add,can_edit=source.can_edit,can_inactive=source.can_inactive,can_approve=source.can_approve,status='Active'
WHEN NOT MATCHED THEN INSERT(role_id,menu_id,can_view,can_add,can_edit,can_inactive,can_approve,status,entered_by)
VALUES(source.role_id,source.menu_id,source.can_view,source.can_add,source.can_edit,source.can_inactive,source.can_approve,'Active','system');
GO

/* Legacy security_permission (area_key based) - grant defaults consistent with
   the pattern used by the Regulatory Repository. */
DECLARE @assAreas TABLE(area_key NVARCHAR(100));
INSERT @assAreas VALUES
 ('assurance-categories'),('assurance-scoring-models'),('assurance-severity'),
 ('assurance-gap-categories'),('assurance-workflow-templates'),('assurance-workflow-stages'),
 ('assurance-question-types'),('assurance-sampling-models'),('assurance-frequency-types'),
 ('assurance-report-templates'),('assurance-starter-templates'),('assurance-version-history');

MERGE GRAC_New.security_permission AS target
USING (
 SELECT area_key,action_code,area_key+' '+action_code permission_name
 FROM @assAreas
 CROSS JOIN (VALUES ('VIEW'),('ADD'),('EDIT'),('DELETE'),('APPROVE'),('REJECT'),('PUBLISH'),('RETIRE')) action(action_code)
) AS source
ON target.area_key=source.area_key AND target.action_code=source.action_code
WHEN NOT MATCHED THEN INSERT(area_key,action_code,permission_name,entered_by)
VALUES(source.area_key,source.action_code,source.permission_name,'system');
GO

/* CM_ADMIN gets everything; reviewers/approvers get VIEW; approvers additionally get APPROVE/PUBLISH/RETIRE. */
INSERT GRAC_New.security_role_permission(security_role_id,security_permission_id,entered_by)
SELECT r.security_role_id,p.security_permission_id,'system'
FROM GRAC_New.security_role r
CROSS JOIN GRAC_New.security_permission p
WHERE r.role_code='CM_ADMIN'
  AND p.area_key IN (
    'assurance-categories','assurance-scoring-models','assurance-severity',
    'assurance-gap-categories','assurance-workflow-templates','assurance-workflow-stages',
    'assurance-question-types','assurance-sampling-models','assurance-frequency-types',
    'assurance-report-templates','assurance-starter-templates','assurance-version-history')
  AND NOT EXISTS(SELECT 1 FROM GRAC_New.security_role_permission x WHERE x.security_role_id=r.security_role_id AND x.security_permission_id=p.security_permission_id);

INSERT GRAC_New.security_role_permission(security_role_id,security_permission_id,entered_by)
SELECT r.security_role_id,p.security_permission_id,'system'
FROM GRAC_New.security_role r
CROSS JOIN GRAC_New.security_permission p
WHERE r.role_code IN ('CM_REVIEWER','CM_APPROVER')
  AND p.action_code='VIEW'
  AND p.area_key IN (
    'assurance-categories','assurance-scoring-models','assurance-severity',
    'assurance-gap-categories','assurance-workflow-templates','assurance-workflow-stages',
    'assurance-question-types','assurance-sampling-models','assurance-frequency-types',
    'assurance-report-templates','assurance-starter-templates','assurance-version-history')
  AND NOT EXISTS(SELECT 1 FROM GRAC_New.security_role_permission x WHERE x.security_role_id=r.security_role_id AND x.security_permission_id=p.security_permission_id);

INSERT GRAC_New.security_role_permission(security_role_id,security_permission_id,entered_by)
SELECT r.security_role_id,p.security_permission_id,'system'
FROM GRAC_New.security_role r
CROSS JOIN GRAC_New.security_permission p
WHERE r.role_code='CM_APPROVER'
  AND p.action_code IN ('APPROVE','PUBLISH','RETIRE','REJECT')
  AND p.area_key IN (
    'assurance-categories','assurance-scoring-models','assurance-severity',
    'assurance-gap-categories','assurance-workflow-templates','assurance-workflow-stages',
    'assurance-question-types','assurance-sampling-models','assurance-frequency-types',
    'assurance-report-templates','assurance-starter-templates','assurance-version-history')
  AND NOT EXISTS(SELECT 1 FROM GRAC_New.security_role_permission x WHERE x.security_role_id=r.security_role_id AND x.security_permission_id=p.security_permission_id);
GO
