/*
  GRAC internal control classification seed data.
  Rerunnable. Inserts/updates Domain -> Sub Domain -> Control seed records and control keywords.
*/
IF SCHEMA_ID('GRAC_New') IS NULL
BEGIN
 RAISERROR('Schema GRAC_New does not exist. Run 001_control_management_schema.sql first.',16,1);
 RETURN;
END;
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
