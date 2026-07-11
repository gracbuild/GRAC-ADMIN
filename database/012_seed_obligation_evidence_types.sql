/*
  Backfill Evidence Type master values and sample obligation evidence mappings.
  Evidence is stored against Requirement Obligation context because evidence expectations
  may differ by release/source structure.
*/
SET NOCOUNT ON;

IF SCHEMA_ID('GRAC_New') IS NULL
BEGIN
 THROW 50120, 'GRAC_New schema is missing.', 1;
END;

IF OBJECT_ID('GRAC_New.evidence_type_master','U') IS NULL
BEGIN
 CREATE TABLE GRAC_New.evidence_type_master(
  evidence_type_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_cm_evidence_type_master PRIMARY KEY,
  evidence_type_code NVARCHAR(60) NOT NULL CONSTRAINT uq_cm_evidence_type_code UNIQUE,
  evidence_type_name NVARCHAR(160) NOT NULL,
  display_order INT NOT NULL DEFAULT 0,
  is_active BIT NOT NULL DEFAULT 1,
  entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
  entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_by NVARCHAR(100) NULL,
  updated_dt DATETIME2 NULL
 );
END;

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
 SELECT 1
 FROM GRAC_New.evidence_type_master existing
 WHERE existing.evidence_type_code=s.evidence_type_code
    OR existing.evidence_type_name=s.evidence_type_name
);

IF OBJECT_ID('GRAC_New.obligation_evidence_type','U') IS NULL
BEGIN
 CREATE TABLE GRAC_New.obligation_evidence_type(
  obligation_evidence_type_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_cm_obligation_evidence_type PRIMARY KEY,
  obligation_id BIGINT NOT NULL REFERENCES GRAC_New.obligation(obligation_id),
  evidence_type_id INT NOT NULL REFERENCES GRAC_New.evidence_type_master(evidence_type_id),
  status NVARCHAR(30) NOT NULL DEFAULT 'Active',
  entered_by NVARCHAR(100) NOT NULL,
  entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_by NVARCHAR(100) NULL,
  updated_dt DATETIME2 NULL,
  CONSTRAINT uq_cm_obligation_evidence_type UNIQUE(obligation_id,evidence_type_id)
 );
END;

;WITH legacy_evidence AS (
 SELECT o.obligation_id,et.evidence_type_id
 FROM GRAC_New.obligation o
 JOIN GRAC_New.evidence_type_master et
   ON et.is_active=1
  AND NULLIF(LTRIM(RTRIM(o.evidence_type)),N'') IS NOT NULL
  AND (
       LOWER(o.evidence_type)=LOWER(et.evidence_type_name)
       OR LOWER(o.evidence_type)=LOWER(et.evidence_type_code)
       OR LOWER(o.evidence_type) LIKE N'%'+LOWER(et.evidence_type_name)+N'%'
      )
 WHERE o.status='Active'
),
suggested_evidence AS (
 SELECT o.obligation_id,
   CASE
     WHEN LOWER(q.requirement_code+N' '+q.requirement_name+N' '+q.requirement_statement) LIKE N'%incident%' THEN N'Incident Report'
     WHEN LOWER(q.requirement_code+N' '+q.requirement_name+N' '+q.requirement_statement) LIKE N'%audit%' THEN N'Audit Log'
     WHEN LOWER(q.requirement_code+N' '+q.requirement_name+N' '+q.requirement_statement) LIKE N'%access%'
       OR LOWER(q.requirement_code+N' '+q.requirement_name+N' '+q.requirement_statement) LIKE N'%mfa%'
       OR LOWER(q.requirement_code+N' '+q.requirement_name+N' '+q.requirement_statement) LIKE N'%password%' THEN N'System Report'
     WHEN LOWER(q.requirement_code+N' '+q.requirement_name+N' '+q.requirement_statement) LIKE N'%kyc%'
       OR LOWER(q.requirement_code+N' '+q.requirement_name+N' '+q.requirement_statement) LIKE N'%customer%' THEN N'Review Register'
     WHEN LOWER(q.requirement_code+N' '+q.requirement_name+N' '+q.requirement_statement) LIKE N'%vendor%'
       OR LOWER(q.requirement_code+N' '+q.requirement_name+N' '+q.requirement_statement) LIKE N'%third%' THEN N'Approval Record'
     WHEN LOWER(q.requirement_code+N' '+q.requirement_name+N' '+q.requirement_statement) LIKE N'%policy%' THEN N'Policy Document'
     ELSE N'Procedure Document'
   END evidence_type_name
 FROM GRAC_New.obligation o
 JOIN GRAC_New.requirement q ON q.requirement_id=o.requirement_id
 WHERE o.status='Active'
   AND NOT EXISTS(SELECT 1 FROM GRAC_New.obligation_evidence_type existing WHERE existing.obligation_id=o.obligation_id AND existing.status='Active')
),
default_evidence AS (
 SELECT o.obligation_id,v.evidence_type_name
 FROM GRAC_New.obligation o
 CROSS APPLY (VALUES(N'Policy Document'),(N'Approval Record')) v(evidence_type_name)
 WHERE o.status='Active'
   AND NOT EXISTS(SELECT 1 FROM GRAC_New.obligation_evidence_type existing WHERE existing.obligation_id=o.obligation_id AND existing.status='Active')
)
INSERT GRAC_New.obligation_evidence_type(obligation_id,evidence_type_id,status,entered_by)
SELECT DISTINCT source.obligation_id,source.evidence_type_id,N'Active',N'system'
FROM (
 SELECT obligation_id,evidence_type_id FROM legacy_evidence
 UNION ALL
 SELECT s.obligation_id,et.evidence_type_id
 FROM suggested_evidence s
 JOIN GRAC_New.evidence_type_master et ON et.evidence_type_name=s.evidence_type_name AND et.is_active=1
 UNION ALL
 SELECT d.obligation_id,et.evidence_type_id
 FROM default_evidence d
 JOIN GRAC_New.evidence_type_master et ON et.evidence_type_name=d.evidence_type_name AND et.is_active=1
) source
WHERE NOT EXISTS(
 SELECT 1
 FROM GRAC_New.obligation_evidence_type existing
 WHERE existing.obligation_id=source.obligation_id AND existing.evidence_type_id=source.evidence_type_id
);

UPDATE o
SET evidence_required=CASE WHEN EXISTS(SELECT 1 FROM GRAC_New.obligation_evidence_type oet WHERE oet.obligation_id=o.obligation_id AND oet.status='Active') THEN 1 ELSE evidence_required END,
    evidence_type=(
      SELECT STRING_AGG(et.evidence_type_name,N', ')
      FROM GRAC_New.obligation_evidence_type oet
      JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id=oet.evidence_type_id
      WHERE oet.obligation_id=o.obligation_id AND oet.status='Active'
    )
FROM GRAC_New.obligation o
WHERE o.status='Active';

SELECT q.requirement_code RequirementCode,q.requirement_name RequirementName,o.obligation_id ObligationID,et.evidence_type_name EvidenceType
FROM GRAC_New.obligation o
JOIN GRAC_New.requirement q ON q.requirement_id=o.requirement_id
JOIN GRAC_New.obligation_evidence_type oet ON oet.obligation_id=o.obligation_id AND oet.status='Active'
JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id=oet.evidence_type_id
ORDER BY q.requirement_code,o.obligation_id,et.display_order;
