/*
  Procedure facade for the Assurance Management (Admin) module.

  These procedures follow the same shape as dbo.cm_get_repository and
  dbo.cm_manage_repository so the API layer can dispatch to them
  interchangeably.  Keeping them separate protects the existing
  Regulatory Repository procedure from Assurance-specific branching.

  Lifecycle values recognised by the manage procedure:
    Draft -> Review -> Approved -> Published -> Retired

  Actions recognised by @p_action:
    QUERY            -> read-only, used by cm_get_assurance_repository
    ADD / SAVE       -> upsert (Draft on insert; Draft/Review updates on edit)
    RETIRE           -> soft delete
    SUBMIT           -> Draft -> Review
    APPROVE          -> Review -> Approved
    REJECT           -> Review -> Draft
    PUBLISH          -> Approved -> Published (writes an immutable version snapshot)
    RETIRE_PUBLISHED -> Published -> Retired (writes an immutable snapshot)
*/

CREATE OR ALTER PROCEDURE dbo.cm_get_assurance_repository
 @p_entity_type NVARCHAR(100),
 @p_action NVARCHAR(30)='',
 @p_id BIGINT=0,
 @p_search NVARCHAR(250)='',
 @p_status NVARCHAR(30)='',
 @p_payload NVARCHAR(MAX)='{}',
 @p_usr_id NVARCHAR(100)='',
 @p_page INT=1,
 @p_page_size INT=0
AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @lifecycle NVARCHAR(30)=ISNULL(JSON_VALUE(@p_payload,'$.LifecycleStatus'),N'');
 DECLARE @category_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.CategoryId'));
 DECLARE @workflow_template_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.WorkflowTemplateId'));
 DECLARE @page_size INT=CASE WHEN @p_page_size IN (10,25,50,100) THEN @p_page_size ELSE 0 END;
 DECLARE @page_no INT=CASE WHEN @p_page IS NULL OR @p_page<=0 THEN 1 ELSE @p_page END;
 DECLARE @page_take INT=CASE WHEN @page_size=0 THEN 2147483647 ELSE @page_size END;
 DECLARE @page_offset BIGINT=CAST(@page_no-1 AS BIGINT)*CAST(@page_take AS BIGINT);
 DECLARE @search NVARCHAR(250)=NULLIF(@p_search,N'');

 IF @p_entity_type='assurance-lookups'
 BEGIN
   SELECT 'assurance-categories' LookupKey,CAST(assurance_category_id AS NVARCHAR(40)) [Value],category_code+' - '+category_name Label
     FROM GRAC_New.assurance_category WHERE status='Active'
   UNION ALL SELECT 'assurance-scoring-models',CAST(scoring_model_id AS NVARCHAR(40)),model_code+' - '+model_name
     FROM GRAC_New.assurance_scoring_model WHERE status='Active'
   UNION ALL SELECT 'assurance-workflow-templates',CAST(workflow_template_id AS NVARCHAR(40)),template_code+' - '+template_name
     FROM GRAC_New.assurance_workflow_template WHERE status='Active'
   UNION ALL SELECT 'assurance-sampling-models',CAST(sampling_model_id AS NVARCHAR(40)),sampling_code+' - '+sampling_name
     FROM GRAC_New.assurance_sampling_model WHERE status='Active'
   UNION ALL SELECT 'assurance-frequency-types',CAST(frequency_type_id AS NVARCHAR(40)),frequency_code+' - '+frequency_name
     FROM GRAC_New.assurance_frequency_type WHERE status='Active'
   UNION ALL SELECT 'assurance-report-templates',CAST(report_template_id AS NVARCHAR(40)),template_code+' - '+template_name
     FROM GRAC_New.assurance_report_template WHERE status='Active'
   UNION ALL SELECT 'assurance-question-types',CAST(question_type_id AS NVARCHAR(40)),question_code+' - '+question_name
     FROM GRAC_New.assurance_question_type WHERE status='Active'
   UNION ALL SELECT 'assurance-severity',CAST(observation_severity_id AS NVARCHAR(40)),severity_code+' - '+severity_name
     FROM GRAC_New.assurance_observation_severity WHERE status='Active'
   UNION ALL SELECT 'assurance-gap-categories',CAST(gap_category_id AS NVARCHAR(40)),gap_code+' - '+gap_name
     FROM GRAC_New.assurance_gap_category WHERE status='Active'
   UNION ALL SELECT 'assurance-lifecycle','Draft','Draft'
   UNION ALL SELECT 'assurance-lifecycle','Review','Review'
   UNION ALL SELECT 'assurance-lifecycle','Approved','Approved'
   UNION ALL SELECT 'assurance-lifecycle','Published','Published'
   UNION ALL SELECT 'assurance-lifecycle','Retired','Retired'
   UNION ALL SELECT 'status-active','Active','Active'
   UNION ALL SELECT 'status-active','Inactive','Inactive';
   RETURN;
 END

 IF @p_entity_type='assurance-categories'
   SELECT assurance_category_id Id,category_code Code,category_name Name,description Description,
          display_order DisplayOrder,version_no Version,lifecycle_status LifecycleStatus,status Status,
          entered_by EnteredBy,entered_dt EnteredDt,updated_by UpdatedBy,updated_dt UpdatedDt
   FROM GRAC_New.assurance_category
   WHERE (@p_id=0 OR assurance_category_id=@p_id)
     AND (@p_status='' OR status=@p_status)
     AND (@lifecycle='' OR lifecycle_status=@lifecycle)
     AND (@search IS NULL OR category_code LIKE '%'+@search+'%' OR category_name LIKE '%'+@search+'%')
   ORDER BY display_order,category_name;
 ELSE IF @p_entity_type='assurance-scoring-models'
   SELECT scoring_model_id Id,model_code Code,model_name Name,description Description,
          formula_definition FormulaDefinition,formula_type FormulaType,rating_scale RatingScale,pass_threshold PassThreshold,
          version_no Version,lifecycle_status LifecycleStatus,status Status,
          entered_by EnteredBy,entered_dt EnteredDt,updated_by UpdatedBy,updated_dt UpdatedDt
   FROM GRAC_New.assurance_scoring_model
   WHERE (@p_id=0 OR scoring_model_id=@p_id)
     AND (@p_status='' OR status=@p_status)
     AND (@lifecycle='' OR lifecycle_status=@lifecycle)
     AND (@search IS NULL OR model_code LIKE '%'+@search+'%' OR model_name LIKE '%'+@search+'%')
   ORDER BY model_name;
 ELSE IF @p_entity_type='assurance-severity'
   SELECT observation_severity_id Id,severity_code Code,severity_name Name,description Description,
          severity_rank SeverityRank,color_code ColorCode,version_no Version,lifecycle_status LifecycleStatus,status Status,
          entered_by EnteredBy,entered_dt EnteredDt,updated_by UpdatedBy,updated_dt UpdatedDt
   FROM GRAC_New.assurance_observation_severity
   WHERE (@p_id=0 OR observation_severity_id=@p_id)
     AND (@p_status='' OR status=@p_status)
     AND (@lifecycle='' OR lifecycle_status=@lifecycle)
     AND (@search IS NULL OR severity_code LIKE '%'+@search+'%' OR severity_name LIKE '%'+@search+'%')
   ORDER BY severity_rank,severity_name;
 ELSE IF @p_entity_type='assurance-gap-categories'
   SELECT gap_category_id Id,gap_code Code,gap_name Name,description Description,
          display_order DisplayOrder,version_no Version,lifecycle_status LifecycleStatus,status Status,
          entered_by EnteredBy,entered_dt EnteredDt,updated_by UpdatedBy,updated_dt UpdatedDt
   FROM GRAC_New.assurance_gap_category
   WHERE (@p_id=0 OR gap_category_id=@p_id)
     AND (@p_status='' OR status=@p_status)
     AND (@lifecycle='' OR lifecycle_status=@lifecycle)
     AND (@search IS NULL OR gap_code LIKE '%'+@search+'%' OR gap_name LIKE '%'+@search+'%')
   ORDER BY display_order,gap_name;
 ELSE IF @p_entity_type='assurance-workflow-templates'
 BEGIN
   SELECT wt.workflow_template_id Id,wt.template_code Code,wt.template_name Name,wt.description Description,
          wt.sla_hours SlaHours,wt.escalation_rule EscalationRule,
          wt.version_no Version,wt.lifecycle_status LifecycleStatus,wt.status Status,
          (SELECT COUNT(1) FROM GRAC_New.assurance_workflow_stage s WHERE s.workflow_template_id=wt.workflow_template_id AND s.status='Active') StageCount,
          wt.entered_by EnteredBy,wt.entered_dt EnteredDt,wt.updated_by UpdatedBy,wt.updated_dt UpdatedDt
   FROM GRAC_New.assurance_workflow_template wt
   WHERE (@p_id=0 OR wt.workflow_template_id=@p_id)
     AND (@p_status='' OR wt.status=@p_status)
     AND (@lifecycle='' OR wt.lifecycle_status=@lifecycle)
     AND (@search IS NULL OR wt.template_code LIKE '%'+@search+'%' OR wt.template_name LIKE '%'+@search+'%')
   ORDER BY wt.template_name;

   -- Second result set: stages for the selected template (or all when @p_id=0).
   SELECT s.workflow_stage_id Id,s.workflow_template_id WorkflowTemplateId,
          s.stage_order StageOrder,s.stage_name StageName,s.stage_type StageType,
          s.approval_rule ApprovalRule,s.escalation_rule EscalationRule,s.sla_hours SlaHours,s.status Status
   FROM GRAC_New.assurance_workflow_stage s
   WHERE (@p_id=0 OR s.workflow_template_id=@p_id)
     AND (@workflow_template_id IS NULL OR s.workflow_template_id=@workflow_template_id)
   ORDER BY s.workflow_template_id,s.stage_order;
 END
 ELSE IF @p_entity_type='assurance-question-types'
   SELECT question_type_id Id,question_code Code,question_name Name,description Description,
          requires_evidence RequiresEvidence,answer_shape AnswerShape,display_order DisplayOrder,
          version_no Version,lifecycle_status LifecycleStatus,status Status,
          entered_by EnteredBy,entered_dt EnteredDt,updated_by UpdatedBy,updated_dt UpdatedDt
   FROM GRAC_New.assurance_question_type
   WHERE (@p_id=0 OR question_type_id=@p_id)
     AND (@p_status='' OR status=@p_status)
     AND (@lifecycle='' OR lifecycle_status=@lifecycle)
     AND (@search IS NULL OR question_code LIKE '%'+@search+'%' OR question_name LIKE '%'+@search+'%')
   ORDER BY display_order,question_name;
 ELSE IF @p_entity_type='assurance-sampling-models'
   SELECT sampling_model_id Id,sampling_code Code,sampling_name Name,description Description,methodology Methodology,
          version_no Version,lifecycle_status LifecycleStatus,status Status,
          entered_by EnteredBy,entered_dt EnteredDt,updated_by UpdatedBy,updated_dt UpdatedDt
   FROM GRAC_New.assurance_sampling_model
   WHERE (@p_id=0 OR sampling_model_id=@p_id)
     AND (@p_status='' OR status=@p_status)
     AND (@lifecycle='' OR lifecycle_status=@lifecycle)
     AND (@search IS NULL OR sampling_code LIKE '%'+@search+'%' OR sampling_name LIKE '%'+@search+'%')
   ORDER BY sampling_name;
 ELSE IF @p_entity_type='assurance-frequency-types'
   SELECT frequency_type_id Id,frequency_code Code,frequency_name Name,description Description,
          interval_days IntervalDays,display_order DisplayOrder,
          version_no Version,lifecycle_status LifecycleStatus,status Status,
          entered_by EnteredBy,entered_dt EnteredDt,updated_by UpdatedBy,updated_dt UpdatedDt
   FROM GRAC_New.assurance_frequency_type
   WHERE (@p_id=0 OR frequency_type_id=@p_id)
     AND (@p_status='' OR status=@p_status)
     AND (@lifecycle='' OR lifecycle_status=@lifecycle)
     AND (@search IS NULL OR frequency_code LIKE '%'+@search+'%' OR frequency_name LIKE '%'+@search+'%')
   ORDER BY display_order,frequency_name;
 ELSE IF @p_entity_type='assurance-report-templates'
   SELECT report_template_id Id,template_code Code,template_name Name,description Description,
          report_scope ReportScope,layout_definition LayoutDefinition,
          version_no Version,lifecycle_status LifecycleStatus,status Status,
          entered_by EnteredBy,entered_dt EnteredDt,updated_by UpdatedBy,updated_dt UpdatedDt
   FROM GRAC_New.assurance_report_template
   WHERE (@p_id=0 OR report_template_id=@p_id)
     AND (@p_status='' OR status=@p_status)
     AND (@lifecycle='' OR lifecycle_status=@lifecycle)
     AND (@search IS NULL OR template_code LIKE '%'+@search+'%' OR template_name LIKE '%'+@search+'%')
   ORDER BY template_name;
 ELSE IF @p_entity_type='assurance-starter-templates'
   SELECT st.starter_template_id Id,st.template_code Code,st.template_name Name,st.description Description,
          st.assurance_category_id CategoryId,cat.category_name Category,
          st.scoring_model_id ScoringModelId,sm.model_name ScoringModel,
          st.workflow_template_id WorkflowTemplateId,wt.template_name WorkflowTemplate,
          st.sampling_model_id SamplingModelId,samp.sampling_name SamplingModel,
          st.frequency_type_id FrequencyTypeId,fr.frequency_name FrequencyType,
          st.report_template_id ReportTemplateId,rt.template_name ReportTemplate,
          st.version_no Version,st.lifecycle_status LifecycleStatus,st.status Status,
          st.entered_by EnteredBy,st.entered_dt EnteredDt,st.updated_by UpdatedBy,st.updated_dt UpdatedDt
   FROM GRAC_New.assurance_starter_template st
   LEFT JOIN GRAC_New.assurance_category cat ON cat.assurance_category_id=st.assurance_category_id
   LEFT JOIN GRAC_New.assurance_scoring_model sm ON sm.scoring_model_id=st.scoring_model_id
   LEFT JOIN GRAC_New.assurance_workflow_template wt ON wt.workflow_template_id=st.workflow_template_id
   LEFT JOIN GRAC_New.assurance_sampling_model samp ON samp.sampling_model_id=st.sampling_model_id
   LEFT JOIN GRAC_New.assurance_frequency_type fr ON fr.frequency_type_id=st.frequency_type_id
   LEFT JOIN GRAC_New.assurance_report_template rt ON rt.report_template_id=st.report_template_id
   WHERE (@p_id=0 OR st.starter_template_id=@p_id)
     AND (@p_status='' OR st.status=@p_status)
     AND (@lifecycle='' OR st.lifecycle_status=@lifecycle)
     AND (@category_id IS NULL OR st.assurance_category_id=@category_id)
     AND (@search IS NULL OR st.template_code LIKE '%'+@search+'%' OR st.template_name LIKE '%'+@search+'%')
   ORDER BY st.template_name;
 ELSE IF @p_entity_type='assurance-version-history'
   SELECT metadata_version_id Id,entity_type EntityType,entity_id EntityId,version_no Version,
          lifecycle_status LifecycleStatus,previous_status PreviousStatus,action_code ActionCode,
          remarks Remarks,published_dt PublishedDt,retired_dt RetiredDt,
          entered_by EnteredBy,entered_dt EnteredDt
   FROM GRAC_New.assurance_metadata_version
   WHERE (@p_id=0 OR metadata_version_id=@p_id)
     AND (@search IS NULL OR entity_type LIKE '%'+@search+'%' OR action_code LIKE '%'+@search+'%' OR remarks LIKE '%'+@search+'%')
   ORDER BY entered_dt DESC;
 ELSE
   THROW 50070,'Unsupported assurance entity type',1;
END;
GO

/*
  Manage procedure.  Handles Add / Edit / Retire and every lifecycle
  transition (Submit, Approve, Reject, Publish, Retire published).

  On any lifecycle transition an immutable snapshot is written to
  GRAC_New.assurance_metadata_version so Phase 2 subscriptions can
  bind to a specific published version and the Version History screen
  can trace the full lifecycle audit trail.
*/
CREATE OR ALTER PROCEDURE dbo.cm_manage_assurance_repository
 @p_entity_type NVARCHAR(100),
 @p_action NVARCHAR(30),
 @p_id BIGINT=0,
 @p_search NVARCHAR(250)='',
 @p_status NVARCHAR(30)='',
 @p_payload NVARCHAR(MAX)='{}',
 @p_usr_id NVARCHAR(100)=''
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
 IF NULLIF(@p_usr_id,'') IS NULL SET @p_usr_id='system';

 DECLARE @new_id BIGINT=@p_id;
 DECLARE @current_lifecycle NVARCHAR(30)=N'Draft';
 DECLARE @current_version NVARCHAR(40)=N'1.0';
 DECLARE @next_lifecycle NVARCHAR(30)=NULL;
 DECLARE @next_version NVARCHAR(40)=NULL;
 DECLARE @remarks NVARCHAR(MAX)=NULLIF(JSON_VALUE(@p_payload,'$.remarks'),N'');
 DECLARE @snapshot NVARCHAR(MAX)=NULL;
 DECLARE @action_norm NVARCHAR(30)=UPPER(@p_action);

 -- Load current lifecycle/version for edit or lifecycle actions.
 IF @p_id>0
 BEGIN
   IF @p_entity_type='assurance-categories'
     SELECT @current_lifecycle=lifecycle_status,@current_version=version_no FROM GRAC_New.assurance_category WHERE assurance_category_id=@p_id;
   ELSE IF @p_entity_type='assurance-scoring-models'
     SELECT @current_lifecycle=lifecycle_status,@current_version=version_no FROM GRAC_New.assurance_scoring_model WHERE scoring_model_id=@p_id;
   ELSE IF @p_entity_type='assurance-severity'
     SELECT @current_lifecycle=lifecycle_status,@current_version=version_no FROM GRAC_New.assurance_observation_severity WHERE observation_severity_id=@p_id;
   ELSE IF @p_entity_type='assurance-gap-categories'
     SELECT @current_lifecycle=lifecycle_status,@current_version=version_no FROM GRAC_New.assurance_gap_category WHERE gap_category_id=@p_id;
   ELSE IF @p_entity_type='assurance-workflow-templates'
     SELECT @current_lifecycle=lifecycle_status,@current_version=version_no FROM GRAC_New.assurance_workflow_template WHERE workflow_template_id=@p_id;
   ELSE IF @p_entity_type='assurance-question-types'
     SELECT @current_lifecycle=lifecycle_status,@current_version=version_no FROM GRAC_New.assurance_question_type WHERE question_type_id=@p_id;
   ELSE IF @p_entity_type='assurance-sampling-models'
     SELECT @current_lifecycle=lifecycle_status,@current_version=version_no FROM GRAC_New.assurance_sampling_model WHERE sampling_model_id=@p_id;
   ELSE IF @p_entity_type='assurance-frequency-types'
     SELECT @current_lifecycle=lifecycle_status,@current_version=version_no FROM GRAC_New.assurance_frequency_type WHERE frequency_type_id=@p_id;
   ELSE IF @p_entity_type='assurance-report-templates'
     SELECT @current_lifecycle=lifecycle_status,@current_version=version_no FROM GRAC_New.assurance_report_template WHERE report_template_id=@p_id;
   ELSE IF @p_entity_type='assurance-starter-templates'
     SELECT @current_lifecycle=lifecycle_status,@current_version=version_no FROM GRAC_New.assurance_starter_template WHERE starter_template_id=@p_id;
 END

 -- Compute the target lifecycle state and next version if applicable.
 SET @next_lifecycle = CASE @action_norm
    WHEN 'SUBMIT'          THEN 'Review'
    WHEN 'APPROVE'         THEN 'Approved'
    WHEN 'REJECT'          THEN 'Draft'
    WHEN 'PUBLISH'         THEN 'Published'
    WHEN 'RETIRE_PUBLISHED'THEN 'Retired'
    ELSE NULL END;

 -- On PUBLISH of an item already Published we bump the minor version.
 IF @action_norm='PUBLISH' AND @current_lifecycle='Published'
   SET @next_version = CONCAT(TRY_CONVERT(INT,LEFT(@current_version,CHARINDEX('.',@current_version+'.')-1)),
                              N'.',
                              TRY_CONVERT(INT,SUBSTRING(@current_version,CHARINDEX('.',@current_version)+1,10))+1);
 ELSE
   SET @next_version = @current_version;

 -- Lifecycle transitions (SUBMIT/APPROVE/REJECT/PUBLISH/RETIRE_PUBLISHED).
 IF @next_lifecycle IS NOT NULL
 BEGIN
   -- Validate transition rules
   IF @action_norm='SUBMIT'           AND @current_lifecycle NOT IN ('Draft')     THROW 50071,'Only Draft records can be submitted for review',1;
   IF @action_norm='APPROVE'          AND @current_lifecycle NOT IN ('Review')    THROW 50072,'Only records in Review can be approved',1;
   IF @action_norm='REJECT'           AND @current_lifecycle NOT IN ('Review')    THROW 50073,'Only records in Review can be rejected',1;
   IF @action_norm='PUBLISH'          AND @current_lifecycle NOT IN ('Approved','Published') THROW 50074,'Only Approved or Published records can be Published',1;
   IF @action_norm='RETIRE_PUBLISHED' AND @current_lifecycle NOT IN ('Published') THROW 50075,'Only Published records can be Retired',1;

   IF @p_entity_type='assurance-categories'
   BEGIN
     UPDATE GRAC_New.assurance_category SET lifecycle_status=@next_lifecycle,version_no=@next_version,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE assurance_category_id=@p_id;
     SELECT @snapshot=(SELECT * FROM GRAC_New.assurance_category WHERE assurance_category_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
   END
   ELSE IF @p_entity_type='assurance-scoring-models'
   BEGIN
     UPDATE GRAC_New.assurance_scoring_model SET lifecycle_status=@next_lifecycle,version_no=@next_version,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE scoring_model_id=@p_id;
     SELECT @snapshot=(SELECT * FROM GRAC_New.assurance_scoring_model WHERE scoring_model_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
   END
   ELSE IF @p_entity_type='assurance-severity'
   BEGIN
     UPDATE GRAC_New.assurance_observation_severity SET lifecycle_status=@next_lifecycle,version_no=@next_version,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE observation_severity_id=@p_id;
     SELECT @snapshot=(SELECT * FROM GRAC_New.assurance_observation_severity WHERE observation_severity_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
   END
   ELSE IF @p_entity_type='assurance-gap-categories'
   BEGIN
     UPDATE GRAC_New.assurance_gap_category SET lifecycle_status=@next_lifecycle,version_no=@next_version,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE gap_category_id=@p_id;
     SELECT @snapshot=(SELECT * FROM GRAC_New.assurance_gap_category WHERE gap_category_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
   END
   ELSE IF @p_entity_type='assurance-workflow-templates'
   BEGIN
     UPDATE GRAC_New.assurance_workflow_template SET lifecycle_status=@next_lifecycle,version_no=@next_version,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE workflow_template_id=@p_id;
     SELECT @snapshot=(SELECT * FROM GRAC_New.assurance_workflow_template WHERE workflow_template_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
   END
   ELSE IF @p_entity_type='assurance-question-types'
   BEGIN
     UPDATE GRAC_New.assurance_question_type SET lifecycle_status=@next_lifecycle,version_no=@next_version,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE question_type_id=@p_id;
     SELECT @snapshot=(SELECT * FROM GRAC_New.assurance_question_type WHERE question_type_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
   END
   ELSE IF @p_entity_type='assurance-sampling-models'
   BEGIN
     UPDATE GRAC_New.assurance_sampling_model SET lifecycle_status=@next_lifecycle,version_no=@next_version,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE sampling_model_id=@p_id;
     SELECT @snapshot=(SELECT * FROM GRAC_New.assurance_sampling_model WHERE sampling_model_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
   END
   ELSE IF @p_entity_type='assurance-frequency-types'
   BEGIN
     UPDATE GRAC_New.assurance_frequency_type SET lifecycle_status=@next_lifecycle,version_no=@next_version,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE frequency_type_id=@p_id;
     SELECT @snapshot=(SELECT * FROM GRAC_New.assurance_frequency_type WHERE frequency_type_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
   END
   ELSE IF @p_entity_type='assurance-report-templates'
   BEGIN
     UPDATE GRAC_New.assurance_report_template SET lifecycle_status=@next_lifecycle,version_no=@next_version,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE report_template_id=@p_id;
     SELECT @snapshot=(SELECT * FROM GRAC_New.assurance_report_template WHERE report_template_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
   END
   ELSE IF @p_entity_type='assurance-starter-templates'
   BEGIN
     UPDATE GRAC_New.assurance_starter_template SET lifecycle_status=@next_lifecycle,version_no=@next_version,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE starter_template_id=@p_id;
     SELECT @snapshot=(SELECT * FROM GRAC_New.assurance_starter_template WHERE starter_template_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
   END
   ELSE
   BEGIN
     ROLLBACK TRAN; THROW 50076,'Unsupported assurance entity for lifecycle action',1;
   END

   INSERT GRAC_New.assurance_metadata_version(entity_type,entity_id,version_no,lifecycle_status,previous_status,snapshot_json,remarks,action_code,published_dt,retired_dt,entered_by)
   VALUES(@p_entity_type,@p_id,@next_version,@next_lifecycle,@current_lifecycle,@snapshot,@remarks,@action_norm,
          CASE WHEN @next_lifecycle='Published' THEN SYSUTCDATETIME() ELSE NULL END,
          CASE WHEN @next_lifecycle='Retired'   THEN SYSUTCDATETIME() ELSE NULL END,
          @p_usr_id);
   SELECT CAST(@p_id AS BIGINT) Id;
   COMMIT TRAN; RETURN;
 END

 -- Soft-delete / retire the working draft.
 IF @action_norm='RETIRE'
 BEGIN
   IF @p_entity_type='assurance-categories'      UPDATE GRAC_New.assurance_category SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE assurance_category_id=@p_id;
   ELSE IF @p_entity_type='assurance-scoring-models'    UPDATE GRAC_New.assurance_scoring_model SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE scoring_model_id=@p_id;
   ELSE IF @p_entity_type='assurance-severity'          UPDATE GRAC_New.assurance_observation_severity SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE observation_severity_id=@p_id;
   ELSE IF @p_entity_type='assurance-gap-categories'    UPDATE GRAC_New.assurance_gap_category SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE gap_category_id=@p_id;
   ELSE IF @p_entity_type='assurance-workflow-templates'UPDATE GRAC_New.assurance_workflow_template SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE workflow_template_id=@p_id;
   ELSE IF @p_entity_type='assurance-question-types'    UPDATE GRAC_New.assurance_question_type SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE question_type_id=@p_id;
   ELSE IF @p_entity_type='assurance-sampling-models'   UPDATE GRAC_New.assurance_sampling_model SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE sampling_model_id=@p_id;
   ELSE IF @p_entity_type='assurance-frequency-types'   UPDATE GRAC_New.assurance_frequency_type SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE frequency_type_id=@p_id;
   ELSE IF @p_entity_type='assurance-report-templates'  UPDATE GRAC_New.assurance_report_template SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE report_template_id=@p_id;
   ELSE IF @p_entity_type='assurance-starter-templates' UPDATE GRAC_New.assurance_starter_template SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE starter_template_id=@p_id;
   ELSE BEGIN ROLLBACK TRAN; THROW 50077,'Unsupported assurance entity for retire action',1; END

   INSERT GRAC_New.assurance_metadata_version(entity_type,entity_id,version_no,lifecycle_status,previous_status,snapshot_json,remarks,action_code,entered_by)
   VALUES(@p_entity_type,@p_id,@current_version,@current_lifecycle,@current_lifecycle,NULL,@remarks,N'RETIRE',@p_usr_id);
   SELECT CAST(@p_id AS BIGINT) Id;
   COMMIT TRAN; RETURN;
 END

 /* ------------------ ADD / SAVE branch ------------------ */
 IF @p_id>0 AND @current_lifecycle IN ('Approved','Published','Retired')
   THROW 50078,'Approved, Published or Retired records cannot be edited directly. Create a new version instead.',1;

 IF @p_entity_type='assurance-categories'
 BEGIN
   DECLARE @cat_code NVARCHAR(80)=JSON_VALUE(@p_payload,'$.code');
   DECLARE @cat_name NVARCHAR(200)=JSON_VALUE(@p_payload,'$.name');
   DECLARE @cat_desc NVARCHAR(MAX)=JSON_VALUE(@p_payload,'$.description');
   DECLARE @cat_order INT=COALESCE(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.displayOrder')),0);
   DECLARE @cat_status NVARCHAR(30)=COALESCE(JSON_VALUE(@p_payload,'$.status'),N'Active');
   IF NULLIF(@cat_code,N'') IS NULL THROW 50080,'Category Code is required',1;
   IF NULLIF(@cat_name,N'') IS NULL THROW 50081,'Category Name is required',1;
   IF @p_id=0
   BEGIN
     IF EXISTS(SELECT 1 FROM GRAC_New.assurance_category WHERE category_code=@cat_code) THROW 50082,'Category Code already exists',1;
     INSERT GRAC_New.assurance_category(category_code,category_name,description,display_order,status,entered_by)
     VALUES(@cat_code,@cat_name,@cat_desc,@cat_order,@cat_status,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
   BEGIN
     UPDATE GRAC_New.assurance_category SET category_code=@cat_code,category_name=@cat_name,description=@cat_desc,display_order=@cat_order,status=@cat_status,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE assurance_category_id=@p_id;
   END
 END
 ELSE IF @p_entity_type='assurance-scoring-models'
 BEGIN
   DECLARE @sm_code NVARCHAR(80)=JSON_VALUE(@p_payload,'$.code');
   DECLARE @sm_name NVARCHAR(200)=JSON_VALUE(@p_payload,'$.name');
   DECLARE @sm_desc NVARCHAR(MAX)=JSON_VALUE(@p_payload,'$.description');
   DECLARE @sm_formula NVARCHAR(MAX)=JSON_VALUE(@p_payload,'$.formulaDefinition');
   DECLARE @sm_ftype NVARCHAR(60)=COALESCE(JSON_VALUE(@p_payload,'$.formulaType'),N'Configuration');
   DECLARE @sm_scale NVARCHAR(MAX)=JSON_VALUE(@p_payload,'$.ratingScale');
   DECLARE @sm_pass DECIMAL(9,2)=TRY_CONVERT(DECIMAL(9,2),JSON_VALUE(@p_payload,'$.passThreshold'));
   DECLARE @sm_status NVARCHAR(30)=COALESCE(JSON_VALUE(@p_payload,'$.status'),N'Active');
   IF NULLIF(@sm_code,N'') IS NULL THROW 50083,'Scoring Model Code is required',1;
   IF NULLIF(@sm_name,N'') IS NULL THROW 50084,'Scoring Model Name is required',1;
   /* Safety: never accept executable / dynamic content in formula_definition. */
   IF @sm_formula IS NOT NULL AND (CHARINDEX(N';',@sm_formula)>0 OR CHARINDEX(N'--',@sm_formula)>0 OR PATINDEX(N'%exec%',@sm_formula)>0 OR PATINDEX(N'%drop%',@sm_formula)>0 OR PATINDEX(N'%delete %',@sm_formula)>0)
     THROW 50085,'Formula definition must be configuration data, not executable SQL',1;
   IF @p_id=0
   BEGIN
     IF EXISTS(SELECT 1 FROM GRAC_New.assurance_scoring_model WHERE model_code=@sm_code) THROW 50086,'Scoring Model Code already exists',1;
     INSERT GRAC_New.assurance_scoring_model(model_code,model_name,description,formula_definition,formula_type,rating_scale,pass_threshold,status,entered_by)
     VALUES(@sm_code,@sm_name,@sm_desc,@sm_formula,@sm_ftype,@sm_scale,@sm_pass,@sm_status,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
   BEGIN
     UPDATE GRAC_New.assurance_scoring_model SET model_code=@sm_code,model_name=@sm_name,description=@sm_desc,formula_definition=@sm_formula,formula_type=@sm_ftype,rating_scale=@sm_scale,pass_threshold=@sm_pass,status=@sm_status,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE scoring_model_id=@p_id;
   END
 END
 ELSE IF @p_entity_type='assurance-severity'
 BEGIN
   DECLARE @sv_code NVARCHAR(80)=JSON_VALUE(@p_payload,'$.code');
   DECLARE @sv_name NVARCHAR(200)=JSON_VALUE(@p_payload,'$.name');
   DECLARE @sv_desc NVARCHAR(MAX)=JSON_VALUE(@p_payload,'$.description');
   DECLARE @sv_rank INT=COALESCE(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.severityRank')),0);
   DECLARE @sv_color NVARCHAR(20)=JSON_VALUE(@p_payload,'$.colorCode');
   DECLARE @sv_status NVARCHAR(30)=COALESCE(JSON_VALUE(@p_payload,'$.status'),N'Active');
   IF NULLIF(@sv_code,N'') IS NULL THROW 50087,'Severity Code is required',1;
   IF NULLIF(@sv_name,N'') IS NULL THROW 50088,'Severity Name is required',1;
   IF @p_id=0
   BEGIN
     IF EXISTS(SELECT 1 FROM GRAC_New.assurance_observation_severity WHERE severity_code=@sv_code) THROW 50089,'Severity Code already exists',1;
     INSERT GRAC_New.assurance_observation_severity(severity_code,severity_name,description,severity_rank,color_code,status,entered_by)
     VALUES(@sv_code,@sv_name,@sv_desc,@sv_rank,@sv_color,@sv_status,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
   BEGIN
     UPDATE GRAC_New.assurance_observation_severity SET severity_code=@sv_code,severity_name=@sv_name,description=@sv_desc,severity_rank=@sv_rank,color_code=@sv_color,status=@sv_status,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE observation_severity_id=@p_id;
   END
 END
 ELSE IF @p_entity_type='assurance-gap-categories'
 BEGIN
   DECLARE @gc_code NVARCHAR(80)=JSON_VALUE(@p_payload,'$.code');
   DECLARE @gc_name NVARCHAR(200)=JSON_VALUE(@p_payload,'$.name');
   DECLARE @gc_desc NVARCHAR(MAX)=JSON_VALUE(@p_payload,'$.description');
   DECLARE @gc_order INT=COALESCE(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.displayOrder')),0);
   DECLARE @gc_status NVARCHAR(30)=COALESCE(JSON_VALUE(@p_payload,'$.status'),N'Active');
   IF NULLIF(@gc_code,N'') IS NULL THROW 50090,'Gap Code is required',1;
   IF NULLIF(@gc_name,N'') IS NULL THROW 50091,'Gap Name is required',1;
   IF @p_id=0
   BEGIN
     IF EXISTS(SELECT 1 FROM GRAC_New.assurance_gap_category WHERE gap_code=@gc_code) THROW 50092,'Gap Code already exists',1;
     INSERT GRAC_New.assurance_gap_category(gap_code,gap_name,description,display_order,status,entered_by)
     VALUES(@gc_code,@gc_name,@gc_desc,@gc_order,@gc_status,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
   BEGIN
     UPDATE GRAC_New.assurance_gap_category SET gap_code=@gc_code,gap_name=@gc_name,description=@gc_desc,display_order=@gc_order,status=@gc_status,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE gap_category_id=@p_id;
   END
 END
 ELSE IF @p_entity_type='assurance-workflow-templates'
 BEGIN
   DECLARE @wt_code NVARCHAR(80)=JSON_VALUE(@p_payload,'$.code');
   DECLARE @wt_name NVARCHAR(200)=JSON_VALUE(@p_payload,'$.name');
   DECLARE @wt_desc NVARCHAR(MAX)=JSON_VALUE(@p_payload,'$.description');
   DECLARE @wt_sla INT=TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.slaHours'));
   DECLARE @wt_escalation NVARCHAR(MAX)=JSON_VALUE(@p_payload,'$.escalationRule');
   DECLARE @wt_status NVARCHAR(30)=COALESCE(JSON_VALUE(@p_payload,'$.status'),N'Active');
   IF NULLIF(@wt_code,N'') IS NULL THROW 50093,'Workflow Template Code is required',1;
   IF NULLIF(@wt_name,N'') IS NULL THROW 50094,'Workflow Template Name is required',1;
   IF @p_id=0
   BEGIN
     IF EXISTS(SELECT 1 FROM GRAC_New.assurance_workflow_template WHERE template_code=@wt_code) THROW 50095,'Workflow Template Code already exists',1;
     INSERT GRAC_New.assurance_workflow_template(template_code,template_name,description,sla_hours,escalation_rule,status,entered_by)
     VALUES(@wt_code,@wt_name,@wt_desc,@wt_sla,@wt_escalation,@wt_status,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
   BEGIN
     UPDATE GRAC_New.assurance_workflow_template SET template_code=@wt_code,template_name=@wt_name,description=@wt_desc,sla_hours=@wt_sla,escalation_rule=@wt_escalation,status=@wt_status,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE workflow_template_id=@p_id;
   END

   -- Stages payload (JSON array).  Replace stages for this template.
   IF ISJSON(ISNULL(JSON_QUERY(@p_payload,'$.stages'),N''))=1
   BEGIN
     UPDATE GRAC_New.assurance_workflow_stage SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
      WHERE workflow_template_id=@new_id;
     INSERT GRAC_New.assurance_workflow_stage(workflow_template_id,stage_order,stage_name,stage_type,approval_rule,escalation_rule,sla_hours,status,entered_by)
     SELECT @new_id,
            COALESCE(TRY_CONVERT(INT,JSON_VALUE(value,'$.stageOrder')),ROW_NUMBER() OVER(ORDER BY (SELECT 1))),
            NULLIF(JSON_VALUE(value,'$.stageName'),N''),
            COALESCE(NULLIF(JSON_VALUE(value,'$.stageType'),N''),N'Review'),
            JSON_VALUE(value,'$.approvalRule'),
            JSON_VALUE(value,'$.escalationRule'),
            TRY_CONVERT(INT,JSON_VALUE(value,'$.slaHours')),
            N'Active',
            @p_usr_id
     FROM OPENJSON(JSON_QUERY(@p_payload,'$.stages'))
     WHERE NULLIF(JSON_VALUE(value,'$.stageName'),N'') IS NOT NULL;
   END
 END
 ELSE IF @p_entity_type='assurance-question-types'
 BEGIN
   DECLARE @qt_code NVARCHAR(80)=JSON_VALUE(@p_payload,'$.code');
   DECLARE @qt_name NVARCHAR(200)=JSON_VALUE(@p_payload,'$.name');
   DECLARE @qt_desc NVARCHAR(MAX)=JSON_VALUE(@p_payload,'$.description');
   DECLARE @qt_evidence BIT=COALESCE(TRY_CONVERT(BIT,JSON_VALUE(@p_payload,'$.requiresEvidence')),0);
   DECLARE @qt_shape NVARCHAR(60)=JSON_VALUE(@p_payload,'$.answerShape');
   DECLARE @qt_order INT=COALESCE(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.displayOrder')),0);
   DECLARE @qt_status NVARCHAR(30)=COALESCE(JSON_VALUE(@p_payload,'$.status'),N'Active');
   IF NULLIF(@qt_code,N'') IS NULL THROW 50096,'Question Type Code is required',1;
   IF NULLIF(@qt_name,N'') IS NULL THROW 50097,'Question Type Name is required',1;
   IF @p_id=0
   BEGIN
     IF EXISTS(SELECT 1 FROM GRAC_New.assurance_question_type WHERE question_code=@qt_code) THROW 50098,'Question Type Code already exists',1;
     INSERT GRAC_New.assurance_question_type(question_code,question_name,description,requires_evidence,answer_shape,display_order,status,entered_by)
     VALUES(@qt_code,@qt_name,@qt_desc,@qt_evidence,@qt_shape,@qt_order,@qt_status,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE GRAC_New.assurance_question_type SET question_code=@qt_code,question_name=@qt_name,description=@qt_desc,requires_evidence=@qt_evidence,answer_shape=@qt_shape,display_order=@qt_order,status=@qt_status,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE question_type_id=@p_id;
 END
 ELSE IF @p_entity_type='assurance-sampling-models'
 BEGIN
   DECLARE @sam_code NVARCHAR(80)=JSON_VALUE(@p_payload,'$.code');
   DECLARE @sam_name NVARCHAR(200)=JSON_VALUE(@p_payload,'$.name');
   DECLARE @sam_desc NVARCHAR(MAX)=JSON_VALUE(@p_payload,'$.description');
   DECLARE @sam_method NVARCHAR(MAX)=JSON_VALUE(@p_payload,'$.methodology');
   DECLARE @sam_status NVARCHAR(30)=COALESCE(JSON_VALUE(@p_payload,'$.status'),N'Active');
   IF NULLIF(@sam_code,N'') IS NULL THROW 50099,'Sampling Model Code is required',1;
   IF NULLIF(@sam_name,N'') IS NULL THROW 50100,'Sampling Model Name is required',1;
   IF @p_id=0
   BEGIN
     IF EXISTS(SELECT 1 FROM GRAC_New.assurance_sampling_model WHERE sampling_code=@sam_code) THROW 50101,'Sampling Model Code already exists',1;
     INSERT GRAC_New.assurance_sampling_model(sampling_code,sampling_name,description,methodology,status,entered_by)
     VALUES(@sam_code,@sam_name,@sam_desc,@sam_method,@sam_status,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE GRAC_New.assurance_sampling_model SET sampling_code=@sam_code,sampling_name=@sam_name,description=@sam_desc,methodology=@sam_method,status=@sam_status,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE sampling_model_id=@p_id;
 END
 ELSE IF @p_entity_type='assurance-frequency-types'
 BEGIN
   DECLARE @fr_code NVARCHAR(80)=JSON_VALUE(@p_payload,'$.code');
   DECLARE @fr_name NVARCHAR(200)=JSON_VALUE(@p_payload,'$.name');
   DECLARE @fr_desc NVARCHAR(MAX)=JSON_VALUE(@p_payload,'$.description');
   DECLARE @fr_days INT=TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.intervalDays'));
   DECLARE @fr_order INT=COALESCE(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.displayOrder')),0);
   DECLARE @fr_status NVARCHAR(30)=COALESCE(JSON_VALUE(@p_payload,'$.status'),N'Active');
   IF NULLIF(@fr_code,N'') IS NULL THROW 50102,'Frequency Code is required',1;
   IF NULLIF(@fr_name,N'') IS NULL THROW 50103,'Frequency Name is required',1;
   IF @p_id=0
   BEGIN
     IF EXISTS(SELECT 1 FROM GRAC_New.assurance_frequency_type WHERE frequency_code=@fr_code) THROW 50104,'Frequency Code already exists',1;
     INSERT GRAC_New.assurance_frequency_type(frequency_code,frequency_name,description,interval_days,display_order,status,entered_by)
     VALUES(@fr_code,@fr_name,@fr_desc,@fr_days,@fr_order,@fr_status,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE GRAC_New.assurance_frequency_type SET frequency_code=@fr_code,frequency_name=@fr_name,description=@fr_desc,interval_days=@fr_days,display_order=@fr_order,status=@fr_status,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE frequency_type_id=@p_id;
 END
 ELSE IF @p_entity_type='assurance-report-templates'
 BEGIN
   DECLARE @rt_code NVARCHAR(80)=JSON_VALUE(@p_payload,'$.code');
   DECLARE @rt_name NVARCHAR(200)=JSON_VALUE(@p_payload,'$.name');
   DECLARE @rt_desc NVARCHAR(MAX)=JSON_VALUE(@p_payload,'$.description');
   DECLARE @rt_scope NVARCHAR(120)=JSON_VALUE(@p_payload,'$.reportScope');
   DECLARE @rt_layout NVARCHAR(MAX)=JSON_VALUE(@p_payload,'$.layoutDefinition');
   DECLARE @rt_status NVARCHAR(30)=COALESCE(JSON_VALUE(@p_payload,'$.status'),N'Active');
   IF NULLIF(@rt_code,N'') IS NULL THROW 50105,'Report Template Code is required',1;
   IF NULLIF(@rt_name,N'') IS NULL THROW 50106,'Report Template Name is required',1;
   IF @p_id=0
   BEGIN
     IF EXISTS(SELECT 1 FROM GRAC_New.assurance_report_template WHERE template_code=@rt_code) THROW 50107,'Report Template Code already exists',1;
     INSERT GRAC_New.assurance_report_template(template_code,template_name,description,report_scope,layout_definition,status,entered_by)
     VALUES(@rt_code,@rt_name,@rt_desc,@rt_scope,@rt_layout,@rt_status,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE GRAC_New.assurance_report_template SET template_code=@rt_code,template_name=@rt_name,description=@rt_desc,report_scope=@rt_scope,layout_definition=@rt_layout,status=@rt_status,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE report_template_id=@p_id;
 END
 ELSE IF @p_entity_type='assurance-starter-templates'
 BEGIN
   DECLARE @st_code NVARCHAR(80)=JSON_VALUE(@p_payload,'$.code');
   DECLARE @st_name NVARCHAR(200)=JSON_VALUE(@p_payload,'$.name');
   DECLARE @st_desc NVARCHAR(MAX)=JSON_VALUE(@p_payload,'$.description');
   DECLARE @st_cat BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.categoryId'));
   DECLARE @st_scoring BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.scoringModelId'));
   DECLARE @st_workflow BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.workflowTemplateId'));
   DECLARE @st_sampling BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.samplingModelId'));
   DECLARE @st_freq BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.frequencyTypeId'));
   DECLARE @st_report BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.reportTemplateId'));
   DECLARE @st_status NVARCHAR(30)=COALESCE(JSON_VALUE(@p_payload,'$.status'),N'Active');
   IF NULLIF(@st_code,N'') IS NULL THROW 50108,'Starter Template Code is required',1;
   IF NULLIF(@st_name,N'') IS NULL THROW 50109,'Starter Template Name is required',1;
   IF @p_id=0
   BEGIN
     IF EXISTS(SELECT 1 FROM GRAC_New.assurance_starter_template WHERE template_code=@st_code) THROW 50110,'Starter Template Code already exists',1;
     INSERT GRAC_New.assurance_starter_template(template_code,template_name,description,assurance_category_id,scoring_model_id,workflow_template_id,sampling_model_id,frequency_type_id,report_template_id,status,entered_by)
     VALUES(@st_code,@st_name,@st_desc,@st_cat,@st_scoring,@st_workflow,@st_sampling,@st_freq,@st_report,@st_status,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE GRAC_New.assurance_starter_template SET template_code=@st_code,template_name=@st_name,description=@st_desc,assurance_category_id=@st_cat,scoring_model_id=@st_scoring,workflow_template_id=@st_workflow,sampling_model_id=@st_sampling,frequency_type_id=@st_freq,report_template_id=@st_report,status=@st_status,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE starter_template_id=@p_id;
 END
 ELSE
 BEGIN
   ROLLBACK TRAN; THROW 50079,'Unsupported assurance entity for save action',1;
 END

 SELECT CAST(@new_id AS BIGINT) Id;
 COMMIT TRAN;
END;
GO
