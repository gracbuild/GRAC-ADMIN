/*
  Optional, rerunnable ISO/IEC 27001:2022 demonstration data.
  Apply after 001_control_management_schema.sql.
  Content is concise paraphrased metadata, not licensed standard text.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRY
 BEGIN TRANSACTION;
 DECLARE @by NVARCHAR(100)=N'sample.seed', @authority BIGINT, @artifact BIGINT, @release BIGINT, @org BIGINT, @change BIGINT, @impact BIGINT;

 IF NOT EXISTS(SELECT 1 FROM GRAC_New.authority WHERE authority_code=N'ISO-IEC')
  INSERT GRAC_New.authority(authority_name,authority_code,description,jurisdiction,website,status,entered_by)
  VALUES(N'International Organization for Standardization / International Electrotechnical Commission',N'ISO-IEC',
   N'International standards bodies. Demonstration metadata only.',N'International',N'https://www.iso.org/',N'Active',@by);
 SELECT @authority=authority_id FROM GRAC_New.authority WHERE authority_code=N'ISO-IEC';

 IF NOT EXISTS(SELECT 1 FROM GRAC_New.artifact WHERE artifact_code=N'ISO-IEC-27001')
  INSERT GRAC_New.artifact(authority_id,artifact_name,artifact_code,description,artifact_category,industry,jurisdiction,status,entered_by)
  VALUES(@authority,N'ISO/IEC 27001',N'ISO-IEC-27001',
   N'Information security management systems requirements standard. Consult licensed standard content for authoritative requirements.',
   N'Standard',N'All Industries',N'International',N'Active',@by);
 SELECT @artifact=artifact_id FROM GRAC_New.artifact WHERE artifact_code=N'ISO-IEC-27001';
 INSERT GRAC_New.artifact_industry_map(artifact_id,reference_option_id,status,entered_by)
 SELECT @artifact,reference_option_id,N'Active',@by FROM GRAC_New.reference_option o WHERE o.option_group=N'industries' AND o.option_value=N'All Industries'
  AND NOT EXISTS(SELECT 1 FROM GRAC_New.artifact_industry_map m WHERE m.artifact_id=@artifact AND m.reference_option_id=o.reference_option_id);
 INSERT GRAC_New.artifact_jurisdiction_map(artifact_id,reference_option_id,status,entered_by)
 SELECT @artifact,reference_option_id,N'Active',@by FROM GRAC_New.reference_option o WHERE o.option_group=N'jurisdictions' AND o.option_value=N'International'
  AND NOT EXISTS(SELECT 1 FROM GRAC_New.artifact_jurisdiction_map m WHERE m.artifact_id=@artifact AND m.reference_option_id=o.reference_option_id);

 IF NOT EXISTS(SELECT 1 FROM GRAC_New.release WHERE artifact_id=@artifact AND version_no=N'2022')
  INSERT GRAC_New.release(artifact_id,version_no,release_notes,status,entered_by)
  VALUES(@artifact,N'2022',N'Edition 3, published October 2022. Demonstration release.',N'Active',@by);
 SELECT @release=release_id FROM GRAC_New.release WHERE artifact_id=@artifact AND version_no=N'2022';

 IF NOT EXISTS(SELECT 1 FROM GRAC_New.organization WHERE organization_code=N'DEMO-ORG')
  INSERT GRAC_New.organization(organization_name,organization_code,status,entered_by) VALUES(N'Demo Organization',N'DEMO-ORG',N'Active',@by);
 SELECT @org=organization_id FROM GRAC_New.organization WHERE organization_code=N'DEMO-ORG';

 IF NOT EXISTS(SELECT 1 FROM GRAC_New.source_structure_node WHERE release_id=@release AND node_reference=N'Clause 4')
  INSERT GRAC_New.source_structure_node(release_id,node_level,node_type,node_reference,node_title,description,display_order,status,entered_by)
  VALUES(@release,1,N'Clause',N'Clause 4',N'Organizational context',N'Demonstration node for context topics.',10,N'Active',@by);
 IF NOT EXISTS(SELECT 1 FROM GRAC_New.source_structure_node WHERE release_id=@release AND node_reference=N'Clause 6')
  INSERT GRAC_New.source_structure_node(release_id,node_level,node_type,node_reference,node_title,description,display_order,status,entered_by)
  VALUES(@release,1,N'Clause',N'Clause 6',N'Planning',N'Demonstration node for planning topics.',20,N'Active',@by);
 IF NOT EXISTS(SELECT 1 FROM GRAC_New.source_structure_node WHERE release_id=@release AND node_reference=N'Clause 8')
  INSERT GRAC_New.source_structure_node(release_id,node_level,node_type,node_reference,node_title,description,display_order,status,entered_by)
  VALUES(@release,1,N'Clause',N'Clause 8',N'Operation',N'Demonstration node for operational topics.',30,N'Active',@by);

 IF NOT EXISTS(SELECT 1 FROM GRAC_New.control WHERE control_code=N'CTRL-ISMS-CONTEXT')
  INSERT GRAC_New.control(control_code,control_name,description,objective,status,entered_by) VALUES
  (N'CTRL-ISMS-CONTEXT',N'Define ISMS context and scope',N'Maintain organizational context and scope for the ISMS.',N'Establish a clear basis for the ISMS.',N'Active',@by);
 IF NOT EXISTS(SELECT 1 FROM GRAC_New.control WHERE control_code=N'CTRL-ISMS-OBJECTIVES')
  INSERT GRAC_New.control(control_code,control_name,description,objective,status,entered_by) VALUES
  (N'CTRL-ISMS-OBJECTIVES',N'Maintain information security objectives',N'Define objectives and track actions, ownership, and evaluation.',N'Produce measurable security outcomes.',N'Active',@by);
 IF NOT EXISTS(SELECT 1 FROM GRAC_New.control WHERE control_code=N'CTRL-ISMS-RISK')
  INSERT GRAC_New.control(control_code,control_name,description,objective,status,entered_by) VALUES
  (N'CTRL-ISMS-RISK',N'Operate information security risk processes',N'Perform repeatable risk assessment and treatment activities.',N'Manage risks consistently and retain evidence.',N'Active',@by);

 IF NOT EXISTS(SELECT 1 FROM GRAC_New.requirement WHERE requirement_code=N'REQ-ISO27001-CTX-001')
  INSERT GRAC_New.requirement(requirement_code,requirement_name,requirement_statement,objective,status,entered_by) VALUES
  (N'REQ-ISO27001-CTX-001',N'Determine ISMS context',N'Determine relevant internal and external considerations and maintain an appropriate ISMS scope.',N'Align the ISMS with organizational context.',N'Active',@by);
 IF NOT EXISTS(SELECT 1 FROM GRAC_New.requirement WHERE requirement_code=N'REQ-ISO27001-OBJ-001')
  INSERT GRAC_New.requirement(requirement_code,requirement_name,requirement_statement,objective,status,entered_by) VALUES
  (N'REQ-ISO27001-OBJ-001',N'Establish information security objectives',N'Establish information security objectives and plan how they will be achieved, monitored, and reviewed.',N'Turn strategy into tracked outcomes.',N'Active',@by);
 IF NOT EXISTS(SELECT 1 FROM GRAC_New.requirement WHERE requirement_code=N'REQ-ISO27001-RISK-001')
  INSERT GRAC_New.requirement(requirement_code,requirement_name,requirement_statement,objective,status,entered_by) VALUES
  (N'REQ-ISO27001-RISK-001',N'Perform risk assessment and treatment activities',N'Operate repeatable risk assessment and treatment activities and retain evidence.',N'Demonstrate risk-based decisions.',N'Active',@by);

 DECLARE @c1 BIGINT=(SELECT control_id FROM GRAC_New.control WHERE control_code=N'CTRL-ISMS-CONTEXT'), @c2 BIGINT=(SELECT control_id FROM GRAC_New.control WHERE control_code=N'CTRL-ISMS-OBJECTIVES'), @c3 BIGINT=(SELECT control_id FROM GRAC_New.control WHERE control_code=N'CTRL-ISMS-RISK');
 DECLARE @r1 BIGINT=(SELECT requirement_id FROM GRAC_New.requirement WHERE requirement_code=N'REQ-ISO27001-CTX-001'), @r2 BIGINT=(SELECT requirement_id FROM GRAC_New.requirement WHERE requirement_code=N'REQ-ISO27001-OBJ-001'), @r3 BIGINT=(SELECT requirement_id FROM GRAC_New.requirement WHERE requirement_code=N'REQ-ISO27001-RISK-001');
 DECLARE @n1 BIGINT=(SELECT structure_node_id FROM GRAC_New.source_structure_node WHERE release_id=@release AND node_reference=N'Clause 4'), @n2 BIGINT=(SELECT structure_node_id FROM GRAC_New.source_structure_node WHERE release_id=@release AND node_reference=N'Clause 6'), @n3 BIGINT=(SELECT structure_node_id FROM GRAC_New.source_structure_node WHERE release_id=@release AND node_reference=N'Clause 8');

 INSERT GRAC_New.source_control_map(structure_node_id,control_id,release_id,artifact_id,status,entered_by) SELECT v.node_id,v.control_id,@release,@artifact,N'Active',@by FROM (VALUES(@n1,@c1),(@n2,@c2),(@n3,@c3))v(node_id,control_id) WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.source_control_map m WHERE m.structure_node_id=v.node_id AND m.control_id=v.control_id);
 INSERT GRAC_New.control_requirement_map(control_id,requirement_id,status,entered_by) SELECT v.control_id,v.requirement_id,N'Active',@by FROM (VALUES(@c1,@r1),(@c2,@r2),(@c3,@r3))v(control_id,requirement_id) WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.control_requirement_map m WHERE m.control_id=v.control_id AND m.requirement_id=v.requirement_id);

 INSERT GRAC_New.obligation(requirement_id,release_id,mandatory_flag,frequency_type,frequency_value,frequency_unit,trigger_condition,due_within,evidence_required,evidence_type,retention_requirement,severity,status,entered_by)
 SELECT v.req,@release,1,v.freq,v.freq_value,v.unit,v.trigger_text,v.due_text,1,v.evidence,N'Per organizational retention policy',v.severity,N'Active',@by FROM (VALUES
  (@r1,N'Scheduled',1,N'Year',N'Annual review or material organizational change',N'Within review cycle',N'Approved scope and context review record',N'Medium'),
  (@r2,N'Scheduled',1,N'Quarter',N'Quarterly management review cycle',N'Within review cycle',N'Objective register and review record',N'Medium'),
  (@r3,N'Event Driven',NULL,NULL,N'Planned interval or material change',N'Before risk acceptance',N'Risk assessment and treatment record',N'High')
 )v(req,freq,freq_value,unit,trigger_text,due_text,evidence,severity)
 WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.obligation o WHERE o.requirement_id=v.req AND o.release_id=@release);

 IF NOT EXISTS(SELECT 1 FROM GRAC_New.applicability_attribute WHERE attribute_code=N'OPERATES_ISMS')
  INSERT GRAC_New.applicability_attribute(attribute_code,attribute_name,data_type,status,entered_by) VALUES(N'OPERATES_ISMS',N'Organization operates or intends to operate an ISMS',N'Boolean',N'Active',@by);
 IF NOT EXISTS(SELECT 1 FROM GRAC_New.applicability_rule WHERE artifact_id=@artifact AND rule_name=N'ISO/IEC 27001 ISMS scope review')
  INSERT GRAC_New.applicability_rule(artifact_id,release_id,rule_name,rule_expression_json,priority_no,outcome,status,entered_by)
  VALUES(@artifact,@release,N'ISO/IEC 27001 ISMS scope review',N'{"expression":"OPERATES_ISMS = true"}',100,N'Applicable',N'Active',@by);

 IF NOT EXISTS(SELECT 1 FROM GRAC_New.change_event WHERE entity_type=N'Release' AND entity_id=@release AND change_summary=N'ISO/IEC 27001:2022 sample release added.')
  INSERT GRAC_New.change_event(entity_type,entity_id,change_type,change_summary,severity,status,entered_by) VALUES(N'Release',@release,N'New',N'ISO/IEC 27001:2022 sample release added.',N'Medium',N'Open',@by);
 SELECT @change=change_event_id FROM GRAC_New.change_event WHERE entity_type=N'Release' AND entity_id=@release AND change_summary=N'ISO/IEC 27001:2022 sample release added.';
 IF NOT EXISTS(SELECT 1 FROM GRAC_New.impact_analysis WHERE change_event_id=@change AND impacted_entity_type=N'Organization' AND impacted_entity_id=@org)
  INSERT GRAC_New.impact_analysis(change_event_id,impacted_entity_type,impacted_entity_id,organization_id,impact_summary,recommended_action,status,entered_by)
  VALUES(@change,N'Organization',@org,@org,N'Review ISMS scope, objectives, and risk process records against the 2022 release metadata.',N'Complete a scoped gap review using licensed standard content.',N'Open',@by);
 SELECT @impact=impact_analysis_id FROM GRAC_New.impact_analysis WHERE change_event_id=@change AND impacted_entity_type=N'Organization' AND impacted_entity_id=@org;
 IF NOT EXISTS(SELECT 1 FROM GRAC_New.notification WHERE impact_analysis_id=@impact AND subject=N'ISO/IEC 27001:2022 sample impact review')
  INSERT GRAC_New.notification(impact_analysis_id,organization_id,notification_type,subject,message_body,severity,recommended_action,status,entered_by)
  VALUES(@impact,@org,N'Impact Alert',N'ISO/IEC 27001:2022 sample impact review',N'A sample release and impact record is ready for review.',N'Medium',N'Complete a scoped demonstration review.',N'Pending',@by);

 INSERT GRAC_New.audit_trace(entity_type,entity_id,action_type,after_json,status,entered_by)
 SELECT v.entity_type,v.entity_id,N'SEED_SAMPLE',v.json,N'Active',@by FROM (VALUES
  (N'Authority',@authority,N'{"sample":"ISO/IEC authority"}'),(N'Artifact',@artifact,N'{"sample":"ISO/IEC 27001"}'),(N'Release',@release,N'{"sample":"ISO/IEC 27001:2022"}'),(N'ChangeEvent',@change,N'{"sample":"demonstration change"}'),(N'ImpactAnalysis',@impact,N'{"sample":"demonstration impact"}')
 )v(entity_type,entity_id,json) WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.audit_trace a WHERE a.entity_type=v.entity_type AND a.entity_id=v.entity_id AND a.action_type=N'SEED_SAMPLE');

 COMMIT TRANSACTION;
 SELECT N'ISO/IEC 27001:2022 sample data ready.' Message,@authority AuthorityId,@artifact ArtifactId,@release ReleaseId,@change ChangeEventId,@impact ImpactAnalysisId;
END TRY
BEGIN CATCH
 IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
GO
