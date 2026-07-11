/*
  Optional, rerunnable multi-authority demonstration data.
  Apply after 001_control_management_schema.sql.
  Content is concise paraphrased metadata, not authoritative regulatory text.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRY
 BEGIN TRANSACTION;
 DECLARE @by NVARCHAR(100)=N'sample.seed';

 DECLARE @authorities TABLE(code NVARCHAR(80),name NVARCHAR(250),description NVARCHAR(500),jurisdiction NVARCHAR(160),website NVARCHAR(500));
 INSERT @authorities VALUES
 (N'RBI',N'Reserve Bank of India',N'India central bank and banking-sector regulator.',N'India',N'https://www.rbi.org.in/'),
 (N'SEBI',N'Securities and Exchange Board of India',N'India securities-market regulator.',N'India',N'https://www.sebi.gov.in/'),
 (N'PCI-SSC',N'PCI Security Standards Council',N'Industry standards body for payment-account data security.',N'International',N'https://www.pcisecuritystandards.org/'),
 (N'NIST',N'National Institute of Standards and Technology',N'United States standards and technology agency.',N'United States',N'https://www.nist.gov/');
 INSERT GRAC_New.authority(authority_name,authority_code,description,jurisdiction,website,status,entered_by)
 SELECT a.name,a.code,a.description,a.jurisdiction,a.website,N'Active',@by FROM @authorities a
 WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.authority x WHERE x.authority_code=a.code);

 DECLARE @artifacts TABLE(authority_code NVARCHAR(80),artifact_code NVARCHAR(100),name NVARCHAR(300),description NVARCHAR(700),category NVARCHAR(80),industry NVARCHAR(160),jurisdiction NVARCHAR(160),version NVARCHAR(80),published DATE,notes NVARCHAR(500));
 INSERT @artifacts VALUES
 (N'RBI',N'RBI-IT-GOV-2023',N'RBI Information Technology Governance, Risk, Controls and Assurance Practices Directions',N'RBI directions covering IT governance, risk, controls, assurance practices, and continuity topics.',N'Directive',N'Banking and Financial Services',N'India',N'2023',CONVERT(DATE,'2023-11-07'),N'Demonstration release based on the November 7, 2023 directions.'),
 (N'SEBI',N'SEBI-CSCRF-2024',N'SEBI Cybersecurity and Cyber Resilience Framework for Regulated Entities',N'SEBI framework for cybersecurity and cyber resilience across regulated entities.',N'Framework',N'Securities Market',N'India',N'1.0',CONVERT(DATE,'2024-08-20'),N'Demonstration release based on the August 20, 2024 circular.'),
 (N'PCI-SSC',N'PCI-DSS',N'Payment Card Industry Data Security Standard',N'Industry standard for protecting payment-account data.',N'Standard',N'Payment Card Industry',N'International',N'4.0.1',CONVERT(DATE,'2024-06-11'),N'Demonstration release for PCI DSS v4.0.1.'),
 (N'NIST',N'NIST-CSF',N'NIST Cybersecurity Framework',N'Framework for managing and communicating cybersecurity risk outcomes.',N'Framework',N'All Industries',N'United States',N'2.0',CONVERT(DATE,'2024-02-26'),N'Demonstration release for NIST CSF 2.0.');
 INSERT GRAC_New.artifact(authority_id,artifact_name,artifact_code,description,artifact_category,industry,jurisdiction,status,entered_by)
 SELECT a.authority_id,x.name,x.artifact_code,x.description,x.category,x.industry,x.jurisdiction,N'Active',@by
 FROM @artifacts x JOIN GRAC_New.authority a ON a.authority_code=x.authority_code
 WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.artifact z WHERE z.artifact_code=x.artifact_code);
 INSERT GRAC_New.artifact_jurisdiction_map(artifact_id,reference_option_id,status,entered_by)
 SELECT a.artifact_id,o.reference_option_id,N'Active',@by FROM @artifacts x JOIN GRAC_New.artifact a ON a.artifact_code=x.artifact_code
 JOIN GRAC_New.reference_option o ON o.option_group=N'jurisdictions' AND o.option_value=x.jurisdiction
 WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.artifact_jurisdiction_map m WHERE m.artifact_id=a.artifact_id AND m.reference_option_id=o.reference_option_id);
 INSERT GRAC_New.artifact_industry_map(artifact_id,reference_option_id,status,entered_by)
 SELECT a.artifact_id,o.reference_option_id,N'Active',@by FROM @artifacts x JOIN GRAC_New.artifact a ON a.artifact_code=x.artifact_code
 JOIN GRAC_New.reference_option o ON o.option_group=N'industries' AND o.option_value=x.industry
 WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.artifact_industry_map m WHERE m.artifact_id=a.artifact_id AND m.reference_option_id=o.reference_option_id);
 INSERT GRAC_New.release(artifact_id,version_no,effective_dt,release_notes,status,entered_by)
 SELECT a.artifact_id,x.version,x.published,x.notes,N'Active',@by FROM @artifacts x JOIN GRAC_New.artifact a ON a.artifact_code=x.artifact_code
 WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.release r WHERE r.artifact_id=a.artifact_id AND r.version_no=x.version);

 DECLARE @controls TABLE(code NVARCHAR(100),name NVARCHAR(300),description NVARCHAR(700),objective NVARCHAR(700));
 INSERT @controls VALUES
 (N'CTRL-CYB-GOVERNANCE',N'Maintain cybersecurity governance',N'Define accountable oversight, policies, reporting, and periodic review for cybersecurity.',N'Keep cybersecurity decisions aligned with business and regulatory expectations.'),
 (N'CTRL-CYB-ASSET-INVENTORY',N'Maintain technology asset inventory',N'Maintain a current inventory of relevant technology assets and ownership information.',N'Provide a reliable foundation for risk-based protection.'),
 (N'CTRL-CYB-ACCESS',N'Control logical access',N'Authorize, review, and remove access according to business need and security risk.',N'Reduce unauthorized access to systems and data.'),
 (N'CTRL-CYB-RISK-ASSESS',N'Assess cybersecurity risk',N'Perform repeatable cybersecurity risk assessments and track treatment decisions.',N'Prioritize risk reduction activities using documented evidence.'),
 (N'CTRL-CYB-THIRD-PARTY',N'Manage third-party cybersecurity risk',N'Assess relevant providers and track cybersecurity obligations and remediation.',N'Manage dependencies introduced by external parties.'),
 (N'CTRL-CYB-INCIDENT',N'Manage cybersecurity incidents',N'Maintain preparation, escalation, response, recovery, and review practices for cybersecurity incidents.',N'Limit impact and improve readiness after incidents.');
 INSERT GRAC_New.control(control_code,control_name,description,objective,status,entered_by)
 SELECT c.code,c.name,c.description,c.objective,N'Active',@by FROM @controls c
 WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.control x WHERE x.control_code=c.code);

 DECLARE @samples TABLE(artifact_code NVARCHAR(100),version NVARCHAR(80),node_reference NVARCHAR(160),node_title NVARCHAR(500),control_code NVARCHAR(100),requirement_code NVARCHAR(100),requirement_name NVARCHAR(300),statement NVARCHAR(900),severity NVARCHAR(30),frequency_type NVARCHAR(40),frequency_value INT,frequency_unit NVARCHAR(40),evidence NVARCHAR(250));
 INSERT @samples VALUES
 (N'RBI-IT-GOV-2023',N'2023',N'Governance',N'IT governance',N'CTRL-CYB-GOVERNANCE',N'REQ-RBI-ITGOV-001',N'Maintain accountable IT governance',N'Maintain approved governance arrangements with oversight, accountability, and periodic reporting for technology risk.',N'High',N'Scheduled',1,N'Quarter',N'Governance review record'),
 (N'RBI-IT-GOV-2023',N'2023',N'IT Risk',N'IT risk management',N'CTRL-CYB-RISK-ASSESS',N'REQ-RBI-ITRISK-001',N'Assess and treat technology risk',N'Assess technology risks at planned intervals and when significant changes occur, then track treatment decisions.',N'High',N'Scheduled',1,N'Year',N'Risk assessment and treatment register'),
 (N'SEBI-CSCRF-2024',N'1.0',N'Govern',N'Cybersecurity governance',N'CTRL-CYB-GOVERNANCE',N'REQ-SEBI-CSCRF-GOV-001',N'Maintain cyber resilience governance',N'Maintain cybersecurity governance and oversight appropriate to the regulated entity profile.',N'High',N'Scheduled',1,N'Quarter',N'Cybersecurity governance review'),
 (N'SEBI-CSCRF-2024',N'1.0',N'Identify',N'Asset and risk identification',N'CTRL-CYB-ASSET-INVENTORY',N'REQ-SEBI-CSCRF-ID-001',N'Maintain cybersecurity asset visibility',N'Maintain visibility of relevant assets and use it to support cybersecurity risk management.',N'High',N'Scheduled',1,N'Quarter',N'Asset inventory review'),
 (N'PCI-DSS',N'4.0.1',N'Requirement 7',N'Restrict access by business need',N'CTRL-CYB-ACCESS',N'REQ-PCI-DSS-ACCESS-001',N'Restrict access according to need',N'Authorize access to system components and data according to business need and review that access periodically.',N'High',N'Scheduled',1,N'Quarter',N'Access review evidence'),
 (N'PCI-DSS',N'4.0.1',N'Requirement 12',N'Support information security with policies and programs',N'CTRL-CYB-THIRD-PARTY',N'REQ-PCI-DSS-TPRM-001',N'Manage relevant provider relationships',N'Maintain oversight of relevant third-party service providers and track applicable security responsibilities.',N'High',N'Scheduled',1,N'Year',N'Provider responsibility review'),
 (N'NIST-CSF',N'2.0',N'GOVERN',N'Govern function',N'CTRL-CYB-GOVERNANCE',N'REQ-NIST-CSF-GV-001',N'Establish cybersecurity risk governance outcomes',N'Define cybersecurity risk-management strategy, expectations, oversight, and communication outcomes.',N'Medium',N'Scheduled',1,N'Year',N'Cybersecurity governance profile'),
 (N'NIST-CSF',N'2.0',N'RESPOND',N'Respond function',N'CTRL-CYB-INCIDENT',N'REQ-NIST-CSF-RS-001',N'Maintain incident response outcomes',N'Prepare for, manage, communicate, and analyze cybersecurity incidents to support effective response.',N'High',N'Scheduled',1,N'Year',N'Incident response exercise record');

 INSERT GRAC_New.source_structure_node(release_id,node_level,node_type,node_reference,node_title,description,display_order,status,entered_by)
 SELECT DISTINCT r.release_id,1,N'Category',s.node_reference,s.node_title,N'Demonstration source node with paraphrased metadata.',ROW_NUMBER() OVER(PARTITION BY r.release_id ORDER BY s.node_reference)*10,N'Active',@by
 FROM @samples s JOIN GRAC_New.artifact a ON a.artifact_code=s.artifact_code JOIN GRAC_New.release r ON r.artifact_id=a.artifact_id AND r.version_no=s.version
 WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.source_structure_node n WHERE n.release_id=r.release_id AND n.node_reference=s.node_reference);
 INSERT GRAC_New.requirement(requirement_code,requirement_name,requirement_statement,objective,status,entered_by)
 SELECT s.requirement_code,s.requirement_name,s.statement,N'Demonstration atomic requirement for repository review.',N'Active',@by FROM @samples s
 WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.requirement r WHERE r.requirement_code=s.requirement_code);
 INSERT GRAC_New.source_control_map(structure_node_id,control_id,release_id,artifact_id,status,entered_by)
 SELECT DISTINCT n.structure_node_id,c.control_id,r.release_id,a.artifact_id,N'Active',@by FROM @samples s JOIN GRAC_New.artifact a ON a.artifact_code=s.artifact_code JOIN GRAC_New.release r ON r.artifact_id=a.artifact_id AND r.version_no=s.version JOIN GRAC_New.source_structure_node n ON n.release_id=r.release_id AND n.node_reference=s.node_reference JOIN GRAC_New.control c ON c.control_code=s.control_code
 WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.source_control_map m WHERE m.structure_node_id=n.structure_node_id AND m.control_id=c.control_id);
 INSERT GRAC_New.control_requirement_map(control_id,requirement_id,status,entered_by)
 SELECT DISTINCT c.control_id,q.requirement_id,N'Active',@by FROM @samples s JOIN GRAC_New.control c ON c.control_code=s.control_code JOIN GRAC_New.requirement q ON q.requirement_code=s.requirement_code
 WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.control_requirement_map m WHERE m.control_id=c.control_id AND m.requirement_id=q.requirement_id);
 INSERT GRAC_New.obligation(requirement_id,release_id,mandatory_flag,frequency_type,frequency_value,frequency_unit,trigger_condition,due_within,evidence_required,evidence_type,retention_requirement,severity,status,entered_by)
 SELECT q.requirement_id,r.release_id,1,s.frequency_type,s.frequency_value,s.frequency_unit,N'Planned interval or material change',N'Within review cycle',1,s.evidence,N'Per organizational retention policy',s.severity,N'Active',@by
 FROM @samples s JOIN GRAC_New.artifact a ON a.artifact_code=s.artifact_code JOIN GRAC_New.release r ON r.artifact_id=a.artifact_id AND r.version_no=s.version JOIN GRAC_New.requirement q ON q.requirement_code=s.requirement_code
 WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.obligation o WHERE o.requirement_id=q.requirement_id AND o.release_id=r.release_id);

 INSERT GRAC_New.audit_trace(entity_type,entity_id,action_type,after_json,status,entered_by)
 SELECT N'Artifact',a.artifact_id,N'SEED_SAMPLE',N'{"sample":"multi-authority demonstration artifact"}',N'Active',@by FROM @artifacts s JOIN GRAC_New.artifact a ON a.artifact_code=s.artifact_code
 WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.audit_trace x WHERE x.entity_type=N'Artifact' AND x.entity_id=a.artifact_id AND x.action_type=N'SEED_SAMPLE');

 COMMIT TRANSACTION;
 SELECT N'Multi-authority sample data ready.' Message,
  (SELECT COUNT(*) FROM @authorities) AuthoritySamples,(SELECT COUNT(*) FROM @artifacts) ArtifactSamples,
  (SELECT COUNT(*) FROM @controls) ReusableControls,(SELECT COUNT(*) FROM @samples) RequirementSamples;
END TRY
BEGIN CATCH
 IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
GO
