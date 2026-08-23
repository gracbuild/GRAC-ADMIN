/* =====================================================================
   053_iso_27001_practices.sql

   Bulk load of the ISO/IEC 27001:2022 Practice catalogue into
   GRAC_New.requirement, and of the Practice -> Statement links into
   GRAC_New.framework_statement_requirement_map.

   Source     : Import ISO 27001 Sample data v1.0.xlsx, sheet 'All Practices'
   Practices  : 186
   Statements : 93 distinct Annex A controls, already loaded
   Follow-on  : 054_iso_27001_obligations.sql loads the three Obligation
                sheets and reads the mapping this script creates, so 053
                must complete successfully before 054 is run.
   Rerunnable : yes. A Practice whose Practice Name already exists is
                skipped; its Statement mapping is still created if missing.
   Rollback   : 053_iso_27001_practices_rollback.sql

   FILE ENCODING
   -------------
   Saved as UTF-8 with BOM. Several Practice texts contain U+2019 (right
   single quotation mark, as in "organisation's"). Open in SSMS normally,
   or run with: sqlcmd -f 65001 -i 053_iso_27001_practices.sql
   All literals are N'' prefixed and embedded apostrophes are doubled.

   HOW A STATEMENT IS RESOLVED
   ---------------------------
   The sheet's 'framework_statement_id' column carries the real
   GRAC_New.framework_statement key, exported from the database the
   Statements were loaded into. It is the authoritative link and this
   script uses it directly: @resolve_by_statement_id = 1 (the default).

   Every row is still cross-checked. The reference parsed from
   'Control No. and Name' -- the leading token with the 'A.' prefix
   stripped ('A.5.10 Acceptable use ...' -> '5.10') -- must equal the
   statement_reference of the row that ID resolves to. Any disagreement
   aborts the whole load and lists every offending pair.

   That check is the point. framework_statement_id is an IDENTITY column,
   so its values belong to ONE database. Run this script against a
   different environment -- a rebuilt UAT, a fresh developer instance,
   statements reloaded in another order -- and the same IDs will name
   different controls. Without the cross-check the load would succeed and
   silently attach 186 Practices to the wrong Annex A controls, which no
   constraint would catch and no screen would make obvious. With it, the
   load stops before writing anything.

   For such an environment set @resolve_by_statement_id = 0. The script
   then matches on statement_reference within the resolved release and
   ignores the ID column entirely. The result is identical on a database
   whose IDs agree with the sheet, and correct on one whose IDs do not.

   PRACTICE CODE IS NOT TAKEN FROM THE SHEET
   -----------------------------------------
   The sheet carries a 'Practice ID' column (POL-01, ROL-01, AUT-01 ...).
   That column is NOT loaded as requirement_code. Since migration 050 the
   Practice Code is system-generated -- PR-001, PR-002, PR-003 ... -- and
   cm_manage_repository assigns it on save. This script follows the same
   rule and the same numbering, continuing from the highest PR-### already
   in GRAC_New.requirement.

   The sheet's own IDs could not be used even if the convention allowed it:
   three of them are reused across unrelated controls --

       AUT-01  A.5.5  Contact with authorities
       AUT-01  A.5.17 Authentication information
       DSP-01  A.6.4  Disciplinary process
       DSP-01  A.7.14 Secure disposal or re-use of equipment
       DSP-02  A.6.4  Disciplinary process
       DSP-02  A.7.14 Secure disposal or re-use of equipment

   -- and requirement_code is UNIQUE, so half of each pair would have been
   rejected. Generated codes make all 186 rows loadable. The sheet's ID is
   still staged in #prac.practice_ref and printed in the load report, so a
   row can be traced back to the spreadsheet.

   HOW A PRACTICE IS IDENTIFIED ON RE-RUN
   --------------------------------------
   By requirement_name. All 186 Practice Names in the sheet are distinct,
   so the name is a safe natural key for the skip test and it is what 054
   joins on. Do not rename a loaded Practice before running 054.

   MAKER-CHECKER
   -------------
   'requirements' is registered with is_maker_checker = 1, so interactive
   saves route through change_management. This script is a controlled bulk
   load and writes directly, exactly as 052 and the other sample-data
   scripts do. An audit_trace row is written per inserted Practice and per
   inserted mapping, so the load is visible in the trail.

   NOT SUPPLIED BY THE SHEET
   -------------------------
   keywords        : left NULL.
   control mapping : control_requirement_map is not written. The sheet maps
                     Practices to Statements, not to internal Controls.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- ---------------------------------------------------------------
-- Clear stale temp tables -- SEPARATE BATCH, ON PURPOSE
--
-- # temp tables live for the whole session, not the script. If an earlier
-- run of a different revision of this file left #prac or #stmt behind
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
IF OBJECT_ID('tempdb..#prac') IS NOT NULL DROP TABLE #prac;
IF OBJECT_ID('tempdb..#stmt') IS NOT NULL DROP TABLE #stmt;
GO

BEGIN TRY
BEGIN TRANSACTION;

-- ---------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------
DECLARE @by                      NVARCHAR(100) = N'anoop.ps@soffit.in';
DECLARE @overwrite_existing      BIT           = 0;  -- 1 = refresh statement/objective on rerun

-- 1 = trust the sheet's framework_statement_id (still cross-checked against
--     the control reference). Correct for the database the sheet came from.
-- 0 = ignore the ID column and match on statement_reference instead. Use
--     this when loading into an environment whose IDENTITY values differ.
DECLARE @resolve_by_statement_id BIT           = 1;

DECLARE @release_id     BIGINT;
DECLARE @practice_start INT;
DECLARE @inserted       INT = 0, @updated INT = 0, @mapped INT = 0;
DECLARE @missing        NVARCHAR(4000), @error NVARCHAR(4000);

-- ---------------------------------------------------------------
-- Preflight
-- ---------------------------------------------------------------
IF SCHEMA_ID('GRAC_New') IS NULL
    THROW 50300, 'Schema GRAC_New is missing. Run 001_control_management_schema.sql first.', 1;

IF OBJECT_ID('GRAC_New.requirement','U') IS NULL
    THROW 50301, 'GRAC_New.requirement is missing. Run 001_control_management_schema.sql first.', 1;

IF OBJECT_ID('GRAC_New.framework_statement_requirement_map','U') IS NULL
    THROW 50302, 'GRAC_New.framework_statement_requirement_map is missing. Run 001_control_management_schema.sql first.', 1;

IF OBJECT_ID('GRAC_New.framework_statement','U') IS NULL
    THROW 50303, 'GRAC_New.framework_statement is missing. Load the Statements first.', 1;

-- ---------------------------------------------------------------
-- Staging
--
-- sheet_statement_id  -- the framework_statement key exported with the sheet
-- statement_reference -- the same control, parsed from 'Control No. and Name'
--                        and used to verify that ID
-- practice_ref        -- the spreadsheet's own Practice ID. Never written to
--                        the database (see the header note on Practice Code)
--                        but carried so the load report can quote it.
-- ---------------------------------------------------------------
CREATE TABLE #prac(
  seq                 INT            NOT NULL PRIMARY KEY,
  sheet_statement_id  BIGINT         NOT NULL,
  statement_reference NVARCHAR(160)  NOT NULL,
  practice_ref        NVARCHAR(60)   NOT NULL,
  practice_name       NVARCHAR(300)  NOT NULL,
  practice_statement  NVARCHAR(MAX)  NOT NULL,
  objective           NVARCHAR(MAX)  NULL);

INSERT #prac(seq,sheet_statement_id,statement_reference,practice_ref,practice_name,practice_statement,objective) VALUES
(1,1,N'5.1',N'POL-01',N'Establish the information security policy',N'Define a high-level information security policy that explains the organisation’s security approach, objectives, guiding principles, commitments, responsibilities and method for handling exceptions. Consider business needs, legal and contractual duties, and current and expected risks and threats.',N'Provide clear management direction and support for information security.'),
(2,1,N'5.1',N'POL-02',N'Maintain topic-specific policies',N'Create detailed policies where needed for security areas and target groups, such as access control, backup, incident management, cryptography, classification, vulnerability management and secure development. Keep them aligned with the main policy.',N'Turn the organisation’s security direction into clear requirements for specific areas and users.'),
(3,2,N'5.2',N'ROL-01',N'Define the security role structure',N'Define and document the information security roles needed to implement, operate and manage information security. Align the structure with the main security policy and supporting topic-specific policies.',N'Create a clear and approved structure for managing information security.'),
(4,2,N'5.2',N'ROL-02',N'Allocate security responsibilities',N'Assign responsibility for protecting information and assets, operating security processes, and ensuring that all personnel follow their security duties. Add site-specific or facility-specific guidance where needed.',N'Ensure every important security activity and asset has a responsible role.'),
(5,4,N'5.3',N'SOD-01',N'Identify conflicting duties',N'Identify duties and responsibility areas that could allow one person to cause or hide fraud, error or control bypass. Document the conflict, affected process, risk and required separation.',N'Maintain a clear view of activities that must not be performed by one person alone.'),
(6,4,N'5.3',N'SOD-02',N'Separate critical activities',N'Assign different people to conflicting steps such as requesting, approving and implementing access; initiating, approving and executing changes; and designing, building and reviewing code or controls.',N'Prevent one person from controlling an entire sensitive transaction or process.'),
(7,5,N'5.4',N'MGT-01',N'Set management security expectations',N'Managers should visibly support information security and require personnel to follow the organisation’s security policies, topic-specific policies and procedures.',N'Make management direction and expected security behaviour clear.'),
(8,5,N'5.4',N'MGT-02',N'Brief personnel before access',N'Explain security roles, responsibilities, acceptable behaviour and working methods before people receive access to information or other assets.',N'Ensure people understand their security duties before they begin work or receive access.'),
(9,6,N'5.5',N'AUT-01',N'Identify and maintain authority contacts',N'Identify relevant legal, regulatory, supervisory, law-enforcement, emergency and utility authorities. Keep accurate contact details and reasons for contact.',N'Ensure the correct authority can be reached quickly when needed.'),
(10,6,N'5.5',N'AUT-02 + AUT-03',N'Define authority contact responsibilities / Define reporting triggers and timelines',N'Document who is authorised to contact each authority, the approval route and alternate contacts. Document which security incidents and events require authority contact, how they must be reported and the required reporting time.',N'Make external authority communication controlled and accountable. Support complete and timely reporting to authorities.'),
(11,7,N'5.6',N'SIG-01',N'Identify relevant security groups',N'Identify special interest groups, specialist security forums and professional associations that match the organisation’s technologies, services, sector, locations and risks.',N'Connect with groups that provide useful and relevant security knowledge.'),
(12,7,N'5.6',N'SIG-02',N'Maintain group contacts and participation',N'Assign owners for memberships and liaison contacts. Keep membership, contact details, access and participation arrangements current.',N'Maintain reliable access to selected security communities and specialists.'),
(13,8,N'5.7',N'THR-01',N'Govern threat intelligence',N'Define the purpose, scope, objectives, responsibilities and expected outputs for threat-intelligence activities so they support prevention, detection and response.',N'Provide clear direction and ownership for producing and using threat intelligence.'),
(14,8,N'5.7',N'THR-02',N'Cover all intelligence levels',N'Consider strategic intelligence about the changing threat landscape, tactical intelligence about attacker methods and tools, and operational intelligence about specific attacks and technical indicators.',N'Maintain a complete view of threats from business-level trends to attack details.'),
(15,9,N'5.8',N'ISPM-03',N'Define security requirements',N'Set security requirements during planning and design. Cover information classification, confidentiality, integrity, availability, laws, contracts, logging and business needs.',N'Build the right protection into the product or service before delivery.'),
(16,9,N'5.8',N'ISPM-06',N'Manage supplier security',N'Check supplier security before engagement, include clear security terms in agreements and confirm suppliers meet them during the project.',N'Ensure third parties protect project information and services as required.'),
(17,10,N'5.9',N'AST-01',N'Identify information and associated assets',N'Identify organisational information and other associated assets and determine their importance to information security.',N'Ensure assets requiring protection are known and prioritised.'),
(18,10,N'5.9',N'AST-02',N'Maintain suitable asset inventories',N'Record assets in dedicated or existing inventories, including location where appropriate, and coordinate the inventories maintained by relevant functions.',N'Maintain usable records covering all important asset types and locations.'),
(19,11,N'5.10',N'USE-01',N'Establish acceptable-use rules',N'Identify, document and implement rules and procedures for the acceptable use and handling of information and other associated assets.',N'Provide clear and enforceable direction for protecting, using and handling assets.'),
(20,11,N'5.10',N'USE-02',N'Communicate responsibilities to users',N'Make personnel and external-party users aware of protection and handling requirements and their responsibility for using information-processing facilities.',N'Ensure every user understands and accepts their security responsibilities.'),
(21,12,N'5.11',N'RET-02',N'Identify assets to be returned',N'Clearly identify and document all organisational information and associated assets held by each person or party, including issued physical and electronic assets.',N'Know exactly what must be returned before a change or termination is completed.'),
(22,12,N'5.11',N'RET-03',N'Recover and verify returned assets',N'Recover endpoint devices, portable media, specialist equipment, authentication hardware, physical information and other entrusted assets, and verify their return.',N'Restore organisational control of all returnable assets.'),
(23,13,N'5.12',N'CLS-01',N'Establish the classification policy and scheme',N'Define and communicate a topic-specific information-classification policy and a scheme that reflects organisational security needs.',N'Provide one approved basis for classifying information.'),
(24,13,N'5.12',N'CLS-02',N'Assess protection requirements',N'Classify information using confidentiality, integrity, availability, business, legal and relevant interested-party requirements.',N'Match classification and protection to the information’s actual needs.'),
(25,14,N'5.13',N'LBL-01',N'Establish information-labelling procedures',N'Develop, approve and implement labelling procedures aligned with the organisation’s information-classification scheme.',N'Provide consistent rules for communicating information classification.'),
(26,14,N'5.13',N'LBL-02',N'Cover all information and asset formats',N'Apply labelling procedures to information and associated assets in electronic, physical and other applicable formats.',N'Ensure classification remains visible regardless of format or storage medium.'),
(27,15,N'5.14',N'XFR-01',N'Govern information transfer',N'Establish and communicate policy, rules, procedures and agreements for information transfers within the organisation and with external parties.',N'Provide one controlled framework for all information-transfer methods.'),
(28,15,N'5.14',N'XFR-02',N'Apply classification and third-party agreements',N'Match transfer protection to information classification and maintain agreements, including recipient authentication, for third-party transfers.',N'Apply suitable protection and accountability to external transfers.'),
(29,16,N'5.15',N'ACL-01',N'Govern access control',N'Define, approve, communicate and maintain access-control policy, rules and procedures based on business and information security needs.',N'Provide one clear and current framework for controlling physical and logical access.'),
(30,16,N'5.15',N'ACL-02',N'Determine access requirements',N'Identify asset owners, the human and technical entities that need access, the type of access required and the business reason for it.',N'Grant access only where a documented business and security need exists.'),
(31,17,N'5.16',N'IDM-01',N'Govern the identity life cycle',N'Define and maintain a controlled process covering identity request, verification, creation, configuration, activation, change, review, disabling and removal.',N'Manage every identity consistently from initial need through final removal.'),
(32,17,N'5.16',N'IDM-02',N'Confirm the business need for identities',N'Require a documented business or operational need, accountable sponsor, defined purpose, scope and expected lifetime before an identity is established.',N'Create identities only where a valid and approved need exists.'),
(33,18,N'5.17',N'AUT-01',N'Govern authentication information',N'Define and operate an approved process for allocating, managing, handling, changing and withdrawing authentication information.',N'Control authentication information throughout its life cycle.'),
(34,18,N'5.17',N'AUT-02',N'Control temporary authentication secrets',N'Generate temporary passwords and PINs that are unique and hard to guess, and require their replacement after first use.',N'Prevent temporary enrolment secrets from enabling unauthorized access.'),
(35,19,N'5.18',N'ART-01',N'Govern the access-right life cycle',N'Define and operate an approved process to provision, review, modify and remove physical and logical access rights under the access-control policy.',N'Keep every access right controlled from request through removal.'),
(36,19,N'5.18',N'ART-02',N'Obtain owner and management authorization',N'Obtain authorization from the information or asset owner and, where appropriate, separate management approval before access is granted.',N'Ensure access is approved by accountable decision-makers.'),
(37,20,N'5.19',N'SUP-01',N'Govern supplier information security',N'Establish, approve, communicate and maintain a supplier-security policy, processes and procedures covering the full relationship life cycle.',N'Maintain an agreed level of security across all supplier relationships.'),
(38,20,N'5.19',N'SUP-02',N'Identify and classify supplier types',N'Identify and document supplier categories that can affect the confidentiality, integrity or availability of information.',N'Apply controls according to the supplier type and its potential impact.'),
(39,21,N'5.20',N'SAG-01',N'Govern supplier security agreements',N'Establish and document supplier agreements that clearly assign both parties’ information security obligations according to the relationship type.',N'Create a shared and enforceable understanding of required security.'),
(40,21,N'5.20',N'SAG-02',N'Describe information and access methods',N'State what information will be provided or accessed and how physical or logical access will occur.',N'Make the information flow and access route explicit.'),
(41,22,N'5.21',N'ISC-01',N'Govern ICT supply-chain security',N'Define and implement processes and procedures for managing security risks across ICT product and service supply chains.',N'Maintain agreed security throughout the ICT supply chain.'),
(42,22,N'5.21',N'ISC-02',N'Set security requirements for ICT acquisition',N'Define security requirements for acquiring ICT products and services according to business need and risk.',N'Ensure security is built into purchasing decisions.'),
(43,23,N'5.22',N'SMC-01',N'Govern supplier monitoring and change management',N'Define a controlled process to monitor, review, evaluate and manage changes in supplier security practices and service delivery.',N'Maintain agreed security and service levels throughout supplier relationships.'),
(44,23,N'5.22',N'SMC-02',N'Verify agreement compliance',N'Check that supplier services comply with all applicable security terms and conditions in the agreement.',N'Ensure contractual security requirements operate in practice.'),
(45,24,N'5.23',N'CLD-01',N'Govern the cloud-service life cycle',N'Define controlled processes for acquiring, using, managing, changing and exiting cloud services according to security requirements.',N'Manage cloud security consistently from selection through exit.'),
(46,24,N'5.23',N'CLD-02',N'Establish a cloud security policy',N'Approve and communicate a topic-specific policy for cloud-service use to relevant interested parties.',N'Provide clear direction for secure cloud use.'),
(47,25,N'5.24',N'IRP-01',N'Govern incident management preparedness',N'Define, establish, approve and maintain processes for planning and preparing to manage information security incidents.',N'Enable quick, effective, consistent and orderly incident handling.'),
(48,25,N'5.24',N'IRP-02',N'Define incident roles and responsibilities',N'Assign accountable roles, authorities, deputies and responsibilities for incident management procedures.',N'Ensure incident duties and decision rights are clear.'),
(49,26,N'5.25',N'EVA-01',N'Govern security-event assessment',N'Define and maintain a controlled process for assessing security events and deciding whether they are incidents.',N'Ensure every security event receives a consistent and accountable decision.'),
(50,26,N'5.25',N'EVA-02',N'Maintain an agreed categorization scheme',N'Define and obtain approval for categories used to classify information security incidents.',N'Apply consistent incident categories across the organization.'),
(51,27,N'5.26',N'IRS-01',N'Govern documented incident response',N'Establish, approve, communicate and maintain procedures for responding to information security incidents.',N'Ensure incidents are handled efficiently and consistently under documented procedures.'),
(52,27,N'5.26',N'IRS-02',N'Use a designated competent response team',N'Assign incident response to a designated team with the authority, availability and competence required.',N'Ensure qualified personnel lead and perform response actions.'),
(53,28,N'5.27',N'LRN-01',N'Govern incident learning and improvement',N'Define and maintain procedures for using incident knowledge to strengthen security controls.',N'Turn incident experience into managed and accountable improvement.'),
(54,28,N'5.27',N'LRN-02',N'Classify incident types for learning',N'Define consistent incident-type categories suitable for measurement and trend analysis.',N'Enable reliable comparison and identification of recurring patterns.'),
(55,29,N'5.28',N'EVD-01',N'Govern security evidence management',N'Establish, approve and implement procedures for managing evidence related to information security events.',N'Ensure evidence is managed consistently and effectively.'),
(56,29,N'5.28',N'EVD-02',N'Identify potential evidence',N'Define how potential physical and digital evidence is recognized, scoped and prioritized when an event is detected.',N'Prevent relevant evidence from being overlooked or destroyed.'),
(57,30,N'5.29',N'DSR-01',N'Govern information security during disruption',N'Define, approve and maintain how information and associated assets will be protected during disruption.',N'Maintain an appropriate level of information security under abnormal conditions.'),
(58,30,N'5.29',N'DSR-02',N'Identify disruption security requirements',N'Determine security requirements that apply before, during and after relevant disruption scenarios.',N'Make required protection explicit for each credible disruption.'),
(59,31,N'5.30',N'ICT-01',N'Govern ICT continuity readiness',N'Plan, implement, maintain and test ICT readiness based on business continuity objectives and ICT continuity requirements.',N'Ensure ICT can support organizational objectives during disruption.'),
(60,31,N'5.30',N'ICT-02',N'Integrate ICT continuity with business continuity',N'Align ICT continuity management with business continuity and information security management.',N'Coordinate ICT availability with wider continuity needs.'),
(61,32,N'5.31',N'LCR-01',N'Govern external information security requirements',N'Define and maintain a controlled approach for identifying, documenting, applying and updating external information security requirements.',N'Ensure legal, statutory, regulatory and contractual duties are managed consistently.'),
(62,32,N'5.31',N'LCR-02',N'Maintain a requirements register',N'Keep a current register of applicable requirements, sources, jurisdictions, owners, obligations and compliance approaches.',N'Provide one traceable view of external security duties.'),
(63,33,N'5.32',N'IPR-01',N'Govern intellectual property protection',N'Define and implement procedures for protecting intellectual property rights and proprietary products.',N'Meet applicable intellectual-property and licence obligations consistently.'),
(64,33,N'5.32',N'IPR-02',N'Establish an intellectual property policy',N'Define, approve and communicate a topic-specific policy for protecting intellectual property rights.',N'Provide clear organizational direction for intellectual-property compliance.'),
(65,34,N'5.33',N'REC-01',N'Govern records protection',N'Define and implement controls and procedures for protecting records throughout their life cycle.',N'Protect records consistently as business and management needs change.'),
(66,34,N'5.33',N'REC-02',N'Prevent record loss and destruction',N'Protect records against accidental or unauthorized loss and destruction.',N'Preserve required records and business evidence.'),
(67,35,N'5.34',N'PII-01',N'Govern privacy and PII protection',N'Establish governance for preserving privacy and protecting PII across the organization and its services.',N'Provide clear direction and oversight for privacy protection.'),
(68,35,N'5.34',N'PII-02',N'Identify applicable privacy requirements',N'Identify and maintain applicable privacy laws, regulations and contractual requirements for every PII processing activity.',N'Know the privacy duties that each activity must meet.'),
(69,36,N'5.35',N'IRV-01',N'Govern independent information security reviews',N'Define accountability, authority and oversight for independent reviews.',N'Ensure reviews are planned, objective and acted upon.'),
(70,36,N'5.35',N'IRV-02',N'Maintain an independent review process',N'Document the method for planning, performing, reporting and following up independent reviews.',N'Make reviews consistent and repeatable.'),
(71,37,N'5.36',N'CMP-01',N'Govern security compliance reviews',N'Define accountability and oversight for reviewing compliance with security requirements.',N'Ensure compliance reviews are owned and consistently managed.'),
(72,37,N'5.36',N'CMP-02',N'Maintain a compliance review method',N'Document how compliance will be measured, reviewed, recorded and reported.',N'Make reviews consistent and repeatable.'),
(73,38,N'5.37',N'SOP-01',N'Govern documented operating procedures',N'Define ownership, approval and oversight for secure operating procedures.',N'Ensure operating instructions are controlled and accountable.'),
(74,38,N'5.37',N'SOP-02',N'Identify activities requiring procedures',N'Determine which operational security activities need documented instructions.',N'Focus documentation on activities where consistency matters.'),
(75,3,N'6.1',N'PR-HR-01',N'Perform Personnel Background Screening',N'Defines checks required to confirm the identity, history and suitability of personnel before engagement.',N'Engage only personnel whose identity, background and qualifications have been appropriately verified.'),
(76,3,N'6.1',N'PR-HR-02 + PR-HR-03 + PR-HR-04',N'Manage Third-Party Personnel Screening / Conduct Legally Compliant Screening / Assess Suitability for Information Security Roles',N'Defines screening controls for supplier and third-party personnel who may access company information or systems. Ensures personnel screening is performed lawfully, fairly and with required candidate communication. Assesses whether personnel assigned to information-security roles are competent and trustworthy.',N'Ensure supplier personnel meet equivalent screening and compliance requirements. Meet applicable legal, privacy, consent and notification requirements during screening. Assign security responsibilities only to personnel with suitable competence and trustworthiness.'),
(77,39,N'6.2',N'EMP-01',N'Govern security terms of employment',N'Define ownership and approval for information security employment and equivalent contractual terms.',N'Ensure security duties are consistently included and enforced.'),
(78,39,N'6.2',N'EMP-02',N'Align terms with security policies',N'Reflect the main security policy and relevant topic-specific policies in contractual obligations.',N'Connect personnel duties to approved security direction.'),
(79,40,N'6.3',N'TRN-01',N'Govern the security learning programme',N'Define ownership, scope, approval and oversight for awareness, education and training.',N'Maintain a coordinated and accountable programme.'),
(80,40,N'6.3',N'TRN-02',N'Align learning with policies and procedures',N'Base learning content on current security policies, topic policies and procedures.',N'Teach the requirements personnel must follow.'),
(81,41,N'6.4',N'DSP-01',N'Govern the disciplinary process',N'Define ownership, authority, approval and oversight for security-related disciplinary action.',N'Ensure fair, consistent and lawful handling.'),
(82,41,N'6.4',N'DSP-02',N'Formalize disciplinary procedures',N'Document investigation, decision, action, appeal and recordkeeping steps.',N'Create a repeatable and controlled process.'),
(83,42,N'6.5',N'EXT-01',N'Govern termination and role-change security',N'Define ownership and oversight for security during employment and contract transitions.',N'Coordinate complete and timely transition controls.'),
(84,42,N'6.5',N'EXT-02',N'Define continuing security duties',N'Identify responsibilities that remain valid after termination or role change.',N'Protect organizational interests after transition.'),
(85,43,N'6.6',N'NDA-01',N'Govern confidentiality agreements',N'Define ownership, approval and oversight for confidentiality and non-disclosure agreements.',N'Ensure agreements are consistent and enforceable.'),
(86,43,N'6.6',N'NDA-02',N'Identify agreement requirements',N'Determine where confidentiality agreements are required based on information and access.',N'Apply agreements to relevant parties and risks.'),
(87,44,N'6.7',N'RMT-01',N'Govern secure remote working',N'Define ownership, approval, oversight and risk acceptance for remote work.',N'Ensure remote work is authorized and controlled.'),
(88,44,N'6.7',N'RMT-02',N'Maintain a remote-working policy',N'Define conditions, restrictions, responsibilities and permitted arrangements.',N'Provide consistent rules for remote work.'),
(89,45,N'6.8',N'EVR-01',N'Govern security event reporting',N'Define ownership, channels, responsibilities and oversight for event reporting.',N'Ensure consistent and accountable reporting.'),
(90,45,N'6.8',N'EVR-02',N'Provide accessible reporting mechanisms',N'Offer easy, accessible and available methods for reporting events.',N'Remove barriers to timely reporting.'),
(91,46,N'7.1',N'PPS-01',N'Define perimeter scope and requirements',N'Identify protected areas, the information and other assets inside them, and the security level each boundary must provide.',N'Make every physical security boundary risk-based, approved and traceable to the assets it protects.'),
(92,46,N'7.1',N'PPS-02',N'Design layered security perimeters',N'Use one or more physical barriers and separate areas with different security needs through suitable internal boundaries and controlled transition points.',N'Use layered and zoned protection so one weak boundary does not expose higher-risk assets.'),
(93,47,N'7.2',N'ENT-01',N'Physical Access Authorization',N'Define, implement and maintain practical controls for physical access authorization, proportionate to the protected assets and physical security risk.',N'Ensure physical access authorization is authorized, effective, monitored and supported by evidence.'),
(94,47,N'7.2',N'ENT-02',N'Periodic Access Review And Revocation',N'Define, implement and maintain practical controls for periodic access review and revocation, proportionate to the protected assets and physical security risk.',N'Ensure periodic access review and revocation is authorized, effective, monitored and supported by evidence.'),
(95,48,N'7.3',N'OFF-01',N'Secure Office And Room Design',N'Define, implement and maintain practical controls for secure office and room design, proportionate to the protected assets and physical security risk.',N'Ensure secure office and room design is authorized, effective, monitored and supported by evidence.'),
(96,48,N'7.3',N'OFF-02',N'Critical Facility Location Away From Public Access',N'Define, implement and maintain practical controls for critical facility location away from public access, proportionate to the protected assets and physical security risk.',N'Ensure critical facility location away from public access is authorized, effective, monitored and supported by evidence.'),
(97,49,N'7.4',N'MON-01',N'Continuous Premises Monitoring',N'Define, implement and maintain practical controls for continuous premises monitoring, proportionate to the protected assets and physical security risk.',N'Ensure continuous premises monitoring is authorized, effective, monitored and supported by evidence.'),
(98,49,N'7.4',N'MON-02',N'Guard And Monitoring-Service Arrangements',N'Define, implement and maintain practical controls for guard and monitoring-service arrangements, proportionate to the protected assets and physical security risk.',N'Ensure guard and monitoring-service arrangements is authorized, effective, monitored and supported by evidence.'),
(99,50,N'7.5',N'ENV-01',N'Site Threat And Consequence Assessment',N'Define, implement and maintain practical controls for site threat and consequence assessment, proportionate to the protected assets and physical security risk.',N'Ensure site threat and consequence assessment is authorized, effective, monitored and supported by evidence.'),
(100,50,N'7.5',N'ENV-02',N'Regular Threat Reassessment And Monitoring',N'Define, implement and maintain practical controls for regular threat reassessment and monitoring, proportionate to the protected assets and physical security risk.',N'Ensure regular threat reassessment and monitoring is authorized, effective, monitored and supported by evidence.'),
(101,51,N'7.6',N'SWA-01',N'Secure-Area Working Rules',N'Define, implement and maintain practical controls for secure-area working rules, proportionate to the protected assets and physical security risk.',N'Ensure secure-area working rules is authorized, effective, monitored and supported by evidence.'),
(102,51,N'7.6',N'SWA-02',N'Need-To-Know Awareness Of Secure Areas',N'Define, implement and maintain practical controls for need-to-know awareness of secure areas, proportionate to the protected assets and physical security risk.',N'Ensure need-to-know awareness of secure areas is authorized, effective, monitored and supported by evidence.'),
(103,52,N'7.7',N'CDS-01',N'Clear Desk And Clear Screen Policy',N'Define, implement and maintain practical controls for clear desk and clear screen policy, proportionate to the protected assets and physical security risk.',N'Ensure clear desk and clear screen policy is authorized, effective, monitored and supported by evidence.'),
(104,52,N'7.7',N'CDS-02',N'Secure Paper And Removable-Media Storage',N'Define, implement and maintain practical controls for secure paper and removable-media storage, proportionate to the protected assets and physical security risk.',N'Ensure secure paper and removable-media storage is authorized, effective, monitored and supported by evidence.'),
(105,53,N'7.8',N'EQP-01',N'Secure Equipment Siting',N'Define, implement and maintain practical controls for secure equipment siting, proportionate to the protected assets and physical security risk.',N'Ensure secure equipment siting is authorized, effective, monitored and supported by evidence.'),
(106,53,N'7.8',N'EQP-02',N'Restricted Access To Work Areas',N'Define, implement and maintain practical controls for restricted access to work areas, proportionate to the protected assets and physical security risk.',N'Ensure restricted access to work areas is authorized, effective, monitored and supported by evidence.'),
(107,54,N'7.9',N'OPA-01',N'Management Authorization For Off-Site Devices',N'Define, implement and maintain practical controls for management authorization for off-site devices, proportionate to the protected assets and physical security risk.',N'Ensure management authorization for off-site devices is authorized, effective, monitored and supported by evidence.'),
(108,54,N'7.9',N'OPA-02',N'BYOD And Organization-Owned Device Coverage',N'Define, implement and maintain practical controls for BYOD and organization-owned device coverage, proportionate to the protected assets and physical security risk.',N'Ensure BYOD and organization-owned device coverage is authorized, effective, monitored and supported by evidence.'),
(109,55,N'7.10',N'MED-01',N'Removable-Media Policy And Communication',N'Define, implement and maintain practical controls for removable-media policy and communication, proportionate to the protected assets and physical security risk.',N'Ensure removable-media policy and communication is authorized, effective, monitored and supported by evidence.'),
(110,55,N'7.10',N'MED-02',N'Media Removal Authorization And Audit Trail',N'Define, implement and maintain practical controls for media removal authorization and audit trail, proportionate to the protected assets and physical security risk.',N'Ensure media removal authorization and audit trail is authorized, effective, monitored and supported by evidence.'),
(111,56,N'7.11',N'UTL-01',N'Utility Dependency And Continuity Assessment',N'Define, implement and maintain practical controls for utility dependency and continuity assessment, proportionate to the protected assets and physical security risk.',N'Ensure utility dependency and continuity assessment is authorized, effective, monitored and supported by evidence.'),
(112,56,N'7.11',N'UTL-02',N'Manufacturer-Compliant Utility Operation',N'Define, implement and maintain practical controls for manufacturer-compliant utility operation, proportionate to the protected assets and physical security risk.',N'Ensure manufacturer-compliant utility operation is authorized, effective, monitored and supported by evidence.'),
(113,57,N'7.12',N'CAB-01',N'Power And Communications Cable Protection',N'Define, implement and maintain practical controls for power and communications cable protection, proportionate to the protected assets and physical security risk.',N'Ensure power and communications cable protection is authorized, effective, monitored and supported by evidence.'),
(114,57,N'7.12',N'CAB-02',N'Underground Or Alternative Cable Protection',N'Define, implement and maintain practical controls for underground or alternative cable protection, proportionate to the protected assets and physical security risk.',N'Ensure underground or alternative cable protection is authorized, effective, monitored and supported by evidence.'),
(115,58,N'7.13',N'MNT-01',N'Supplier-Recommended Maintenance',N'Define, implement and maintain practical controls for supplier-recommended maintenance, proportionate to the protected assets and physical security risk.',N'Ensure supplier-recommended maintenance is authorized, effective, monitored and supported by evidence.'),
(116,58,N'7.13',N'MNT-02',N'Maintenance Programme Ownership And Monitoring',N'Define, implement and maintain practical controls for maintenance programme ownership and monitoring, proportionate to the protected assets and physical security risk.',N'Ensure maintenance programme ownership and monitoring is authorized, effective, monitored and supported by evidence.'),
(117,59,N'7.14',N'DSP-01',N'Storage-Media Presence Verification',N'Define, implement and maintain practical controls for storage-media presence verification, proportionate to the protected assets and physical security risk.',N'Ensure storage-media presence verification is authorized, effective, monitored and supported by evidence.'),
(118,59,N'7.14',N'DSP-02',N'Sensitive-Data Removal Verification',N'Define, implement and maintain practical controls for sensitive-data removal verification, proportionate to the protected assets and physical security risk.',N'Ensure sensitive-data removal verification is authorized, effective, monitored and supported by evidence.'),
(119,60,N'8.1',N'EPD-01',N'Endpoint Security Policy And User Communication',N'Define, implement and maintain practical controls for endpoint security policy and user communication, proportionate to business need, information classification and security risk.',N'Ensure endpoint security policy and user communication is authorized, effective, monitored and supported by evidence.'),
(120,60,N'8.1',N'EPD-02',N'Information Classification And Device Handling Limits',N'Define, implement and maintain practical controls for information classification and device handling limits, proportionate to business need, information classification and security risk.',N'Ensure information classification and device handling limits is authorized, effective, monitored and supported by evidence.');

INSERT #prac(seq,sheet_statement_id,statement_reference,practice_ref,practice_name,practice_statement,objective) VALUES
(121,61,N'8.2',N'PAM-01',N'Privileged Access Policy And Authorization',N'Define, implement and maintain practical controls for privileged access policy and authorization, proportionate to business need, information classification and security risk.',N'Ensure privileged access policy and authorization is authorized, effective, monitored and supported by evidence.'),
(122,61,N'8.2',N'PAM-02',N'Identification Of Privileged Users Services And Processes',N'Define, implement and maintain practical controls for identification of privileged users services and processes, proportionate to business need, information classification and security risk.',N'Ensure identification of privileged users services and processes is authorized, effective, monitored and supported by evidence.'),
(123,62,N'8.3',N'IAR-01',N'Access Restriction Policy Implementation',N'Define, implement and maintain practical controls for access restriction policy implementation, proportionate to business need, information classification and security risk.',N'Ensure access restriction policy implementation is authorized, effective, monitored and supported by evidence.'),
(124,62,N'8.3',N'IAR-02',N'Anonymous And Public Access Restriction',N'Define, implement and maintain practical controls for anonymous and public access restriction, proportionate to business need, information classification and security risk.',N'Ensure anonymous and public access restriction is authorized, effective, monitored and supported by evidence.'),
(125,63,N'8.4',N'SRC-01',N'Source Code Access Policy And Procedures',N'Define, implement and maintain practical controls for source code access policy and procedures, proportionate to business need, information classification and security risk.',N'Ensure source code access policy and procedures is authorized, effective, monitored and supported by evidence.'),
(126,63,N'8.4',N'SRC-02',N'Central Source Code Repository Protection',N'Define, implement and maintain practical controls for central source code repository protection, proportionate to business need, information classification and security risk.',N'Ensure central source code repository protection is authorized, effective, monitored and supported by evidence.'),
(127,64,N'8.5',N'SAA-01',N'Risk-Based Authentication Design',N'Define, implement and maintain practical controls for risk-based authentication design, proportionate to business need, information classification and security risk.',N'Ensure risk-based authentication design is authorized, effective, monitored and supported by evidence.'),
(128,64,N'8.5',N'SAA-02',N'Authentication Strength By Information Classification',N'Define, implement and maintain practical controls for authentication strength by information classification, proportionate to business need, information classification and security risk.',N'Ensure authentication strength by information classification is authorized, effective, monitored and supported by evidence.'),
(129,65,N'8.6',N'CAP-01',N'Capacity Requirements And Criticality Assessment',N'Define, implement and maintain practical controls for capacity requirements and criticality assessment, proportionate to business need, information classification and security risk.',N'Ensure capacity requirements and criticality assessment is authorized, effective, monitored and supported by evidence.'),
(130,65,N'8.6',N'CAP-02',N'Resource Utilization Monitoring',N'Define, implement and maintain practical controls for resource utilization monitoring, proportionate to business need, information classification and security risk.',N'Ensure resource utilization monitoring is authorized, effective, monitored and supported by evidence.'),
(131,66,N'8.7',N'MLW-01',N'Malware Protection Policy Roles And Awareness',N'Define, implement and maintain practical controls for malware protection policy roles and awareness, proportionate to business need, information classification and security risk.',N'Ensure malware protection policy roles and awareness is authorized, effective, monitored and supported by evidence.'),
(132,66,N'8.7',N'MLW-02',N'Unauthorized Software Prevention And Allowlisting',N'Define, implement and maintain practical controls for unauthorized software prevention and allowlisting, proportionate to business need, information classification and security risk.',N'Ensure unauthorized software prevention and allowlisting is authorized, effective, monitored and supported by evidence.'),
(133,67,N'8.8',N'VUL-01',N'Asset Software Version And Ownership Inventory',N'Define, implement and maintain practical controls for asset software version and ownership inventory, proportionate to business need, information classification and security risk.',N'Ensure asset software version and ownership inventory is authorized, effective, monitored and supported by evidence.'),
(134,67,N'8.8',N'VUL-02',N'Vulnerability Roles Responsibilities And Coordination',N'Define, implement and maintain practical controls for vulnerability roles responsibilities and coordination, proportionate to business need, information classification and security risk.',N'Ensure vulnerability roles responsibilities and coordination is authorized, effective, monitored and supported by evidence.'),
(135,68,N'8.9',N'CFG-01',N'Configuration Management Process And Tools',N'Define, implement and maintain practical controls for configuration management process and tools, proportionate to business need, information classification and security risk.',N'Ensure configuration management process and tools is authorized, effective, monitored and supported by evidence.'),
(136,68,N'8.9',N'CFG-02',N'Configuration Roles Responsibilities And Procedures',N'Define, implement and maintain practical controls for configuration roles responsibilities and procedures, proportionate to business need, information classification and security risk.',N'Ensure configuration roles responsibilities and procedures is authorized, effective, monitored and supported by evidence.'),
(137,69,N'8.10',N'DEL-01',N'Retention-Based Information Deletion Policy',N'Define, implement and maintain practical controls for retention-based information deletion policy, proportionate to business need, information classification and security risk.',N'Ensure retention-based information deletion policy is authorized, effective, monitored and supported by evidence.'),
(138,69,N'8.10',N'DEL-02',N'Legal Regulatory Contractual And Business Requirements',N'Define, implement and maintain practical controls for legal regulatory contractual and business requirements, proportionate to business need, information classification and security risk.',N'Ensure legal regulatory contractual and business requirements is authorized, effective, monitored and supported by evidence.'),
(139,70,N'8.11',N'MSK-01',N'Data Masking Policy And Business Requirements',N'Define, implement and maintain practical controls for data masking policy and business requirements, proportionate to business need, information classification and security risk.',N'Ensure data masking policy and business requirements is authorized, effective, monitored and supported by evidence.'),
(140,70,N'8.11',N'MSK-02',N'Sensitive Data And PII Identification',N'Define, implement and maintain practical controls for sensitive data and PII identification, proportionate to business need, information classification and security risk.',N'Ensure sensitive data and PII identification is authorized, effective, monitored and supported by evidence.'),
(141,71,N'8.12',N'DLP-01',N'Sensitive Information Identification And Classification',N'Define, implement and maintain practical controls for sensitive information identification and classification, proportionate to business need, information classification and security risk.',N'Ensure sensitive information identification and classification is authorized, effective, monitored and supported by evidence.'),
(142,71,N'8.12',N'DLP-02',N'Email File Transfer Device And Media Channel Monitoring',N'Define, implement and maintain practical controls for email file transfer device and media channel monitoring, proportionate to business need, information classification and security risk.',N'Ensure email file transfer device and media channel monitoring is authorized, effective, monitored and supported by evidence.'),
(143,72,N'8.13',N'BKP-01',N'Set backup requirements and plans',N'Define backup rules and plans for information, software and systems. Set the backup scope, method, frequency, retention, recovery point and restoration steps according to business need and criticality.',N'Make sure every important system has clear, approved and usable backup requirements.'),
(144,72,N'8.13',N'BKP-03',N'Protect backup copies',N'Store backup copies in a secure remote location and protect them from unauthorised access, physical damage and environmental threats. Use encryption when the risk requires it.',N'Keep backup copies confidential, intact and available after a main-site incident.'),
(145,73,N'8.14',N'RED-01',N'Availability And Redundancy Requirements',N'Define, implement and maintain practical controls for availability and redundancy requirements, proportionate to business availability and security risk.',N'Ensure availability and redundancy requirements is effective, monitored and supported by evidence.'),
(146,73,N'8.14',N'RED-02',N'Redundant Architecture And Component Design',N'Define, implement and maintain practical controls for redundant architecture and component design, proportionate to business availability and security risk.',N'Ensure redundant architecture and component design is effective, monitored and supported by evidence.'),
(147,74,N'8.15',N'LOG-01',N'Logging Policy Purpose Scope And Handling',N'Define, implement and maintain practical controls for logging policy purpose scope and handling, proportionate to business availability and security risk.',N'Ensure logging policy purpose scope and handling is effective, monitored and supported by evidence.'),
(148,74,N'8.15',N'LOG-02',N'Event Identity Time Device Network And Protocol Data',N'Define, implement and maintain practical controls for event identity time device network and protocol data, proportionate to business availability and security risk.',N'Ensure event identity time device network and protocol data is effective, monitored and supported by evidence.'),
(149,75,N'8.16',N'MAV-01',N'Monitoring Scope Legal Requirements And Retention',N'Define, implement and maintain practical controls for monitoring scope legal requirements and retention, proportionate to business availability and security risk.',N'Ensure monitoring scope legal requirements and retention is effective, monitored and supported by evidence.'),
(150,75,N'8.16',N'MAV-02',N'Network System Application And Access Monitoring',N'Define, implement and maintain practical controls for network system application and access monitoring, proportionate to business availability and security risk.',N'Ensure network system application and access monitoring is effective, monitored and supported by evidence.'),
(151,76,N'8.17',N'CLK-01',N'Time Synchronization Requirements',N'Define, implement and maintain practical controls for time synchronization requirements, proportionate to business need and technology security risk.',N'Ensure time synchronization requirements is authorized, effective, monitored and supported by evidence.'),
(152,76,N'8.17',N'CLK-02',N'Legal Contractual And Monitoring Time Accuracy',N'Define, implement and maintain practical controls for legal contractual and monitoring time accuracy, proportionate to business need and technology security risk.',N'Ensure legal contractual and monitoring time accuracy is authorized, effective, monitored and supported by evidence.'),
(153,77,N'8.18',N'UTP-01',N'Privileged Utility Inventory And Classification',N'Define, implement and maintain practical controls for privileged utility inventory and classification, proportionate to business need and technology security risk.',N'Ensure privileged utility inventory and classification is authorized, effective, monitored and supported by evidence.'),
(154,77,N'8.18',N'UTP-02',N'Minimum Trusted Authorized Utility Users',N'Define, implement and maintain practical controls for minimum trusted authorized utility users, proportionate to business need and technology security risk.',N'Ensure minimum trusted authorized utility users is authorized, effective, monitored and supported by evidence.'),
(155,78,N'8.19',N'INS-01',N'Operational Software Installation Procedures',N'Define, implement and maintain practical controls for operational software installation procedures, proportionate to business need and technology security risk.',N'Ensure operational software installation procedures is authorized, effective, monitored and supported by evidence.'),
(156,78,N'8.19',N'INS-02',N'Trained Administrator And Management Authorization',N'Define, implement and maintain practical controls for trained administrator and management authorization, proportionate to business need and technology security risk.',N'Ensure trained administrator and management authorization is authorized, effective, monitored and supported by evidence.'),
(157,79,N'8.20',N'NET-01',N'Network Information Classification And Protection',N'Define, implement and maintain practical controls for network information classification and protection, proportionate to business need and technology security risk.',N'Ensure network information classification and protection is authorized, effective, monitored and supported by evidence.'),
(158,79,N'8.20',N'NET-02',N'Network Device Ownership And Procedures',N'Define, implement and maintain practical controls for network device ownership and procedures, proportionate to business need and technology security risk.',N'Ensure network device ownership and procedures is authorized, effective, monitored and supported by evidence.'),
(159,80,N'8.21',N'NWS-01',N'Network Service Security Requirements And Levels',N'Define, implement and maintain practical controls for network service security requirements and levels, proportionate to business need and technology security risk.',N'Ensure network service security requirements and levels is authorized, effective, monitored and supported by evidence.'),
(160,80,N'8.21',N'NWS-02',N'Internal And External Provider Responsibilities',N'Define, implement and maintain practical controls for internal and external provider responsibilities, proportionate to business need and technology security risk.',N'Ensure internal and external provider responsibilities is authorized, effective, monitored and supported by evidence.'),
(161,81,N'8.22',N'SEG-01',N'Network Segregation Policy And Criteria',N'Define, implement and maintain practical controls for network segregation policy and criteria, proportionate to information classification, business need and security risk.',N'Ensure network segregation policy and criteria is authorized, effective, monitored and supported by evidence.'),
(162,81,N'8.22',N'SEG-02',N'Network Domains By Trust Criticality And Sensitivity',N'Define, implement and maintain practical controls for network domains by trust criticality and sensitivity, proportionate to information classification, business need and security risk.',N'Ensure network domains by trust criticality and sensitivity is authorized, effective, monitored and supported by evidence.'),
(163,82,N'8.23',N'WEB-01',N'Safe And Appropriate Web-Use Rules',N'Define, implement and maintain practical controls for safe and appropriate web-use rules, proportionate to information classification, business need and security risk.',N'Ensure safe and appropriate web-use rules is authorized, effective, monitored and supported by evidence.'),
(164,82,N'8.23',N'WEB-02',N'Allowed And Prohibited Website Categories',N'Define, implement and maintain practical controls for allowed and prohibited website categories, proportionate to information classification, business need and security risk.',N'Ensure allowed and prohibited website categories is authorized, effective, monitored and supported by evidence.'),
(165,83,N'8.24',N'CRY-01',N'Cryptography Policy And Approved Use',N'Define, implement and maintain practical controls for cryptography policy and approved use, proportionate to information classification, business need and security risk.',N'Ensure cryptography policy and approved use is authorized, effective, monitored and supported by evidence.'),
(166,83,N'8.24',N'CRY-02',N'Information Classification And Protection Strength',N'Define, implement and maintain practical controls for information classification and protection strength, proportionate to information classification, business need and security risk.',N'Ensure information classification and protection strength is authorized, effective, monitored and supported by evidence.'),
(167,84,N'8.25',N'SDL-01',N'Secure Development Policy And Methodology',N'Define, implement and maintain practical controls for secure development policy and methodology, proportionate to information classification, business need and security risk.',N'Ensure secure development policy and methodology is authorized, effective, monitored and supported by evidence.'),
(168,84,N'8.25',N'SDL-02',N'Development Test And Production Separation',N'Define, implement and maintain practical controls for development test and production separation, proportionate to information classification, business need and security risk.',N'Ensure development test and production separation is authorized, effective, monitored and supported by evidence.'),
(169,85,N'8.26',N'APP-01',N'Application Security Risk Assessment And Approval',N'Define, implement and maintain practical controls for application security risk assessment and approval, proportionate to information classification, business need and security risk.',N'Ensure application security risk assessment and approval is authorized, effective, monitored and supported by evidence.'),
(170,85,N'8.26',N'APP-02',N'Identity Trust Authentication And Access Segregation',N'Define, implement and maintain practical controls for identity trust authentication and access segregation, proportionate to information classification, business need and security risk.',N'Ensure identity trust authentication and access segregation is authorized, effective, monitored and supported by evidence.'),
(171,86,N'8.27',N'ARC-01',N'Secure Engineering Principles And Governance',N'Define, implement and maintain practical controls for secure engineering principles and governance, proportionate to information classification, business need and security risk.',N'Ensure secure engineering principles and governance is authorized, effective, monitored and supported by evidence.'),
(172,86,N'8.27',N'ARC-02',N'Security Across Business Data Application And Technology Layers',N'Define, implement and maintain practical controls for security across business data application and technology layers, proportionate to information classification, business need and security risk.',N'Ensure security across business data application and technology layers is authorized, effective, monitored and supported by evidence.'),
(173,87,N'8.28',N'COD-01',N'Secure Coding Governance And Minimum Baseline',N'Define, implement and maintain practical controls for secure coding governance and minimum baseline, proportionate to information classification, business need and security risk.',N'Ensure secure coding governance and minimum baseline is authorized, effective, monitored and supported by evidence.'),
(174,87,N'8.28',N'COD-02',N'Third-Party And Open-Source Component Coverage',N'Define, implement and maintain practical controls for third-party and open-source component coverage, proportionate to information classification, business need and security risk.',N'Ensure third-party and open-source component coverage is authorized, effective, monitored and supported by evidence.'),
(175,88,N'8.29',N'TST-01',N'Security Testing Process And Requirements',N'Define, implement and maintain practical controls for security testing process and requirements, proportionate to information classification, business need and security risk.',N'Ensure security testing process and requirements is authorized, effective, monitored and supported by evidence.'),
(176,88,N'8.29',N'TST-02',N'New System Upgrade And Version Testing',N'Define, implement and maintain practical controls for new system upgrade and version testing, proportionate to information classification, business need and security risk.',N'Ensure new system upgrade and version testing is authorized, effective, monitored and supported by evidence.'),
(177,89,N'8.30',N'OSD-01',N'Outsourced Development Requirements And Oversight',N'Define, implement and maintain practical controls for outsourced development requirements and oversight, proportionate to information classification, business need and security risk.',N'Ensure outsourced development requirements and oversight is authorized, effective, monitored and supported by evidence.'),
(178,89,N'8.30',N'OSD-02',N'Licensing Code Ownership And Intellectual Property',N'Define, implement and maintain practical controls for licensing code ownership and intellectual property, proportionate to information classification, business need and security risk.',N'Ensure licensing code ownership and intellectual property is authorized, effective, monitored and supported by evidence.'),
(179,90,N'8.31',N'ESEP-01',N'Environment Separation Requirements And Design',N'Define, implement and maintain practical controls for environment separation requirements and design, proportionate to information classification, business need and security risk.',N'Ensure environment separation requirements and design is authorized, effective, monitored and supported by evidence.'),
(180,90,N'8.31',N'ESEP-02',N'Separate Development Test And Production Domains',N'Define, implement and maintain practical controls for separate development test and production domains, proportionate to information classification, business need and security risk.',N'Ensure separate development test and production domains is authorized, effective, monitored and supported by evidence.'),
(181,91,N'8.32',N'CHG-01',N'Formal Change Policy And Life-Cycle Process',N'Define, implement and maintain practical controls for formal change policy and life-cycle process, proportionate to information classification, business need and security risk.',N'Ensure formal change policy and life-cycle process is authorized, effective, monitored and supported by evidence.'),
(182,91,N'8.32',N'CHG-02',N'Change Ownership Responsibilities And Procedures',N'Define, implement and maintain practical controls for change ownership responsibilities and procedures, proportionate to information classification, business need and security risk.',N'Ensure change ownership responsibilities and procedures is authorized, effective, monitored and supported by evidence.'),
(183,92,N'8.33',N'TIN-01',N'Test Information Selection And Reliability',N'Define, implement and maintain practical controls for test information selection and reliability, proportionate to information classification, business need and security risk.',N'Ensure test information selection and reliability is authorized, effective, monitored and supported by evidence.'),
(184,92,N'8.33',N'TIN-02',N'Sensitive And Personal Data Avoidance',N'Define, implement and maintain practical controls for sensitive and personal data avoidance, proportionate to information classification, business need and security risk.',N'Ensure sensitive and personal data avoidance is authorized, effective, monitored and supported by evidence.'),
(185,93,N'8.34',N'ATS-01',N'Audit Testing Planning And Management Agreement',N'Plan audit tests and assurance activities affecting operational systems, and obtain agreement between the tester and appropriate management before work begins.',N'Ensure audit testing is authorized, coordinated and designed to minimize disruption to systems and business processes.'),
(186,93,N'8.34',N'ATS-02',N'System And Data Access Approval',N'Define, approve and document audit requests for access to operational systems and data before access is granted.',N'Ensure audit access is necessary, authorized, limited and accountable.');

CREATE INDEX ix_prac_name ON #prac(practice_name);
CREATE INDEX ix_prac_ref  ON #prac(statement_reference);
CREATE INDEX ix_prac_sid  ON #prac(sheet_statement_id);

-- ---------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------
-- 1. Practice Name must be unique inside the sheet, because the skip test
--    and 054's join both key on it.
IF EXISTS(SELECT 1 FROM #prac GROUP BY practice_name HAVING COUNT(*) > 1)
BEGIN
  SET @missing = STUFF((SELECT DISTINCT N', ' + practice_name FROM #prac
                        GROUP BY practice_name HAVING COUNT(*) > 1
                        FOR XML PATH('')), 1, 2, N'');
  SET @error = CONCAT(N'Duplicate Practice Name(s) in the sheet: ', @missing,
                      N'. Practice Name is the natural key for this load and for 054.');
  THROW 50304, @error, 1;
END

-- 2. The sheet must be internally consistent: one framework_statement_id
--    per control reference and vice versa. A row that breaks this means the
--    export is damaged, and no resolution mode would be trustworthy.
IF EXISTS(SELECT 1 FROM (SELECT DISTINCT sheet_statement_id, statement_reference FROM #prac) d
          GROUP BY d.sheet_statement_id HAVING COUNT(*) > 1)
   OR EXISTS(SELECT 1 FROM (SELECT DISTINCT sheet_statement_id, statement_reference FROM #prac) d
             GROUP BY d.statement_reference HAVING COUNT(*) > 1)
BEGIN
  SET @error = N'The sheet maps a framework_statement_id to more than one control reference, or a control reference to more than one id. Re-export the Practices sheet.';
  THROW 50305, @error, 1;
END

IF @resolve_by_statement_id = 1
BEGIN
  -- 3a. Every id in the sheet must exist.
  IF EXISTS(SELECT 1 FROM #prac p
            WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.framework_statement fs
                             WHERE fs.framework_statement_id = p.sheet_statement_id))
  BEGIN
    SET @missing = STUFF((
      SELECT DISTINCT N', ' + CAST(p.sheet_statement_id AS NVARCHAR(20)) + N' (' + p.statement_reference + N')'
      FROM #prac p
      WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.framework_statement fs
                       WHERE fs.framework_statement_id = p.sheet_statement_id)
      FOR XML PATH('')), 1, 2, N'');
    SET @error = CONCAT(N'framework_statement_id(s) not found: ', @missing,
                        N'. Load the Statements first, or set @resolve_by_statement_id = 0 to match on the control reference instead.');
    -- THROW, not RAISERROR: it reaches the CATCH block below, which rolls
    -- the transaction back. RAISERROR would leave it open.
    THROW 50306, @error, 1;
  END

  -- 3b. The id and the control reference must name the SAME statement.
  --     This is what stops the load from silently attaching Practices to
  --     the wrong controls in an environment whose IDENTITY values differ.
  IF EXISTS(SELECT 1 FROM #prac p
            JOIN GRAC_New.framework_statement fs ON fs.framework_statement_id = p.sheet_statement_id
            WHERE fs.statement_reference <> p.statement_reference)
  BEGIN
    SET @missing = STUFF((
      SELECT DISTINCT N', ' + CAST(p.sheet_statement_id AS NVARCHAR(20))
                    + N': sheet says ' + p.statement_reference
                    + N', database says ' + fs.statement_reference
      FROM #prac p
      JOIN GRAC_New.framework_statement fs ON fs.framework_statement_id = p.sheet_statement_id
      WHERE fs.statement_reference <> p.statement_reference
      FOR XML PATH('')), 1, 2, N'');
    SET @error = CONCAT(N'framework_statement_id does not match the control reference for: ', @missing,
                        N'. The sheet was exported from a different database. Set @resolve_by_statement_id = 0 to match on the control reference, or re-export the sheet from this environment.');
    THROW 50307, @error, 1;
  END
END
ELSE
BEGIN
  -- 3c. Reference mode: every control reference must exist instead.
  IF EXISTS(SELECT 1 FROM #prac p
            WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.framework_statement fs
                             WHERE fs.statement_reference = p.statement_reference))
  BEGIN
    SET @missing = STUFF((
      SELECT DISTINCT N', ' + p.statement_reference FROM #prac p
      WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.framework_statement fs
                       WHERE fs.statement_reference = p.statement_reference)
      FOR XML PATH('')), 1, 2, N'');
    SET @error = CONCAT(N'Framework Statement(s) not found by reference: ', @missing, N'.');
    THROW 50308, @error, 1;
  END
END

-- ---------------------------------------------------------------
-- Resolve each sheet row to one framework_statement, by whichever mode
-- is configured. Everything below reads #stmt and never re-decides.
-- ---------------------------------------------------------------
SELECT p.seq,
       fs.framework_statement_id,
       fs.release_id
INTO #stmt
FROM #prac p
JOIN GRAC_New.framework_statement fs
  ON (@resolve_by_statement_id = 1 AND fs.framework_statement_id = p.sheet_statement_id)
  OR (@resolve_by_statement_id = 0 AND fs.statement_reference    = p.statement_reference);
CREATE UNIQUE CLUSTERED INDEX ux_stmt_seq ON #stmt(seq);

-- 4. Exactly one statement per sheet row -- in reference mode a duplicated
--    statement_reference across releases would otherwise fan the row out.
IF (SELECT COUNT(*) FROM #stmt) <> (SELECT COUNT(*) FROM #prac)
BEGIN
  SET @error = CONCAT(N'Statement resolution produced ', (SELECT COUNT(*) FROM #stmt),
                      N' rows for ', (SELECT COUNT(*) FROM #prac),
                      N' sheet rows. A control reference resolves to more than one Statement -- load one release at a time, or set @resolve_by_statement_id = 1.');
  THROW 50309, @error, 1;
END

-- 5. All resolved statements must sit in one release, otherwise the mapping
--    would silently span two artifact versions.
IF (SELECT COUNT(DISTINCT release_id) FROM #stmt) > 1
BEGIN
  SET @error = N'The referenced Framework Statements belong to more than one Release. Load one release at a time.';
  THROW 50310, @error, 1;
END

SELECT TOP 1 @release_id = release_id FROM #stmt;

-- 6. requirement_name is not unique in the database, only in the sheet. If a
--    name already resolves to two rows the mapping insert below would fan
--    out, so stop instead of guessing which one is meant.
--    The row set being counted is the DATABASE table alone, narrowed with
--    EXISTS rather than joined to #prac. A join would multiply each
--    requirement row by its matching staging rows, and the count would stop
--    meaning "copies of this Practice".
IF EXISTS(SELECT 1
          FROM GRAC_New.requirement r
          WHERE EXISTS(SELECT 1 FROM #prac p WHERE p.practice_name = r.requirement_name)
          GROUP BY r.requirement_name HAVING COUNT(*) > 1)
BEGIN
  SET @missing = STUFF((
    SELECT N', ' + x.requirement_name
    FROM (SELECT r.requirement_name
          FROM GRAC_New.requirement r
          WHERE EXISTS(SELECT 1 FROM #prac p WHERE p.practice_name = r.requirement_name)
          GROUP BY r.requirement_name HAVING COUNT(*) > 1) x
    FOR XML PATH('')), 1, 2, N'');
  SET @error = CONCAT(N'Practice Name(s) already present more than once in GRAC_New.requirement: ', @missing,
                      N'. Resolve the duplicates before loading -- the load and 054 both key on the name.');
  THROW 50311, @error, 1;
END

PRINT CONCAT(N'Statement resolution: ',
             CASE WHEN @resolve_by_statement_id = 1
                  THEN N'by sheet framework_statement_id, verified against the control reference'
                  ELSE N'by control reference (sheet ids ignored)' END,
             N' | Release ', @release_id, N'.');

-- ---------------------------------------------------------------
-- Practice Code allocation
--
-- Same rule and same numbering as cm_manage_repository (migration 050):
-- continue from the highest PR-### already in use. UPDLOCK + HOLDLOCK
-- serialize against a concurrent interactive save inside this
-- transaction, so the block cannot be claimed twice.
-- ---------------------------------------------------------------
SELECT @practice_start = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(requirement_code, 4, 50))), 0) + 1
FROM GRAC_New.requirement WITH (UPDLOCK, HOLDLOCK)
WHERE requirement_code LIKE N'PR-[0-9]%'
  AND TRY_CONVERT(INT, SUBSTRING(requirement_code, 4, 50)) IS NOT NULL;

-- ---------------------------------------------------------------
-- Insert new Practices
-- ---------------------------------------------------------------
DECLARE @new TABLE(requirement_id BIGINT, requirement_code NVARCHAR(100), requirement_name NVARCHAR(300));

;WITH pending AS (
  SELECT p.seq, p.practice_name, p.practice_statement, p.objective,
         ROW_NUMBER() OVER (ORDER BY p.seq) AS rn
  FROM #prac p
  WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.requirement r
                   WHERE r.requirement_name = p.practice_name))
INSERT GRAC_New.requirement
  (requirement_code, requirement_name, requirement_statement, objective, status, entered_by)
OUTPUT inserted.requirement_id, inserted.requirement_code, inserted.requirement_name INTO @new
SELECT CONCAT(N'PR-', FORMAT(@practice_start + pending.rn - 1, N'000')),
       pending.practice_name, pending.practice_statement, pending.objective,
       N'Active', @by
FROM pending;

SET @inserted = @@ROWCOUNT;

-- Defensive: 050 skips a generated number already taken by a legacy
-- hand-typed code. Starting above MAX(PR-###) makes that impossible here,
-- but assert it rather than assume it.
IF EXISTS(SELECT 1 FROM GRAC_New.requirement
          GROUP BY requirement_code HAVING COUNT(*) > 1)
BEGIN
  SET @error = N'Practice Code collision detected after insert. No codes were committed.';
  THROW 50312, @error, 1;
END

-- ---------------------------------------------------------------
-- Optional refresh of Practices that already exist
-- ---------------------------------------------------------------
IF @overwrite_existing = 1
BEGIN
  UPDATE r
    SET r.requirement_statement = p.practice_statement,
        r.objective             = p.objective,
        r.updated_by            = @by,
        r.updated_dt            = SYSUTCDATETIME()
  FROM GRAC_New.requirement r
  JOIN #prac p ON p.practice_name = r.requirement_name
  WHERE r.requirement_statement <> p.practice_statement
     OR ISNULL(r.objective, N'') <> ISNULL(p.objective, N'');
  SET @updated = @@ROWCOUNT;
END

-- ---------------------------------------------------------------
-- Practice -> Statement mapping
--
-- Written for every sheet row whose Practice resolves, not only for the
-- rows inserted above: a Practice that already existed may still be
-- missing its link to this release's Statement.
-- ---------------------------------------------------------------
DECLARE @newmap TABLE(statement_requirement_map_id BIGINT, framework_statement_id BIGINT, requirement_id BIGINT);

INSERT GRAC_New.framework_statement_requirement_map
  (framework_statement_id, requirement_id, status, entered_by)
OUTPUT inserted.statement_requirement_map_id, inserted.framework_statement_id, inserted.requirement_id INTO @newmap
SELECT DISTINCT s.framework_statement_id, r.requirement_id, N'Active', @by
FROM #prac p
JOIN #stmt s              ON s.seq = p.seq
JOIN GRAC_New.requirement r ON r.requirement_name = p.practice_name
WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.framework_statement_requirement_map m
                 WHERE m.framework_statement_id = s.framework_statement_id
                   AND m.requirement_id         = r.requirement_id);

SET @mapped = @@ROWCOUNT;

-- Re-activate any mapping that this load covers but that a previous
-- rollback retired, so a rollback-then-reload round trip is clean.
UPDATE m
   SET m.status     = N'Active',
       m.updated_by = @by,
       m.updated_dt = SYSUTCDATETIME()
FROM GRAC_New.framework_statement_requirement_map m
JOIN #stmt s              ON s.framework_statement_id = m.framework_statement_id
JOIN #prac p              ON p.seq                    = s.seq
JOIN GRAC_New.requirement r ON r.requirement_id       = m.requirement_id
                           AND r.requirement_name     = p.practice_name
WHERE m.status <> N'Active';

-- ---------------------------------------------------------------
-- Audit trail: Practices
--
-- Mirrors the three-table shape cm_manage_repository writes, so these
-- rows render on the Audit Trace screen like any other Add:
--   audit_trace_event  -> one event per Practice
--   audit_trace_detail -> field-level values for that event
--   audit_trace        -> the flat row, linked by audit_event_id
-- action_type is 'Add' to stay inside the existing vocabulary.
-- ---------------------------------------------------------------
DECLARE @events TABLE(audit_event_id BIGINT, entity_id BIGINT);

INSERT GRAC_New.audit_trace_event
  (entity_type,entity_id,action_type,table_name,record_reference,remarks,before_json,after_json,status,entered_by)
OUTPUT inserted.audit_event_id, inserted.entity_id INTO @events
SELECT N'requirements', n.requirement_id, N'Add',
       N'GRAC_New.requirement',
       CONCAT(n.requirement_code, N' - ', n.requirement_name),
       N'Bulk load: migration 053, Import ISO 27001 Sample data v1.0.xlsx, sheet All Practices.',
       NULL,
       (SELECT r.requirement_code code, r.requirement_name name,
               r.requirement_statement statement, r.objective, r.status
        FROM GRAC_New.requirement r
        WHERE r.requirement_id = n.requirement_id
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
       N'Active', @by
FROM @new n;

INSERT GRAC_New.audit_trace_detail(audit_event_id,field_name,old_value,new_value,entered_by)
SELECT e.audit_event_id, d.field_name, NULL, d.new_value, @by
FROM @events e
JOIN GRAC_New.requirement r ON r.requirement_id = e.entity_id
CROSS APPLY (VALUES
  (N'Practice Code',      r.requirement_code),
  (N'Practice Name',      r.requirement_name),
  (N'Practice Statement', r.requirement_statement),
  (N'Objective',          r.objective),
  (N'Status',             r.status)
) AS d(field_name, new_value)
WHERE d.new_value IS NOT NULL;

INSERT GRAC_New.audit_trace
  (audit_event_id,entity_type,entity_id,action_type,table_name,record_reference,remarks,after_json,status,entered_by)
SELECT ev.audit_event_id, ev.entity_type, ev.entity_id, ev.action_type, ev.table_name,
       ev.record_reference, ev.remarks, ev.after_json, N'Active', @by
FROM GRAC_New.audit_trace_event ev
JOIN @events e ON e.audit_event_id = ev.audit_event_id;

-- ---------------------------------------------------------------
-- Audit trail: Practice -> Statement mappings
--
-- entity_type is the cm_entity_master entity_code for the
-- 'Practices - Statement Mapping' screen, so these rows filter
-- alongside interactive saves of the same mapping.
-- ---------------------------------------------------------------
DECLARE @mapevents TABLE(audit_event_id BIGINT, entity_id BIGINT);

INSERT GRAC_New.audit_trace_event
  (entity_type,entity_id,action_type,table_name,record_reference,remarks,before_json,after_json,status,entered_by)
OUTPUT inserted.audit_event_id, inserted.entity_id INTO @mapevents
SELECT N'source-control-mappings', nm.statement_requirement_map_id, N'Add',
       N'GRAC_New.framework_statement_requirement_map',
       CONCAT(fs.statement_reference, N' -> ', r.requirement_code),
       N'Bulk load: migration 053, Import ISO 27001 Sample data v1.0.xlsx, sheet All Practices.',
       NULL,
       (SELECT fs.framework_statement_id frameworkStatementId,
               fs.statement_reference statementReference,
               r.requirement_id requirementId, r.requirement_code code,
               r.requirement_name name, N'Active' status
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
       N'Active', @by
FROM @newmap nm
JOIN GRAC_New.framework_statement fs ON fs.framework_statement_id = nm.framework_statement_id
JOIN GRAC_New.requirement r          ON r.requirement_id          = nm.requirement_id;

INSERT GRAC_New.audit_trace_detail(audit_event_id,field_name,old_value,new_value,entered_by)
SELECT e.audit_event_id, d.field_name, NULL, d.new_value, @by
FROM @mapevents e
JOIN GRAC_New.framework_statement_requirement_map m ON m.statement_requirement_map_id = e.entity_id
JOIN GRAC_New.framework_statement fs ON fs.framework_statement_id = m.framework_statement_id
JOIN GRAC_New.requirement r          ON r.requirement_id          = m.requirement_id
CROSS APPLY (VALUES
  (N'Framework Statement', fs.statement_reference),
  (N'Practice',            CONCAT(r.requirement_code, N' - ', r.requirement_name)),
  (N'Status',              m.status)
) AS d(field_name, new_value)
WHERE d.new_value IS NOT NULL;

INSERT GRAC_New.audit_trace
  (audit_event_id,entity_type,entity_id,action_type,table_name,record_reference,remarks,after_json,status,entered_by)
SELECT ev.audit_event_id, ev.entity_type, ev.entity_id, ev.action_type, ev.table_name,
       ev.record_reference, ev.remarks, ev.after_json, N'Active', @by
FROM GRAC_New.audit_trace_event ev
JOIN @mapevents e ON e.audit_event_id = ev.audit_event_id;

COMMIT TRANSACTION;

PRINT CONCAT(N'053 complete. Release ', @release_id,
             N' | Practices inserted ', @inserted,
             N' | refreshed ', @updated,
             N' | skipped ', 186 - @inserted - @updated, N' already present',
             N' | Statement mappings created ', @mapped, N'.');
PRINT N'Next: run 054_iso_27001_obligations.sql.';
END TRY
BEGIN CATCH
  IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
  THROW;
END CATCH
GO

-- ---------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------
-- Practices per Annex A clause. Expect 93 statements carrying 186
-- Practices in total.
SELECT LEFT(fs.statement_reference, CHARINDEX(N'.', fs.statement_reference) - 1) AS clause,
       COUNT(DISTINCT fs.framework_statement_id) AS statements,
       COUNT(DISTINCT m.requirement_id)          AS practices
FROM GRAC_New.framework_statement_requirement_map m
JOIN GRAC_New.framework_statement fs ON fs.framework_statement_id = m.framework_statement_id
WHERE m.status = N'Active' AND fs.status = N'Active'
GROUP BY LEFT(fs.statement_reference, CHARINDEX(N'.', fs.statement_reference) - 1)
ORDER BY clause;
GO

-- Spot-check the mapping the way the Practices - Statement Mapping screen
-- shows it. Confirm a handful of rows against the spreadsheet before
-- running 054.
SELECT TOP 20 fs.framework_statement_id, fs.statement_reference, fs.statement_title,
       r.requirement_code, r.requirement_name
FROM GRAC_New.framework_statement_requirement_map m
JOIN GRAC_New.framework_statement fs ON fs.framework_statement_id = m.framework_statement_id
JOIN GRAC_New.requirement r          ON r.requirement_id          = m.requirement_id
WHERE m.status = N'Active'
ORDER BY fs.framework_statement_id, r.requirement_code;
GO

-- Any Statement that ended up with no Practice at all.
SELECT fs.framework_statement_id, fs.statement_reference, fs.statement_title
FROM GRAC_New.framework_statement fs
WHERE fs.status = N'Active'
  AND NOT EXISTS(SELECT 1 FROM GRAC_New.framework_statement_requirement_map m
                 WHERE m.framework_statement_id = fs.framework_statement_id
                   AND m.status = N'Active')
ORDER BY fs.statement_reference;
GO
