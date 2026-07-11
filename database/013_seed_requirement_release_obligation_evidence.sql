/*
  Seed sample Requirement + Release obligation evidence data.

  Run this script in the GRAC_NewPhase database.

  Purpose:
  - Practice Management "View Obligations" reads recommendations from:
      GRAC_New.requirement_obligation
      GRAC_New.requirement_obligation_evidence
  - This script creates realistic sample obligation evidence rows for every
    Requirement + Release pair derived from:
      control_requirement_map -> source_control_map -> source_structure_node -> release

  Notes:
  - Idempotent: safe to run multiple times.
  - Does not hardcode identity values.
  - Does not physically delete or overwrite existing configured evidence.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF SCHEMA_ID(N'GRAC_New') IS NULL
    THROW 51300, 'GRAC_New schema is missing. Run ControlManagement schema scripts first.', 1;

IF OBJECT_ID(N'GRAC_New.requirement', N'U') IS NULL
    THROW 51301, 'GRAC_New.requirement table is missing.', 1;

IF OBJECT_ID(N'GRAC_New.release', N'U') IS NULL
    THROW 51302, 'GRAC_New.release table is missing.', 1;

IF OBJECT_ID(N'GRAC_New.control_requirement_map', N'U') IS NULL
    THROW 51303, 'GRAC_New.control_requirement_map table is missing.', 1;

IF OBJECT_ID(N'GRAC_New.source_control_map', N'U') IS NULL
    THROW 51304, 'GRAC_New.source_control_map table is missing.', 1;

IF OBJECT_ID(N'GRAC_New.source_structure_node', N'U') IS NULL
    THROW 51305, 'GRAC_New.source_structure_node table is missing.', 1;

IF OBJECT_ID(N'GRAC_New.requirement_obligation', N'U') IS NULL
    THROW 51306, 'GRAC_New.requirement_obligation table is missing. Run 002_control_management_procedures.sql first.', 1;

IF OBJECT_ID(N'GRAC_New.requirement_obligation_evidence', N'U') IS NULL
    THROW 51307, 'GRAC_New.requirement_obligation_evidence table is missing. Run 002_control_management_procedures.sql first.', 1;

IF OBJECT_ID(N'GRAC_New.evidence_type_master', N'U') IS NULL
    THROW 51308, 'GRAC_New.evidence_type_master table is missing. Run 012_seed_obligation_evidence_types.sql first.', 1;

IF OBJECT_ID(N'GRAC_New.reference_option', N'U') IS NULL
    THROW 51309, 'GRAC_New.reference_option table is missing.', 1;

BEGIN TRANSACTION;

PRINT 'Requirement obligation evidence sample seed started.';

DECLARE @seed_all_active_requirement_release BIT = 0;
/*
  Default 0 = seed only real Requirement + Release contexts derived from mappings.
  Set to 1 only when you intentionally want sample obligations for every active
  Requirement against every active Release.
*/

SELECT N'BEFORE' AS Stage, N'GRAC_New.requirement_obligation' AS ObjectName, COUNT_BIG(1) AS RecordCount
FROM GRAC_New.requirement_obligation
UNION ALL
SELECT N'BEFORE', N'GRAC_New.requirement_obligation_evidence', COUNT_BIG(1)
FROM GRAC_New.requirement_obligation_evidence;

;WITH seed(evidence_type_code, evidence_type_name, display_order) AS (
    SELECT N'Policy Document', N'Policy Document', 1 UNION ALL
    SELECT N'Procedure Document', N'Procedure Document', 2 UNION ALL
    SELECT N'System Screenshot', N'System Screenshot', 3 UNION ALL
    SELECT N'System Report', N'System Report', 4 UNION ALL
    SELECT N'Audit Log', N'Audit Log', 5 UNION ALL
    SELECT N'Approval Record', N'Approval Record', 6 UNION ALL
    SELECT N'Review Register', N'Review Register', 7 UNION ALL
    SELECT N'Meeting Minutes', N'Meeting Minutes', 8 UNION ALL
    SELECT N'Configuration Export', N'Configuration Export', 9 UNION ALL
    SELECT N'Incident Report', N'Incident Report', 10
)
INSERT GRAC_New.evidence_type_master(evidence_type_code, evidence_type_name, display_order, entered_by)
SELECT s.evidence_type_code, s.evidence_type_name, s.display_order, N'system-seed'
FROM seed s
WHERE NOT EXISTS (
    SELECT 1
    FROM GRAC_New.evidence_type_master existing
    WHERE existing.evidence_type_code = s.evidence_type_code
       OR existing.evidence_type_name = s.evidence_type_name
);

;WITH seed(option_group, option_value, option_label, display_order) AS (
    SELECT N'frequency-types', N'Daily', N'Daily', 1 UNION ALL
    SELECT N'frequency-types', N'Weekly', N'Weekly', 2 UNION ALL
    SELECT N'frequency-types', N'Monthly', N'Monthly', 3 UNION ALL
    SELECT N'frequency-types', N'Quarterly', N'Quarterly', 4 UNION ALL
    SELECT N'frequency-types', N'Half-Yearly', N'Half-Yearly', 5 UNION ALL
    SELECT N'frequency-types', N'Annual', N'Annual', 6 UNION ALL
    SELECT N'frequency-types', N'Event Driven', N'Event Driven', 7 UNION ALL
    SELECT N'frequency-types', N'Continuous', N'Continuous', 8
)
INSERT GRAC_New.reference_option(option_group, option_value, option_label, display_order, status)
SELECT s.option_group, s.option_value, s.option_label, s.display_order, N'Active'
FROM seed s
WHERE NOT EXISTS (
    SELECT 1
    FROM GRAC_New.reference_option existing
    WHERE existing.option_group = s.option_group
      AND existing.option_value = s.option_value
);

DECLARE @monthly_id BIGINT = (
    SELECT TOP 1 reference_option_id
    FROM GRAC_New.reference_option
    WHERE option_group = N'frequency-types' AND status = N'Active'
      AND (option_value = N'Monthly' OR option_label = N'Monthly')
);

DECLARE @quarterly_id BIGINT = (
    SELECT TOP 1 reference_option_id
    FROM GRAC_New.reference_option
    WHERE option_group = N'frequency-types' AND status = N'Active'
      AND (option_value = N'Quarterly' OR option_label = N'Quarterly')
);

DECLARE @annual_id BIGINT = (
    SELECT TOP 1 reference_option_id
    FROM GRAC_New.reference_option
    WHERE option_group = N'frequency-types' AND status = N'Active'
      AND (option_value = N'Annual' OR option_label = N'Annual')
);

DECLARE @event_driven_id BIGINT = (
    SELECT TOP 1 reference_option_id
    FROM GRAC_New.reference_option
    WHERE option_group = N'frequency-types' AND status = N'Active'
      AND (option_value = N'Event Driven' OR option_label = N'Event Driven')
);

DECLARE @active_status_id BIGINT = (
    SELECT TOP 1 reference_option_id
    FROM GRAC_New.reference_option
    WHERE status = N'Active'
      AND (
          (option_group IN (N'record-status', N'status', N'status-active') AND option_value = N'Active')
          OR option_label = N'Active'
      )
    ORDER BY reference_option_id
);

IF OBJECT_ID('tempdb..#requirement_release_pair') IS NOT NULL DROP TABLE #requirement_release_pair;
CREATE TABLE #requirement_release_pair(
    requirement_id BIGINT NOT NULL,
    release_id BIGINT NOT NULL,
    source_reason NVARCHAR(80) NOT NULL,
    CONSTRAINT pk_seed_requirement_release_pair PRIMARY KEY(requirement_id, release_id)
);

INSERT #requirement_release_pair(requirement_id, release_id, source_reason)
SELECT DISTINCT crm.requirement_id, ssn.release_id, N'Control source mapping'
FROM GRAC_New.control_requirement_map crm
JOIN GRAC_New.requirement req
  ON req.requirement_id = crm.requirement_id
 AND req.status = N'Active'
JOIN GRAC_New.source_control_map scm
  ON scm.control_id = crm.control_id
 AND scm.status = N'Active'
JOIN GRAC_New.source_structure_node ssn
  ON ssn.structure_node_id = scm.structure_node_id
 AND ssn.status = N'Active'
JOIN GRAC_New.release rel
  ON rel.release_id = ssn.release_id
WHERE crm.status = N'Active'
  AND ISNULL(rel.status, N'Active') NOT IN (N'Inactive', N'Retired', N'Deleted');

IF OBJECT_ID(N'grac_practice.organization_requirement', N'U') IS NOT NULL
   AND OBJECT_ID(N'grac_practice.organization_control', N'U') IS NOT NULL
BEGIN
    INSERT #requirement_release_pair(requirement_id, release_id, source_reason)
    SELECT DISTINCT org_req.repository_requirement_id, org_ctrl.release_id, N'Practice imported requirement context'
    FROM grac_practice.organization_requirement org_req
    JOIN grac_practice.organization_control org_ctrl
      ON org_ctrl.organization_control_id = org_req.organization_control_id
     AND org_ctrl.organization_id = org_req.organization_id
    JOIN GRAC_New.requirement repo_req
      ON repo_req.requirement_id = org_req.repository_requirement_id
     AND repo_req.status = N'Active'
    JOIN GRAC_New.release rel
      ON rel.release_id = org_ctrl.release_id
    WHERE org_req.repository_requirement_id IS NOT NULL
      AND org_ctrl.release_id IS NOT NULL
      AND org_req.status = N'Active'
      AND org_ctrl.status = N'Active'
      AND ISNULL(rel.status, N'Active') NOT IN (N'Inactive', N'Retired', N'Deleted')
      AND NOT EXISTS (
          SELECT 1
          FROM #requirement_release_pair existing
          WHERE existing.requirement_id = org_req.repository_requirement_id
            AND existing.release_id = org_ctrl.release_id
      );
END;

IF NOT EXISTS (SELECT 1 FROM #requirement_release_pair)
BEGIN
    PRINT 'No mapped Requirement + Release pairs found. Falling back to all active requirements and releases for sample data.';

    INSERT #requirement_release_pair(requirement_id, release_id, source_reason)
    SELECT req.requirement_id, rel.release_id, N'Fallback all active requirement-release sample'
    FROM GRAC_New.requirement req
    CROSS JOIN GRAC_New.release rel
    WHERE req.status = N'Active'
      AND ISNULL(rel.status, N'Active') NOT IN (N'Inactive', N'Retired', N'Deleted');
END;

IF @seed_all_active_requirement_release = 1
BEGIN
    PRINT 'Full sample mode enabled: adding every active Requirement + active Release pair.';

    INSERT #requirement_release_pair(requirement_id, release_id, source_reason)
    SELECT req.requirement_id, rel.release_id, N'Full all active requirement-release sample'
    FROM GRAC_New.requirement req
    CROSS JOIN GRAC_New.release rel
    WHERE req.status = N'Active'
      AND ISNULL(rel.status, N'Active') NOT IN (N'Inactive', N'Retired', N'Deleted')
      AND NOT EXISTS (
          SELECT 1
          FROM #requirement_release_pair existing
          WHERE existing.requirement_id = req.requirement_id
            AND existing.release_id = rel.release_id
      );
END;

INSERT GRAC_New.requirement_obligation(requirement_id, release_id, status_id, status, entered_by)
SELECT p.requirement_id, p.release_id, @active_status_id, N'Active', N'sample-seed'
FROM #requirement_release_pair p
WHERE NOT EXISTS (
    SELECT 1
    FROM GRAC_New.requirement_obligation existing
    WHERE existing.requirement_id = p.requirement_id
      AND existing.release_id = p.release_id
      AND existing.status = N'Active'
);

IF OBJECT_ID('tempdb..#evidence_choice') IS NOT NULL DROP TABLE #evidence_choice;
CREATE TABLE #evidence_choice(
    requirement_id BIGINT NOT NULL,
    evidence_type_id INT NOT NULL,
    frequency_id BIGINT NULL,
    retention_requirement NVARCHAR(250) NULL,
    remarks NVARCHAR(MAX) NULL,
    display_order INT NOT NULL
);

;WITH requirement_text AS (
    SELECT requirement_id,
           LOWER(CONCAT(requirement_code, N' ', requirement_name, N' ', requirement_statement, N' ', objective)) AS search_text
    FROM GRAC_New.requirement
),
choice(requirement_id, evidence_type_name, frequency_id, retention_requirement, remarks, display_order) AS (
    SELECT requirement_id, N'System Report', @monthly_id, N'3 Years', N'Monthly system-generated compliance report.', 1
    FROM requirement_text
    WHERE search_text LIKE N'%access%' OR search_text LIKE N'%mfa%' OR search_text LIKE N'%password%' OR search_text LIKE N'%privileged%'

    UNION ALL
    SELECT requirement_id, N'Approval Record', @quarterly_id, N'3 Years', N'Quarterly approval or attestation record.', 2
    FROM requirement_text
    WHERE search_text LIKE N'%access%' OR search_text LIKE N'%mfa%' OR search_text LIKE N'%password%' OR search_text LIKE N'%privileged%'

    UNION ALL
    SELECT requirement_id, N'Review Register', @quarterly_id, N'5 Years', N'Periodic review register with reviewer comments.', 3
    FROM requirement_text
    WHERE search_text LIKE N'%review%' OR search_text LIKE N'%kyc%' OR search_text LIKE N'%customer%' OR search_text LIKE N'%vendor%'

    UNION ALL
    SELECT requirement_id, N'Policy Document', @annual_id, N'7 Years', N'Approved policy or governance document.', 1
    FROM requirement_text
    WHERE search_text LIKE N'%policy%' OR search_text LIKE N'%governance%' OR search_text LIKE N'%role%'

    UNION ALL
    SELECT requirement_id, N'Procedure Document', @annual_id, N'7 Years', N'Approved procedure or operating guideline.', 2
    FROM requirement_text
    WHERE search_text LIKE N'%procedure%' OR search_text LIKE N'%process%' OR search_text LIKE N'%governance%' OR search_text LIKE N'%role%'

    UNION ALL
    SELECT requirement_id, N'Incident Report', @event_driven_id, N'5 Years', N'Incident record including escalation and closure evidence.', 1
    FROM requirement_text
    WHERE search_text LIKE N'%incident%' OR search_text LIKE N'%escalat%'

    UNION ALL
    SELECT requirement_id, N'Audit Log', @monthly_id, N'2 Years', N'Audit trail or system log extract.', 2
    FROM requirement_text
    WHERE search_text LIKE N'%incident%' OR search_text LIKE N'%audit%' OR search_text LIKE N'%log%'

    UNION ALL
    SELECT requirement_id, N'Configuration Export', @quarterly_id, N'2 Years', N'Configuration export supporting control operation.', 1
    FROM requirement_text
    WHERE search_text LIKE N'%configuration%' OR search_text LIKE N'%backup%' OR search_text LIKE N'%data%' OR search_text LIKE N'%classification%'

    UNION ALL
    SELECT requirement_id, N'Meeting Minutes', @quarterly_id, N'3 Years', N'Committee or management review minutes.', 3
    FROM requirement_text
    WHERE search_text LIKE N'%objective%' OR search_text LIKE N'%governance%' OR search_text LIKE N'%risk%'

    UNION ALL
    SELECT requirement_id, N'Procedure Document', @annual_id, N'5 Years', N'Documented operating procedure.', 10
    FROM requirement_text

    UNION ALL
    SELECT requirement_id, N'Approval Record', @quarterly_id, N'3 Years', N'Approval or review evidence.', 11
    FROM requirement_text
)
INSERT #evidence_choice(requirement_id, evidence_type_id, frequency_id, retention_requirement, remarks, display_order)
SELECT c.requirement_id, et.evidence_type_id, c.frequency_id, c.retention_requirement, c.remarks, MIN(c.display_order)
FROM choice c
JOIN GRAC_New.evidence_type_master et
  ON et.evidence_type_name = c.evidence_type_name
 AND et.is_active = 1
GROUP BY c.requirement_id, et.evidence_type_id, c.frequency_id, c.retention_requirement, c.remarks;

;WITH ranked_choice AS (
    SELECT requirement_id,
           evidence_type_id,
           frequency_id,
           retention_requirement,
           remarks,
           ROW_NUMBER() OVER (PARTITION BY requirement_id ORDER BY display_order, evidence_type_id) AS row_no
    FROM #evidence_choice
)
INSERT GRAC_New.requirement_obligation_evidence(
    obligation_id,
    evidence_type_id,
    frequency_id,
    retention_requirement,
    remarks,
    status_id,
    status,
    entered_by
)
SELECT ro.obligation_id,
       rc.evidence_type_id,
       rc.frequency_id,
       rc.retention_requirement,
       rc.remarks,
       @active_status_id,
       N'Active',
       N'sample-seed'
FROM GRAC_New.requirement_obligation ro
JOIN #requirement_release_pair p
  ON p.requirement_id = ro.requirement_id
 AND p.release_id = ro.release_id
JOIN ranked_choice rc
  ON rc.requirement_id = ro.requirement_id
 AND rc.row_no <= 3
WHERE ro.status = N'Active'
  AND NOT EXISTS (
      SELECT 1
      FROM GRAC_New.requirement_obligation_evidence existing
      WHERE existing.obligation_id = ro.obligation_id
        AND existing.evidence_type_id = rc.evidence_type_id
        AND existing.status = N'Active'
  );

SELECT N'AFTER' AS Stage, N'GRAC_New.requirement_obligation' AS ObjectName, COUNT_BIG(1) AS RecordCount
FROM GRAC_New.requirement_obligation
UNION ALL
SELECT N'AFTER', N'GRAC_New.requirement_obligation_evidence', COUNT_BIG(1)
FROM GRAC_New.requirement_obligation_evidence;

SELECT TOP (200)
       req.requirement_code AS RequirementCode,
       req.requirement_name AS RequirementName,
       art.artifact_code AS ArtifactCode,
       rel.version_no AS ReleaseVersion,
       et.evidence_type_name AS EvidenceType,
       freq.option_label AS Frequency,
       roe.retention_requirement AS RetentionRequirement
FROM GRAC_New.requirement_obligation ro
JOIN GRAC_New.requirement req ON req.requirement_id = ro.requirement_id
JOIN GRAC_New.release rel ON rel.release_id = ro.release_id
JOIN GRAC_New.artifact art ON art.artifact_id = rel.artifact_id
JOIN GRAC_New.requirement_obligation_evidence roe
  ON roe.obligation_id = ro.obligation_id
 AND roe.status = N'Active'
JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id = roe.evidence_type_id
LEFT JOIN GRAC_New.reference_option freq ON freq.reference_option_id = roe.frequency_id
WHERE ro.status = N'Active'
ORDER BY req.requirement_code, art.artifact_code, rel.version_no, et.display_order;

COMMIT TRANSACTION;

PRINT 'Requirement obligation evidence sample seed completed.';
