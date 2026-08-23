/* =====================================================================
   053_iso_27001_practices_rollback.sql

   Reverses 053_iso_27001_practices.sql.

   Default behaviour is a soft rollback: the loaded Practices and their
   Statement mappings are set to Retired, matching the platform convention
   that repository records are retired by status rather than physically
   deleted (migration 049 -- Repository masters and mappings use the
   Active / Retired vocabulary).

   Set @hard_delete = 1 for a true undo of the load. That path refuses to
   run if any loaded Practice still carries an Obligation, an Obligation
   mapping or a Control mapping, so it cannot silently break downstream
   records. Run 054_iso_27001_obligations_rollback.sql with @hard_delete = 1
   first if the Obligations were loaded.

   Practices are matched by requirement_name against the 186 names in the
   sheet -- the same natural key 053 loads on. A Practice created by hand
   that happens to share a name will therefore be caught by this rollback;
   review the report before committing to @hard_delete.

   AUDIT ROWS ARE NOT REMOVED, by either path. audit_trace,
   audit_trace_event and audit_trace_detail carry INSTEAD OF UPDATE,
   DELETE triggers that reject any attempt to change them, so the record
   that the load happened survives the rollback. That is the intended
   behaviour of an append-only trail, not an oversight.

   FILE ENCODING: UTF-8 with BOM. Run with sqlcmd -f 65001 if needed.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- ---------------------------------------------------------------
-- Clear stale temp tables -- SEPARATE BATCH, ON PURPOSE
--
-- # temp tables live for the whole session, not the script. If an earlier
-- run of a different revision of this file left #name or #target behind
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
IF OBJECT_ID('tempdb..#name')   IS NOT NULL DROP TABLE #name;
IF OBJECT_ID('tempdb..#target') IS NOT NULL DROP TABLE #target;
GO

BEGIN TRY
BEGIN TRANSACTION;

DECLARE @by          NVARCHAR(100) = N'anoop.ps@soffit.in';
DECLARE @hard_delete BIT           = 0;
DECLARE @error       NVARCHAR(4000), @blocked NVARCHAR(4000);
DECLARE @maps INT = 0, @pracs INT = 0;

CREATE TABLE #name(practice_name NVARCHAR(300) NOT NULL PRIMARY KEY);

INSERT #name(practice_name) VALUES
(N'Establish the information security policy'),
(N'Maintain topic-specific policies'),
(N'Define the security role structure'),
(N'Allocate security responsibilities'),
(N'Identify conflicting duties'),
(N'Separate critical activities'),
(N'Set management security expectations'),
(N'Brief personnel before access'),
(N'Identify and maintain authority contacts'),
(N'Define authority contact responsibilities / Define reporting triggers and timelines'),
(N'Identify relevant security groups'),
(N'Maintain group contacts and participation'),
(N'Govern threat intelligence'),
(N'Cover all intelligence levels'),
(N'Define security requirements'),
(N'Manage supplier security'),
(N'Identify information and associated assets'),
(N'Maintain suitable asset inventories'),
(N'Establish acceptable-use rules'),
(N'Communicate responsibilities to users'),
(N'Identify assets to be returned'),
(N'Recover and verify returned assets'),
(N'Establish the classification policy and scheme'),
(N'Assess protection requirements'),
(N'Establish information-labelling procedures'),
(N'Cover all information and asset formats'),
(N'Govern information transfer'),
(N'Apply classification and third-party agreements'),
(N'Govern access control'),
(N'Determine access requirements'),
(N'Govern the identity life cycle'),
(N'Confirm the business need for identities'),
(N'Govern authentication information'),
(N'Control temporary authentication secrets'),
(N'Govern the access-right life cycle'),
(N'Obtain owner and management authorization'),
(N'Govern supplier information security'),
(N'Identify and classify supplier types'),
(N'Govern supplier security agreements'),
(N'Describe information and access methods'),
(N'Govern ICT supply-chain security'),
(N'Set security requirements for ICT acquisition'),
(N'Govern supplier monitoring and change management'),
(N'Verify agreement compliance'),
(N'Govern the cloud-service life cycle'),
(N'Establish a cloud security policy'),
(N'Govern incident management preparedness'),
(N'Define incident roles and responsibilities'),
(N'Govern security-event assessment'),
(N'Maintain an agreed categorization scheme'),
(N'Govern documented incident response'),
(N'Use a designated competent response team'),
(N'Govern incident learning and improvement'),
(N'Classify incident types for learning'),
(N'Govern security evidence management'),
(N'Identify potential evidence'),
(N'Govern information security during disruption'),
(N'Identify disruption security requirements'),
(N'Govern ICT continuity readiness'),
(N'Integrate ICT continuity with business continuity'),
(N'Govern external information security requirements'),
(N'Maintain a requirements register'),
(N'Govern intellectual property protection'),
(N'Establish an intellectual property policy'),
(N'Govern records protection'),
(N'Prevent record loss and destruction'),
(N'Govern privacy and PII protection'),
(N'Identify applicable privacy requirements'),
(N'Govern independent information security reviews'),
(N'Maintain an independent review process'),
(N'Govern security compliance reviews'),
(N'Maintain a compliance review method'),
(N'Govern documented operating procedures'),
(N'Identify activities requiring procedures'),
(N'Perform Personnel Background Screening'),
(N'Manage Third-Party Personnel Screening / Conduct Legally Compliant Screening / Assess Suitability for Information Security Roles'),
(N'Govern security terms of employment'),
(N'Align terms with security policies'),
(N'Govern the security learning programme'),
(N'Align learning with policies and procedures'),
(N'Govern the disciplinary process'),
(N'Formalize disciplinary procedures'),
(N'Govern termination and role-change security'),
(N'Define continuing security duties'),
(N'Govern confidentiality agreements'),
(N'Identify agreement requirements'),
(N'Govern secure remote working'),
(N'Maintain a remote-working policy'),
(N'Govern security event reporting'),
(N'Provide accessible reporting mechanisms'),
(N'Define perimeter scope and requirements'),
(N'Design layered security perimeters'),
(N'Physical Access Authorization'),
(N'Periodic Access Review And Revocation'),
(N'Secure Office And Room Design'),
(N'Critical Facility Location Away From Public Access'),
(N'Continuous Premises Monitoring'),
(N'Guard And Monitoring-Service Arrangements'),
(N'Site Threat And Consequence Assessment'),
(N'Regular Threat Reassessment And Monitoring'),
(N'Secure-Area Working Rules'),
(N'Need-To-Know Awareness Of Secure Areas'),
(N'Clear Desk And Clear Screen Policy'),
(N'Secure Paper And Removable-Media Storage'),
(N'Secure Equipment Siting'),
(N'Restricted Access To Work Areas'),
(N'Management Authorization For Off-Site Devices'),
(N'BYOD And Organization-Owned Device Coverage'),
(N'Removable-Media Policy And Communication'),
(N'Media Removal Authorization And Audit Trail'),
(N'Utility Dependency And Continuity Assessment'),
(N'Manufacturer-Compliant Utility Operation'),
(N'Power And Communications Cable Protection'),
(N'Underground Or Alternative Cable Protection'),
(N'Supplier-Recommended Maintenance'),
(N'Maintenance Programme Ownership And Monitoring'),
(N'Storage-Media Presence Verification'),
(N'Sensitive-Data Removal Verification'),
(N'Endpoint Security Policy And User Communication'),
(N'Information Classification And Device Handling Limits');

INSERT #name(practice_name) VALUES
(N'Privileged Access Policy And Authorization'),
(N'Identification Of Privileged Users Services And Processes'),
(N'Access Restriction Policy Implementation'),
(N'Anonymous And Public Access Restriction'),
(N'Source Code Access Policy And Procedures'),
(N'Central Source Code Repository Protection'),
(N'Risk-Based Authentication Design'),
(N'Authentication Strength By Information Classification'),
(N'Capacity Requirements And Criticality Assessment'),
(N'Resource Utilization Monitoring'),
(N'Malware Protection Policy Roles And Awareness'),
(N'Unauthorized Software Prevention And Allowlisting'),
(N'Asset Software Version And Ownership Inventory'),
(N'Vulnerability Roles Responsibilities And Coordination'),
(N'Configuration Management Process And Tools'),
(N'Configuration Roles Responsibilities And Procedures'),
(N'Retention-Based Information Deletion Policy'),
(N'Legal Regulatory Contractual And Business Requirements'),
(N'Data Masking Policy And Business Requirements'),
(N'Sensitive Data And PII Identification'),
(N'Sensitive Information Identification And Classification'),
(N'Email File Transfer Device And Media Channel Monitoring'),
(N'Set backup requirements and plans'),
(N'Protect backup copies'),
(N'Availability And Redundancy Requirements'),
(N'Redundant Architecture And Component Design'),
(N'Logging Policy Purpose Scope And Handling'),
(N'Event Identity Time Device Network And Protocol Data'),
(N'Monitoring Scope Legal Requirements And Retention'),
(N'Network System Application And Access Monitoring'),
(N'Time Synchronization Requirements'),
(N'Legal Contractual And Monitoring Time Accuracy'),
(N'Privileged Utility Inventory And Classification'),
(N'Minimum Trusted Authorized Utility Users'),
(N'Operational Software Installation Procedures'),
(N'Trained Administrator And Management Authorization'),
(N'Network Information Classification And Protection'),
(N'Network Device Ownership And Procedures'),
(N'Network Service Security Requirements And Levels'),
(N'Internal And External Provider Responsibilities'),
(N'Network Segregation Policy And Criteria'),
(N'Network Domains By Trust Criticality And Sensitivity'),
(N'Safe And Appropriate Web-Use Rules'),
(N'Allowed And Prohibited Website Categories'),
(N'Cryptography Policy And Approved Use'),
(N'Information Classification And Protection Strength'),
(N'Secure Development Policy And Methodology'),
(N'Development Test And Production Separation'),
(N'Application Security Risk Assessment And Approval'),
(N'Identity Trust Authentication And Access Segregation'),
(N'Secure Engineering Principles And Governance'),
(N'Security Across Business Data Application And Technology Layers'),
(N'Secure Coding Governance And Minimum Baseline'),
(N'Third-Party And Open-Source Component Coverage'),
(N'Security Testing Process And Requirements'),
(N'New System Upgrade And Version Testing'),
(N'Outsourced Development Requirements And Oversight'),
(N'Licensing Code Ownership And Intellectual Property'),
(N'Environment Separation Requirements And Design'),
(N'Separate Development Test And Production Domains'),
(N'Formal Change Policy And Life-Cycle Process'),
(N'Change Ownership Responsibilities And Procedures'),
(N'Test Information Selection And Reliability'),
(N'Sensitive And Personal Data Avoidance'),
(N'Audit Testing Planning And Management Agreement'),
(N'System And Data Access Approval');

-- Resolve to real Practices once, so every step below works off one set.
SELECT r.requirement_id, r.requirement_code, r.requirement_name
INTO #target
FROM GRAC_New.requirement r
JOIN #name n ON n.practice_name = r.requirement_name;
CREATE UNIQUE CLUSTERED INDEX ux_target ON #target(requirement_id);

PRINT CONCAT(N'Practices matched for rollback: ', (SELECT COUNT(*) FROM #target), N' of 186 in the sheet.');

IF @hard_delete = 1
BEGIN
  -- Refuse if anything still hangs off these Practices.
  IF EXISTS(SELECT 1 FROM GRAC_New.obligation_requirement_release_map m
            JOIN #target t ON t.requirement_id = m.requirement_id)
     OR EXISTS(SELECT 1 FROM GRAC_New.requirement_obligation o
               JOIN #target t ON t.requirement_id = o.requirement_id)
     OR EXISTS(SELECT 1 FROM GRAC_New.control_requirement_map c
               JOIN #target t ON t.requirement_id = c.requirement_id)
  BEGIN
    SET @blocked = STUFF((
      SELECT DISTINCT N', ' + t.requirement_code
      FROM #target t
      WHERE EXISTS(SELECT 1 FROM GRAC_New.obligation_requirement_release_map m WHERE m.requirement_id = t.requirement_id)
         OR EXISTS(SELECT 1 FROM GRAC_New.requirement_obligation o            WHERE o.requirement_id = t.requirement_id)
         OR EXISTS(SELECT 1 FROM GRAC_New.control_requirement_map c           WHERE c.requirement_id = t.requirement_id)
      FOR XML PATH('')), 1, 2, N'');
    SET @error = CONCAT(N'Hard delete refused. These Practices still carry Obligations or Control mappings: ', @blocked,
                        N'. Run 054_iso_27001_obligations_rollback.sql with @hard_delete = 1 first, or use the soft path.');
    -- THROW, not RAISERROR: it reaches the CATCH block below, which rolls
    -- the transaction back. RAISERROR would leave it open.
    THROW 50350, @error, 1;
  END

  DELETE m
  FROM GRAC_New.framework_statement_requirement_map m
  JOIN #target t ON t.requirement_id = m.requirement_id;
  SET @maps = @@ROWCOUNT;

  DELETE r
  FROM GRAC_New.requirement r
  JOIN #target t ON t.requirement_id = r.requirement_id;
  SET @pracs = @@ROWCOUNT;

  PRINT CONCAT(N'053 rollback (hard delete) complete. Statement mappings deleted ', @maps,
               N' | Practices deleted ', @pracs, N'.');
END
ELSE
BEGIN
  UPDATE m
     SET m.status = N'Retired', m.updated_by = @by, m.updated_dt = SYSUTCDATETIME()
  FROM GRAC_New.framework_statement_requirement_map m
  JOIN #target t ON t.requirement_id = m.requirement_id
  WHERE m.status <> N'Retired';
  SET @maps = @@ROWCOUNT;

  UPDATE r
     SET r.status = N'Retired', r.updated_by = @by, r.updated_dt = SYSUTCDATETIME()
  FROM GRAC_New.requirement r
  JOIN #target t ON t.requirement_id = r.requirement_id
  WHERE r.status <> N'Retired';
  SET @pracs = @@ROWCOUNT;

  PRINT CONCAT(N'053 rollback (soft, Retired) complete. Statement mappings retired ', @maps,
               N' | Practices retired ', @pracs, N'.');
  PRINT N'Re-running 053 re-activates the mappings but does NOT re-activate a Retired Practice -- flip status in the UI, or use @hard_delete = 1 for a clean reload.';
END

COMMIT TRANSACTION;
END TRY
BEGIN CATCH
  IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
  THROW;
END CATCH
GO

-- Verification
-- ---------------------------------------------------------------
-- Status spread across every Practice that carries a Statement mapping.
-- After a soft rollback the sheet's Practices should all read Retired;
-- after a hard delete they should not appear at all.
SELECT r.status, COUNT(*) AS practices
FROM GRAC_New.requirement r
WHERE EXISTS(SELECT 1 FROM GRAC_New.framework_statement_requirement_map m
             WHERE m.requirement_id = r.requirement_id)
GROUP BY r.status
ORDER BY r.status;
GO

-- Statements left with no Active Practice. After a full rollback of the
-- load this should list all 93 Annex A controls.
SELECT COUNT(*) AS statements_without_active_practice
FROM GRAC_New.framework_statement fs
WHERE fs.status = N'Active'
  AND NOT EXISTS(SELECT 1 FROM GRAC_New.framework_statement_requirement_map m
                 JOIN GRAC_New.requirement r ON r.requirement_id = m.requirement_id
                 WHERE m.framework_statement_id = fs.framework_statement_id
                   AND m.status = N'Active' AND r.status = N'Active');
GO
