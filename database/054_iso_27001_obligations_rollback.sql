/* =====================================================================
   054_iso_27001_obligations_rollback.sql

   Reverses 054_iso_27001_obligations.sql.

   Default behaviour is a soft rollback: the loaded Obligations, their
   type detail rows, evidence specs, evidence links and Practice mappings
   are set to Retired, matching the platform convention that repository
   records are retired by status rather than physically deleted
   (migration 049 -- Repository masters and mappings use Active / Retired).

   Set @hard_delete = 1 for a true undo. Rows are deleted child-first --
   evidence links, then evidence, then the type detail row, then the
   Practice mapping, then the parent -- so no foreign key is violated.
   The hard path refuses to run if any loaded Obligation has an assurance
   runtime record (035+), because deleting the definition would orphan a
   raised checklist.

   Obligations are matched by obligation_name against the 558 names in the
   workbook -- the same natural key 054 loads on. An Obligation created by
   hand that happens to share a name will therefore be caught by this
   rollback; review the report before committing to @hard_delete.

   AUDIT ROWS ARE NOT REMOVED, by either path. audit_trace,
   audit_trace_event and audit_trace_detail carry INSTEAD OF UPDATE,
   DELETE triggers that reject any attempt to change them, so the record
   that the load happened survives the rollback. That is the intended
   behaviour of an append-only trail, not an oversight.

   Run this BEFORE 053_iso_27001_practices_rollback.sql when using the
   hard path -- 053's hard delete refuses while Obligations still exist.

   FILE ENCODING: UTF-8 with BOM. Run with sqlcmd -f 65001 if needed.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- ---------------------------------------------------------------
-- Clear stale temp tables -- SEPARATE BATCH, ON PURPOSE
--
-- # temp tables live for the whole session, not the script. If an earlier
-- run of a different revision of this file left #oname or #otarget behind
-- with different columns, SQL Server binds the INSERT statements further
-- down against THAT table when it compiles the batch -- before the
-- CREATE TABLE below has had a chance to run -- and the load dies with
-- "Invalid column name" on a column this file plainly declares.
--
-- The GO after this block is what fixes it: the drops complete in their
-- own batch, so the batch that follows compiles against nothing and the
-- CREATE TABLE statements define the shape. Do not fold these drops into
-- the main batch, and do not rely on reconnecting instead.
-- ---------------------------------------------------------------
IF OBJECT_ID('tempdb..#oname')   IS NOT NULL DROP TABLE #oname;
IF OBJECT_ID('tempdb..#otarget') IS NOT NULL DROP TABLE #otarget;
GO

BEGIN TRY
BEGIN TRANSACTION;

DECLARE @by          NVARCHAR(100) = N'anoop.ps@soffit.in';
DECLARE @hard_delete BIT           = 0;
DECLARE @error   NVARCHAR(4000), @blocked NVARCHAR(4000);
DECLARE @links INT=0, @evid INT=0, @detail INT=0, @maps INT=0, @parents INT=0;

CREATE TABLE #oname(obligation_name NVARCHAR(500) NOT NULL PRIMARY KEY);

INSERT #oname(obligation_name) VALUES
(N'Maintain an Approved Information Security Policy'),
(N'Maintain a Topic-Specific Policy Register'),
(N'Maintain an Approved Security Role Structure'),
(N'Assign Responsibility for Security Activities and Assets'),
(N'Maintain a Segregation Conflict Register'),
(N'Separate Request, Approval and Execution'),
(N'Maintain Documented Management Security Expectations'),
(N'Provide Role-Specific Security Guidance'),
(N'Maintain a Relevant Authority Register'),
(N'Assign Authorised Authority Contacts'),
(N'Maintain Reporting Triggers and Timelines'),
(N'Maintain a Relevant Security Group Register'),
(N'Assign Group Liaison Owners'),
(N'Maintain Approved Threat-Intelligence Objectives'),
(N'Assign Threat-Intelligence Responsibilities'),
(N'Include Security Terms in Supplier Agreements'),
(N'Maintain Documented Asset Inventories'),
(N'Maintain Inventory Fields Needed for Management'),
(N'Maintain Approved Acceptable-Use Rules'),
(N'Maintain Asset-Handling Procedures'),
(N'Obtain User Acknowledgement of Acceptable Use'),
(N'Assign Responsibility for Use of Processing Facilities'),
(N'Maintain a Record of Assets to Be Returned'),
(N'Maintain an Approved Information-Classification Policy'),
(N'Maintain an Information-Classification Scheme'),
(N'Maintain Approved Information-Labelling Procedures'),
(N'Align Labelling Procedures with the Classification Scheme'),
(N'Cover Information in Electronic Format'),
(N'Cover Information in Physical Format'),
(N'Cover Information in Other Formats'),
(N'Maintain an Information-Transfer Policy'),
(N'Maintain Transfer Rules and Procedures'),
(N'Align Transfer Protection with Classification'),
(N'Maintain Third-Party Transfer Agreements'),
(N'Cover All Information Forms in Transfer Agreements'),
(N'Maintain an Approved Access-Control Policy'),
(N'Assign Information and Asset Owners'),
(N'Maintain an Approved Identity Lifecycle Process'),
(N'Define Identity Lifecycle Stages'),
(N'Document the Business Need for Each Identity'),
(N'Define the Identity Purpose and Scope'),
(N'Maintain an Approved Authentication Management Process'),
(N'Define Authentication Information Types in Scope'),
(N'Generate Unique Temporary Passwords'),
(N'Assign Temporary Secrets to One Person'),
(N'Maintain an Approved Access-Right Lifecycle Process'),
(N'Define Physical and Logical Access in Scope'),
(N'Require Asset-Owner Authorization'),
(N'Record the Business Purpose for Approval'),
(N'Maintain supplier information security'),
(N'Define the scope of supplier information security'),
(N'Maintain and classify supplier types'),
(N'Define the scope of and classify supplier types'),
(N'Maintain supplier security agreements'),
(N'Define scope and criteria for supplier security agreements'),
(N'Maintain information and access methods'),
(N'Define scope and criteria for information and access methods'),
(N'Maintain ICT supply-chain security'),
(N'Define scope and criteria for ICT supply-chain security'),
(N'Maintain ICT acquisition security requirements'),
(N'Define scope and criteria for ICT acquisition security requirements'),
(N'Maintain supplier monitoring and change management'),
(N'Define scope and criteria for supplier monitoring and change management'),
(N'Maintain supplier agreement compliance'),
(N'Define scope and criteria for supplier agreement compliance'),
(N'Maintain cloud-service lifecycle governance'),
(N'Define scope and criteria for cloud-service lifecycle governance'),
(N'Maintain the cloud security policy'),
(N'Define scope and criteria for the cloud security policy'),
(N'Maintain incident management preparedness'),
(N'Define scope and criteria for incident management preparedness'),
(N'Maintain incident roles and responsibilities'),
(N'Define scope and criteria for incident roles and responsibilities'),
(N'Maintain security-event assessment'),
(N'Define scope and criteria for security-event assessment'),
(N'Maintain the agreed incident categorization scheme'),
(N'Define scope and criteria for the agreed incident categorization scheme'),
(N'Maintain documented incident response'),
(N'Define scope and criteria for documented incident response'),
(N'Maintain the designated competent response team'),
(N'Define scope and criteria for the designated competent response team'),
(N'Maintain incident learning and improvement'),
(N'Define scope and criteria for incident learning and improvement'),
(N'Maintain incident-type classification for learning'),
(N'Define scope and criteria for incident-type classification for learning'),
(N'Maintain security evidence management'),
(N'Define scope and criteria for security evidence management'),
(N'Maintain potential-evidence identification'),
(N'Define scope and criteria for potential-evidence identification'),
(N'Maintain information security during disruption'),
(N'Define scope and criteria for information security during disruption'),
(N'Maintain disruption security requirements'),
(N'Define scope and criteria for disruption security requirements'),
(N'Maintain ICT continuity readiness'),
(N'Define scope and criteria for ICT continuity readiness'),
(N'Maintain integration of ICT and business continuity'),
(N'Define scope and criteria for integration of ICT and business continuity'),
(N'Maintain external information security requirements'),
(N'Define scope and criteria for external information security requirements'),
(N'Maintain the external-requirements register'),
(N'Define scope and criteria for the external-requirements register'),
(N'Maintain intellectual-property protection governance'),
(N'Define scope and criteria for intellectual-property protection governance'),
(N'Maintain the intellectual-property policy'),
(N'Define scope and criteria for the intellectual-property policy'),
(N'Maintain records-protection governance'),
(N'Define scope and criteria for records-protection governance'),
(N'Maintain prevention of record loss and destruction'),
(N'Define scope and criteria for prevention of record loss and destruction'),
(N'Maintain privacy and PII protection governance'),
(N'Define scope and criteria for privacy and PII protection governance'),
(N'Maintain applicable privacy requirements'),
(N'Define scope and criteria for applicable privacy requirements'),
(N'Maintain independent review governance'),
(N'Define scope and criteria for independent review governance'),
(N'Maintain independent review process'),
(N'Define scope and criteria for independent review process'),
(N'Maintain security compliance review governance'),
(N'Define scope and criteria for security compliance review governance'),
(N'Maintain compliance review method');

INSERT #oname(obligation_name) VALUES
(N'Define scope and criteria for compliance review method'),
(N'Maintain operating procedure governance'),
(N'Define scope and criteria for operating procedure governance'),
(N'Maintain activities requiring procedures'),
(N'Define scope and criteria for activities requiring procedures'),
(N'Include Screening Requirements in Supplier Contracts'),
(N'Maintain requirements for Govern security terms of employment'),
(N'Define scope and criteria for Govern security terms of employment'),
(N'Maintain requirements for Align terms with security policies'),
(N'Define scope and criteria for Align terms with security policies'),
(N'Maintain requirements for Govern the security learning programme'),
(N'Define scope and criteria for Govern the security learning programme'),
(N'Maintain requirements for Align learning with policies and procedures'),
(N'Define scope and criteria for Align learning with policies and procedures'),
(N'Maintain requirements for Govern the disciplinary process'),
(N'Define scope and criteria for Govern the disciplinary process'),
(N'Maintain requirements for Formalize disciplinary procedures'),
(N'Define scope and criteria for Formalize disciplinary procedures'),
(N'Maintain requirements for Govern termination and role-change security'),
(N'Define scope and criteria for Govern termination and role-change security'),
(N'Maintain requirements for Define continuing security duties'),
(N'Define scope and criteria for Define continuing security duties'),
(N'Maintain requirements for Govern confidentiality agreements'),
(N'Define scope and criteria for Govern confidentiality agreements'),
(N'Maintain requirements for Identify agreement requirements'),
(N'Define scope and criteria for Identify agreement requirements'),
(N'Maintain requirements for Govern secure remote working'),
(N'Define scope and criteria for Govern secure remote working'),
(N'Maintain requirements for Maintain a remote-working policy'),
(N'Define scope and criteria for Maintain a remote-working policy'),
(N'Maintain requirements for Govern security event reporting'),
(N'Define scope and criteria for Govern security event reporting'),
(N'Maintain requirements for Provide accessible reporting mechanisms'),
(N'Define scope and criteria for Provide accessible reporting mechanisms'),
(N'Set Perimeter Security Requirements'),
(N'Maintain Continuous Internal Boundaries'),
(N'Maintain Effective Controls: Physical Access Authorization'),
(N'Maintain Effective Controls: Periodic Access Review And Revocation'),
(N'Maintain Effective Controls: Secure Office And Room Design'),
(N'Maintain Effective Controls: Critical Facility Location Away From Public Access'),
(N'Maintain Effective Controls: Continuous Premises Monitoring'),
(N'Maintain Effective Controls: Guard And Monitoring-Service Arrangements'),
(N'Maintain Effective Controls: Site Threat And Consequence Assessment'),
(N'Maintain Effective Controls: Regular Threat Reassessment And Monitoring'),
(N'Maintain Effective Controls: Secure-Area Working Rules'),
(N'Maintain Effective Controls: Need-To-Know Awareness Of Secure Areas'),
(N'Maintain Effective Controls: Clear Desk And Clear Screen Policy'),
(N'Maintain Effective Controls: Secure Paper And Removable-Media Storage'),
(N'Maintain Effective Controls: Secure Equipment Siting'),
(N'Maintain Effective Controls: Restricted Access To Work Areas'),
(N'Maintain Effective Controls: Management Authorization For Off-Site Devices'),
(N'Maintain Effective Controls: BYOD And Organization-Owned Device Coverage'),
(N'Maintain Effective Controls: Removable-Media Policy And Communication'),
(N'Maintain Effective Controls: Media Removal Authorization And Audit Trail'),
(N'Maintain Effective Controls: Utility Dependency And Continuity Assessment'),
(N'Maintain Effective Controls: Manufacturer-Compliant Utility Operation'),
(N'Maintain Effective Controls: Power And Communications Cable Protection'),
(N'Maintain Effective Controls: Underground Or Alternative Cable Protection'),
(N'Maintain Effective Controls: Supplier-Recommended Maintenance'),
(N'Maintain Effective Controls: Maintenance Programme Ownership And Monitoring'),
(N'Maintain Effective Controls: Storage-Media Presence Verification'),
(N'Maintain Effective Controls: Sensitive-Data Removal Verification'),
(N'Maintain Effective Controls: Endpoint Security Policy And User Communication'),
(N'Maintain Effective Controls: Information Classification And Device Handling Limits'),
(N'Maintain Effective Controls: Privileged Access Policy And Authorization'),
(N'Maintain Effective Controls: Identification Of Privileged Users Services And Processes'),
(N'Maintain Effective Controls: Access Restriction Policy Implementation'),
(N'Maintain Effective Controls: Anonymous And Public Access Restriction'),
(N'Maintain Effective Controls: Source Code Access Policy And Procedures'),
(N'Maintain Effective Controls: Central Source Code Repository Protection'),
(N'Maintain Effective Controls: Risk-Based Authentication Design'),
(N'Maintain Effective Controls: Authentication Strength By Information Classification'),
(N'Maintain Effective Controls: Capacity Requirements And Criticality Assessment'),
(N'Maintain Effective Controls: Resource Utilization Monitoring'),
(N'Maintain Effective Controls: Malware Protection Policy Roles And Awareness'),
(N'Maintain Effective Controls: Unauthorized Software Prevention And Allowlisting'),
(N'Maintain Effective Controls: Asset Software Version And Ownership Inventory'),
(N'Maintain Effective Controls: Vulnerability Roles Responsibilities And Coordination'),
(N'Maintain Effective Controls: Configuration Management Process And Tools'),
(N'Maintain Effective Controls: Configuration Roles Responsibilities And Procedures'),
(N'Maintain Effective Controls: Retention-Based Information Deletion Policy'),
(N'Maintain Effective Controls: Legal Regulatory Contractual And Business Requirements'),
(N'Maintain Effective Controls: Data Masking Policy And Business Requirements'),
(N'Maintain Effective Controls: Sensitive Data And PII Identification'),
(N'Maintain Effective Controls: Sensitive Information Identification And Classification'),
(N'Maintain Effective Controls: Email File Transfer Device And Media Channel Monitoring'),
(N'Maintain Approved Backup Requirements'),
(N'Keep a Secure Remote Backup Copy'),
(N'Protect Backup Access and Encryption'),
(N'Maintain Effective Controls: Availability And Redundancy Requirements'),
(N'Maintain Effective Controls: Redundant Architecture And Component Design'),
(N'Maintain Effective Controls: Logging Policy Purpose Scope And Handling'),
(N'Maintain Effective Controls: Event Identity Time Device Network And Protocol Data'),
(N'Maintain Effective Controls: Monitoring Scope Legal Requirements And Retention'),
(N'Maintain Effective Controls: Network System Application And Access Monitoring'),
(N'Maintain Effective Controls: Time Synchronization Requirements'),
(N'Maintain Effective Controls: Legal Contractual And Monitoring Time Accuracy'),
(N'Maintain Effective Controls: Privileged Utility Inventory And Classification'),
(N'Maintain Effective Controls: Minimum Trusted Authorized Utility Users'),
(N'Maintain Effective Controls: Operational Software Installation Procedures'),
(N'Maintain Effective Controls: Trained Administrator And Management Authorization'),
(N'Maintain Effective Controls: Network Information Classification And Protection'),
(N'Maintain Effective Controls: Network Device Ownership And Procedures'),
(N'Maintain Effective Controls: Network Service Security Requirements And Levels'),
(N'Maintain Effective Controls: Internal And External Provider Responsibilities'),
(N'Maintain Effective Controls: Network Segregation Policy And Criteria'),
(N'Maintain Effective Controls: Network Domains By Trust Criticality And Sensitivity'),
(N'Maintain Effective Controls: Safe And Appropriate Web-Use Rules'),
(N'Maintain Effective Controls: Allowed And Prohibited Website Categories'),
(N'Maintain Effective Controls: Cryptography Policy And Approved Use'),
(N'Maintain Effective Controls: Information Classification And Protection Strength'),
(N'Maintain Effective Controls: Secure Development Policy And Methodology'),
(N'Maintain Effective Controls: Development Test And Production Separation'),
(N'Maintain Effective Controls: Application Security Risk Assessment And Approval'),
(N'Maintain Effective Controls: Identity Trust Authentication And Access Segregation'),
(N'Maintain Effective Controls: Secure Engineering Principles And Governance'),
(N'Maintain Effective Controls: Security Across Business Data Application And Technology Layers'),
(N'Maintain Effective Controls: Secure Coding Governance And Minimum Baseline'),
(N'Maintain Effective Controls: Third-Party And Open-Source Component Coverage'),
(N'Maintain Effective Controls: Security Testing Process And Requirements');

INSERT #oname(obligation_name) VALUES
(N'Maintain Effective Controls: New System Upgrade And Version Testing'),
(N'Maintain Effective Controls: Outsourced Development Requirements And Oversight'),
(N'Maintain Effective Controls: Licensing Code Ownership And Intellectual Property'),
(N'Maintain Effective Controls: Environment Separation Requirements And Design'),
(N'Maintain Effective Controls: Separate Development Test And Production Domains'),
(N'Maintain Effective Controls: Formal Change Policy And Life-Cycle Process'),
(N'Maintain Effective Controls: Change Ownership Responsibilities And Procedures'),
(N'Maintain Effective Controls: Test Information Selection And Reliability'),
(N'Maintain Effective Controls: Sensitive And Personal Data Avoidance'),
(N'Maintain Effective Controls: Audit Testing Planning And Management Agreement'),
(N'Maintain Effective Controls: System And Data Access Approval'),
(N'Consider Business, Legal and Risk Requirements'),
(N'Create Required Topic-Specific Policies'),
(N'Define Required Information Security Roles'),
(N'Communicate Assigned Security Responsibilities'),
(N'Provide Local Security Responsibility Guidance'),
(N'Assess Processes for Conflicting Duties'),
(N'Separate Development, Production and Review Duties'),
(N'Communicate Management Support for Security'),
(N'Brief Personnel on Security Duties Before Access'),
(N'Identify Applicable Authorities'),
(N'Brief Authorised Contacts'),
(N'Assess Suitable Security Groups'),
(N'Maintain Membership and Contact Access'),
(N'Define Threat-Intelligence Requirements'),
(N'Produce Strategic Threat Intelligence'),
(N'Produce Tactical Threat Intelligence'),
(N'Produce Operational Threat Intelligence'),
(N'Document Security Requirements Early'),
(N'Classify Information and Set Protection Needs'),
(N'Assess Supplier Security Before Engagement'),
(N'Identify Organisational Information Assets'),
(N'Identify Other Associated Assets'),
(N'Determine Asset Information-Security Importance'),
(N'Record Asset Location Where Appropriate'),
(N'Implement Acceptable-Use Rules and Procedures'),
(N'Communicate Protection and Handling Requirements'),
(N'Identify All Issued Physical Assets'),
(N'Identify All Issued Electronic Assets'),
(N'Recover User Endpoint Devices'),
(N'Recover Portable Storage Devices'),
(N'Recover Specialist Equipment'),
(N'Communicate the Classification Policy'),
(N'Assess Confidentiality Requirements'),
(N'Assess Integrity Requirements'),
(N'Assess Availability Requirements'),
(N'Implement Information-Labelling Procedures'),
(N'Communicate the Transfer Policy to Relevant Parties'),
(N'Approve the Access-Control Policy'),
(N'Communicate Access-Control Rules'),
(N'Identify Entities Requiring Access'),
(N'Define Required Access Types'),
(N'Assign Identity Lifecycle Responsibilities'),
(N'Assign an Accountable Identity Sponsor'),
(N'Assign Authentication Management Responsibilities'),
(N'Generate Non-Guessable Temporary PINs'),
(N'Assign Access-Right Process Ownership'),
(N'Route Requests to the Correct Asset Owner'),
(N'Assign ownership for supplier information security'),
(N'Assign ownership for and classify supplier types'),
(N'Assign ownership for supplier security agreements'),
(N'Assign ownership for information and access methods'),
(N'Assign ownership for ICT supply-chain security'),
(N'Assign ownership for ICT acquisition security requirements'),
(N'Assign ownership for supplier monitoring and change management'),
(N'Assign ownership for supplier agreement compliance'),
(N'Assign ownership for cloud-service lifecycle governance'),
(N'Assign ownership for the cloud security policy'),
(N'Assign ownership for incident management preparedness'),
(N'Assign ownership for incident roles and responsibilities'),
(N'Assign ownership for security-event assessment'),
(N'Assign ownership for the agreed incident categorization scheme'),
(N'Assign ownership for documented incident response'),
(N'Assign ownership for the designated competent response team'),
(N'Assign ownership for incident learning and improvement'),
(N'Assign ownership for incident-type classification for learning'),
(N'Assign ownership for security evidence management'),
(N'Assign ownership for potential-evidence identification'),
(N'Assign ownership for information security during disruption'),
(N'Assign ownership for disruption security requirements'),
(N'Assign ownership for ICT continuity readiness'),
(N'Assign ownership for integration of ICT and business continuity'),
(N'Assign ownership for external information security requirements'),
(N'Assign ownership for the external-requirements register'),
(N'Assign ownership for intellectual-property protection governance'),
(N'Assign ownership for the intellectual-property policy'),
(N'Assign ownership for records-protection governance'),
(N'Assign ownership for prevention of record loss and destruction'),
(N'Assign ownership for privacy and PII protection governance'),
(N'Assign ownership for applicable privacy requirements'),
(N'Assign ownership for independent review governance'),
(N'Assign ownership for independent review process'),
(N'Assign ownership for security compliance review governance'),
(N'Assign ownership for compliance review method'),
(N'Assign ownership for operating procedure governance'),
(N'Assign ownership for activities requiring procedures'),
(N'Screen All Personnel Prior to Engagement'),
(N'Verify Candidate References'),
(N'Validate Competence for Information Security Roles'),
(N'Assign ownership for Govern security terms of employment'),
(N'Assign ownership for Align terms with security policies'),
(N'Assign ownership for Govern the security learning programme'),
(N'Assign ownership for Align learning with policies and procedures'),
(N'Assign ownership for Govern the disciplinary process'),
(N'Assign ownership for Formalize disciplinary procedures'),
(N'Assign ownership for Govern termination and role-change security'),
(N'Assign ownership for Define continuing security duties'),
(N'Assign ownership for Govern confidentiality agreements'),
(N'Assign ownership for Identify agreement requirements'),
(N'Assign ownership for Govern secure remote working'),
(N'Assign ownership for Maintain a remote-working policy'),
(N'Assign ownership for Govern security event reporting'),
(N'Assign ownership for Provide accessible reporting mechanisms'),
(N'Identify Protected Areas'),
(N'List Assets Within Each Perimeter'),
(N'Design Layered Physical Barriers'),
(N'Define Security Zones'),
(N'Define Requirements: Physical Access Authorization'),
(N'Assign Ownership: Physical Access Authorization'),
(N'Define Requirements: Periodic Access Review And Revocation');

INSERT #oname(obligation_name) VALUES
(N'Assign Ownership: Periodic Access Review And Revocation'),
(N'Define Requirements: Secure Office And Room Design'),
(N'Assign Ownership: Secure Office And Room Design'),
(N'Define Requirements: Critical Facility Location Away From Public Access'),
(N'Assign Ownership: Critical Facility Location Away From Public Access'),
(N'Define Requirements: Continuous Premises Monitoring'),
(N'Assign Ownership: Continuous Premises Monitoring'),
(N'Define Requirements: Guard And Monitoring-Service Arrangements'),
(N'Assign Ownership: Guard And Monitoring-Service Arrangements'),
(N'Define Requirements: Site Threat And Consequence Assessment'),
(N'Assign Ownership: Site Threat And Consequence Assessment'),
(N'Define Requirements: Regular Threat Reassessment And Monitoring'),
(N'Assign Ownership: Regular Threat Reassessment And Monitoring'),
(N'Define Requirements: Secure-Area Working Rules'),
(N'Assign Ownership: Secure-Area Working Rules'),
(N'Define Requirements: Need-To-Know Awareness Of Secure Areas'),
(N'Assign Ownership: Need-To-Know Awareness Of Secure Areas'),
(N'Define Requirements: Clear Desk And Clear Screen Policy'),
(N'Assign Ownership: Clear Desk And Clear Screen Policy'),
(N'Define Requirements: Secure Paper And Removable-Media Storage'),
(N'Assign Ownership: Secure Paper And Removable-Media Storage'),
(N'Define Requirements: Secure Equipment Siting'),
(N'Assign Ownership: Secure Equipment Siting'),
(N'Define Requirements: Restricted Access To Work Areas'),
(N'Assign Ownership: Restricted Access To Work Areas'),
(N'Define Requirements: Management Authorization For Off-Site Devices'),
(N'Assign Ownership: Management Authorization For Off-Site Devices'),
(N'Define Requirements: BYOD And Organization-Owned Device Coverage'),
(N'Assign Ownership: BYOD And Organization-Owned Device Coverage'),
(N'Define Requirements: Removable-Media Policy And Communication'),
(N'Assign Ownership: Removable-Media Policy And Communication'),
(N'Define Requirements: Media Removal Authorization And Audit Trail'),
(N'Assign Ownership: Media Removal Authorization And Audit Trail'),
(N'Define Requirements: Utility Dependency And Continuity Assessment'),
(N'Assign Ownership: Utility Dependency And Continuity Assessment'),
(N'Define Requirements: Manufacturer-Compliant Utility Operation'),
(N'Assign Ownership: Manufacturer-Compliant Utility Operation'),
(N'Define Requirements: Power And Communications Cable Protection'),
(N'Assign Ownership: Power And Communications Cable Protection'),
(N'Define Requirements: Underground Or Alternative Cable Protection'),
(N'Assign Ownership: Underground Or Alternative Cable Protection'),
(N'Define Requirements: Supplier-Recommended Maintenance'),
(N'Assign Ownership: Supplier-Recommended Maintenance'),
(N'Define Requirements: Maintenance Programme Ownership And Monitoring'),
(N'Assign Ownership: Maintenance Programme Ownership And Monitoring'),
(N'Define Requirements: Storage-Media Presence Verification'),
(N'Assign Ownership: Storage-Media Presence Verification'),
(N'Define Requirements: Sensitive-Data Removal Verification'),
(N'Assign Ownership: Sensitive-Data Removal Verification'),
(N'Define Requirements: Endpoint Security Policy And User Communication'),
(N'Assign Ownership: Endpoint Security Policy And User Communication'),
(N'Define Requirements: Information Classification And Device Handling Limits'),
(N'Assign Ownership: Information Classification And Device Handling Limits'),
(N'Define Requirements: Privileged Access Policy And Authorization'),
(N'Assign Ownership: Privileged Access Policy And Authorization'),
(N'Define Requirements: Identification Of Privileged Users Services And Processes'),
(N'Assign Ownership: Identification Of Privileged Users Services And Processes'),
(N'Define Requirements: Access Restriction Policy Implementation'),
(N'Assign Ownership: Access Restriction Policy Implementation'),
(N'Define Requirements: Anonymous And Public Access Restriction'),
(N'Assign Ownership: Anonymous And Public Access Restriction'),
(N'Define Requirements: Source Code Access Policy And Procedures'),
(N'Assign Ownership: Source Code Access Policy And Procedures'),
(N'Define Requirements: Central Source Code Repository Protection'),
(N'Assign Ownership: Central Source Code Repository Protection'),
(N'Define Requirements: Risk-Based Authentication Design'),
(N'Assign Ownership: Risk-Based Authentication Design'),
(N'Define Requirements: Authentication Strength By Information Classification'),
(N'Assign Ownership: Authentication Strength By Information Classification'),
(N'Define Requirements: Capacity Requirements And Criticality Assessment'),
(N'Assign Ownership: Capacity Requirements And Criticality Assessment'),
(N'Define Requirements: Resource Utilization Monitoring'),
(N'Assign Ownership: Resource Utilization Monitoring'),
(N'Define Requirements: Malware Protection Policy Roles And Awareness'),
(N'Assign Ownership: Malware Protection Policy Roles And Awareness'),
(N'Define Requirements: Unauthorized Software Prevention And Allowlisting'),
(N'Assign Ownership: Unauthorized Software Prevention And Allowlisting'),
(N'Define Requirements: Asset Software Version And Ownership Inventory'),
(N'Assign Ownership: Asset Software Version And Ownership Inventory'),
(N'Define Requirements: Vulnerability Roles Responsibilities And Coordination'),
(N'Assign Ownership: Vulnerability Roles Responsibilities And Coordination'),
(N'Define Requirements: Configuration Management Process And Tools'),
(N'Assign Ownership: Configuration Management Process And Tools'),
(N'Define Requirements: Configuration Roles Responsibilities And Procedures'),
(N'Assign Ownership: Configuration Roles Responsibilities And Procedures'),
(N'Define Requirements: Retention-Based Information Deletion Policy'),
(N'Assign Ownership: Retention-Based Information Deletion Policy'),
(N'Define Requirements: Legal Regulatory Contractual And Business Requirements'),
(N'Assign Ownership: Legal Regulatory Contractual And Business Requirements'),
(N'Define Requirements: Data Masking Policy And Business Requirements'),
(N'Assign Ownership: Data Masking Policy And Business Requirements'),
(N'Define Requirements: Sensitive Data And PII Identification'),
(N'Assign Ownership: Sensitive Data And PII Identification'),
(N'Define Requirements: Sensitive Information Identification And Classification'),
(N'Assign Ownership: Sensitive Information Identification And Classification'),
(N'Define Requirements: Email File Transfer Device And Media Channel Monitoring'),
(N'Assign Ownership: Email File Transfer Device And Media Channel Monitoring'),
(N'Create a Backup and Restoration Plan'),
(N'Define Requirements: Availability And Redundancy Requirements'),
(N'Assign Ownership: Availability And Redundancy Requirements'),
(N'Define Requirements: Redundant Architecture And Component Design'),
(N'Assign Ownership: Redundant Architecture And Component Design'),
(N'Define Requirements: Logging Policy Purpose Scope And Handling'),
(N'Assign Ownership: Logging Policy Purpose Scope And Handling'),
(N'Define Requirements: Event Identity Time Device Network And Protocol Data'),
(N'Assign Ownership: Event Identity Time Device Network And Protocol Data'),
(N'Define Requirements: Monitoring Scope Legal Requirements And Retention'),
(N'Assign Ownership: Monitoring Scope Legal Requirements And Retention'),
(N'Define Requirements: Network System Application And Access Monitoring'),
(N'Assign Ownership: Network System Application And Access Monitoring'),
(N'Define Requirements: Time Synchronization Requirements'),
(N'Assign Ownership: Time Synchronization Requirements'),
(N'Define Requirements: Legal Contractual And Monitoring Time Accuracy'),
(N'Assign Ownership: Legal Contractual And Monitoring Time Accuracy'),
(N'Define Requirements: Privileged Utility Inventory And Classification'),
(N'Assign Ownership: Privileged Utility Inventory And Classification'),
(N'Define Requirements: Minimum Trusted Authorized Utility Users'),
(N'Assign Ownership: Minimum Trusted Authorized Utility Users'),
(N'Define Requirements: Operational Software Installation Procedures'),
(N'Assign Ownership: Operational Software Installation Procedures');

INSERT #oname(obligation_name) VALUES
(N'Define Requirements: Trained Administrator And Management Authorization'),
(N'Assign Ownership: Trained Administrator And Management Authorization'),
(N'Define Requirements: Network Information Classification And Protection'),
(N'Assign Ownership: Network Information Classification And Protection'),
(N'Define Requirements: Network Device Ownership And Procedures'),
(N'Assign Ownership: Network Device Ownership And Procedures'),
(N'Define Requirements: Network Service Security Requirements And Levels'),
(N'Assign Ownership: Network Service Security Requirements And Levels'),
(N'Define Requirements: Internal And External Provider Responsibilities'),
(N'Assign Ownership: Internal And External Provider Responsibilities'),
(N'Define Requirements: Network Segregation Policy And Criteria'),
(N'Assign Ownership: Network Segregation Policy And Criteria'),
(N'Define Requirements: Network Domains By Trust Criticality And Sensitivity'),
(N'Assign Ownership: Network Domains By Trust Criticality And Sensitivity'),
(N'Define Requirements: Safe And Appropriate Web-Use Rules'),
(N'Assign Ownership: Safe And Appropriate Web-Use Rules'),
(N'Define Requirements: Allowed And Prohibited Website Categories'),
(N'Assign Ownership: Allowed And Prohibited Website Categories'),
(N'Define Requirements: Cryptography Policy And Approved Use'),
(N'Assign Ownership: Cryptography Policy And Approved Use'),
(N'Define Requirements: Information Classification And Protection Strength'),
(N'Assign Ownership: Information Classification And Protection Strength'),
(N'Define Requirements: Secure Development Policy And Methodology'),
(N'Assign Ownership: Secure Development Policy And Methodology'),
(N'Define Requirements: Development Test And Production Separation'),
(N'Assign Ownership: Development Test And Production Separation'),
(N'Define Requirements: Application Security Risk Assessment And Approval'),
(N'Assign Ownership: Application Security Risk Assessment And Approval'),
(N'Define Requirements: Identity Trust Authentication And Access Segregation'),
(N'Assign Ownership: Identity Trust Authentication And Access Segregation'),
(N'Define Requirements: Secure Engineering Principles And Governance'),
(N'Assign Ownership: Secure Engineering Principles And Governance'),
(N'Define Requirements: Security Across Business Data Application And Technology Layers'),
(N'Assign Ownership: Security Across Business Data Application And Technology Layers'),
(N'Define Requirements: Secure Coding Governance And Minimum Baseline'),
(N'Assign Ownership: Secure Coding Governance And Minimum Baseline'),
(N'Define Requirements: Third-Party And Open-Source Component Coverage'),
(N'Assign Ownership: Third-Party And Open-Source Component Coverage'),
(N'Define Requirements: Security Testing Process And Requirements'),
(N'Assign Ownership: Security Testing Process And Requirements'),
(N'Define Requirements: New System Upgrade And Version Testing'),
(N'Assign Ownership: New System Upgrade And Version Testing'),
(N'Define Requirements: Outsourced Development Requirements And Oversight'),
(N'Assign Ownership: Outsourced Development Requirements And Oversight'),
(N'Define Requirements: Licensing Code Ownership And Intellectual Property'),
(N'Assign Ownership: Licensing Code Ownership And Intellectual Property'),
(N'Define Requirements: Environment Separation Requirements And Design'),
(N'Assign Ownership: Environment Separation Requirements And Design'),
(N'Define Requirements: Separate Development Test And Production Domains'),
(N'Assign Ownership: Separate Development Test And Production Domains'),
(N'Define Requirements: Formal Change Policy And Life-Cycle Process'),
(N'Assign Ownership: Formal Change Policy And Life-Cycle Process'),
(N'Define Requirements: Change Ownership Responsibilities And Procedures'),
(N'Assign Ownership: Change Ownership Responsibilities And Procedures'),
(N'Define Requirements: Test Information Selection And Reliability'),
(N'Assign Ownership: Test Information Selection And Reliability'),
(N'Define Requirements: Sensitive And Personal Data Avoidance'),
(N'Assign Ownership: Sensitive And Personal Data Avoidance'),
(N'Define Requirements: Audit Testing Planning And Management Agreement'),
(N'Assign Ownership: Audit Testing Planning And Management Agreement'),
(N'Define Requirements: System And Data Access Approval'),
(N'Assign Ownership: System And Data Access Approval'),
(N'Include Required Policy Commitments'),
(N'Verify Policy Alignment and Consistency'),
(N'Review the Security Role Structure'),
(N'Consider Collusion Risk'),
(N'Verify Critical Transaction Separation'),
(N'Review Management Application of Security Expectations'),
(N'Confirm Briefing Before Access Approval'),
(N'Verify Authority Contact Details'),
(N'Approve Security Group Memberships'),
(N'Review Participation and Membership Value'),
(N'Verify Requirement Coverage'),
(N'Verify Supplier Security Performance'),
(N'Verify Curriculum Vitae Accuracy'),
(N'Verify Supplier Compliance with Screening Requirements'),
(N'Review Backup Coverage and Criticality'),
(N'Review Backup Storage Protection');

SELECT ro.obligation_id, ro.obligation_name
INTO #otarget
FROM GRAC_New.requirement_obligation ro
JOIN #oname n ON n.obligation_name = ro.obligation_name;
CREATE UNIQUE CLUSTERED INDEX ux_otarget ON #otarget(obligation_id);

PRINT CONCAT(N'Obligations matched for rollback: ', (SELECT COUNT(*) FROM #otarget), N' of 558 in the workbook.');

IF @hard_delete = 1
BEGIN
  -- Refuse if the assurance runtime (035) has already raised a checklist
  -- item against these definitions -- deleting the definition would orphan it.
  IF OBJECT_ID('GRAC_New.assurance_checklist_item','U') IS NOT NULL
  BEGIN
    IF EXISTS(SELECT 1 FROM GRAC_New.assurance_checklist_item a
              JOIN GRAC_New.obligation_assurance_spec s ON s.assurance_spec_id = a.assurance_spec_id
              JOIN #otarget t ON t.obligation_id = s.obligation_id)
    BEGIN
      SET @error = N'Hard delete refused. Assurance checklist items have been raised against these Obligations (assurance runtime, migration 035). Clear the runtime records first, or use the soft path.';
      -- THROW, not RAISERROR: it reaches the CATCH block below, which rolls
      -- the transaction back. RAISERROR would leave it open.
      THROW 50450, @error, 1;
    END
  END

  -- Child-first deletion order.
  DELETE l FROM GRAC_New.obligation_state_evidence_link     l JOIN #otarget t ON t.obligation_id = l.obligation_id;  SET @links = @@ROWCOUNT;
  DELETE l FROM GRAC_New.obligation_execution_evidence_link l JOIN #otarget t ON t.obligation_id = l.obligation_id;  SET @links = @links + @@ROWCOUNT;
  DELETE l FROM GRAC_New.obligation_assurance_evidence_link l JOIN #otarget t ON t.obligation_id = l.obligation_id;  SET @links = @links + @@ROWCOUNT;

  DELETE e FROM GRAC_New.requirement_obligation_evidence e JOIN #otarget t ON t.obligation_id = e.obligation_id;     SET @evid = @@ROWCOUNT;

  DELETE d FROM GRAC_New.obligation_state_rule      d JOIN #otarget t ON t.obligation_id = d.obligation_id;          SET @detail = @@ROWCOUNT;
  DELETE d FROM GRAC_New.obligation_execution_spec  d JOIN #otarget t ON t.obligation_id = d.obligation_id;          SET @detail = @detail + @@ROWCOUNT;
  DELETE d FROM GRAC_New.obligation_assurance_spec  d JOIN #otarget t ON t.obligation_id = d.obligation_id;          SET @detail = @detail + @@ROWCOUNT;

  DELETE m FROM GRAC_New.obligation_requirement_release_map m JOIN #otarget t ON t.obligation_id = m.obligation_id;  SET @maps = @@ROWCOUNT;

  DELETE ro FROM GRAC_New.requirement_obligation ro JOIN #otarget t ON t.obligation_id = ro.obligation_id;           SET @parents = @@ROWCOUNT;

  PRINT CONCAT(N'054 rollback (hard delete) complete. Evidence links ', @links,
               N' | Evidence ', @evid, N' | Detail rows ', @detail,
               N' | Mappings ', @maps, N' | Obligations ', @parents, N'.');
END
ELSE
BEGIN
  UPDATE l SET l.status=N'Retired', l.updated_by=@by, l.updated_dt=SYSUTCDATETIME()
  FROM GRAC_New.obligation_state_evidence_link l JOIN #otarget t ON t.obligation_id=l.obligation_id WHERE l.status<>N'Retired';
  SET @links = @@ROWCOUNT;
  UPDATE l SET l.status=N'Retired', l.updated_by=@by, l.updated_dt=SYSUTCDATETIME()
  FROM GRAC_New.obligation_execution_evidence_link l JOIN #otarget t ON t.obligation_id=l.obligation_id WHERE l.status<>N'Retired';
  SET @links = @links + @@ROWCOUNT;
  UPDATE l SET l.status=N'Retired', l.updated_by=@by, l.updated_dt=SYSUTCDATETIME()
  FROM GRAC_New.obligation_assurance_evidence_link l JOIN #otarget t ON t.obligation_id=l.obligation_id WHERE l.status<>N'Retired';
  SET @links = @links + @@ROWCOUNT;

  UPDATE e SET e.status=N'Retired', e.updated_by=@by, e.updated_dt=SYSUTCDATETIME()
  FROM GRAC_New.requirement_obligation_evidence e JOIN #otarget t ON t.obligation_id=e.obligation_id WHERE e.status<>N'Retired';
  SET @evid = @@ROWCOUNT;

  UPDATE d SET d.status=N'Retired', d.updated_by=@by, d.updated_dt=SYSUTCDATETIME()
  FROM GRAC_New.obligation_state_rule d JOIN #otarget t ON t.obligation_id=d.obligation_id WHERE d.status<>N'Retired';
  SET @detail = @@ROWCOUNT;
  UPDATE d SET d.status=N'Retired', d.updated_by=@by, d.updated_dt=SYSUTCDATETIME()
  FROM GRAC_New.obligation_execution_spec d JOIN #otarget t ON t.obligation_id=d.obligation_id WHERE d.status<>N'Retired';
  SET @detail = @detail + @@ROWCOUNT;
  UPDATE d SET d.status=N'Retired', d.updated_by=@by, d.updated_dt=SYSUTCDATETIME()
  FROM GRAC_New.obligation_assurance_spec d JOIN #otarget t ON t.obligation_id=d.obligation_id WHERE d.status<>N'Retired';
  SET @detail = @detail + @@ROWCOUNT;

  UPDATE m SET m.status=N'Retired', m.updated_by=@by, m.updated_dt=SYSUTCDATETIME()
  FROM GRAC_New.obligation_requirement_release_map m JOIN #otarget t ON t.obligation_id=m.obligation_id WHERE m.status<>N'Retired';
  SET @maps = @@ROWCOUNT;

  UPDATE ro SET ro.status=N'Retired', ro.updated_by=@by, ro.updated_dt=SYSUTCDATETIME()
  FROM GRAC_New.requirement_obligation ro JOIN #otarget t ON t.obligation_id=ro.obligation_id WHERE ro.status<>N'Retired';
  SET @parents = @@ROWCOUNT;

  PRINT CONCAT(N'054 rollback (soft, Retired) complete. Evidence links ', @links,
               N' | Evidence ', @evid, N' | Detail rows ', @detail,
               N' | Mappings ', @maps, N' | Obligations ', @parents, N'.');
  PRINT N'Re-running 054 skips a Retired Obligation because it matches by name -- use @hard_delete = 1 for a clean reload.';
END

COMMIT TRANSACTION;
END TRY
BEGIN CATCH
  IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
  THROW;
END CATCH
GO

-- Verification: nothing from the load should remain Active.
SELECT ro.status, COUNT(*) AS obligations
FROM GRAC_New.requirement_obligation ro
WHERE EXISTS(SELECT 1 FROM GRAC_New.audit_trace_event ae
             WHERE ae.entity_type = N'obligations' AND ae.entity_id = ro.obligation_id
               AND ae.remarks LIKE N'Bulk load: migration 054%')
GROUP BY ro.status
ORDER BY ro.status;
GO
