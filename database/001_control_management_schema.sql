/*
  GRAC Regulatory Intelligence Repository and Change Management Engine
  Standalone SQL Server schema. Rerunnable for first-review deployment.
  All mutable entities use status-based retirement. Audit rows are append-only.
*/
IF SCHEMA_ID('GRAC_New') IS NULL EXEC('CREATE SCHEMA GRAC_New');
GO

CREATE OR ALTER PROCEDURE dbo.cm_bootstrap_table @sql NVARCHAR(MAX) AS BEGIN EXEC sp_executesql @sql; END;
GO

IF OBJECT_ID('GRAC_New.authority','U') IS NULL CREATE TABLE GRAC_New.authority(
 authority_id BIGINT IDENTITY PRIMARY KEY, authority_name NVARCHAR(250) NOT NULL, authority_code NVARCHAR(80) NOT NULL UNIQUE,
 description NVARCHAR(MAX) NULL, jurisdiction NVARCHAR(160) NULL, website NVARCHAR(500) NULL, status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL, entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL);
GO
IF OBJECT_ID('GRAC_New.artifact','U') IS NULL CREATE TABLE GRAC_New.artifact(
 artifact_id BIGINT IDENTITY PRIMARY KEY, authority_id BIGINT NOT NULL REFERENCES GRAC_New.authority(authority_id), artifact_name NVARCHAR(300) NOT NULL,
 artifact_code NVARCHAR(100) NOT NULL UNIQUE, description NVARCHAR(MAX) NULL, artifact_category NVARCHAR(80) NOT NULL, industry NVARCHAR(160) NULL,
 jurisdiction NVARCHAR(160) NULL, status NVARCHAR(30) NOT NULL DEFAULT 'Active', entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL);
GO
IF OBJECT_ID('GRAC_New.release','U') IS NULL CREATE TABLE GRAC_New.release(
 release_id BIGINT IDENTITY PRIMARY KEY, artifact_id BIGINT NOT NULL REFERENCES GRAC_New.artifact(artifact_id), version_no NVARCHAR(80) NOT NULL,
 effective_dt DATE NULL, end_dt DATE NULL, release_notes NVARCHAR(MAX) NULL, status NVARCHAR(30) NOT NULL DEFAULT 'Draft',
 entered_by NVARCHAR(100) NOT NULL, entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL,
 CONSTRAINT uq_cm_release UNIQUE(artifact_id, version_no));
GO
IF OBJECT_ID('GRAC_New.source_structure_node','U') IS NULL CREATE TABLE GRAC_New.source_structure_node(
 structure_node_id BIGINT IDENTITY PRIMARY KEY, release_id BIGINT NOT NULL REFERENCES GRAC_New.release(release_id),
 parent_node_id BIGINT NULL REFERENCES GRAC_New.source_structure_node(structure_node_id), node_level INT NOT NULL, node_type NVARCHAR(100) NOT NULL,
 node_reference NVARCHAR(160) NOT NULL, node_title NVARCHAR(500) NULL, description NVARCHAR(MAX) NULL, display_order INT NOT NULL DEFAULT 0,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active', entered_by NVARCHAR(100) NOT NULL, entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL, CONSTRAINT uq_cm_source_node UNIQUE(release_id,node_reference));
GO
IF OBJECT_ID('GRAC_New.statement_classification','U') IS NULL CREATE TABLE GRAC_New.statement_classification(
 statement_classification_id BIGINT IDENTITY PRIMARY KEY,
 release_id BIGINT NOT NULL REFERENCES GRAC_New.release(release_id),
 classification_code NVARCHAR(80) NOT NULL,
 classification_scheme NVARCHAR(200) NULL,
 classification_name NVARCHAR(200) NOT NULL,
 description NVARCHAR(MAX) NULL,
 display_order INT NOT NULL DEFAULT 0,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_cm_statement_classification UNIQUE(release_id,classification_code));
GO
IF OBJECT_ID('GRAC_New.framework_statement','U') IS NULL CREATE TABLE GRAC_New.framework_statement(
 framework_statement_id BIGINT IDENTITY PRIMARY KEY,
 release_id BIGINT NOT NULL REFERENCES GRAC_New.release(release_id),
 structure_node_id BIGINT NOT NULL REFERENCES GRAC_New.source_structure_node(structure_node_id),
 classification_id BIGINT NULL REFERENCES GRAC_New.statement_classification(statement_classification_id),
 statement_reference NVARCHAR(160) NOT NULL,
 statement_title NVARCHAR(500) NULL,
 statement_text NVARCHAR(MAX) NOT NULL,
 statement_type NVARCHAR(100) NULL,
 remarks NVARCHAR(MAX) NULL,
 display_order INT NOT NULL DEFAULT 0,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_cm_framework_statement UNIQUE(release_id,statement_reference));
GO
IF COL_LENGTH('GRAC_New.framework_statement','statement_type') IS NULL ALTER TABLE GRAC_New.framework_statement ADD statement_type NVARCHAR(100) NULL;
GO
IF COL_LENGTH('GRAC_New.framework_statement','remarks') IS NULL ALTER TABLE GRAC_New.framework_statement ADD remarks NVARCHAR(MAX) NULL;
GO
IF COL_LENGTH('GRAC_New.framework_statement','classification_id') IS NULL ALTER TABLE GRAC_New.framework_statement ADD classification_id BIGINT NULL;
GO
IF OBJECT_ID('GRAC_New.control','U') IS NULL CREATE TABLE GRAC_New.control(
 control_id BIGINT IDENTITY PRIMARY KEY, control_code NVARCHAR(100) NOT NULL UNIQUE,
 control_name NVARCHAR(300) NOT NULL, description NVARCHAR(MAX) NULL, objective NVARCHAR(MAX) NULL, status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL, entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL);
GO
IF OBJECT_ID('GRAC_New.control_domain','U') IS NULL CREATE TABLE GRAC_New.control_domain(
 control_domain_id BIGINT IDENTITY PRIMARY KEY, domain_name NVARCHAR(200) NOT NULL UNIQUE, description NVARCHAR(MAX) NULL,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active', entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL);
GO
IF OBJECT_ID('GRAC_New.control_sub_domain','U') IS NULL CREATE TABLE GRAC_New.control_sub_domain(
 control_sub_domain_id BIGINT IDENTITY PRIMARY KEY, control_domain_id BIGINT NOT NULL REFERENCES GRAC_New.control_domain(control_domain_id),
 sub_domain_name NVARCHAR(200) NOT NULL, description NVARCHAR(MAX) NULL, status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system', entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL, CONSTRAINT uq_cm_control_sub_domain UNIQUE(control_domain_id,sub_domain_name));
GO
IF COL_LENGTH('GRAC_New.control','control_domain_id') IS NULL ALTER TABLE GRAC_New.control ADD control_domain_id BIGINT NULL REFERENCES GRAC_New.control_domain(control_domain_id);
GO
IF COL_LENGTH('GRAC_New.control','control_sub_domain_id') IS NULL ALTER TABLE GRAC_New.control ADD control_sub_domain_id BIGINT NULL REFERENCES GRAC_New.control_sub_domain(control_sub_domain_id);
GO
IF OBJECT_ID('GRAC_New.control_keyword','U') IS NULL CREATE TABLE GRAC_New.control_keyword(
 control_keyword_id BIGINT IDENTITY PRIMARY KEY, control_id BIGINT NOT NULL REFERENCES GRAC_New.control(control_id),
 keyword NVARCHAR(120) NOT NULL, status NVARCHAR(30) NOT NULL DEFAULT 'Active', entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL,
 CONSTRAINT uq_cm_control_keyword UNIQUE(control_id,keyword));
GO
MERGE GRAC_New.control_domain AS target
USING (VALUES
 (N'Access Control',N'GRAC internal controls for identity, authentication, user access and privilege governance.',1),
 (N'KYC & Customer Due Diligence',N'GRAC internal controls for customer onboarding, due diligence, risk classification and screening.',2),
 (N'Vendor Risk Management',N'GRAC internal controls for third-party onboarding, assessment, monitoring and exit.',3),
 (N'Data Protection & Privacy',N'GRAC internal controls for data classification, privacy compliance, retention and subject rights.',4),
 (N'Incident Management',N'GRAC internal controls for incident detection, response, analysis and corrective action.',5),
 (N'Business Continuity',N'GRAC internal controls for backup management, disaster recovery and operational resilience.',6)
) AS source(domain_name,description,display_order)
ON target.domain_name=source.domain_name
WHEN MATCHED THEN UPDATE SET description=source.description,status=N'Active',updated_by=N'system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(domain_name,description,status,entered_by) VALUES(source.domain_name,source.description,N'Active',N'system');
GO
MERGE GRAC_New.control_sub_domain AS target
USING (
 SELECT d.control_domain_id,v.sub_domain_name,v.description
 FROM (VALUES
  (N'Access Control',N'Identity & User Access Management',N'User lifecycle, access review, privileged access and MFA controls.'),
  (N'Access Control',N'Password & Authentication',N'Password, credential, account lockout and dormant account controls.'),
  (N'KYC & Customer Due Diligence',N'Customer Onboarding',N'Customer identity verification, document collection and initial risk classification controls.'),
  (N'KYC & Customer Due Diligence',N'Ongoing Due Diligence',N'Periodic KYC review, high-risk monitoring, sanctions and PEP screening controls.'),
  (N'Vendor Risk Management',N'Vendor Onboarding',N'Vendor due diligence, risk classification, contract and SLA review controls.'),
  (N'Vendor Risk Management',N'Vendor Monitoring',N'Periodic vendor assessment, third-party access review and vendor exit controls.'),
  (N'Data Protection & Privacy',N'Data Classification',N'Sensitive data identification, labeling and handling controls.'),
  (N'Data Protection & Privacy',N'Privacy Compliance',N'Consent, data subject request and personal data retention controls.'),
  (N'Incident Management',N'Incident Detection',N'Security event monitoring and incident logging controls.'),
  (N'Incident Management',N'Incident Response',N'Incident escalation, root cause analysis and corrective action controls.'),
  (N'Business Continuity',N'Backup Management',N'Backup scheduling and restoration testing controls.'),
  (N'Business Continuity',N'Disaster Recovery',N'Disaster recovery plan maintenance and drill execution controls.')
 ) v(domain_name,sub_domain_name,description)
 JOIN GRAC_New.control_domain d ON d.domain_name=v.domain_name
) AS source(control_domain_id,sub_domain_name,description)
ON target.control_domain_id=source.control_domain_id AND target.sub_domain_name=source.sub_domain_name
WHEN MATCHED THEN UPDATE SET description=source.description,status=N'Active',updated_by=N'system',updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(control_domain_id,sub_domain_name,description,status,entered_by) VALUES(source.control_domain_id,source.sub_domain_name,source.description,N'Active',N'system');
GO
DECLARE @grac_control_seed TABLE(
 domain_name NVARCHAR(200) NOT NULL,
 sub_domain_name NVARCHAR(200) NOT NULL,
 control_code NVARCHAR(100) NOT NULL,
 control_name NVARCHAR(300) NOT NULL,
 description NVARCHAR(MAX) NULL,
 objective NVARCHAR(MAX) NULL,
 keywords NVARCHAR(MAX) NULL
);

INSERT @grac_control_seed(domain_name,sub_domain_name,control_code,control_name,description,objective,keywords) VALUES
 (N'Access Control',N'Identity & User Access Management',N'AC-001',N'User Access Provisioning',N'Ensure user access is requested, approved, provisioned and recorded based on business need.',N'Provide authorized users with appropriate access while preventing unauthorized account creation.',N'access provisioning,user onboarding,least privilege,approval'),
 (N'Access Control',N'Identity & User Access Management',N'AC-002',N'User Access Review',N'Perform periodic review of user access rights and remove inappropriate or obsolete access.',N'Ensure access remains aligned with user role, business need and segregation of duties.',N'access review,recertification,least privilege,user access'),
 (N'Access Control',N'Identity & User Access Management',N'AC-003',N'Privileged Access Management',N'Control, monitor and periodically review privileged and administrative access.',N'Reduce the risk of misuse of high-risk privileged accounts.',N'privileged access,admin access,pam,elevated rights'),
 (N'Access Control',N'Identity & User Access Management',N'AC-004',N'Multi-Factor Authentication',N'Enforce multi-factor authentication for high-risk users, remote access and privileged activities.',N'Strengthen authentication and reduce credential compromise risk.',N'mfa,multi-factor authentication,authentication,privileged users'),
 (N'Access Control',N'Password & Authentication',N'AC-005',N'Password Policy Management',N'Define and enforce password complexity, rotation and reuse controls where passwords are used.',N'Maintain strong authentication secrets and reduce password-related compromise risk.',N'password policy,password complexity,password rotation,authentication'),
 (N'Access Control',N'Password & Authentication',N'AC-006',N'Account Lockout Controls',N'Lock or throttle accounts after repeated failed authentication attempts.',N'Reduce brute-force and credential stuffing risks.',N'account lockout,failed login,brute force,authentication'),
 (N'Access Control',N'Password & Authentication',N'AC-007',N'Dormant Account Management',N'Identify, review and disable dormant or unused accounts within defined timelines.',N'Reduce attack surface from stale accounts and orphaned access.',N'dormant account,inactive user,orphan account,user access'),
 (N'KYC & Customer Due Diligence',N'Customer Onboarding',N'KYC-001',N'Customer Identity Verification',N'Verify customer identity using reliable and independent documents, data or sources during onboarding.',N'Establish customer identity before business relationship activation.',N'kyc,identity verification,customer onboarding,cdd'),
 (N'KYC & Customer Due Diligence',N'Customer Onboarding',N'KYC-002',N'KYC Document Collection',N'Collect and maintain required KYC documents based on customer type and regulatory requirements.',N'Ensure adequate customer records are available for due diligence and audit.',N'kyc documents,document collection,customer records,cdd'),
 (N'KYC & Customer Due Diligence',N'Customer Onboarding',N'KYC-003',N'Customer Risk Classification',N'Classify customers by risk profile using defined criteria during onboarding.',N'Apply proportionate due diligence and monitoring based on customer risk.',N'customer risk,risk classification,onboarding,aml'),
 (N'KYC & Customer Due Diligence',N'Ongoing Due Diligence',N'KYC-004',N'Periodic KYC Review',N'Perform periodic review and refresh of customer KYC information based on risk category.',N'Keep customer due diligence information current and reliable.',N'periodic kyc,kyc refresh,ongoing due diligence,cdd'),
 (N'KYC & Customer Due Diligence',N'Ongoing Due Diligence',N'KYC-005',N'High-Risk Customer Monitoring',N'Monitor high-risk customer relationships using enhanced due diligence and review triggers.',N'Detect and manage elevated financial crime and compliance risk.',N'high-risk customer,edd,monitoring,aml'),
 (N'KYC & Customer Due Diligence',N'Ongoing Due Diligence',N'KYC-006',N'Sanctions and PEP Screening',N'Screen customers and relevant parties against sanctions, watchlists and politically exposed person lists.',N'Prevent prohibited relationships and identify enhanced due diligence obligations.',N'sanctions,pep screening,watchlist,aml'),
 (N'Vendor Risk Management',N'Vendor Onboarding',N'VRM-001',N'Vendor Due Diligence',N'Perform risk-based due diligence before onboarding vendors or third parties.',N'Assess vendor suitability and control posture before engagement.',N'vendor due diligence,third party,onboarding,supplier risk'),
 (N'Vendor Risk Management',N'Vendor Onboarding',N'VRM-002',N'Vendor Risk Classification',N'Classify vendors by criticality, data access, service impact and inherent risk.',N'Apply appropriate governance and monitoring based on vendor risk.',N'vendor risk,criticality,third party classification,supplier risk'),
 (N'Vendor Risk Management',N'Vendor Onboarding',N'VRM-003',N'Contract and SLA Review',N'Review vendor contracts and service level agreements for compliance, security and operational obligations.',N'Ensure contractual commitments address required controls and accountability.',N'contract review,sla,vendor agreement,third party'),
 (N'Vendor Risk Management',N'Vendor Monitoring',N'VRM-004',N'Periodic Vendor Assessment',N'Perform periodic assessment of vendor performance, risk and control compliance.',N'Ensure vendor risk remains within accepted tolerance over the relationship lifecycle.',N'vendor assessment,third party monitoring,periodic review,supplier risk'),
 (N'Vendor Risk Management',N'Vendor Monitoring',N'VRM-005',N'Third-Party Access Review',N'Review third-party access to systems, data and facilities on a periodic basis.',N'Ensure third-party access remains authorized, necessary and controlled.',N'third-party access,vendor access,access review,external users'),
 (N'Vendor Risk Management',N'Vendor Monitoring',N'VRM-006',N'Vendor Exit Management',N'Manage vendor offboarding, access removal, data return or disposal and contract closure activities.',N'Ensure risks are controlled when vendor relationships end.',N'vendor exit,offboarding,data return,access removal'),
 (N'Data Protection & Privacy',N'Data Classification',N'DP-001',N'Sensitive Data Identification',N'Identify sensitive, confidential, regulated and personal data across systems and processes.',N'Enable appropriate protection based on data sensitivity and regulatory obligation.',N'sensitive data,data discovery,personal data,classification'),
 (N'Data Protection & Privacy',N'Data Classification',N'DP-002',N'Data Labeling',N'Apply data labels or classifications according to approved data handling standards.',N'Make data sensitivity visible for users, systems and downstream controls.',N'data labeling,classification,label,information handling'),
 (N'Data Protection & Privacy',N'Data Classification',N'DP-003',N'Data Handling Rules',N'Define and enforce handling rules for storage, transmission, sharing and disposal of data.',N'Prevent unauthorized disclosure, misuse or loss of sensitive information.',N'data handling,data protection,storage,transmission,disposal'),
 (N'Data Protection & Privacy',N'Privacy Compliance',N'DP-004',N'Consent Management',N'Capture, maintain and honor valid consent where personal data processing depends on consent.',N'Ensure personal data processing aligns with privacy obligations and customer choices.',N'consent,privacy,personal data,processing basis'),
 (N'Data Protection & Privacy',N'Privacy Compliance',N'DP-005',N'Data Subject Request Handling',N'Manage data subject requests for access, correction, deletion, portability or objection within defined timelines.',N'Protect individual privacy rights and demonstrate timely compliance.',N'dsr,data subject request,privacy rights,personal data'),
 (N'Data Protection & Privacy',N'Privacy Compliance',N'DP-006',N'Personal Data Retention',N'Define and enforce retention and disposal rules for personal data.',N'Limit personal data retention to approved business and regulatory needs.',N'data retention,personal data,disposal,privacy'),
 (N'Incident Management',N'Incident Detection',N'IM-001',N'Security Event Monitoring',N'Monitor security events and alerts across critical systems and services.',N'Detect potential incidents quickly and support timely response.',N'security monitoring,event monitoring,alerts,siem'),
 (N'Incident Management',N'Incident Detection',N'IM-002',N'Incident Logging',N'Record incidents with required details, ownership, severity, timeline and status.',N'Maintain a reliable incident record for response, audit and lessons learned.',N'incident logging,incident record,severity,timeline'),
 (N'Incident Management',N'Incident Response',N'IM-003',N'Incident Escalation',N'Escalate incidents based on severity, impact and defined notification criteria.',N'Ensure timely management attention and coordinated response.',N'incident escalation,severity,notification,response'),
 (N'Incident Management',N'Incident Response',N'IM-004',N'Root Cause Analysis',N'Perform root cause analysis for significant incidents and recurring issues.',N'Identify underlying causes and prevent recurrence.',N'root cause analysis,rca,incident review,problem management'),
 (N'Incident Management',N'Incident Response',N'IM-005',N'Corrective Action Tracking',N'Track corrective and preventive actions from incidents through closure.',N'Ensure incident lessons are converted into completed remediation actions.',N'corrective action,remediation,action tracking,cap'),
 (N'Business Continuity',N'Backup Management',N'BC-001',N'Backup Scheduling',N'Define and operate backup schedules for critical systems, data and services.',N'Ensure recoverable copies are available according to business recovery needs.',N'backup schedule,backup policy,recovery,critical systems'),
 (N'Business Continuity',N'Backup Management',N'BC-002',N'Backup Restoration Testing',N'Test backup restoration periodically and record results and exceptions.',N'Confirm backups can be restored within required recovery objectives.',N'backup restoration,restore test,recovery testing,backup'),
 (N'Business Continuity',N'Disaster Recovery',N'BC-003',N'DR Plan Maintenance',N'Maintain disaster recovery plans, recovery contacts, dependencies and procedures.',N'Keep disaster recovery capability current and actionable.',N'dr plan,disaster recovery,continuity,recovery procedures'),
 (N'Business Continuity',N'Disaster Recovery',N'BC-004',N'DR Drill Execution',N'Conduct disaster recovery drills and document outcomes, issues and improvements.',N'Validate recovery readiness and improve resilience through exercises.',N'dr drill,disaster recovery test,resilience,continuity');

MERGE GRAC_New.control AS target
USING (
 SELECT d.control_domain_id,sd.control_sub_domain_id,s.control_code,s.control_name,s.description,s.objective
 FROM @grac_control_seed s
 JOIN GRAC_New.control_domain d ON d.domain_name=s.domain_name
 JOIN GRAC_New.control_sub_domain sd ON sd.control_domain_id=d.control_domain_id AND sd.sub_domain_name=s.sub_domain_name
) AS source(control_domain_id,control_sub_domain_id,control_code,control_name,description,objective)
ON target.control_code=source.control_code
WHEN MATCHED THEN UPDATE SET
 control_domain_id=source.control_domain_id,
 control_sub_domain_id=source.control_sub_domain_id,
 control_name=source.control_name,
 description=COALESCE(NULLIF(target.description,N''),source.description),
 objective=COALESCE(NULLIF(target.objective,N''),source.objective),
 updated_by=N'system',
 updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(control_code,control_name,description,objective,control_domain_id,control_sub_domain_id,status,entered_by)
 VALUES(source.control_code,source.control_name,source.description,source.objective,source.control_domain_id,source.control_sub_domain_id,N'Active',N'system');

INSERT GRAC_New.control_keyword(control_id,keyword,status,entered_by)
SELECT c.control_id,LTRIM(RTRIM(k.value)),N'Active',N'system'
FROM @grac_control_seed s
JOIN GRAC_New.control c ON c.control_code=s.control_code
CROSS APPLY STRING_SPLIT(s.keywords,N',') k
WHERE NULLIF(LTRIM(RTRIM(k.value)),N'') IS NOT NULL
 AND NOT EXISTS(
  SELECT 1 FROM GRAC_New.control_keyword ck
  WHERE ck.control_id=c.control_id AND ck.keyword=LTRIM(RTRIM(k.value))
 );
GO
IF OBJECT_ID('GRAC_New.requirement','U') IS NULL CREATE TABLE GRAC_New.requirement(
 requirement_id BIGINT IDENTITY PRIMARY KEY, requirement_code NVARCHAR(100) NOT NULL UNIQUE, requirement_name NVARCHAR(300) NOT NULL,
 requirement_statement NVARCHAR(MAX) NOT NULL, objective NVARCHAR(MAX) NULL,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active', entered_by NVARCHAR(100) NOT NULL, entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL);
GO
IF OBJECT_ID('GRAC_New.evidence_type_master','U') IS NULL CREATE TABLE GRAC_New.evidence_type_master(
 evidence_type_id INT IDENTITY PRIMARY KEY,
 evidence_type_code NVARCHAR(60) NOT NULL UNIQUE,
 evidence_type_name NVARCHAR(160) NOT NULL,
 display_order INT NOT NULL DEFAULT 0,
 is_active BIT NOT NULL DEFAULT 1,
 entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL);
GO
;WITH seed(evidence_type_code,evidence_type_name,display_order) AS (
 SELECT N'Policy Document',N'Policy Document',1 UNION ALL
 SELECT N'Procedure Document',N'Procedure Document',2 UNION ALL
 SELECT N'System Screenshot',N'System Screenshot',3 UNION ALL
 SELECT N'System Report',N'System Report',4 UNION ALL
 SELECT N'Audit Log',N'Audit Log',5 UNION ALL
 SELECT N'Approval Record',N'Approval Record',6 UNION ALL
 SELECT N'Review Register',N'Review Register',7 UNION ALL
 SELECT N'Meeting Minutes',N'Meeting Minutes',8 UNION ALL
 SELECT N'Configuration Export',N'Configuration Export',9 UNION ALL
 SELECT N'Incident Report',N'Incident Report',10
)
INSERT GRAC_New.evidence_type_master(evidence_type_code,evidence_type_name,display_order,entered_by)
SELECT s.evidence_type_code,s.evidence_type_name,s.display_order,N'system'
FROM seed s
WHERE NOT EXISTS(
 SELECT 1 FROM GRAC_New.evidence_type_master existing
 WHERE existing.evidence_type_code=s.evidence_type_code OR existing.evidence_type_name=s.evidence_type_name
);
GO
IF OBJECT_ID('GRAC_New.obligation','U') IS NULL CREATE TABLE GRAC_New.obligation(
 obligation_id BIGINT IDENTITY PRIMARY KEY, framework_statement_id BIGINT NULL REFERENCES GRAC_New.framework_statement(framework_statement_id),
 requirement_id BIGINT NULL REFERENCES GRAC_New.requirement(requirement_id),
 release_id BIGINT NOT NULL REFERENCES GRAC_New.release(release_id), structure_node_id BIGINT NULL REFERENCES GRAC_New.source_structure_node(structure_node_id),
 obligation_text NVARCHAR(MAX) NULL, approval_authority NVARCHAR(250) NULL, responsibility NVARCHAR(250) NULL, reporting_target NVARCHAR(250) NULL,
 mandatory_flag BIT NOT NULL DEFAULT 1, frequency_type NVARCHAR(40) NULL,
 frequency_value INT NULL, frequency_unit NVARCHAR(40) NULL, trigger_condition NVARCHAR(500) NULL, due_within NVARCHAR(120) NULL,
 evidence_required BIT NOT NULL DEFAULT 0, evidence_type NVARCHAR(250) NULL, evidence_requirement NVARCHAR(MAX) NULL, retention_requirement NVARCHAR(250) NULL,
 severity NVARCHAR(30) NOT NULL DEFAULT 'Medium', status NVARCHAR(30) NOT NULL DEFAULT 'Active', entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL);
GO
IF OBJECT_ID('GRAC_New.obligation_evidence_type','U') IS NULL CREATE TABLE GRAC_New.obligation_evidence_type(
 obligation_evidence_type_id BIGINT IDENTITY PRIMARY KEY,
 obligation_id BIGINT NOT NULL REFERENCES GRAC_New.obligation(obligation_id),
 evidence_type_id INT NOT NULL REFERENCES GRAC_New.evidence_type_master(evidence_type_id),
 frequency_id BIGINT NULL REFERENCES GRAC_New.reference_option(reference_option_id),
 retention_requirement NVARCHAR(250) NULL,
 remarks NVARCHAR(MAX) NULL,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_cm_obligation_evidence_type UNIQUE(obligation_id,evidence_type_id));
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_cm_obligation_evidence_type_status' AND object_id=OBJECT_ID('GRAC_New.obligation_evidence_type'))
 CREATE INDEX ix_cm_obligation_evidence_type_status ON GRAC_New.obligation_evidence_type(obligation_id,status,evidence_type_id);
GO
IF COL_LENGTH('GRAC_New.obligation','structure_node_id') IS NULL ALTER TABLE GRAC_New.obligation ADD structure_node_id BIGINT NULL REFERENCES GRAC_New.source_structure_node(structure_node_id);
GO
IF COL_LENGTH('GRAC_New.obligation','framework_statement_id') IS NULL ALTER TABLE GRAC_New.obligation ADD framework_statement_id BIGINT NULL REFERENCES GRAC_New.framework_statement(framework_statement_id);
GO
IF COL_LENGTH('GRAC_New.obligation','obligation_text') IS NULL ALTER TABLE GRAC_New.obligation ADD obligation_text NVARCHAR(MAX) NULL;
GO
IF COL_LENGTH('GRAC_New.obligation','approval_authority') IS NULL ALTER TABLE GRAC_New.obligation ADD approval_authority NVARCHAR(250) NULL;
GO
IF COL_LENGTH('GRAC_New.obligation','responsibility') IS NULL ALTER TABLE GRAC_New.obligation ADD responsibility NVARCHAR(250) NULL;
GO
IF COL_LENGTH('GRAC_New.obligation','reporting_target') IS NULL ALTER TABLE GRAC_New.obligation ADD reporting_target NVARCHAR(250) NULL;
GO
IF COL_LENGTH('GRAC_New.obligation','evidence_requirement') IS NULL ALTER TABLE GRAC_New.obligation ADD evidence_requirement NVARCHAR(MAX) NULL;
GO
IF COL_LENGTH('GRAC_New.obligation_evidence_type','frequency_id') IS NULL ALTER TABLE GRAC_New.obligation_evidence_type ADD frequency_id BIGINT NULL REFERENCES GRAC_New.reference_option(reference_option_id);
GO
IF COL_LENGTH('GRAC_New.obligation_evidence_type','retention_requirement') IS NULL ALTER TABLE GRAC_New.obligation_evidence_type ADD retention_requirement NVARCHAR(250) NULL;
GO
IF COL_LENGTH('GRAC_New.obligation_evidence_type','remarks') IS NULL ALTER TABLE GRAC_New.obligation_evidence_type ADD remarks NVARCHAR(MAX) NULL;
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_cm_obligation_framework_statement_status' AND object_id=OBJECT_ID('GRAC_New.obligation'))
 CREATE INDEX ix_cm_obligation_framework_statement_status ON GRAC_New.obligation(framework_statement_id,status) INCLUDE(release_id,structure_node_id);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ux_cm_obligation_statement_requirement_active' AND object_id=OBJECT_ID('GRAC_New.obligation'))
 CREATE UNIQUE INDEX ux_cm_obligation_statement_requirement_active ON GRAC_New.obligation(framework_statement_id,requirement_id) WHERE framework_statement_id IS NOT NULL AND requirement_id IS NOT NULL AND status='Active';
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ux_cm_obligation_requirement_source_active' AND object_id=OBJECT_ID('GRAC_New.obligation'))
 CREATE UNIQUE INDEX ux_cm_obligation_requirement_source_active ON GRAC_New.obligation(requirement_id,structure_node_id) WHERE requirement_id IS NOT NULL AND structure_node_id IS NOT NULL AND status='Active';
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ux_cm_obligation_requirement_release_active' AND object_id=OBJECT_ID('GRAC_New.obligation'))
 CREATE UNIQUE INDEX ux_cm_obligation_requirement_release_active ON GRAC_New.obligation(requirement_id,release_id) WHERE requirement_id IS NOT NULL AND structure_node_id IS NULL AND status='Active';
GO
IF OBJECT_ID('GRAC_New.requirement_obligation','U') IS NULL CREATE TABLE GRAC_New.requirement_obligation(
 obligation_id BIGINT IDENTITY PRIMARY KEY,
 requirement_id BIGINT NOT NULL REFERENCES GRAC_New.requirement(requirement_id),
 release_id BIGINT NOT NULL REFERENCES GRAC_New.release(release_id),
obligation_text NVARCHAR(MAX) NULL,
frequency_type NVARCHAR(40) NULL,
approval_authority NVARCHAR(250) NULL,
 responsibility NVARCHAR(250) NULL,
 trigger_condition NVARCHAR(500) NULL,
 reporting_target NVARCHAR(250) NULL,
 retention_requirement NVARCHAR(250) NULL,
 evidence_requirement NVARCHAR(MAX) NULL,
 status_id BIGINT NULL REFERENCES GRAC_New.reference_option(reference_option_id),
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL);
GO
IF COL_LENGTH('GRAC_New.requirement_obligation','obligation_text') IS NULL ALTER TABLE GRAC_New.requirement_obligation ADD obligation_text NVARCHAR(MAX) NULL;
IF COL_LENGTH('GRAC_New.requirement_obligation','frequency_type') IS NULL ALTER TABLE GRAC_New.requirement_obligation ADD frequency_type NVARCHAR(40) NULL;
IF COL_LENGTH('GRAC_New.requirement_obligation','approval_authority') IS NULL ALTER TABLE GRAC_New.requirement_obligation ADD approval_authority NVARCHAR(250) NULL;
IF COL_LENGTH('GRAC_New.requirement_obligation','responsibility') IS NULL ALTER TABLE GRAC_New.requirement_obligation ADD responsibility NVARCHAR(250) NULL;
IF COL_LENGTH('GRAC_New.requirement_obligation','trigger_condition') IS NULL ALTER TABLE GRAC_New.requirement_obligation ADD trigger_condition NVARCHAR(500) NULL;
IF COL_LENGTH('GRAC_New.requirement_obligation','reporting_target') IS NULL ALTER TABLE GRAC_New.requirement_obligation ADD reporting_target NVARCHAR(250) NULL;
IF COL_LENGTH('GRAC_New.requirement_obligation','retention_requirement') IS NULL ALTER TABLE GRAC_New.requirement_obligation ADD retention_requirement NVARCHAR(250) NULL;
IF COL_LENGTH('GRAC_New.requirement_obligation','evidence_requirement') IS NULL ALTER TABLE GRAC_New.requirement_obligation ADD evidence_requirement NVARCHAR(MAX) NULL;
GO
IF OBJECT_ID('GRAC_New.requirement_obligation_evidence','U') IS NULL CREATE TABLE GRAC_New.requirement_obligation_evidence(
 obligation_evidence_id BIGINT IDENTITY PRIMARY KEY,
 obligation_id BIGINT NOT NULL REFERENCES GRAC_New.requirement_obligation(obligation_id),
 evidence_type_id INT NOT NULL REFERENCES GRAC_New.evidence_type_master(evidence_type_id),
 frequency_id BIGINT NULL REFERENCES GRAC_New.reference_option(reference_option_id),
 retention_requirement NVARCHAR(250) NULL,
 remarks NVARCHAR(MAX) NULL,
 status_id BIGINT NULL REFERENCES GRAC_New.reference_option(reference_option_id),
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ux_cm_requirement_obligation_release_active' AND object_id=OBJECT_ID('GRAC_New.requirement_obligation'))
 CREATE UNIQUE INDEX ux_cm_requirement_obligation_release_active ON GRAC_New.requirement_obligation(requirement_id,release_id) WHERE status='Active';
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ux_cm_requirement_obligation_evidence_active' AND object_id=OBJECT_ID('GRAC_New.requirement_obligation_evidence'))
 CREATE UNIQUE INDEX ux_cm_requirement_obligation_evidence_active ON GRAC_New.requirement_obligation_evidence(obligation_id,evidence_type_id) WHERE status='Active';
GO
IF OBJECT_ID('GRAC_New.source_control_map','U') IS NULL CREATE TABLE GRAC_New.source_control_map(
 source_control_map_id BIGINT IDENTITY PRIMARY KEY, structure_node_id BIGINT NOT NULL REFERENCES GRAC_New.source_structure_node(structure_node_id),
 control_id BIGINT NOT NULL REFERENCES GRAC_New.control(control_id), release_id BIGINT NULL REFERENCES GRAC_New.release(release_id),
 artifact_id BIGINT NULL REFERENCES GRAC_New.artifact(artifact_id), status NVARCHAR(30) NOT NULL DEFAULT 'Active', entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL,
 CONSTRAINT uq_cm_source_control UNIQUE(structure_node_id,control_id));
GO
IF COL_LENGTH('GRAC_New.source_control_map','release_id') IS NULL ALTER TABLE GRAC_New.source_control_map ADD release_id BIGINT NULL REFERENCES GRAC_New.release(release_id);
GO
IF COL_LENGTH('GRAC_New.source_control_map','artifact_id') IS NULL ALTER TABLE GRAC_New.source_control_map ADD artifact_id BIGINT NULL REFERENCES GRAC_New.artifact(artifact_id);
GO
UPDATE m SET release_id=n.release_id, artifact_id=r.artifact_id
FROM GRAC_New.source_control_map m JOIN GRAC_New.source_structure_node n ON n.structure_node_id=m.structure_node_id JOIN GRAC_New.release r ON r.release_id=n.release_id
WHERE m.release_id IS NULL OR m.artifact_id IS NULL;
GO
IF OBJECT_ID('GRAC_New.framework_statement_control_map','U') IS NULL CREATE TABLE GRAC_New.framework_statement_control_map(
 statement_control_map_id BIGINT IDENTITY PRIMARY KEY,
 framework_statement_id BIGINT NOT NULL REFERENCES GRAC_New.framework_statement(framework_statement_id),
 control_id BIGINT NOT NULL REFERENCES GRAC_New.control(control_id),
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_cm_framework_statement_control UNIQUE(framework_statement_id,control_id));
GO
IF OBJECT_ID('GRAC_New.control_requirement_map','U') IS NULL CREATE TABLE GRAC_New.control_requirement_map(
 control_requirement_map_id BIGINT IDENTITY PRIMARY KEY, control_id BIGINT NOT NULL REFERENCES GRAC_New.control(control_id),
 requirement_id BIGINT NOT NULL REFERENCES GRAC_New.requirement(requirement_id), status NVARCHAR(30) NOT NULL DEFAULT 'Active', entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL,
 CONSTRAINT uq_cm_control_requirement UNIQUE(control_id,requirement_id));
GO
IF OBJECT_ID('GRAC_New.framework_statement_requirement_map','U') IS NULL CREATE TABLE GRAC_New.framework_statement_requirement_map(
 statement_requirement_map_id BIGINT IDENTITY PRIMARY KEY,
 framework_statement_id BIGINT NOT NULL REFERENCES GRAC_New.framework_statement(framework_statement_id),
 requirement_id BIGINT NOT NULL REFERENCES GRAC_New.requirement(requirement_id),
 status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL,
 updated_dt DATETIME2 NULL,
 CONSTRAINT uq_cm_framework_statement_requirement UNIQUE(framework_statement_id,requirement_id));
GO
IF OBJECT_ID('GRAC_New.applicability_attribute','U') IS NULL CREATE TABLE GRAC_New.applicability_attribute(
 applicability_attribute_id BIGINT IDENTITY PRIMARY KEY, attribute_code NVARCHAR(100) NOT NULL UNIQUE, attribute_name NVARCHAR(200) NOT NULL,
 data_type NVARCHAR(40) NOT NULL DEFAULT 'Text', status NVARCHAR(30) NOT NULL DEFAULT 'Active', entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL);
GO
IF OBJECT_ID('GRAC_New.applicability_rule','U') IS NULL CREATE TABLE GRAC_New.applicability_rule(
 applicability_rule_id BIGINT IDENTITY PRIMARY KEY, artifact_id BIGINT NULL REFERENCES GRAC_New.artifact(artifact_id), release_id BIGINT NULL REFERENCES GRAC_New.release(release_id),
 rule_name NVARCHAR(250) NOT NULL, rule_expression_json NVARCHAR(MAX) NOT NULL, priority_no INT NOT NULL DEFAULT 100, outcome NVARCHAR(40) NOT NULL DEFAULT 'Applicable',
 status NVARCHAR(30) NOT NULL DEFAULT 'Active', entered_by NVARCHAR(100) NOT NULL, entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL);
GO
IF OBJECT_ID('GRAC_New.change_event','U') IS NULL CREATE TABLE GRAC_New.change_event(
 change_event_id BIGINT IDENTITY PRIMARY KEY, entity_type NVARCHAR(80) NOT NULL, entity_id BIGINT NOT NULL, change_type NVARCHAR(80) NOT NULL,
 change_summary NVARCHAR(MAX) NOT NULL, effective_dt DATE NULL, severity NVARCHAR(30) NOT NULL DEFAULT 'Medium', status NVARCHAR(30) NOT NULL DEFAULT 'Open',
 entered_by NVARCHAR(100) NOT NULL, entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL);
GO
IF OBJECT_ID('GRAC_New.impact_analysis','U') IS NULL CREATE TABLE GRAC_New.impact_analysis(
 impact_analysis_id BIGINT IDENTITY PRIMARY KEY, change_event_id BIGINT NOT NULL REFERENCES GRAC_New.change_event(change_event_id),
 impacted_entity_type NVARCHAR(80) NOT NULL, impacted_entity_id BIGINT NOT NULL, organization_id BIGINT NULL, impact_summary NVARCHAR(MAX) NULL,
 recommended_action NVARCHAR(MAX) NULL, status NVARCHAR(30) NOT NULL DEFAULT 'Open', entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL);
GO
IF OBJECT_ID('GRAC_New.notification','U') IS NULL CREATE TABLE GRAC_New.notification(
 notification_id BIGINT IDENTITY PRIMARY KEY, impact_analysis_id BIGINT NULL REFERENCES GRAC_New.impact_analysis(impact_analysis_id), organization_id BIGINT NULL,
 notification_type NVARCHAR(80) NOT NULL, subject NVARCHAR(300) NOT NULL, message_body NVARCHAR(MAX) NOT NULL, severity NVARCHAR(30) NOT NULL DEFAULT 'Medium',
 recommended_action NVARCHAR(MAX) NULL, status NVARCHAR(30) NOT NULL DEFAULT 'Pending', sent_dt DATETIME2 NULL, entered_by NVARCHAR(100) NOT NULL,
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL);
GO
IF OBJECT_ID('GRAC_New.audit_trace','U') IS NULL CREATE TABLE GRAC_New.audit_trace(
 audit_trace_id BIGINT IDENTITY PRIMARY KEY, entity_type NVARCHAR(80) NOT NULL, entity_id BIGINT NOT NULL, action_type NVARCHAR(40) NOT NULL,
 table_name NVARCHAR(128) NULL, record_reference NVARCHAR(300) NULL, field_name NVARCHAR(128) NULL, old_value NVARCHAR(MAX) NULL, new_value NVARCHAR(MAX) NULL, remarks NVARCHAR(MAX) NULL,
 before_json NVARCHAR(MAX) NULL, after_json NVARCHAR(MAX) NULL, status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL, entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL);
GO
IF OBJECT_ID('GRAC_New.audit_trace_event','U') IS NULL CREATE TABLE GRAC_New.audit_trace_event(
 audit_event_id BIGINT IDENTITY PRIMARY KEY, entity_type NVARCHAR(80) NOT NULL, entity_id BIGINT NOT NULL, action_type NVARCHAR(40) NOT NULL,
 table_name NVARCHAR(128) NULL, record_reference NVARCHAR(300) NULL, remarks NVARCHAR(MAX) NULL,
 before_json NVARCHAR(MAX) NULL, after_json NVARCHAR(MAX) NULL, status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL, entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME());
GO
IF OBJECT_ID('GRAC_New.audit_trace_detail','U') IS NULL CREATE TABLE GRAC_New.audit_trace_detail(
 audit_detail_id BIGINT IDENTITY PRIMARY KEY, audit_event_id BIGINT NOT NULL,
 field_name NVARCHAR(128) NOT NULL, old_value NVARCHAR(MAX) NULL, new_value NVARCHAR(MAX) NULL,
 entered_by NVARCHAR(100) NOT NULL, entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 CONSTRAINT fk_cm_audit_detail_event FOREIGN KEY(audit_event_id) REFERENCES GRAC_New.audit_trace_event(audit_event_id));
GO
IF COL_LENGTH('GRAC_New.audit_trace','audit_event_id') IS NULL ALTER TABLE GRAC_New.audit_trace ADD audit_event_id BIGINT NULL;
GO
IF COL_LENGTH('GRAC_New.audit_trace','table_name') IS NULL ALTER TABLE GRAC_New.audit_trace ADD table_name NVARCHAR(128) NULL;
IF COL_LENGTH('GRAC_New.audit_trace','record_reference') IS NULL ALTER TABLE GRAC_New.audit_trace ADD record_reference NVARCHAR(300) NULL;
IF COL_LENGTH('GRAC_New.audit_trace','field_name') IS NULL ALTER TABLE GRAC_New.audit_trace ADD field_name NVARCHAR(128) NULL;
IF COL_LENGTH('GRAC_New.audit_trace','old_value') IS NULL ALTER TABLE GRAC_New.audit_trace ADD old_value NVARCHAR(MAX) NULL;
IF COL_LENGTH('GRAC_New.audit_trace','new_value') IS NULL ALTER TABLE GRAC_New.audit_trace ADD new_value NVARCHAR(MAX) NULL;
IF COL_LENGTH('GRAC_New.audit_trace','remarks') IS NULL ALTER TABLE GRAC_New.audit_trace ADD remarks NVARCHAR(MAX) NULL;
GO
IF OBJECT_ID('GRAC_New.approval_action','U') IS NULL CREATE TABLE GRAC_New.approval_action(
 approval_action_id BIGINT IDENTITY PRIMARY KEY, entity_type NVARCHAR(80) NOT NULL, entity_id BIGINT NOT NULL,
 action_type NVARCHAR(30) NOT NULL, comments NVARCHAR(1000) NULL, status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL, entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL);
GO
IF OBJECT_ID('GRAC_New.organization','U') IS NULL CREATE TABLE GRAC_New.organization(
 organization_id BIGINT IDENTITY PRIMARY KEY, organization_name NVARCHAR(250) NOT NULL, organization_code NVARCHAR(80) NOT NULL UNIQUE,
 status NVARCHAR(30) NOT NULL DEFAULT 'Active', entered_by NVARCHAR(100) NOT NULL, entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL);
GO
IF OBJECT_ID('GRAC_New.reference_option','U') IS NULL CREATE TABLE GRAC_New.reference_option(
 reference_option_id BIGINT IDENTITY PRIMARY KEY, option_group NVARCHAR(100) NOT NULL, option_value NVARCHAR(100) NOT NULL, option_label NVARCHAR(200) NOT NULL,
 display_order INT NOT NULL DEFAULT 0, status NVARCHAR(30) NOT NULL DEFAULT 'Active', entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL,
 CONSTRAINT uq_cm_reference_option UNIQUE(option_group,option_value));
GO
IF OBJECT_ID('GRAC_New.artifact_industry_map','U') IS NULL CREATE TABLE GRAC_New.artifact_industry_map(
 artifact_industry_map_id BIGINT IDENTITY PRIMARY KEY, artifact_id BIGINT NOT NULL REFERENCES GRAC_New.artifact(artifact_id),
 reference_option_id BIGINT NOT NULL REFERENCES GRAC_New.reference_option(reference_option_id), status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL, entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL,
 CONSTRAINT uq_cm_artifact_industry UNIQUE(artifact_id,reference_option_id));
GO
IF OBJECT_ID('GRAC_New.artifact_jurisdiction_map','U') IS NULL CREATE TABLE GRAC_New.artifact_jurisdiction_map(
 artifact_jurisdiction_map_id BIGINT IDENTITY PRIMARY KEY, artifact_id BIGINT NOT NULL REFERENCES GRAC_New.artifact(artifact_id),
 reference_option_id BIGINT NOT NULL REFERENCES GRAC_New.reference_option(reference_option_id), status NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by NVARCHAR(100) NOT NULL, entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_by NVARCHAR(100) NULL, updated_dt DATETIME2 NULL,
 CONSTRAINT uq_cm_artifact_jurisdiction UNIQUE(artifact_id,reference_option_id));
GO
MERGE GRAC_New.reference_option AS target
USING (VALUES
 ('status-active','Active','Active',1),('status-active','Inactive','Inactive',2),('status-active','Retired','Retired',3),
 ('release-status','Draft','Draft',1),('release-status','Active','Active',2),('release-status','Retired','Retired',3),('release-status','Archived','Archived',4),
 ('artifact-categories','Regulation','Regulation',1),('artifact-categories','Standard','Standard',2),('artifact-categories','Framework','Framework',3),('artifact-categories','Law','Law',4),('artifact-categories','Directive','Directive',5),('artifact-categories','Circular','Circular',6),('artifact-categories','Guideline','Guideline',7),('artifact-categories','Accreditation Program','Accreditation Program',8),
 ('industries','Banking','Banking',1),('industries','Insurance','Insurance',2),('industries','Healthcare','Healthcare',3),('industries','Financial Services','Financial Services',4),('industries','IT / ITES','IT / ITES',5),('industries','Government','Government',6),('industries','Education','Education',7),('industries','Manufacturing','Manufacturing',8),('industries','Retail','Retail',9),('industries','Telecom','Telecom',10),('industries','Others','Others',11),('industries','All Industries','All Industries',12),('industries','Banking and Financial Services','Banking and Financial Services',13),('industries','Securities Market','Securities Market',14),('industries','Payment Card Industry','Payment Card Industry',15),
 ('jurisdictions','India','India',1),('jurisdictions','UAE','UAE',2),('jurisdictions','Saudi Arabia','Saudi Arabia',3),('jurisdictions','Qatar','Qatar',4),('jurisdictions','Bahrain','Bahrain',5),('jurisdictions','Oman','Oman',6),('jurisdictions','Kuwait','Kuwait',7),('jurisdictions','United States','United States',8),('jurisdictions','United Kingdom','United Kingdom',9),('jurisdictions','European Union','European Union',10),('jurisdictions','Global','Global',11),('jurisdictions','Others','Others',12),('jurisdictions','International','International',13),
 ('node-types','Chapter','Chapter',1),('node-types','Clause','Clause',2),('node-types','Guideline','Guideline',3),('node-types','Standard','Standard',4),('node-types','Objective Element','Objective Element',5),('node-types','Requirement','Requirement',6),('node-types','Sub-Requirement','Sub-Requirement',7),('node-types','Domain','Domain',8),('node-types','Process','Process',9),('node-types','Function','Function',10),('node-types','Category','Category',11),('node-types','Subcategory','Subcategory',12),
 ('frequency-types','Daily','Daily',1),('frequency-types','Weekly','Weekly',2),('frequency-types','Monthly','Monthly',3),('frequency-types','Quarterly','Quarterly',4),('frequency-types','Half-Yearly','Half-Yearly',5),('frequency-types','Annual','Annual',6),('frequency-types','Event Driven','Event Driven',7),('frequency-types','Continuous','Continuous',8),('frequency-types','Custom','Custom',9),
 ('frequency-units','Day','Day',1),('frequency-units','Week','Week',2),('frequency-units','Month','Month',3),('frequency-units','Quarter','Quarter',4),('frequency-units','Year','Year',5),
 ('trigger-types','Scheduled','Scheduled',1),('trigger-types','Event Driven','Event Driven',2),('trigger-types','Regulatory Change','Regulatory Change',3),('trigger-types','Incident','Incident',4),('trigger-types','Audit Finding','Audit Finding',5),('trigger-types','Management Request','Management Request',6),
 ('severity','Critical','Critical',1),('severity','High','High',2),('severity','Medium','Medium',3),('severity','Low','Low',4),
 ('applicability-outcomes','Applicable','Applicable',1),('applicability-outcomes','Not Applicable','Not Applicable',2),('applicability-outcomes','Review Required','Review Required',3),
 ('entity-types','Artifact','Artifact',1),('entity-types','Release','Release',2),('entity-types','Control','Control',3),('entity-types','Requirement','Requirement',4),('entity-types','Obligation','Obligation',5),
 ('change-types','New','New',1),('change-types','Modified','Modified',2),('change-types','Clarified','Clarified',3),('change-types','Deprecated','Deprecated',4),('change-types','Retired','Retired',5),
 ('change-status','Open','Open',1),('change-status','In Review','In Review',2),('change-status','Completed','Completed',3),('change-status','Archived','Archived',4),
 ('notification-types','Regulatory Change','Regulatory Change',1),('notification-types','Applicability Change','Applicability Change',2),('notification-types','Impact Alert','Impact Alert',3),
 ('notification-status','Pending','Pending',1),('notification-status','Sent','Sent',2),('notification-status','Archived','Archived',3)
) AS source(option_group,option_value,option_label,display_order)
ON target.option_group=source.option_group AND target.option_value=source.option_value
WHEN NOT MATCHED THEN INSERT(option_group,option_value,option_label,display_order) VALUES(source.option_group,source.option_value,source.option_label,source.display_order);
GO
INSERT GRAC_New.artifact_industry_map(artifact_id,reference_option_id,status,entered_by)
SELECT a.artifact_id,o.reference_option_id,'Active','system'
FROM GRAC_New.artifact a JOIN GRAC_New.reference_option o ON o.option_group='industries' AND o.option_value=a.industry
WHERE NULLIF(a.industry,'') IS NOT NULL
 AND NOT EXISTS(SELECT 1 FROM GRAC_New.artifact_industry_map m WHERE m.artifact_id=a.artifact_id AND m.reference_option_id=o.reference_option_id);
GO
INSERT GRAC_New.artifact_jurisdiction_map(artifact_id,reference_option_id,status,entered_by)
SELECT a.artifact_id,o.reference_option_id,'Active','system'
FROM GRAC_New.artifact a JOIN GRAC_New.reference_option o ON o.option_group='jurisdictions' AND o.option_value=a.jurisdiction
WHERE NULLIF(a.jurisdiction,'') IS NOT NULL
 AND NOT EXISTS(SELECT 1 FROM GRAC_New.artifact_jurisdiction_map m WHERE m.artifact_id=a.artifact_id AND m.reference_option_id=o.reference_option_id);
GO
IF OBJECT_ID('GRAC_New.artifact_standard_map','U') IS NOT NULL DROP TABLE GRAC_New.artifact_standard_map;
GO
UPDATE GRAC_New.reference_option SET status='Inactive',updated_by='system',updated_dt=SYSUTCDATETIME() WHERE option_group='standards' AND status<>'Inactive';
GO
