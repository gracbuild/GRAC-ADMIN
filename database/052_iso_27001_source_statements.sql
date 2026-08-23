/* =====================================================================
   052_iso_27001_source_statements.sql

   Bulk load of ISO/IEC 27001:2022 Annex A source statements into
   GRAC_New.framework_statement.

   Source        : ISO 27001 Source Statements v1.0.xlsx (sheet 'Source Statements')
   Statements    : 93
   Prerequisites : 001_control_management_schema.sql, and the Source
                   Structure nodes referenced below must already exist.
   Rerunnable    : yes. Existing (release_id, statement_reference) rows are
                   skipped, or refreshed when @overwrite_existing = 1.
   Rollback      : 052_iso_27001_source_statements_rollback.sql

   FILE ENCODING
   -------------
   Saved as UTF-8 with BOM. Several statements contain U+2019 (right
   single quotation mark, as in "organization’s"). Open in SSMS normally,
   or run with: sqlcmd -f 65001 -i 052_iso_27001_source_statements.sql
   All literals are N'' prefixed and embedded apostrophes are doubled.

   CONTROL NUMBER CORRECTIONS
   --------------------------
   The spreadsheet stores Control No as a number, so Excel dropped the
   trailing zero on seven references and collided them with existing ones
   (5.10 became 5.1, and so on). That would violate
   uq_cm_framework_statement UNIQUE(release_id, statement_reference).
   Each was rebuilt from its ordinal position within the clause and
   cross-checked against the ISO/IEC 27001:2022 Annex A control counts
   (5.x = 37, 6.x = 8, 7.x = 14, 8.x = 34, total 93 -- all matched).

   Sheet value  ->  Loaded as   Title
   5.1          ->  5.10        Acceptable use of information and other associated assets
   5.2          ->  5.20        Addressing information security within supplier agreements
   5.3          ->  5.30        ICT readiness for business continuity
   7.1          ->  7.10        Storage media
   8.1          ->  8.10        Information deletion
   8.2          ->  8.20        Networks security
   8.3          ->  8.30        Outsourced development

   MAKER-CHECKER
   -------------
   'framework-statements' is registered with is_maker_checker = 1, so
   interactive saves route through change_management. This script is a
   controlled bulk load and writes directly, exactly as the existing
   sample-data scripts do. An audit_trace row is written per inserted
   statement so the load is visible in the trail.

   NOT SUPPLIED BY THE SHEET
   -------------------------
   statement_type : left NULL. The field was removed from the Statement
                    form; the column remains for historic values only.
   classification : the sheet carries none, so the script ensures one
                    default classification exists for the release and
                    assigns it. Change @classification_* below, or set
                    @assign_classification = 0 to leave it NULL.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

BEGIN TRY
BEGIN TRANSACTION;

-- ---------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------
DECLARE @by                    NVARCHAR(100) = N'anoop.ps@soffit.in';
DECLARE @overwrite_existing    BIT           = 0;   -- 1 = refresh title/text/remarks on rerun
DECLARE @assign_classification BIT           = 1;   -- 0 = leave classification_id NULL
DECLARE @classification_code   NVARCHAR(80)  = N'ANNEX-A';
DECLARE @classification_name   NVARCHAR(200) = N'Annex A Control';
DECLARE @classification_scheme NVARCHAR(200) = N'ISO/IEC 27001:2022 Annex A';

DECLARE @release_id BIGINT, @classification_id BIGINT;
DECLARE @inserted INT = 0, @updated INT = 0;
DECLARE @missing NVARCHAR(1000), @error NVARCHAR(2000);

-- ---------------------------------------------------------------
-- Staging
-- ---------------------------------------------------------------
IF OBJECT_ID('tempdb..#src') IS NOT NULL DROP TABLE #src;
CREATE TABLE #src(
  seq                 INT            NOT NULL,
  structure_node_id   BIGINT         NOT NULL,
  statement_reference NVARCHAR(160)  NOT NULL,
  statement_title     NVARCHAR(500)  NULL,
  statement_text      NVARCHAR(MAX)  NOT NULL,
  remarks             NVARCHAR(MAX)  NULL);

INSERT #src(seq,structure_node_id,statement_reference,statement_title,statement_text,remarks) VALUES
(1,2,N'5.1',N'Policies for information security',N'Information security policy and topic-specific policies should be defined, approved by management, published, communicated to and acknowledged by relevant personnel and relevant interested parties, and reviewed at planned intervals and if significant changes occur.',N'To ensure continuing suitability, adequacy, effectiveness of management direction and support for information security in accordance with business, legal, statutory, regulatory and contractual requirements.'),
(2,2,N'5.2',N'Information security roles and responsibilities',N'Information security roles and responsibilities should be defined and allocated according to the organization needs.',N'To establish a defined, approved and understood structure for the implementation, operation and management of information security within the organization.'),
(3,2,N'5.3',N'Segregation of duties',N'Conflicting duties and conflicting areas of responsibility should be segregated.',N'To reduce the risk of fraud, error and bypassing of information security controls.'),
(4,2,N'5.4',N'Management responsibilities',N'Management should require all personnel to apply information security in accordance with the established information security policy, topic-specific policies and procedures of the organization.',N'To ensure management understand their role in information security and undertake actions aiming to ensure all personnel are aware of and fulfil their information security responsibilities.'),
(5,2,N'5.5',N'Contact with authorities',N'The organization should establish and maintain contact with relevant authorities.',N'To ensure appropriate flow of information takes place with respect to information security between the organization and relevant legal, regulatory and supervisory authorities.'),
(6,2,N'5.6',N'Contact with special interest groups',N'The organization should establish and maintain contact with special interest groups or other specialist security forums and professional associations.',N'To ensure appropriate flow of information takes place with respect to information security.'),
(7,2,N'5.7',N'Threat intelligence',N'Information relating to information security threats should be collected and analysed to produce threat intelligence.',N'To provide awareness of the organization’s threat environment so that the appropriate mitigation actions can be taken.'),
(8,2,N'5.8',N'Information security in project management',N'Information security should be integrated into project management.',N'To ensure information security risks related to projects and deliverables are effectively addressed in project management throughout the project life cycle.'),
(9,2,N'5.9',N'Inventory of information and other associated assets',N'An inventory of information and other associated assets, including owners, should be developed and maintained.',N'To identify the organization’s information and other associated assets in order to preserve their information security and assign appropriate ownership.'),
(10,2,N'5.10',N'Acceptable use of information and other associated assets',N'Rules for the acceptable use and procedures for handling information and other associated assets should be identified, documented and implemented.',N'To ensure information and other associated assets are appropriately protected, used and handled.'),
(11,2,N'5.11',N'Return of assets',N'Personnel and other interested parties as appropriate should return all the organization’s assets in their possession upon change or termination of their employment, contract or agreement.',N'To protect the organization’s assets as part of the process of changing or terminating employment, contract or agreement.'),
(12,2,N'5.12',N'Classification of information',N'Information should be classified according to the information security needs of the organization based on confidentiality, integrity, availability and relevant interested party requirements.',N'To ensure identification and understanding of protection needs of information in accordance with its importance to the organization.'),
(13,2,N'5.13',N'Labelling of information',N'An appropriate set of procedures for information labelling should be developed and implemented in accordance with the information classification scheme adopted by the organization.',N'To facilitate the communication of classification of information and support automation of information processing and management.'),
(14,2,N'5.14',N'Information transfer',N'Information transfer rules, procedures, or agreements should be in place for all types of transfer facilities within the organization and between the organization and other parties.',N'To maintain the security of information transferred within an organization and with any external interested party.'),
(15,2,N'5.15',N'Access control',N'Rules to control physical and logical access to information and other associated assets should be established and implemented based on business and information security requirements.',N'To ensure authorized access and to prevent unauthorized access to information and other associated assets.'),
(16,2,N'5.16',N'Identity management',N'The full life cycle of identities should be managed.',N'To allow for the unique identification of individuals and systems accessing the organization’s information and other associated assets and to enable appropriate assignment of access rights.'),
(17,2,N'5.17',N'Authentication information',N'Allocation and management of authentication information should be controlled by a management process, including advising personnel on the appropriate handling of authentication information.',N'To ensure proper entity authentication and prevent failures of authentication processes.'),
(18,2,N'5.18',N'Access rights',N'Access rights to information and other associated assets should be provisioned, reviewed, modified and removed in accordance with the organization’s topic-specific policy on and rules for access control.',N'To ensure access to information and other associated assets is defined and authorized according to the business requirements.'),
(19,2,N'5.19',N'Information security in supplier relationships',N'Processes and procedures should be defined and implemented to manage the information security risks associated with the use of supplier’s products or services.',N'To maintain an agreed level of information security in supplier relationships.'),
(20,2,N'5.20',N'Addressing information security within supplier agreements',N'Relevant information security requirements should be established and agreed with each supplier based on the type of supplier relationship.',N'To maintain an agreed level of information security in supplier relationships.'),
(21,2,N'5.21',N'Managing information security in the ICT supply chain',N'Processes and procedures should be defined and implemented to manage the information security risks associated with the ICT products and services supply chain.',N'To maintain an agreed level of information security in supplier relationships.'),
(22,2,N'5.22',N'Monitoring, review and change management of supplier services',N'The organization should regularly monitor, review, evaluate and manage change in supplier information security practices and service delivery.',N'To maintain an agreed level of information security and service delivery in line with supplier agreements.'),
(23,2,N'5.23',N'Information security for use of cloud services',N'Processes for acquisition, use, management and exit from cloud services should be established in accordance with the organization’s information security requirements.',N'To specify and manage information security for the use of cloud services.'),
(24,2,N'5.24',N'Information security incident management planning and preparation',N'The organization should plan and prepare for managing information security incidents by defining, establishing and communicating information security incident management processes, roles and responsibilities.',N'To ensure quick, effective, consistent and orderly response to information security incidents, including communication on information security events.'),
(25,2,N'5.25',N'Assessment and decision on information security events',N'The organization should assess information security events and decide if they are to be categorized as information security incidents.',N'To ensure effective categorization and prioritization of information security events.'),
(26,2,N'5.26',N'Response to information security incidents',N'Information security incidents should be responded to in accordance with the documented procedures.',N'To ensure efficient and effective response to information security incidents.'),
(27,2,N'5.27',N'Learning from information security incidents',N'Knowledge gained from information security incidents should be used to strengthen and improve the information security controls.',N'To reduce the likelihood or consequences of future incidents.'),
(28,2,N'5.28',N'Collection of evidence',N'The organization should establish and implement procedures for the identification, collection, acquisition and preservation of evidence related to information security events.',N'To ensure a consistent and effective management of evidence related to information security incidents for the purposes of disciplinary and legal actions.'),
(29,2,N'5.29',N'Information security during disruption',N'The organization should plan how to maintain information security at an appropriate level during disruption.',N'To protect information and other associated assets during disruption.'),
(30,2,N'5.30',N'ICT readiness for business continuity',N'ICT readiness should be planned, implemented, maintained and tested based on business continuity objectives and ICT continuity requirements.',N'To ensure the availability of the organization’s information and other associated assets during disruption.'),
(31,2,N'5.31',N'Legal, statutory, regulatory and contractual requirements',N'Legal, statutory, regulatory and contractual requirements relevant to information security and the organization’s approach to meet these requirements should be identified, documented and kept up to date.',N'To ensure compliance with legal, statutory, regulatory and contractual requirements related to information security.'),
(32,2,N'5.32',N'Intellectual property rights',N'The organization should implement appropriate procedures to protect intellectual property rights.',N'To ensure compliance with legal, statutory, regulatory and contractual requirements related to intellectual property rights and use of proprietary products.'),
(33,2,N'5.33',N'Protection of records',N'Records should be protected from loss, destruction, falsification, unauthorized access and unauthorized release.',N'To ensure compliance with legal, statutory, regulatory and contractual requirements, as well as community or societal expectations related to the protection and availability of records.'),
(34,2,N'5.34',N'Privacy and protection of PII',N'The organization should identify and meet the requirements regarding the preservation of privacy and protection of PII according to applicable laws and regulations and contractual requirements.',N'To ensure compliance with legal, statutory, regulatory and contractual requirements related to the information security aspects of the protection of PII.'),
(35,2,N'5.35',N'Independent review of information security',N'The organization’s approach to managing information security and its implementation including people, processes and technologies should be reviewed independently at planned intervals, or when significant changes occur.',N'To ensure the continuing suitability, adequacy and effectiveness of the organization’s approach to managing information security.'),
(36,2,N'5.36',N'Compliance with policies, rules and standards for information security',N'Compliance with the organization’s information security policy, topic-specific policies, rules and standards should be regularly reviewed.',N'To ensure that information security is implemented and operated in accordance with the organization’s information security policy, topic-specific policies, rules and standards.'),
(37,2,N'5.37',N'Documented operating procedures',N'Operating procedures for information processing facilities should be documented and made available to personnel who need them.',N'To ensure the correct and secure operation of information processing facilities.'),
(38,5,N'6.1',N'Screening',N'Background verification checks on all candidates to become personnel should be carried out prior to joining the organization and on an ongoing basis taking into consideration applicable laws, regulations and ethics and be proportional to the business requirements, the classification of the information to be accessed and the perceived risks.',N'To ensure all personnel are eligible and suitable for the roles for which they are considered and remain eligible and suitable during their employment.'),
(39,5,N'6.2',N'Terms and conditions of employment',N'The employment contractual agreements should state the personnel’s and the organization’s responsibilities for information security.',N'To ensure personnel understand their information security responsibilities for the roles for which they are considered.'),
(40,5,N'6.3',N'Information security awareness, education and training',N'Personnel of the organization and relevant interested parties should receive appropriate information security awareness, education and training and regular updates of the organization''s information security policy, topic-specific policies and procedures, as relevant for their job function.',N'To ensure personnel and relevant interested parties are aware of and fulfil their information security responsibilities.'),
(41,5,N'6.4',N'Disciplinary process',N'A disciplinary process should be formalized and communicated to take actions against personnel and other relevant interested parties who have committed an information security policy violation.',N'To ensure personnel and other relevant interested parties understand the consequences of information security policy violation, to deter and appropriately deal with personnel and other relevant interested parties who committed the violation.'),
(42,5,N'6.5',N'Responsibilities after termination or change of employment',N'Information security responsibilities and duties that remain valid after termination or change of employment should be defined, enforced and communicated to relevant personnel and other interested parties.',N'To protect the organization’s interests as part of the process of changing or terminating employment or contracts.'),
(43,5,N'6.6',N'Confidentiality or non-disclosure agreements',N'Confidentiality or non-disclosure agreements reflecting the organization’s needs for the protection of information should be identified, documented, regularly reviewed and signed by personnel and other relevant interested parties.',N'To maintain confidentiality of information accessible by personnel or external parties.'),
(44,5,N'6.7',N'Remote working',N'Security measures should be implemented when personnel are working remotely to protect information accessed, processed or stored outside the organization’s premises.',N'To ensure the security of information when personnel are working remotely.'),
(45,5,N'6.8',N'Information security event reporting',N'The organization should provide a mechanism for personnel to report observed or suspected information security events through appropriate channels in a timely manner.',N'To support timely, consistent and effective reporting of information security events that can be identified by personnel.'),
(46,6,N'7.1',N'Physical security perimeters',N'Security perimeters should be defined and used to protect areas that contain information and other associated assets.',N'To prevent unauthorized physical access, damage and interference to the organization’s information and other associated assets.'),
(47,6,N'7.2',N'Physical entry',N'Secure areas should be protected by appropriate entry controls and access points.',N'To ensure only authorized physical access to the organization’s information and other associated assets occurs.'),
(48,6,N'7.3',N'Securing offices, rooms and facilities',N'Physical security for offices, rooms and facilities should be designed and implemented.',N'To prevent unauthorized physical access, damage and interference to the organization’s information and other associated assets in offices, rooms and facilities.'),
(49,6,N'7.4',N'Physical security monitoring',N'Premises should be continuously monitored for unauthorized physical access.',N'To detect and deter unauthorized physical access.'),
(50,6,N'7.5',N'Protecting against physical and environmental threats',N'Protection against physical and environmental threats, such as natural disasters and other intentional or unintentional physical threats to infrastructure should be designed and implemented.',N'To prevent or reduce the consequences of events originating from physical and environmental threats.'),
(51,6,N'7.6',N'Working in secure areas',N'Security measures for working in secure areas should be designed and implemented.',N'To protect information and other associated assets in secure areas from damage and unauthorized interference by personnel working in these areas.'),
(52,6,N'7.7',N'Clear desk and clear screen',N'Clear desk rules for papers and removable storage media and clear screen rules for information processing facilities should be defined and appropriately enforced.',N'To reduce the risks of unauthorized access, loss of and damage to information on desks, screens and in other accessible locations during and outside normal working hours.'),
(53,6,N'7.8',N'Equipment siting and protection',N'Equipment should be sited securely and protected.',N'To reduce the risks from physical and environmental threats, and from unauthorized access and damage.'),
(54,6,N'7.9',N'Security of assets off-premises',N'Off-site assets should be protected.',N'To prevent loss, damage, theft or compromise of off-site devices and interruption to the organization’s operations.'),
(55,6,N'7.10',N'Storage media',N'Storage media should be managed through their life cycle of acquisition, use, transportation and disposal in accordance with the organization’s classification scheme and handling requirements.',N'To ensure only authorized disclosure, modification, removal or destruction of information on storage media.'),
(56,6,N'7.11',N'Supporting utilities',N'Information processing facilities should be protected from power failures and other disruptions caused by failures in supporting utilities.',N'To prevent loss, damage or compromise of information and other associated assets, or interruption to the organization’s operations due to failure and disruption of supporting utilities.'),
(57,6,N'7.12',N'Cabling security',N'Cables carrying power, data or supporting information services should be protected from interception, interference or damage.',N'To prevent loss, damage, theft or compromise of information and other associated assets and interruption to the organization’s operations related to power and communications cabling.'),
(58,6,N'7.13',N'Equipment maintenance',N'Equipment should be maintained correctly to ensure availability, integrity and confidentiality of information.',N'To prevent loss, damage, theft or compromise of information and other associated assets and interruption to the organization’s operations caused by lack of maintenance.'),
(59,6,N'7.14',N'Secure disposal or re-use of equipment',N'Items of equipment containing storage media should be verified to ensure that any sensitive data and licensed software has been removed or securely overwritten prior to disposal or re-use.',N'To prevent leakage of information from equipment to be disposed or re-used.'),
(60,8,N'8.1',N'User endpoint devices',N'Information stored on, processed by or accessible via user endpoint devices should be protected.',N'To protect information against the risks introduced by using user endpoint devices.'),
(61,8,N'8.2',N'Privileged access rights',N'The allocation and use of privileged access rights should be restricted and managed.',N'To ensure only authorized users, software components and services are provided with privileged access rights.'),
(62,8,N'8.3',N'Information access restriction',N'Access to information and other associated assets should be restricted in accordance with the established topic-specific policy on access control.',N'To ensure only authorized access and to prevent unauthorized access to information and other associated assets.'),
(63,8,N'8.4',N'Access to source code',N'Read and write access to source code, development tools and software libraries should be appropriately managed.',N'To prevent the introduction of unauthorized functionality, avoid unintentional or malicious changes and to maintain the confidentiality of valuable intellectual property.'),
(64,8,N'8.5',N'Secure authentication',N'Secure authentication technologies and procedures should be implemented based on information access restrictions and the topic-specific policy on access control.',N'To ensure a user or an entity is securely authenticated, when access to systems, applications and services is granted.'),
(65,8,N'8.6',N'Capacity management',N'The use of resources should be monitored and adjusted in line with current and expected capacity requirements.',N'To ensure the required capacity of information processing facilities, human resources, offices and other facilities.'),
(66,8,N'8.7',N'Protection against malware',N'Protection against malware should be implemented and supported by appropriate user awareness.',N'To ensure information and other associated assets are protected against malware.'),
(67,8,N'8.8',N'Management of technical vulnerabilities',N'Information about technical vulnerabilities of information systems in use should be obtained, the organization’s exposure to such vulnerabilities should be evaluated and appropriate measures should be taken.',N'To prevent exploitation of technical vulnerabilities.'),
(68,8,N'8.9',N'Configuration management',N'Configurations, including security configurations, of hardware, software, services and networks should be established, documented, implemented, monitored and reviewed.',N'To ensure hardware, software, services and networks function correctly with required security settings, and configuration is not altered by unauthorized or incorrect changes.'),
(69,8,N'8.10',N'Information deletion',N'Information stored in information systems, devices or in any other storage media should be deleted when no longer required.',N'To prevent unnecessary exposure of sensitive information and to comply with legal, statutory, regulatory and contractual requirements for information deletion.'),
(70,8,N'8.11',N'Data masking',N'Data masking should be used in accordance with the organization’s topic-specific policy on access control and other related topic-specific policies, and business requirements, taking applicable legislation into consideration.',N'To limit the exposure of sensitive data including PII, and to comply with legal, statutory, regulatory and contractual requirements.'),
(71,8,N'8.12',N'Data leakage prevention',N'Data leakage prevention measures should be applied to systems, networks and any other devices that process, store or transmit sensitive information.',N'To detect and prevent the unauthorized disclosure and extraction of information by individuals or systems.'),
(72,8,N'8.13',N'Information backup',N'Backup copies of information, software and systems should be maintained and regularly tested in accordance with the agreed topic-specific policy on backup.',N'To enable recovery from loss of data or systems.'),
(73,8,N'8.14',N'Redundancy of information processing facilities',N'Information processing facilities should be implemented with redundancy sufficient to meet availability requirements.',N'To ensure the continuous operation of information processing facilities.'),
(74,8,N'8.15',N'Logging',N'Logs that record activities, exceptions, faults and other relevant events should be produced, stored, protected and analysed.',N'To record events, generate evidence, ensure the integrity of log information, prevent against unauthorized access, identify information security events that can lead to an information security incident and to support investigations.'),
(75,8,N'8.16',N'Monitoring activities',N'Networks, systems and applications should be monitored for anomalous behaviour and appropriate actions taken to evaluate potential information security incidents.',N'To detect anomalous behaviour and potential information security incidents.'),
(76,8,N'8.17',N'Clock synchronization',N'The clocks of information processing systems used by the organization should be synchronized to approved time sources.',N'To enable the correlation and analysis of security-related events and other recorded data, and to support investigations into information security incidents.'),
(77,8,N'8.18',N'Use of privileged utility programs',N'The use of utility programs that can be capable of overriding system and application controls should be restricted and tightly controlled.',N'To ensure the use of utility programs does not harm system and application controls for information security.'),
(78,8,N'8.19',N'Installation of software on operational systems',N'Procedures and measures should be implemented to securely manage software installation on operational systems.',N'To ensure the integrity of operational systems and prevent exploitation of technical vulnerabilities.'),
(79,8,N'8.20',N'Networks security',N'Networks and network devices should be secured, managed and controlled to protect information in systems and applications.',N'To protect information in networks and its supporting information processing facilities from compromise via the network.'),
(80,8,N'8.21',N'Security of network services',N'Security mechanisms, service levels and service requirements of network services should be identified, implemented and monitored.',N'To ensure security in the use of network services.'),
(81,8,N'8.22',N'Segregation of networks',N'Groups of information services, users and information systems should be segregated in the organization’s networks.',N'To split the network in security boundaries and to control traffic between them based on business needs.'),
(82,8,N'8.23',N'Web filtering',N'Access to external websites should be managed to reduce exposure to malicious content.',N'To protect systems from being compromised by malware and to prevent access to unauthorized web resources.'),
(83,8,N'8.24',N'Use of cryptography',N'Rules for the effective use of cryptography, including cryptographic key management, should be defined and implemented.',N'To ensure proper and effective use of cryptography to protect the confidentiality, authenticity or integrity of information according to business and information security requirements, and taking into consideration legal, statutory, regulatory and contractual requirements related to cryptography.'),
(84,8,N'8.25',N'Secure development life cycle',N'Rules for the secure development of software and systems should be established and applied.',N'To ensure information security is designed and implemented within the secure development life cycle of software and systems.'),
(85,8,N'8.26',N'Application security requirements',N'Information security requirements should be identified, specified and approved when developing or acquiring applications.',N'To ensure all information security requirements are identified and addressed when developing or acquiring applications.'),
(86,8,N'8.27',N'Secure system architecture and engineering principles',N'Principles for engineering secure systems should be established, documented, maintained and applied to any information system development activities.',N'To ensure information systems are securely designed, implemented and operated within the development life cycle.'),
(87,8,N'8.28',N'Secure coding',N'Secure coding principles should be applied to software development.',N'To ensure software is written securely thereby reducing the number of potential information security vulnerabilities in the software.'),
(88,8,N'8.29',N'Security testing in development and acceptance',N'Security testing processes should be defined and implemented in the development life cycle.',N'To validate if information security requirements are met when applications or code are deployed to the production environment.'),
(89,8,N'8.30',N'Outsourced development',N'The organization should direct, monitor and review the activities related to outsourced system development.',N'To ensure information security measures required by the organization are implemented in outsourced system development.'),
(90,8,N'8.31',N'Separation of development, test and production environments',N'Development, testing and production environments should be separated and secured.',N'To protect the production environment and data from compromise by development and test activities.'),
(91,8,N'8.32',N'Change management',N'Changes to information processing facilities and information systems should be subject to change management procedures.',N'To preserve information security when executing changes.'),
(92,8,N'8.33',N'Test information',N'Test information should be appropriately selected, protected and managed.',N'To ensure relevance of testing and protection of operational information used for testing.'),
(93,8,N'8.34',N'Protection of information systems during audit testing',N'Audit tests and other assurance activities involving assessment of operational systems should be planned and agreed between the tester and appropriate management.',N'To minimize the impact of audit and other assurance activities on operational systems and business processes.');

-- ---------------------------------------------------------------
-- Validation: every node must exist, and all must share one release
-- ---------------------------------------------------------------
IF EXISTS(SELECT 1 FROM #src s
          WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.source_structure_node n
                           WHERE n.structure_node_id = s.structure_node_id))
BEGIN
  SET @missing = STUFF((
    SELECT DISTINCT N', ' + CAST(s.structure_node_id AS NVARCHAR(20))
    FROM #src s
    WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.source_structure_node n
                     WHERE n.structure_node_id = s.structure_node_id)
    FOR XML PATH('')), 1, 2, N'');
  SET @error = CONCAT(N'Source Structure Node(s) not found: ', @missing,
                      N'. Load the Source Structure sheet first.');
  -- THROW, not RAISERROR: it reaches the CATCH block below, which rolls
  -- the transaction back. RAISERROR would leave it open.
  THROW 50201, @error, 1;
END

IF (SELECT COUNT(DISTINCT n.release_id)
    FROM #src s JOIN GRAC_New.source_structure_node n ON n.structure_node_id = s.structure_node_id) > 1
BEGIN
  SET @error = N'The referenced Source Structure Nodes belong to more than one Release. Load one release at a time.';
  THROW 50202, @error, 1;
END

SELECT TOP 1 @release_id = n.release_id
FROM #src s JOIN GRAC_New.source_structure_node n ON n.structure_node_id = s.structure_node_id;

-- ---------------------------------------------------------------
-- Default classification (rerunnable)
-- ---------------------------------------------------------------
IF @assign_classification = 1
BEGIN
  IF NOT EXISTS(SELECT 1 FROM GRAC_New.statement_classification
                WHERE release_id = @release_id AND classification_code = @classification_code)
    INSERT GRAC_New.statement_classification
      (release_id,classification_code,classification_scheme,classification_name,description,display_order,status,entered_by)
    VALUES(@release_id,@classification_code,@classification_scheme,@classification_name,
           N'Default classification applied to the bulk-loaded Annex A source statements.',1,N'Active',@by);

  SELECT @classification_id = statement_classification_id
  FROM GRAC_New.statement_classification
  WHERE release_id = @release_id AND classification_code = @classification_code;
END

-- ---------------------------------------------------------------
-- Insert new statements
--
-- display_order follows cm_manage_repository: statements are
-- sequenced within their Source Structure Node, continuing from
-- whatever that node already holds.
-- ---------------------------------------------------------------
DECLARE @new TABLE(framework_statement_id BIGINT, statement_reference NVARCHAR(160), statement_title NVARCHAR(500));

WITH ordered AS (
  SELECT s.*,
         ISNULL((SELECT MAX(fs.display_order) FROM GRAC_New.framework_statement fs
                 WHERE fs.structure_node_id = s.structure_node_id), 0)
         + ROW_NUMBER() OVER (PARTITION BY s.structure_node_id ORDER BY s.seq) AS display_order
  FROM #src s
  WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.framework_statement fs
                   WHERE fs.release_id = @release_id
                     AND fs.statement_reference = s.statement_reference))
INSERT GRAC_New.framework_statement
  (release_id,structure_node_id,classification_id,statement_reference,statement_title,
   statement_text,statement_type,remarks,display_order,status,entered_by)
OUTPUT inserted.framework_statement_id, inserted.statement_reference, inserted.statement_title INTO @new
SELECT @release_id, o.structure_node_id, @classification_id, o.statement_reference, o.statement_title,
       o.statement_text, NULL, o.remarks, o.display_order, N'Active', @by
FROM ordered o;

SET @inserted = @@ROWCOUNT;

-- ---------------------------------------------------------------
-- Optional refresh of rows that already exist
-- ---------------------------------------------------------------
IF @overwrite_existing = 1
BEGIN
  UPDATE fs
    SET fs.statement_title = s.statement_title,
        fs.statement_text  = s.statement_text,
        fs.remarks         = s.remarks,
        fs.updated_by      = @by,
        fs.updated_dt      = SYSUTCDATETIME()
  FROM GRAC_New.framework_statement fs
  JOIN #src s ON s.statement_reference = fs.statement_reference
  WHERE fs.release_id = @release_id
    AND (ISNULL(fs.statement_title,N'') <> ISNULL(s.statement_title,N'')
      OR fs.statement_text <> s.statement_text
      OR ISNULL(fs.remarks,N'') <> ISNULL(s.remarks,N''));
  SET @updated = @@ROWCOUNT;
END

-- ---------------------------------------------------------------
-- Audit trail for the bulk load
--
-- Mirrors the three-table shape cm_manage_repository writes, so these
-- rows render on the Audit Trace screen like any other Add:
--   audit_trace_event  -> one event per statement
--   audit_trace_detail -> field-level values for that event
--   audit_trace        -> the flat row, linked by audit_event_id
-- action_type is 'Add' to stay inside the existing vocabulary.
-- ---------------------------------------------------------------
DECLARE @events TABLE(audit_event_id BIGINT, entity_id BIGINT);

INSERT GRAC_New.audit_trace_event
  (entity_type,entity_id,action_type,table_name,record_reference,remarks,before_json,after_json,status,entered_by)
OUTPUT inserted.audit_event_id, inserted.entity_id INTO @events
SELECT N'framework-statements', n.framework_statement_id, N'Add',
       N'GRAC_New.framework_statement',
       CONCAT(n.statement_reference, N' - ', ISNULL(n.statement_title, N'')),
       N'Bulk load: migration 052, ISO 27001 Source Statements v1.0.xlsx.',
       NULL,
       (SELECT fs.release_id releaseId, fs.structure_node_id structureNodeId,
               fs.classification_id classificationId, fs.statement_reference statementReference,
               fs.statement_title statementTitle, fs.statement_text statementText,
               fs.remarks, fs.display_order displayOrder, fs.status
        FROM GRAC_New.framework_statement fs
        WHERE fs.framework_statement_id = n.framework_statement_id
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
       N'Active', @by
FROM @new n;

INSERT GRAC_New.audit_trace_detail(audit_event_id,field_name,old_value,new_value,entered_by)
SELECT e.audit_event_id, d.field_name, NULL, d.new_value, @by
FROM @events e
JOIN GRAC_New.framework_statement fs ON fs.framework_statement_id = e.entity_id
CROSS APPLY (VALUES
  (N'Source Structure',         CAST(fs.structure_node_id AS NVARCHAR(MAX))),
  (N'Statement Reference',      fs.statement_reference),
  (N'Statement Title',          fs.statement_title),
  (N'Statement Text',           fs.statement_text),
  (N'Statement Classification', CAST(fs.classification_id AS NVARCHAR(MAX))),
  (N'Remarks',                  fs.remarks)
) AS d(field_name, new_value)
WHERE d.new_value IS NOT NULL;

INSERT GRAC_New.audit_trace
  (audit_event_id,entity_type,entity_id,action_type,table_name,record_reference,remarks,after_json,status,entered_by)
SELECT ev.audit_event_id, ev.entity_type, ev.entity_id, ev.action_type, ev.table_name,
       ev.record_reference, ev.remarks, ev.after_json, N'Active', @by
FROM GRAC_New.audit_trace_event ev
JOIN @events e ON e.audit_event_id = ev.audit_event_id;

COMMIT TRANSACTION;

PRINT CONCAT(N'052 complete. Release ', @release_id,
             N' | inserted ', @inserted,
             N' | refreshed ', @updated,
             N' | skipped ', 93 - @inserted - @updated, N' already present.');
END TRY
BEGIN CATCH
  IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
  THROW;
END CATCH
GO

-- ---------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------
SELECT n.node_reference, n.node_title, COUNT(*) AS statement_count
FROM GRAC_New.framework_statement fs
JOIN GRAC_New.source_structure_node n ON n.structure_node_id = fs.structure_node_id
WHERE fs.status = N'Active'
  AND fs.structure_node_id IN (2,5,6,8)
GROUP BY n.node_reference, n.node_title
ORDER BY n.node_reference;
GO
