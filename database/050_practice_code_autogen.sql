-- =====================================================================
-- 050 -- Practice Code is system-generated (PR-001, PR-002, PR-003 ...)
--
-- THE PROBLEM
-- -----------
-- Practice Code was a free-text field on the Add Practice form.  Every user
-- invented their own convention, the codes drifted apart across teams, and a
-- typo produced either a duplicate-key failure at save time or a Practice
-- that no report could group.  The code carries no business meaning -- it is
-- an identifier -- so there is no reason for a human to type it.
--
-- AFTER THIS SCRIPT
-- -----------------
-- Saving a new Practice with no Code assigns the next free PR-### number,
-- continuing from the highest PR-### already in the table:
--
--     PR-001, PR-002, PR-003, ... PR-999, PR-1000, ...
--
-- Existing Practices are NOT renumbered.  Whatever code they carry today is
-- what they keep -- any report, export or external reference that quotes an
-- old code still resolves.  The generator simply starts after the highest
-- PR-### it finds, so old and new codes coexist.
--
-- A caller may still supply a Code explicitly.  Bulk upload and single-form
-- upload keep their Code column and that value wins; only a blank Code is
-- generated.  On UPDATE a payload without a Code leaves the existing code
-- untouched instead of nulling it.
--
-- Concurrency: the next number is read under UPDLOCK + HOLDLOCK inside the
-- procedure's own transaction, so two sessions inserting at the same moment
-- cannot claim the same number.  The unique index on requirement_code stays
-- as the final backstop.
--
-- WHAT IT SHIPS
-- -------------
--   1. dbo.cm_manage_repository -- the 'requirements' save branch generates
--      the Practice Code when the payload does not carry one, and no longer
--      clears the code on update
--
-- Everything else in the procedure is unchanged from 049.
--
-- Preflight: 002, then 047, 048, 049.
-- Rollback:  database/050_practice_code_autogen_rollback.sql
-- Safe to re-run.  ASCII-only.
-- =====================================================================

IF OBJECT_ID('dbo.cm_manage_repository','P') IS NULL
  THROW 51002, 'Apply 002_control_management_procedures.sql before this script.', 1;
GO

-- ---------------------------------------------------------------------
-- 0. Before: the Practice codes currently in use, and the next number
--    this script would hand out.
-- ---------------------------------------------------------------------
SELECT
  COUNT(*)                                                              AS TotalPractices,
  SUM(CASE WHEN requirement_code LIKE 'PR-[0-9]%' THEN 1 ELSE 0 END)    AS PrPatternCodes,
  SUM(CASE WHEN requirement_code LIKE 'PR-[0-9]%' THEN 0 ELSE 1 END)    AS OtherCodes,
  CONCAT('PR-', FORMAT(ISNULL(MAX(CASE WHEN requirement_code LIKE 'PR-[0-9]%'
                                       THEN TRY_CONVERT(INT, SUBSTRING(requirement_code, 4, 50)) END), 0) + 1, '000'))
                                                                        AS NextCodeToBeIssued
FROM GRAC_New.requirement;
GO

-- ---------------------------------------------------------------------
-- 1. dbo.cm_manage_repository
--    Only the 'requirements' save branch differs from 049.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.cm_manage_repository
 @p_entity_type NVARCHAR(100), @p_action NVARCHAR(30), @p_id BIGINT=0, @p_search NVARCHAR(250)='', @p_status NVARCHAR(30)='',
 @p_payload NVARCHAR(MAX)='{}', @p_usr_id NVARCHAR(100)=''
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
 DECLARE @new_id BIGINT=@p_id, @before NVARCHAR(MAX)=NULL, @after NVARCHAR(MAX)=NULL, @audit_action NVARCHAR(40)=NULL, @audit_table NVARCHAR(128)=NULL, @record_reference NVARCHAR(300)=NULL;
 IF NULLIF(@p_usr_id,'') IS NULL SET @p_usr_id='system';
 -- Read-only preview (048).  Answers "what else would this deactivation take
 -- down?" so the UI can show the count before the user confirms.  It lives
 -- here rather than in cm_get_repository so it reuses the manage plumbing the
 -- Inactive action already travels through, and so it is gated by the same
 -- DELETE permission.
 IF @p_action='RETIRE_IMPACT'
 BEGIN
   SELECT EntityType, COUNT(*) AS RecordCount
   FROM dbo.fn_cm_repository_descendant_status(@p_entity_type,@p_id)
   WHERE CurrentStatus NOT IN ('Retired','Inactive','Archived')
   GROUP BY EntityType
   ORDER BY EntityType;
   COMMIT; RETURN;
 END
 SET @audit_action=CASE WHEN @p_action='RETIRE' THEN N'Inactive' WHEN @p_action='ACTIVATE' THEN N'Activate' WHEN @p_action='APPROVE' THEN N'Status Change' WHEN @p_id=0 THEN N'Add' ELSE N'Edit' END;
 SET @audit_table=CASE @p_entity_type
   WHEN 'authorities' THEN N'GRAC_New.authority'
   WHEN 'artifacts' THEN N'GRAC_New.artifact'
   WHEN 'releases' THEN N'GRAC_New.release'
   WHEN 'statement-classifications' THEN N'GRAC_New.statement_classification'
   WHEN 'source-structure' THEN N'GRAC_New.source_structure_node'
   WHEN 'framework-statements' THEN N'GRAC_New.framework_statement'
   WHEN 'controls' THEN N'GRAC_New.control'
   WHEN 'control-domains' THEN N'GRAC_New.control_domain'
   WHEN 'control-sub-domains' THEN N'GRAC_New.control_sub_domain'
   WHEN 'requirements' THEN N'GRAC_New.requirement'
   WHEN 'obligations' THEN N'GRAC_New.requirement_obligation'
   WHEN 'obligation-mappings' THEN N'GRAC_New.obligation_requirement_release_map'
   WHEN 'control-requirement-mappings' THEN N'GRAC_New.control_requirement_map'
   WHEN 'source-control-mappings' THEN N'GRAC_New.source_control_map'
   WHEN 'applicability-rules' THEN N'GRAC_New.applicability_rule'
   WHEN 'changes' THEN N'GRAC_New.change_event'
    WHEN 'impact-analysis' THEN N'GRAC_New.impact_analysis'
    WHEN 'notifications' THEN N'GRAC_New.notification'
    WHEN 'change-management' THEN N'GRAC_New.change_management'
    WHEN 'approval-workflow' THEN N'GRAC_New.approval_workflow_config'
    WHEN 'user-management' THEN N'GRAC_New.cm_user'
    WHEN 'role-management' THEN N'GRAC_New.cm_role'
    WHEN 'menu-management' THEN N'GRAC_New.cm_menu'
    WHEN 'role-permissions' THEN N'GRAC_New.cm_role_permission'
    ELSE @p_entity_type END;
 IF @p_id>0
 BEGIN
    IF @p_entity_type='authorities' SELECT @before=(SELECT authority_code code,authority_name name,description,jurisdiction,website,status FROM GRAC_New.authority WHERE authority_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=(SELECT CONCAT(authority_code,N' - ',authority_name) FROM GRAC_New.authority WHERE authority_id=@p_id);
    ELSE IF @p_entity_type='artifacts' SELECT @before=(SELECT authority_id authorityId,artifact_code code,artifact_name name,description,artifact_category category,status FROM GRAC_New.artifact WHERE artifact_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=(SELECT CONCAT(artifact_code,N' - ',artifact_name) FROM GRAC_New.artifact WHERE artifact_id=@p_id);
    ELSE IF @p_entity_type='releases' SELECT @before=(SELECT artifact_id artifactId,version_no version,effective_dt effectiveDate,end_dt endDate,release_notes releaseNotes,status FROM GRAC_New.release WHERE release_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=(SELECT CONCAT(a.artifact_name,N' / ',r.version_no) FROM GRAC_New.release r JOIN GRAC_New.artifact a ON a.artifact_id=r.artifact_id WHERE r.release_id=@p_id);
    ELSE IF @p_entity_type='statement-classifications' SELECT @before=(SELECT release_id releaseId,classification_code code,classification_scheme scheme,classification_name name,description,display_order displayOrder,status FROM GRAC_New.statement_classification WHERE statement_classification_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=(SELECT classification_name FROM GRAC_New.statement_classification WHERE statement_classification_id=@p_id);
    ELSE IF @p_entity_type='source-structure' SELECT @before=(SELECT release_id releaseId,parent_node_id parentNodeId,node_type nodeType,node_reference reference,node_title title,description,display_order displayOrder,status FROM GRAC_New.source_structure_node WHERE structure_node_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=(SELECT CONCAT(node_reference,N' - ',node_title) FROM GRAC_New.source_structure_node WHERE structure_node_id=@p_id);
    ELSE IF @p_entity_type='framework-statements' SELECT @before=(SELECT release_id releaseId,structure_node_id structureNodeId,classification_id classificationId,statement_reference statementReference,statement_title statementTitle,statement_text statementText,statement_type statementType,remarks,display_order displayOrder,status FROM GRAC_New.framework_statement WHERE framework_statement_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=(SELECT CONCAT(statement_reference,N' - ',statement_title) FROM GRAC_New.framework_statement WHERE framework_statement_id=@p_id);
    ELSE IF @p_entity_type='controls' SELECT @before=(SELECT control_code code,control_name name,control_domain_id domainId,control_sub_domain_id subDomainId,description,objective,status FROM GRAC_New.control WHERE control_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=(SELECT CONCAT(control_code,N' - ',control_name) FROM GRAC_New.control WHERE control_id=@p_id);
   ELSE IF @p_entity_type='control-domains' SELECT @before=(SELECT domain_name name,description,status FROM GRAC_New.control_domain WHERE control_domain_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=(SELECT domain_name FROM GRAC_New.control_domain WHERE control_domain_id=@p_id);
   ELSE IF @p_entity_type='control-sub-domains' SELECT @before=(SELECT control_domain_id domainId,sub_domain_name name,description,status FROM GRAC_New.control_sub_domain WHERE control_sub_domain_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=(SELECT sub_domain_name FROM GRAC_New.control_sub_domain WHERE control_sub_domain_id=@p_id);
    ELSE IF @p_entity_type='requirements' SELECT @before=(SELECT requirement_code code,requirement_name name,requirement_statement statement,objective,COALESCE(keywords,N'') keywords,status FROM GRAC_New.requirement WHERE requirement_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=(SELECT CONCAT(requirement_code,N' - ',requirement_name) FROM GRAC_New.requirement WHERE requirement_id=@p_id);
    ELSE IF @p_entity_type='obligations' SELECT @before=(SELECT requirement_id requirementId,release_id releaseId,obligation_text obligationText,frequency_type frequencyType,retention_requirement retentionRequirement,evidence_requirement evidenceRequirement,status FROM GRAC_New.requirement_obligation WHERE obligation_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=(SELECT COALESCE(NULLIF(obligation_text,N''),CONCAT(N'Obligation #',obligation_id)) FROM GRAC_New.requirement_obligation WHERE obligation_id=@p_id);
   ELSE IF @p_entity_type='applicability-rules' SELECT @before=(SELECT artifact_id artifactId,release_id releaseId,rule_name name,rule_expression_json expression,priority_no priority,outcome,status FROM GRAC_New.applicability_rule WHERE applicability_rule_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=(SELECT rule_name FROM GRAC_New.applicability_rule WHERE applicability_rule_id=@p_id);
    ELSE IF @p_entity_type='changes' SELECT @before=(SELECT entity_type entityType,entity_id entityId,change_type changeType,change_summary summary,effective_dt effectiveDate,severity,status FROM GRAC_New.change_event WHERE change_event_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=(SELECT CONCAT(N'CHG-',change_event_id) FROM GRAC_New.change_event WHERE change_event_id=@p_id);
    ELSE IF @p_entity_type='impact-analysis' SELECT @before=(SELECT change_event_id changeEventId,impacted_entity_type impactedEntityType,impacted_entity_id impactedEntityId,organization_id organizationId,impact_summary summary,recommended_action recommendedAction,status FROM GRAC_New.impact_analysis WHERE impact_analysis_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=(SELECT CONCAT(N'IMP-',impact_analysis_id) FROM GRAC_New.impact_analysis WHERE impact_analysis_id=@p_id);
    ELSE IF @p_entity_type='notifications' SELECT @before=(SELECT impact_analysis_id impactAnalysisId,organization_id organizationId,notification_type type,subject,message_body message,severity,recommended_action recommendedAction,status FROM GRAC_New.notification WHERE notification_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=(SELECT subject FROM GRAC_New.notification WHERE notification_id=@p_id);
    ELSE IF @p_entity_type='approval-workflow' SELECT @before=(SELECT module_name moduleName,maker_roles makerRoles,maker_users makerUsers,checker_roles checkerRoles,checker_users checkerUsers,approval_required approvalRequired,self_approval_allowed selfApprovalAllowed,minimum_approvers minimumApprovers,status FROM GRAC_New.approval_workflow_config WHERE workflow_config_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=(SELECT module_name FROM GRAC_New.approval_workflow_config WHERE workflow_config_id=@p_id);
    ELSE IF @p_entity_type='user-management' SELECT @before=(SELECT user_name userName,login_id loginId,email,password_hash passwordHash,status,remarks FROM GRAC_New.cm_user WHERE user_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=(SELECT CONCAT(user_name,N' - ',login_id) FROM GRAC_New.cm_user WHERE user_id=@p_id);
    ELSE IF @p_entity_type='role-management' SELECT @before=(SELECT role_name roleName,description,status FROM GRAC_New.cm_role WHERE role_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=(SELECT role_name FROM GRAC_New.cm_role WHERE role_id=@p_id);
    ELSE IF @p_entity_type='menu-management' SELECT @before=(SELECT parent_menu_id parentMenuId,menu_name menuName,menu_code menuCode,route_url routeUrl,display_order displayOrder,icon,status FROM GRAC_New.cm_menu WHERE menu_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=(SELECT menu_name FROM GRAC_New.cm_menu WHERE menu_id=@p_id);
    ELSE IF @p_entity_type='role-permissions' SELECT @before=(SELECT role_id roleId,menu_id menuId,can_view canView,can_add canAdd,can_edit canEdit,can_inactive canInactive,can_approve canApprove,status FROM GRAC_New.cm_role_permission WHERE role_permission_id=@p_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=(SELECT CONCAT(r.role_name,N' / ',m.menu_name) FROM GRAC_New.cm_role_permission rp JOIN GRAC_New.cm_role r ON r.role_id=rp.role_id JOIN GRAC_New.cm_menu m ON m.menu_id=rp.menu_id WHERE rp.role_permission_id=@p_id);
  END

  IF @p_entity_type='change-management'
  BEGIN
    DECLARE @change_status NVARCHAR(40), @target_entity_type NVARCHAR(100), @target_action_type NVARCHAR(30), @target_record_id BIGINT, @target_payload NVARCHAR(MAX), @target_maker NVARCHAR(100), @checker_comments NVARCHAR(MAX)=NULLIF(JSON_VALUE(@p_payload,'$.comments'),N'');
    SELECT @change_status=status,@target_entity_type=entity_type,@target_action_type=CASE action_type WHEN 'Inactive' THEN 'RETIRE' WHEN 'Activate' THEN 'ACTIVATE' ELSE 'SAVE' END,@target_record_id=COALESCE(record_id,0),@target_payload=proposed_data_json,@target_maker=maker_user
    FROM GRAC_New.change_management WHERE change_request_id=@p_id;
    IF @change_status IS NULL THROW 50006,'A valid change request identifier is required',1;
    IF @change_status<>'Pending Approval' THROW 50007,'Only pending change requests can be actioned',1;
    IF @p_action IN ('REJECT','SEND_BACK') AND @checker_comments IS NULL THROW 50026,'Checker comments are mandatory.',1;

    -- ------------------------------------------------------------------
    -- Bundle interception (031/032).
    --
    -- A composite save (e.g. the merged Obligation Master form) emits ONE
    -- change_management row per sub-entity, tied together by bundle_id.
    -- Those rows MUST be actioned as a unit -- approving the master while
    -- rejecting its typed detail would leave a half-configured record,
    -- which is precisely what the bundle exists to prevent.
    --
    -- So: if the change request the checker clicked belongs to a bundle,
    -- delegate to the bundle procedures, which lock every row in the
    -- bundle and apply / reject them atomically.  The checker can click
    -- ANY row of the bundle and get the same, whole-bundle outcome.
    --
    -- bundle_id is declared by this script's own CREATE TABLE (and back-filled
    -- by the guarded ALTER above), so it is always present.  When 031 has not
    -- been applied the sp_cm_change_bundle_* procedures do not exist -- but
    -- nothing writes bundle_id in that case either, so this branch stays dark.
    -- ------------------------------------------------------------------
    DECLARE @cm_bundle_id UNIQUEIDENTIFIER =
      (SELECT bundle_id FROM GRAC_New.change_management WHERE change_request_id = @p_id);

    IF @cm_bundle_id IS NOT NULL
    BEGIN
      -- The bundle procedures own their own transaction, so release the one
      -- this procedure opened before handing control over.
      COMMIT;

      IF @p_action = 'APPROVE'
        EXEC dbo.sp_cm_change_bundle_approve
             @p_bundle_id = @cm_bundle_id, @p_usr_id = @p_usr_id, @p_comments = @checker_comments;
      ELSE IF @p_action = 'REJECT'
        EXEC dbo.sp_cm_change_bundle_reject
             @p_bundle_id = @cm_bundle_id, @p_usr_id = @p_usr_id, @p_comments = @checker_comments;
      ELSE IF @p_action = 'SEND_BACK'
        EXEC dbo.sp_cm_change_bundle_send_back
             @p_bundle_id = @cm_bundle_id, @p_usr_id = @p_usr_id, @p_comments = @checker_comments;
      ELSE
        THROW 50007,'Unsupported change management action',1;

      SELECT @p_id Id; RETURN;
    END

    IF @p_action='APPROVE'
    BEGIN
      -- Resolve the canonical module identity via cm_entity_master so the workflow
      -- lookup never depends on raw text. entity_code is the slug stored in
      -- change_management.entity_type when the change was raised.
      DECLARE @target_entity_id BIGINT=(SELECT TOP 1 entity_id FROM GRAC_New.cm_entity_master WHERE entity_code=@target_entity_type AND status='Active');
      DECLARE @self_approval_allowed BIT=COALESCE((
        SELECT TOP 1 awc.self_approval_allowed
        FROM GRAC_New.approval_workflow_config awc
        WHERE awc.status='Active' AND awc.entity_id=@target_entity_id
      ),0);
      IF @self_approval_allowed=0 AND @target_maker=@p_usr_id THROW 50027,'Self approval is not allowed for this module.',1;
      DECLARE @apply_payload NVARCHAR(MAX)=JSON_MODIFY(COALESCE(@target_payload,N'{}'),'$.__approvalBypass',1);
      DECLARE @draft_parent_value BIGINT=NULL, @resolved_parent_id BIGINT=NULL, @resolved_parent_status NVARCHAR(40)=NULL;
      IF @target_entity_type='artifacts'
      BEGIN
        SET @draft_parent_value=TRY_CONVERT(BIGINT,JSON_VALUE(@apply_payload,'$.authorityId'));
        IF @draft_parent_value<0
        BEGIN
          SELECT @resolved_parent_id=applied_record_id,@resolved_parent_status=status
          FROM GRAC_New.change_management
          WHERE change_request_id=ABS(@draft_parent_value) AND entity_type='authorities' AND action_type='Add';
          IF @resolved_parent_status='Rejected' THROW 50036,'Parent change request was rejected. Child change request cannot be approved.',1;
          IF @resolved_parent_status<>'Approved' OR @resolved_parent_id IS NULL THROW 50035,'Approve the parent Authority change request before approving this Artifact.',1;
          SET @apply_payload=JSON_MODIFY(@apply_payload,'$.authorityId',@resolved_parent_id);
        END
      END
      ELSE IF @target_entity_type='releases'
      BEGIN
        SET @draft_parent_value=TRY_CONVERT(BIGINT,JSON_VALUE(@apply_payload,'$.artifactId'));
        IF @draft_parent_value<0
        BEGIN
          SELECT @resolved_parent_id=applied_record_id,@resolved_parent_status=status
          FROM GRAC_New.change_management
          WHERE change_request_id=ABS(@draft_parent_value) AND entity_type='artifacts' AND action_type='Add';
          IF @resolved_parent_status='Rejected' THROW 50036,'Parent change request was rejected. Child change request cannot be approved.',1;
          IF @resolved_parent_status<>'Approved' OR @resolved_parent_id IS NULL THROW 50035,'Approve the parent Artifact change request before approving this Release.',1;
          SET @apply_payload=JSON_MODIFY(@apply_payload,'$.artifactId',@resolved_parent_id);
        END
      END
      SET @apply_payload=JSON_MODIFY(@apply_payload,'$.remarks',CONCAT(N'Maker: ',@target_maker,N'; Checker: ',@p_usr_id,CASE WHEN @checker_comments IS NULL THEN N'' ELSE CONCAT(N'; Comments: ',@checker_comments) END));
      DECLARE @apply_result TABLE(Id BIGINT);
      INSERT @apply_result(Id)
      EXEC dbo.cm_manage_repository @p_entity_type=@target_entity_type,@p_action=@target_action_type,@p_id=@target_record_id,@p_search=N'',@p_status=N'',@p_payload=@apply_payload,@p_usr_id=@p_usr_id;
      DECLARE @applied_record_id BIGINT=(SELECT TOP 1 Id FROM @apply_result);
      UPDATE GRAC_New.change_management SET status='Approved',applied_record_id=COALESCE(@applied_record_id,applied_record_id),checker_user=@p_usr_id,checked_dt=SYSUTCDATETIME(),checker_comments=@checker_comments,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE change_request_id=@p_id;
      INSERT GRAC_New.approval_action(entity_type,entity_id,action_type,comments,entered_by) VALUES('change-management',@p_id,'APPROVE',@checker_comments,@p_usr_id);
    END
    ELSE IF @p_action='REJECT'
    BEGIN
      UPDATE GRAC_New.change_management SET status='Rejected',checker_user=@p_usr_id,checked_dt=SYSUTCDATETIME(),checker_comments=@checker_comments,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE change_request_id=@p_id;
      IF @target_entity_type='authorities'
      BEGIN
        UPDATE rel SET status='Rejected',checker_user=@p_usr_id,checked_dt=SYSUTCDATETIME(),checker_comments=COALESCE(@checker_comments,N'Parent Authority change request was rejected.'),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
        FROM GRAC_New.change_management rel
        JOIN GRAC_New.change_management art ON art.change_request_id=rel.parent_change_request_id
        WHERE art.parent_change_request_id=@p_id AND rel.entity_type='releases' AND rel.status='Pending Approval';

        UPDATE GRAC_New.change_management
        SET status='Rejected',checker_user=@p_usr_id,checked_dt=SYSUTCDATETIME(),checker_comments=COALESCE(@checker_comments,N'Parent Authority change request was rejected.'),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
        WHERE parent_change_request_id=@p_id AND entity_type='artifacts' AND status='Pending Approval';
      END
      ELSE IF @target_entity_type='artifacts'
      BEGIN
        UPDATE GRAC_New.change_management
        SET status='Rejected',checker_user=@p_usr_id,checked_dt=SYSUTCDATETIME(),checker_comments=COALESCE(@checker_comments,N'Parent Artifact change request was rejected.'),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
        WHERE parent_change_request_id=@p_id AND entity_type='releases' AND status='Pending Approval';
      END
      INSERT GRAC_New.approval_action(entity_type,entity_id,action_type,comments,entered_by) VALUES('change-management',@p_id,'REJECT',@checker_comments,@p_usr_id);
    END
    ELSE IF @p_action='SEND_BACK'
    BEGIN
      UPDATE GRAC_New.change_management SET status='Sent Back',checker_user=@p_usr_id,checked_dt=SYSUTCDATETIME(),checker_comments=@checker_comments,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE change_request_id=@p_id;
      INSERT GRAC_New.approval_action(entity_type,entity_id,action_type,comments,entered_by) VALUES('change-management',@p_id,'SEND_BACK',@checker_comments,@p_usr_id);
    END
    ELSE THROW 50007,'Unsupported change management action',1;
    COMMIT; SELECT @p_id Id; RETURN;
  END

  DECLARE @approval_bypass BIT=CASE WHEN JSON_VALUE(@p_payload,'$.__approvalBypass') IN ('1','true','True') THEN 1 ELSE 0 END;
  -- Resolve module identity from cm_entity_master so every workflow decision below
  -- joins on a stable id instead of comparing text.  Fall back to the hard-coded
  -- slug list if the master row is missing for backwards compatibility.
  DECLARE @entity_master_id BIGINT=(SELECT TOP 1 entity_id FROM GRAC_New.cm_entity_master WHERE entity_code=@p_entity_type AND status='Active');
  DECLARE @maker_checker_entity BIT=COALESCE(
    (SELECT TOP 1 is_maker_checker FROM GRAC_New.cm_entity_master WHERE entity_id=@entity_master_id),
    CASE WHEN @p_entity_type IN ('authorities','artifacts','releases','statement-classifications','source-structure','framework-statements','controls','requirements','obligations','control-requirement-mappings','source-control-mappings','applicability-rules') THEN 1 ELSE 0 END);
  -- For the regulatory entities a missing workflow row defaults to "approval required" (legacy behaviour).
  -- For Access Administration (user/role/menu/role-permissions) we require an explicit workflow row to opt in,
  -- otherwise simple admin saves would unexpectedly route through change_management.
  DECLARE @approval_required BIT=COALESCE((
    SELECT TOP 1 approval_required FROM GRAC_New.approval_workflow_config WHERE status='Active' AND entity_id=@entity_master_id
  ), CASE WHEN @p_entity_type IN ('authorities','artifacts','releases','statement-classifications','source-structure','framework-statements','controls','requirements','obligations','control-requirement-mappings','source-control-mappings','applicability-rules') THEN 1 ELSE 0 END);
  IF @maker_checker_entity=1 AND @approval_bypass=0 AND @approval_required=1 AND @p_action IN ('SAVE','RETIRE','ACTIVATE')
  BEGIN
    DECLARE @change_action NVARCHAR(30)=CASE WHEN @p_action='RETIRE' THEN N'Inactive' WHEN @p_action='ACTIVATE' THEN N'Activate' WHEN @p_id=0 THEN N'Add' ELSE N'Edit' END;
    DECLARE @retire_status NVARCHAR(30)=CASE WHEN @p_entity_type IN ('user-management','role-management','menu-management','role-permissions','approval-workflow') THEN N'Inactive' ELSE N'Retired' END;
    DECLARE @change_payload NVARCHAR(MAX)=CASE WHEN @p_action='RETIRE' THEN JSON_MODIFY(N'{}','$.status',@retire_status) WHEN @p_action='ACTIVATE' THEN JSON_MODIFY(N'{}','$.status',N'Active') ELSE @p_payload END;
    DECLARE @change_id BIGINT, @parent_change_request_id BIGINT=NULL;
    IF @change_action='Add' AND @p_entity_type='artifacts'
    BEGIN
      DECLARE @draft_authority_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@change_payload,'$.authorityId'));
      IF @draft_authority_id<0 SET @parent_change_request_id=ABS(@draft_authority_id);
      SET @record_reference=COALESCE(@record_reference,CONCAT(NULLIF(JSON_VALUE(@change_payload,'$.code'),N''),N' - ',NULLIF(JSON_VALUE(@change_payload,'$.name'),N'')));
    END
    ELSE IF @change_action='Add' AND @p_entity_type='releases'
    BEGIN
      DECLARE @draft_artifact_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@change_payload,'$.artifactId'));
      IF @draft_artifact_id<0 SET @parent_change_request_id=ABS(@draft_artifact_id);
      SET @record_reference=COALESCE(@record_reference,CONCAT(N'Release ',NULLIF(JSON_VALUE(@change_payload,'$.version'),N'')));
    END
    ELSE IF @change_action='Add' AND @p_entity_type='authorities'
    BEGIN
      SET @record_reference=COALESCE(@record_reference,CONCAT(NULLIF(JSON_VALUE(@change_payload,'$.code'),N''),N' - ',NULLIF(JSON_VALUE(@change_payload,'$.name'),N'')));
    END
    IF @record_reference IS NULL SET @record_reference=CASE WHEN @p_id>0 THEN CONCAT(N'Record ID: ',@p_id) ELSE CONCAT(@p_entity_type,N' new record') END;
    INSERT GRAC_New.change_management(module_name,entity_type,entity_id,action_type,record_id,record_reference,old_data_json,proposed_data_json,maker_user,parent_change_request_id,entered_by)
    VALUES(@p_entity_type,@p_entity_type,@entity_master_id,@change_action,NULLIF(@p_id,0),@record_reference,@before,@change_payload,@p_usr_id,@parent_change_request_id,@p_usr_id);
    SET @change_id=SCOPE_IDENTITY();
    IF @change_action='Add' AND @p_entity_type IN ('authorities','artifacts','releases')
      UPDATE GRAC_New.change_management SET draft_reference_id=-@change_id WHERE change_request_id=@change_id;
    IF @change_action='Inactive'
      INSERT GRAC_New.change_management_field(change_request_id,field_name,old_value,new_value)
      VALUES(@change_id,N'Status',JSON_VALUE(@before,'$.status'),@retire_status);
    ELSE IF @change_action='Add'
      INSERT GRAC_New.change_management_field(change_request_id,field_name,old_value,new_value)
      SELECT @change_id,CASE [key]
        WHEN N'code' THEN N'Code' WHEN N'name' THEN N'Name' WHEN N'status' THEN N'Status'
        WHEN N'classificationId' THEN N'Statement Classification'
        WHEN N'statementReference' THEN N'Statement Reference' WHEN N'statementTitle' THEN N'Statement Title'
        WHEN N'obligationText' THEN N'Obligation Name' ELSE UPPER(LEFT([key],1))+SUBSTRING([key],2,200) END,NULL,CONVERT(NVARCHAR(MAX),[value])
      FROM OPENJSON(@change_payload)
      WHERE LEFT([key],2)<>N'__';
    ELSE
    BEGIN
      ;WITH before_values AS (
        SELECT [key],CONVERT(NVARCHAR(MAX),[value]) old_value
        FROM OPENJSON(@before)
        WHERE LEFT([key],2)<>N'__'
      ),
      after_values AS (
        SELECT [key],CONVERT(NVARCHAR(MAX),[value]) new_value
        FROM OPENJSON(@change_payload)
        WHERE LEFT([key],2)<>N'__'
      ),
      changed AS (
        SELECT COALESCE(a.[key],b.[key]) field_key,b.old_value,a.new_value
        FROM after_values a
        FULL OUTER JOIN before_values b ON b.[key]=a.[key]
        WHERE ISNULL(b.old_value,N'')<>ISNULL(a.new_value,N'')
      )
      INSERT GRAC_New.change_management_field(change_request_id,field_name,old_value,new_value)
      SELECT @change_id,CASE field_key
        WHEN N'code' THEN N'Code' WHEN N'name' THEN N'Name' WHEN N'status' THEN N'Status'
        WHEN N'classificationId' THEN N'Statement Classification'
        WHEN N'statementReference' THEN N'Statement Reference' WHEN N'statementTitle' THEN N'Statement Title'
        WHEN N'obligationText' THEN N'Obligation Name' ELSE UPPER(LEFT(field_key,1))+SUBSTRING(field_key,2,200) END,
        old_value,new_value
      FROM changed;
    END

    -- Auto-approve branch: when the workflow row has self_approval_allowed=1 AND
    -- the API has confirmed the maker holds APPROVE permission for this area
    -- (signalled via the __autoApproveAllowed payload flag), apply the change
    -- immediately rather than parking it as 'Pending Approval'.  We skip the
    -- shortcut when the request depends on a still-draft parent (artifacts that
    -- reference a draft authorityId, releases that reference a draft artifactId)
    -- because the main-table apply would fail until the parent is in place.
    DECLARE @workflow_self_approval BIT = COALESCE(
      (SELECT TOP 1 self_approval_allowed FROM GRAC_New.approval_workflow_config WHERE status='Active' AND entity_id=@entity_master_id), 0);
    DECLARE @auto_approve_allowed BIT = CASE WHEN JSON_VALUE(@p_payload,'$.__autoApproveAllowed') IN ('1','true','True') THEN 1 ELSE 0 END;

    IF @workflow_self_approval=1 AND @auto_approve_allowed=1 AND @parent_change_request_id IS NULL
    BEGIN
      -- Apply via self-recursive call with bypass flag set so the gate is skipped.
      DECLARE @apply_payload_auto NVARCHAR(MAX) = JSON_MODIFY(COALESCE(@change_payload, N'{}'), '$.__approvalBypass', 1);
      DECLARE @apply_action_auto NVARCHAR(30)   = CASE WHEN @change_action=N'Inactive' THEN N'RETIRE' WHEN @change_action=N'Activate' THEN N'ACTIVATE' ELSE N'SAVE' END;
      DECLARE @apply_result_auto TABLE(Id BIGINT);
      INSERT @apply_result_auto(Id)
      EXEC dbo.cm_manage_repository
        @p_entity_type=@p_entity_type,
        @p_action=@apply_action_auto,
        @p_id=@p_id,
        @p_search=N'', @p_status=N'',
        @p_payload=@apply_payload_auto,
        @p_usr_id=@p_usr_id;
      DECLARE @applied_record_id_auto BIGINT = (SELECT TOP 1 Id FROM @apply_result_auto);

      UPDATE GRAC_New.change_management
      SET status            = N'Auto Approved',
          applied_record_id = COALESCE(@applied_record_id_auto, applied_record_id),
          checker_user      = @p_usr_id,
          checked_dt        = SYSUTCDATETIME(),
          checker_comments  = N'Auto-approved: Self Approval is enabled and the maker holds APPROVE permission for this module.',
          updated_by        = @p_usr_id,
          updated_dt        = SYSUTCDATETIME()
      WHERE change_request_id = @change_id;

      INSERT GRAC_New.approval_action(entity_type, entity_id, action_type, comments, entered_by)
      VALUES (N'change-management', @change_id, N'AUTO_APPROVE',
              N'Auto Self Approval (workflow.self_approval_allowed=1 and maker has APPROVE permission).',
              @p_usr_id);

      COMMIT;
      SELECT @change_id Id, N'Auto Approved' Status, COALESCE(@applied_record_id_auto, 0) AppliedRecordId;
      RETURN;
    END

    COMMIT; SELECT @change_id Id,N'Pending Approval' Status; RETURN;
  END

  IF @p_action='APPROVE'
  BEGIN
    IF @p_id<=0 THROW 50006,'A valid record identifier is required',1;
    IF @p_entity_type NOT IN ('changes','impact-analysis')
       THROW 50007,'Approval is not configured for this repository area',1;
    INSERT GRAC_New.approval_action(entity_type,entity_id,action_type,comments,entered_by)
    VALUES(@p_entity_type,@p_id,'APPROVE',JSON_VALUE(@p_payload,'$.comments'),@p_usr_id);
  END
 ELSE IF @p_action='RETIRE'
 BEGIN
   IF @p_entity_type='authorities' UPDATE GRAC_New.authority SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE authority_id=@p_id;
   ELSE IF @p_entity_type='artifacts' UPDATE GRAC_New.artifact SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE artifact_id=@p_id;
   ELSE IF @p_entity_type='releases' UPDATE GRAC_New.release SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE release_id=@p_id;
   ELSE IF @p_entity_type='statement-classifications' UPDATE GRAC_New.statement_classification SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE statement_classification_id=@p_id;
   ELSE IF @p_entity_type='controls' UPDATE GRAC_New.control SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE control_id=@p_id;
   ELSE IF @p_entity_type='control-domains' UPDATE GRAC_New.control_domain SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE control_domain_id=@p_id;
   ELSE IF @p_entity_type='control-sub-domains' UPDATE GRAC_New.control_sub_domain SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE control_sub_domain_id=@p_id;
   ELSE IF @p_entity_type='requirements' UPDATE GRAC_New.requirement SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE requirement_id=@p_id;
   ELSE IF @p_entity_type='obligations'
   BEGIN
     UPDATE GRAC_New.obligation SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE obligation_id=@p_id;
     UPDATE GRAC_New.obligation_evidence_type SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE obligation_id=@p_id AND status='Active';
   END
   ELSE IF @p_entity_type='source-structure' UPDATE GRAC_New.source_structure_node SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE structure_node_id=@p_id;
   ELSE IF @p_entity_type='framework-statements' UPDATE GRAC_New.framework_statement SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE framework_statement_id=@p_id;
   ELSE IF @p_entity_type='applicability-rules' UPDATE GRAC_New.applicability_rule SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE applicability_rule_id=@p_id;
   ELSE IF @p_entity_type='control-requirement-mappings' UPDATE GRAC_New.control_requirement_map SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE control_requirement_map_id=@p_id;
   ELSE IF @p_entity_type='source-control-mappings'
   BEGIN
     -- The Practices - Statement Mapping tree retires
     -- framework_statement_requirement_map rows; the legacy tree retires
     -- framework_statement_control_map rows; and the Add/Edit Control in-form
     -- section retires source_control_map rows.  The @p_id in each case comes
     -- from that table's identity, so try each in order and stop as soon as a
     -- row is updated -- this keeps overlapping identity ranges safe.
     UPDATE GRAC_New.framework_statement_requirement_map SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE statement_requirement_map_id=@p_id AND status='Active';
     IF @@ROWCOUNT=0
     BEGIN
       UPDATE GRAC_New.framework_statement_control_map SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE statement_control_map_id=@p_id AND status='Active';
       IF @@ROWCOUNT=0
         UPDATE GRAC_New.source_control_map SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE source_control_map_id=@p_id;
     END
   END
    ELSE IF @p_entity_type='changes' UPDATE GRAC_New.change_event SET status='Archived',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE change_event_id=@p_id;
    ELSE IF @p_entity_type='impact-analysis' UPDATE GRAC_New.impact_analysis SET status='Archived',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE impact_analysis_id=@p_id;
    ELSE IF @p_entity_type='notifications' UPDATE GRAC_New.notification SET status='Archived',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE notification_id=@p_id;
    ELSE IF @p_entity_type='approval-workflow' UPDATE GRAC_New.approval_workflow_config SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE workflow_config_id=@p_id;
    ELSE IF @p_entity_type='user-management' UPDATE GRAC_New.cm_user SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE user_id=@p_id;
    ELSE IF @p_entity_type='role-management' UPDATE GRAC_New.cm_role SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE role_id=@p_id;
    ELSE IF @p_entity_type='menu-management' UPDATE GRAC_New.cm_menu SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE menu_id=@p_id;
    ELSE IF @p_entity_type='role-permissions' UPDATE GRAC_New.cm_role_permission SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE role_permission_id=@p_id;
    ELSE THROW 50002,'Retirement is not configured for this repository area',1;
   -- ---------------------------------------------------------------
   -- Cascade (048).  Take the subtree down with the parent, and record
   -- what was taken down so ACTIVATE can put back exactly these rows.
   -- Descendants that were already inactive are left alone and NOT
   -- recorded, so re-activating never revives something the user had
   -- deliberately switched off earlier.
   -- ---------------------------------------------------------------
   IF @p_entity_type IN ('authorities','artifacts','releases','source-structure','framework-statements')
   BEGIN
     DECLARE @cascade_id UNIQUEIDENTIFIER=NEWID();
     DECLARE @cascade_scope TABLE(EntityType NVARCHAR(100), RecordId BIGINT, CurrentStatus NVARCHAR(30));
     -- Anything not already inactive comes down.  Draft counts: a live Draft
     -- Release under a Retired Artifact is just as wrong as an Active one.
     -- previous_status is recorded per row, so restore is faithful either way.
     INSERT @cascade_scope(EntityType,RecordId,CurrentStatus)
     SELECT EntityType,RecordId,CurrentStatus
     FROM dbo.fn_cm_repository_descendant_status(@p_entity_type,@p_id)
     WHERE CurrentStatus NOT IN ('Retired','Inactive','Archived');

     IF EXISTS(SELECT 1 FROM @cascade_scope)
     BEGIN
       INSERT GRAC_New.cm_cascade_deactivation(cascade_id,root_entity_type,root_record_id,child_entity_type,child_record_id,previous_status,entered_by)
       SELECT @cascade_id,@p_entity_type,@p_id,EntityType,RecordId,CurrentStatus,@p_usr_id FROM @cascade_scope;

       UPDATE t SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.artifact t JOIN @cascade_scope c ON c.EntityType=N'artifacts' AND c.RecordId=t.artifact_id;

       UPDATE t SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.release t JOIN @cascade_scope c ON c.EntityType=N'releases' AND c.RecordId=t.release_id;

       UPDATE t SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.source_structure_node t JOIN @cascade_scope c ON c.EntityType=N'source-structure' AND c.RecordId=t.structure_node_id;

       UPDATE t SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.statement_classification t JOIN @cascade_scope c ON c.EntityType=N'statement-classifications' AND c.RecordId=t.statement_classification_id;

       UPDATE t SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.framework_statement t JOIN @cascade_scope c ON c.EntityType=N'framework-statements' AND c.RecordId=t.framework_statement_id;

       UPDATE t SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.source_control_map t JOIN @cascade_scope c ON c.EntityType=N'source-control-map' AND c.RecordId=t.source_control_map_id;

       UPDATE t SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.framework_statement_control_map t JOIN @cascade_scope c ON c.EntityType=N'statement-control-map' AND c.RecordId=t.statement_control_map_id;

       UPDATE t SET status='Retired',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.framework_statement_requirement_map t JOIN @cascade_scope c ON c.EntityType=N'statement-requirement-map' AND c.RecordId=t.statement_requirement_map_id;
     END
   END
 END
 ELSE IF @p_action='ACTIVATE'
 BEGIN
   -- Re-enable a record that was previously marked Inactive / Retired.  This is
   -- the mirror of the RETIRE branch above and is reached the same way: the
   -- 3-dots menu offers Activate instead of Inactive once a row is no longer
   -- Active, and (for the maker-checker areas) the request lands here only
   -- after a checker has approved the 'Activate' change request.
   --
   -- Hierarchy rule: a record cannot be re-activated while an ancestor is still
   -- inactive, otherwise the grids end up showing an active child hanging off a
   -- retired parent.  Each guard names the parent so the maker knows exactly
   -- what to activate first.
   DECLARE @activated INT=0;
   IF @p_entity_type='authorities'
   BEGIN
     UPDATE GRAC_New.authority SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE authority_id=@p_id AND status<>'Active';
     SET @activated=@@ROWCOUNT;
   END
   ELSE IF @p_entity_type='artifacts'
   BEGIN
     IF NOT EXISTS(SELECT 1 FROM GRAC_New.artifact a JOIN GRAC_New.authority au ON au.authority_id=a.authority_id WHERE a.artifact_id=@p_id AND au.status='Active')
       THROW 50110,'Activate the parent Regulatory Authority first.',1;
     UPDATE GRAC_New.artifact SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE artifact_id=@p_id AND status<>'Active';
     SET @activated=@@ROWCOUNT;
   END
   ELSE IF @p_entity_type='releases'
   BEGIN
     IF NOT EXISTS(SELECT 1 FROM GRAC_New.release r JOIN GRAC_New.artifact a ON a.artifact_id=r.artifact_id WHERE r.release_id=@p_id AND a.status='Active')
       THROW 50111,'Activate the parent Regulatory Artifact first.',1;
     UPDATE GRAC_New.release SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE release_id=@p_id AND status<>'Active';
     SET @activated=@@ROWCOUNT;
   END
   ELSE IF @p_entity_type='source-structure'
   BEGIN
     IF NOT EXISTS(SELECT 1 FROM GRAC_New.source_structure_node n JOIN GRAC_New.release r ON r.release_id=n.release_id WHERE n.structure_node_id=@p_id AND r.status='Active')
       THROW 50112,'Activate the parent Artifact Release first.',1;
     IF EXISTS(SELECT 1 FROM GRAC_New.source_structure_node n JOIN GRAC_New.source_structure_node p ON p.structure_node_id=n.parent_node_id WHERE n.structure_node_id=@p_id AND p.status<>'Active')
       THROW 50113,'Activate the parent Source Structure node first.',1;
     UPDATE GRAC_New.source_structure_node SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE structure_node_id=@p_id AND status<>'Active';
     SET @activated=@@ROWCOUNT;
   END
   ELSE IF @p_entity_type='statement-classifications'
   BEGIN
     UPDATE GRAC_New.statement_classification SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE statement_classification_id=@p_id AND status<>'Active';
     SET @activated=@@ROWCOUNT;
   END
   ELSE IF @p_entity_type='framework-statements'
   BEGIN
     IF NOT EXISTS(SELECT 1 FROM GRAC_New.framework_statement s JOIN GRAC_New.source_structure_node n ON n.structure_node_id=s.structure_node_id WHERE s.framework_statement_id=@p_id AND n.status='Active')
       THROW 50114,'Activate the parent Source Structure node first.',1;
     UPDATE GRAC_New.framework_statement SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE framework_statement_id=@p_id AND status<>'Active';
     SET @activated=@@ROWCOUNT;
   END
   ELSE IF @p_entity_type='controls'
   BEGIN
     UPDATE GRAC_New.control SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE control_id=@p_id AND status<>'Active';
     SET @activated=@@ROWCOUNT;
   END
   ELSE IF @p_entity_type='control-domains'
   BEGIN
     UPDATE GRAC_New.control_domain SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE control_domain_id=@p_id AND status<>'Active';
     SET @activated=@@ROWCOUNT;
   END
   ELSE IF @p_entity_type='control-sub-domains'
   BEGIN
     IF NOT EXISTS(SELECT 1 FROM GRAC_New.control_sub_domain s JOIN GRAC_New.control_domain d ON d.control_domain_id=s.control_domain_id WHERE s.control_sub_domain_id=@p_id AND d.status='Active')
       THROW 50115,'Activate the parent Control Domain first.',1;
     UPDATE GRAC_New.control_sub_domain SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE control_sub_domain_id=@p_id AND status<>'Active';
     SET @activated=@@ROWCOUNT;
   END
   ELSE IF @p_entity_type='requirements'
   BEGIN
     UPDATE GRAC_New.requirement SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE requirement_id=@p_id AND status<>'Active';
     SET @activated=@@ROWCOUNT;
   END
   ELSE IF @p_entity_type='obligations'
   BEGIN
     UPDATE GRAC_New.obligation SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE obligation_id=@p_id AND status<>'Active';
     SET @activated=@@ROWCOUNT;
   END
   ELSE IF @p_entity_type='applicability-rules'
   BEGIN
     UPDATE GRAC_New.applicability_rule SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE applicability_rule_id=@p_id AND status<>'Active';
     SET @activated=@@ROWCOUNT;
   END
   ELSE IF @p_entity_type='control-requirement-mappings'
   BEGIN
     IF NOT EXISTS(SELECT 1 FROM GRAC_New.control_requirement_map m JOIN GRAC_New.control c ON c.control_id=m.control_id JOIN GRAC_New.requirement r ON r.requirement_id=m.requirement_id WHERE m.control_requirement_map_id=@p_id AND c.status='Active' AND r.status='Active')
       THROW 50116,'Activate the mapped Control and Practice first.',1;
     UPDATE GRAC_New.control_requirement_map SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE control_requirement_map_id=@p_id AND status<>'Active';
     SET @activated=@@ROWCOUNT;
   END
   ELSE IF @p_entity_type='source-control-mappings'
   BEGIN
     -- Mirrors the RETIRE branch: the same @p_id may belong to any of the three
     -- mapping tables, so try each in turn and stop at the first hit.  Each is
     -- guarded so a mapping never comes back active with an inactive end.
     IF EXISTS(SELECT 1 FROM GRAC_New.framework_statement_requirement_map WHERE statement_requirement_map_id=@p_id AND status<>'Active')
     BEGIN
       IF NOT EXISTS(SELECT 1 FROM GRAC_New.framework_statement_requirement_map m JOIN GRAC_New.framework_statement s ON s.framework_statement_id=m.framework_statement_id JOIN GRAC_New.requirement r ON r.requirement_id=m.requirement_id WHERE m.statement_requirement_map_id=@p_id AND s.status='Active' AND r.status='Active')
         THROW 50117,'Activate the mapped Framework Statement and Practice first.',1;
       UPDATE GRAC_New.framework_statement_requirement_map SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE statement_requirement_map_id=@p_id;
       SET @activated=@@ROWCOUNT;
     END
     ELSE IF EXISTS(SELECT 1 FROM GRAC_New.framework_statement_control_map WHERE statement_control_map_id=@p_id AND status<>'Active')
     BEGIN
       IF NOT EXISTS(SELECT 1 FROM GRAC_New.framework_statement_control_map m JOIN GRAC_New.framework_statement s ON s.framework_statement_id=m.framework_statement_id JOIN GRAC_New.control c ON c.control_id=m.control_id WHERE m.statement_control_map_id=@p_id AND s.status='Active' AND c.status='Active')
         THROW 50118,'Activate the mapped Framework Statement and Control first.',1;
       UPDATE GRAC_New.framework_statement_control_map SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE statement_control_map_id=@p_id;
       SET @activated=@@ROWCOUNT;
     END
     ELSE
     BEGIN
       IF NOT EXISTS(SELECT 1 FROM GRAC_New.source_control_map m JOIN GRAC_New.source_structure_node n ON n.structure_node_id=m.structure_node_id JOIN GRAC_New.control c ON c.control_id=m.control_id WHERE m.source_control_map_id=@p_id AND n.status='Active' AND c.status='Active')
         THROW 50119,'Activate the mapped Source Structure node and Control first.',1;
       UPDATE GRAC_New.source_control_map SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE source_control_map_id=@p_id AND status<>'Active';
       SET @activated=@@ROWCOUNT;
     END
   END
   ELSE IF @p_entity_type='approval-workflow'
   BEGIN
     UPDATE GRAC_New.approval_workflow_config SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE workflow_config_id=@p_id AND status<>'Active';
     SET @activated=@@ROWCOUNT;
   END
   ELSE IF @p_entity_type='user-management'
   BEGIN
     UPDATE GRAC_New.cm_user SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE user_id=@p_id AND status<>'Active';
     SET @activated=@@ROWCOUNT;
   END
   ELSE IF @p_entity_type='role-management'
   BEGIN
     UPDATE GRAC_New.cm_role SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE role_id=@p_id AND status<>'Active';
     SET @activated=@@ROWCOUNT;
   END
   ELSE IF @p_entity_type='menu-management'
   BEGIN
     UPDATE GRAC_New.cm_menu SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE menu_id=@p_id AND status<>'Active';
     SET @activated=@@ROWCOUNT;
   END
   ELSE IF @p_entity_type='role-permissions'
   BEGIN
     UPDATE GRAC_New.cm_role_permission SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE role_permission_id=@p_id AND status<>'Active';
     SET @activated=@@ROWCOUNT;
   END
   ELSE THROW 50120,'Activation is not configured for this repository area',1;
   IF @activated=0 THROW 50121,'This record is already Active.',1;
   -- ---------------------------------------------------------------
   -- Restore (048).  Put back exactly the rows this record's most recent
   -- cascade took down -- nothing that was already inactive beforehand,
   -- and nothing deactivated by a different event.  Each child returns to
   -- the status it held before the cascade ran.
   -- ---------------------------------------------------------------
   IF @p_entity_type IN ('authorities','artifacts','releases','source-structure','framework-statements')
   BEGIN
     DECLARE @restore_cascade_id UNIQUEIDENTIFIER=
       (SELECT TOP 1 cascade_id FROM GRAC_New.cm_cascade_deactivation
        WHERE root_entity_type=@p_entity_type AND root_record_id=@p_id AND restored_dt IS NULL
        ORDER BY cascade_row_id DESC);
     IF @restore_cascade_id IS NOT NULL
     BEGIN
       UPDATE t SET status=c.previous_status,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.artifact t JOIN GRAC_New.cm_cascade_deactivation c
         ON c.cascade_id=@restore_cascade_id AND c.restored_dt IS NULL AND c.child_entity_type=N'artifacts' AND c.child_record_id=t.artifact_id;

       UPDATE t SET status=c.previous_status,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.release t JOIN GRAC_New.cm_cascade_deactivation c
         ON c.cascade_id=@restore_cascade_id AND c.restored_dt IS NULL AND c.child_entity_type=N'releases' AND c.child_record_id=t.release_id;

       UPDATE t SET status=c.previous_status,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.source_structure_node t JOIN GRAC_New.cm_cascade_deactivation c
         ON c.cascade_id=@restore_cascade_id AND c.restored_dt IS NULL AND c.child_entity_type=N'source-structure' AND c.child_record_id=t.structure_node_id;

       UPDATE t SET status=c.previous_status,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.statement_classification t JOIN GRAC_New.cm_cascade_deactivation c
         ON c.cascade_id=@restore_cascade_id AND c.restored_dt IS NULL AND c.child_entity_type=N'statement-classifications' AND c.child_record_id=t.statement_classification_id;

       UPDATE t SET status=c.previous_status,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.framework_statement t JOIN GRAC_New.cm_cascade_deactivation c
         ON c.cascade_id=@restore_cascade_id AND c.restored_dt IS NULL AND c.child_entity_type=N'framework-statements' AND c.child_record_id=t.framework_statement_id;

       UPDATE t SET status=c.previous_status,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.source_control_map t JOIN GRAC_New.cm_cascade_deactivation c
         ON c.cascade_id=@restore_cascade_id AND c.restored_dt IS NULL AND c.child_entity_type=N'source-control-map' AND c.child_record_id=t.source_control_map_id;

       UPDATE t SET status=c.previous_status,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.framework_statement_control_map t JOIN GRAC_New.cm_cascade_deactivation c
         ON c.cascade_id=@restore_cascade_id AND c.restored_dt IS NULL AND c.child_entity_type=N'statement-control-map' AND c.child_record_id=t.statement_control_map_id;

       UPDATE t SET status=c.previous_status,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.framework_statement_requirement_map t JOIN GRAC_New.cm_cascade_deactivation c
         ON c.cascade_id=@restore_cascade_id AND c.restored_dt IS NULL AND c.child_entity_type=N'statement-requirement-map' AND c.child_record_id=t.statement_requirement_map_id;

       UPDATE GRAC_New.cm_cascade_deactivation
       SET restored_dt=SYSUTCDATETIME(), restored_by=@p_usr_id
       WHERE cascade_id=@restore_cascade_id AND restored_dt IS NULL;
     END
   END
 END
 ELSE IF @p_entity_type='authorities'
 BEGIN
   DECLARE @authority_code NVARCHAR(80)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.code'))),'');
   IF @authority_code IS NULL THROW 50008,'Authority Code is required.',1;
   IF EXISTS(SELECT 1 FROM GRAC_New.authority WHERE authority_code=@authority_code AND authority_id<>@p_id) THROW 50009,'Authority Code already exists.',1;
   IF @p_id=0
   BEGIN
     DECLARE @authority_next_order INT = ISNULL((SELECT MAX(display_order) FROM GRAC_New.authority), 0) + 1;
     INSERT GRAC_New.authority(authority_code,authority_name,description,jurisdiction,website,display_order,status,entered_by)
     VALUES(@authority_code,JSON_VALUE(@p_payload,'$.name'),JSON_VALUE(@p_payload,'$.description'),JSON_VALUE(@p_payload,'$.jurisdiction'),JSON_VALUE(@p_payload,'$.website'),@authority_next_order,COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE GRAC_New.authority SET authority_code=@authority_code,authority_name=JSON_VALUE(@p_payload,'$.name'),description=JSON_VALUE(@p_payload,'$.description'),jurisdiction=JSON_VALUE(@p_payload,'$.jurisdiction'),website=JSON_VALUE(@p_payload,'$.website'),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE authority_id=@p_id;
 END
 ELSE IF @p_entity_type='controls'
 BEGIN
   DECLARE @control_domain_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.domainId'),''));
   DECLARE @control_sub_domain_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.subDomainId'),''));
   IF @control_sub_domain_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM GRAC_New.control_sub_domain WHERE control_sub_domain_id=@control_sub_domain_id AND (@control_domain_id IS NULL OR control_domain_id=@control_domain_id)) THROW 50018,'The selected Sub Domain is invalid for the selected Domain.',1;
   IF @p_id=0 BEGIN INSERT GRAC_New.control(control_code,control_name,control_domain_id,control_sub_domain_id,description,objective,status,entered_by) VALUES(JSON_VALUE(@p_payload,'$.code'),JSON_VALUE(@p_payload,'$.name'),@control_domain_id,@control_sub_domain_id,JSON_VALUE(@p_payload,'$.description'),JSON_VALUE(@p_payload,'$.objective'),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),@p_usr_id); SET @new_id=SCOPE_IDENTITY(); END
   ELSE UPDATE GRAC_New.control SET control_code=JSON_VALUE(@p_payload,'$.code'),control_name=JSON_VALUE(@p_payload,'$.name'),control_domain_id=@control_domain_id,control_sub_domain_id=@control_sub_domain_id,description=JSON_VALUE(@p_payload,'$.description'),objective=JSON_VALUE(@p_payload,'$.objective'),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE control_id=@p_id;
   UPDATE k SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
   FROM GRAC_New.control_keyword k
   WHERE k.control_id=@new_id AND k.status='Active'
     AND NOT EXISTS(SELECT 1 FROM OPENJSON(@p_payload,'$.keywords') j WHERE LOWER(LTRIM(RTRIM(j.[value])))=LOWER(k.keyword));
   UPDATE k SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
   FROM GRAC_New.control_keyword k
   JOIN OPENJSON(@p_payload,'$.keywords') j ON LOWER(LTRIM(RTRIM(j.[value])))=LOWER(k.keyword)
   WHERE k.control_id=@new_id AND k.status<>'Active';
    INSERT GRAC_New.control_keyword(control_id,keyword,status,entered_by)
    SELECT DISTINCT @new_id,LTRIM(RTRIM(j.[value])),'Active',@p_usr_id
    FROM OPENJSON(@p_payload,'$.keywords') j
    WHERE NULLIF(LTRIM(RTRIM(j.[value])),'') IS NOT NULL
      AND NOT EXISTS(SELECT 1 FROM GRAC_New.control_keyword k WHERE k.control_id=@new_id AND LOWER(k.keyword)=LOWER(LTRIM(RTRIM(j.[value]))));
    IF ISJSON(JSON_QUERY(@p_payload,'$.sourceStructureNodeIds'))=1
    BEGIN
      UPDATE m SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
      FROM GRAC_New.source_control_map m
      WHERE m.control_id=@new_id AND m.status='Active'
        AND NOT EXISTS(SELECT 1 FROM OPENJSON(@p_payload,'$.sourceStructureNodeIds') j WHERE TRY_CONVERT(BIGINT,j.[value])=m.structure_node_id);
      UPDATE m SET status='Active',release_id=n.release_id,artifact_id=r.artifact_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
      FROM GRAC_New.source_control_map m
      JOIN OPENJSON(@p_payload,'$.sourceStructureNodeIds') j ON TRY_CONVERT(BIGINT,j.[value])=m.structure_node_id
      JOIN GRAC_New.source_structure_node n ON n.structure_node_id=m.structure_node_id
      JOIN GRAC_New.release r ON r.release_id=n.release_id
      WHERE m.control_id=@new_id AND m.status<>'Active';
      INSERT GRAC_New.source_control_map(structure_node_id,control_id,release_id,artifact_id,status,entered_by)
      SELECT DISTINCT n.structure_node_id,@new_id,n.release_id,r.artifact_id,'Active',@p_usr_id
      FROM OPENJSON(@p_payload,'$.sourceStructureNodeIds') j
      JOIN GRAC_New.source_structure_node n ON n.structure_node_id=TRY_CONVERT(BIGINT,j.[value])
      JOIN GRAC_New.release r ON r.release_id=n.release_id
      WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.source_control_map m WHERE m.structure_node_id=n.structure_node_id AND m.control_id=@new_id);
    END
  END
 ELSE IF @p_entity_type='control-domains'
 BEGIN
   IF @p_id=0 BEGIN INSERT GRAC_New.control_domain(domain_name,description,status,entered_by) VALUES(JSON_VALUE(@p_payload,'$.name'),JSON_VALUE(@p_payload,'$.description'),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),@p_usr_id); SET @new_id=SCOPE_IDENTITY(); END
   ELSE UPDATE GRAC_New.control_domain SET domain_name=JSON_VALUE(@p_payload,'$.name'),description=JSON_VALUE(@p_payload,'$.description'),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE control_domain_id=@p_id;
 END
 ELSE IF @p_entity_type='control-sub-domains'
 BEGIN
   IF @p_id=0 BEGIN INSERT GRAC_New.control_sub_domain(control_domain_id,sub_domain_name,description,status,entered_by) VALUES(JSON_VALUE(@p_payload,'$.domainId'),JSON_VALUE(@p_payload,'$.name'),JSON_VALUE(@p_payload,'$.description'),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),@p_usr_id); SET @new_id=SCOPE_IDENTITY(); END
   ELSE UPDATE GRAC_New.control_sub_domain SET control_domain_id=JSON_VALUE(@p_payload,'$.domainId'),sub_domain_name=JSON_VALUE(@p_payload,'$.name'),description=JSON_VALUE(@p_payload,'$.description'),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE control_sub_domain_id=@p_id;
 END
 ELSE IF @p_entity_type='requirements'
 BEGIN
   -- Normalize the incoming Keywords tag list into a de-duplicated,
   -- lower-trimmed CSV so the "similar records" search stays cheap and the
   -- stored value is stable across submissions.  Accepts either an array
   -- (from the JS tags widget) or a plain comma-separated string.
   DECLARE @req_keywords NVARCHAR(MAX) = NULL;
   IF ISJSON(JSON_QUERY(@p_payload,'$.keywords')) = 1
     SELECT @req_keywords = STRING_AGG(kw, N', ')
     FROM (
       SELECT DISTINCT LTRIM(RTRIM(j.[value])) kw
       FROM OPENJSON(@p_payload,'$.keywords') j
       WHERE NULLIF(LTRIM(RTRIM(j.[value])),'') IS NOT NULL
     ) d;
   ELSE
     SET @req_keywords = NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.keywords'))), N'');

   -- Practice Code (050) is system-generated: PR-001, PR-002, PR-003 ...
   -- The Add Practice form no longer collects it.  A caller may still supply
   -- one (bulk upload keeps its Code column); anything blank is filled with
   -- the next free PR-### number, continuing from the highest one in use.
   -- UPDLOCK + HOLDLOCK serialize concurrent inserts inside the surrounding
   -- transaction so two sessions cannot claim the same number.
   DECLARE @practice_code NVARCHAR(100) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.code'))), N'');
   IF @p_id=0 AND @practice_code IS NULL
   BEGIN
     DECLARE @practice_no INT;
     SELECT @practice_no = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(requirement_code, 4, 50))), 0) + 1
     FROM GRAC_New.requirement WITH (UPDLOCK, HOLDLOCK)
     WHERE requirement_code LIKE N'PR-[0-9]%'
       AND TRY_CONVERT(INT, SUBSTRING(requirement_code, 4, 50)) IS NOT NULL;
     SET @practice_code = CONCAT(N'PR-', FORMAT(@practice_no, N'000'));
     -- Defensive: skip any PR-### already taken by a legacy hand-typed code.
     WHILE EXISTS(SELECT 1 FROM GRAC_New.requirement WHERE requirement_code=@practice_code)
     BEGIN
       SET @practice_no = @practice_no + 1;
       SET @practice_code = CONCAT(N'PR-', FORMAT(@practice_no, N'000'));
     END
   END
   IF @p_id=0 BEGIN INSERT GRAC_New.requirement(requirement_code,requirement_name,requirement_statement,objective,keywords,status,entered_by) VALUES(@practice_code,JSON_VALUE(@p_payload,'$.name'),JSON_VALUE(@p_payload,'$.statement'),JSON_VALUE(@p_payload,'$.objective'),@req_keywords,COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),@p_usr_id); SET @new_id=SCOPE_IDENTITY(); END
   -- On update the code is never cleared: a payload without a Code keeps the
   -- code the Practice already has.
   ELSE UPDATE GRAC_New.requirement SET requirement_code=COALESCE(@practice_code,requirement_code),requirement_name=JSON_VALUE(@p_payload,'$.name'),requirement_statement=JSON_VALUE(@p_payload,'$.statement'),objective=JSON_VALUE(@p_payload,'$.objective'),keywords=@req_keywords,status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE requirement_id=@p_id;
  IF ISJSON(JSON_QUERY(@p_payload,'$.controlIds'))=1
  BEGIN
     UPDATE m SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     FROM GRAC_New.control_requirement_map m
     WHERE m.requirement_id=@new_id AND m.status='Active'
       AND NOT EXISTS(SELECT 1 FROM OPENJSON(@p_payload,'$.controlIds') j WHERE TRY_CONVERT(BIGINT,j.[value])=m.control_id);
     UPDATE m SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     FROM GRAC_New.control_requirement_map m
     JOIN OPENJSON(@p_payload,'$.controlIds') j ON TRY_CONVERT(BIGINT,j.[value])=m.control_id
     WHERE m.requirement_id=@new_id AND m.status<>'Active';
     INSERT GRAC_New.control_requirement_map(control_id,requirement_id,status,entered_by)
     SELECT DISTINCT TRY_CONVERT(BIGINT,j.[value]),@new_id,'Active',@p_usr_id
     FROM OPENJSON(@p_payload,'$.controlIds') j
     WHERE TRY_CONVERT(BIGINT,j.[value]) IS NOT NULL
      AND NOT EXISTS(SELECT 1 FROM GRAC_New.control_requirement_map m WHERE m.requirement_id=@new_id AND m.control_id=TRY_CONVERT(BIGINT,j.[value]));
  END
  IF ISJSON(JSON_QUERY(@p_payload,'$.statementIds'))=1
  BEGIN
    UPDATE m SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
    FROM GRAC_New.framework_statement_requirement_map m
    WHERE m.requirement_id=@new_id AND m.status='Active'
      AND NOT EXISTS(SELECT 1 FROM OPENJSON(@p_payload,'$.statementIds') j WHERE TRY_CONVERT(BIGINT,j.[value])=m.framework_statement_id);
    UPDATE m SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
    FROM GRAC_New.framework_statement_requirement_map m
    JOIN OPENJSON(@p_payload,'$.statementIds') j ON TRY_CONVERT(BIGINT,j.[value])=m.framework_statement_id
    WHERE m.requirement_id=@new_id AND m.status<>'Active';
    INSERT GRAC_New.framework_statement_requirement_map(framework_statement_id,requirement_id,status,entered_by)
    SELECT DISTINCT TRY_CONVERT(BIGINT,j.[value]),@new_id,'Active',@p_usr_id
    FROM OPENJSON(@p_payload,'$.statementIds') j
    WHERE TRY_CONVERT(BIGINT,j.[value]) IS NOT NULL
      AND EXISTS(SELECT 1 FROM GRAC_New.framework_statement fs WHERE fs.framework_statement_id=TRY_CONVERT(BIGINT,j.[value]) AND fs.status='Active')
      AND NOT EXISTS(SELECT 1 FROM GRAC_New.framework_statement_requirement_map m WHERE m.requirement_id=@new_id AND m.framework_statement_id=TRY_CONVERT(BIGINT,j.[value]));
  END
END
 ELSE IF @p_entity_type='artifacts'
 BEGIN
    DECLARE @artifact_code NVARCHAR(100)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.code'))),'');
    DECLARE @artifact_authority_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.authorityId'));
    IF @artifact_code IS NULL THROW 50010,'Artifact Code is required.',1;
    IF @artifact_authority_id IS NULL OR @artifact_authority_id<=0 THROW 50035,'Approve the parent Authority change request before saving this Artifact.',1;
    IF EXISTS(SELECT 1 FROM GRAC_New.artifact WHERE artifact_code=@artifact_code AND artifact_id<>@p_id) THROW 50011,'Artifact Code already exists.',1;
   IF EXISTS(SELECT 1 FROM OPENJSON(@p_payload,'$.industries') j LEFT JOIN GRAC_New.reference_option o ON o.option_group='industries' AND o.option_value=j.[value] AND o.status='Active' WHERE o.reference_option_id IS NULL) THROW 50012,'The selected Industry is invalid.',1;
   IF EXISTS(SELECT 1 FROM OPENJSON(@p_payload,'$.jurisdictions') j LEFT JOIN GRAC_New.reference_option o ON o.option_group='jurisdictions' AND o.option_value=j.[value] AND o.status='Active' WHERE o.reference_option_id IS NULL) THROW 50013,'The selected Jurisdiction is invalid.',1;
    IF @p_id=0
    BEGIN
      DECLARE @artifact_next_order INT = ISNULL((SELECT MAX(display_order) FROM GRAC_New.artifact WHERE authority_id=@artifact_authority_id), 0) + 1;
      INSERT GRAC_New.artifact(authority_id,artifact_code,artifact_name,description,artifact_category,industry,jurisdiction,display_order,status,entered_by)
      VALUES(@artifact_authority_id,@artifact_code,JSON_VALUE(@p_payload,'$.name'),JSON_VALUE(@p_payload,'$.description'),JSON_VALUE(@p_payload,'$.category'),JSON_VALUE(@p_payload,'$.industries[0]'),JSON_VALUE(@p_payload,'$.jurisdictions[0]'),@artifact_next_order,COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),@p_usr_id);
      SET @new_id=SCOPE_IDENTITY();
    END
    ELSE UPDATE GRAC_New.artifact SET authority_id=@artifact_authority_id,artifact_code=@artifact_code,artifact_name=JSON_VALUE(@p_payload,'$.name'),description=JSON_VALUE(@p_payload,'$.description'),artifact_category=JSON_VALUE(@p_payload,'$.category'),industry=JSON_VALUE(@p_payload,'$.industries[0]'),jurisdiction=JSON_VALUE(@p_payload,'$.jurisdictions[0]'),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE artifact_id=@p_id;
   UPDATE m SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() FROM GRAC_New.artifact_industry_map m WHERE m.artifact_id=@new_id AND m.status='Active' AND NOT EXISTS(SELECT 1 FROM OPENJSON(@p_payload,'$.industries') j JOIN GRAC_New.reference_option o ON o.option_group='industries' AND o.option_value=j.[value] WHERE o.reference_option_id=m.reference_option_id);
   UPDATE m SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() FROM GRAC_New.artifact_industry_map m JOIN GRAC_New.reference_option o ON o.reference_option_id=m.reference_option_id JOIN OPENJSON(@p_payload,'$.industries') j ON j.[value]=o.option_value WHERE m.artifact_id=@new_id AND m.status<>'Active';
   INSERT GRAC_New.artifact_industry_map(artifact_id,reference_option_id,status,entered_by) SELECT DISTINCT @new_id,o.reference_option_id,'Active',@p_usr_id FROM OPENJSON(@p_payload,'$.industries') j JOIN GRAC_New.reference_option o ON o.option_group='industries' AND o.option_value=j.[value] WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.artifact_industry_map m WHERE m.artifact_id=@new_id AND m.reference_option_id=o.reference_option_id);
   UPDATE m SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() FROM GRAC_New.artifact_jurisdiction_map m WHERE m.artifact_id=@new_id AND m.status='Active' AND NOT EXISTS(SELECT 1 FROM OPENJSON(@p_payload,'$.jurisdictions') j JOIN GRAC_New.reference_option o ON o.option_group='jurisdictions' AND o.option_value=j.[value] WHERE o.reference_option_id=m.reference_option_id);
   UPDATE m SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() FROM GRAC_New.artifact_jurisdiction_map m JOIN GRAC_New.reference_option o ON o.reference_option_id=m.reference_option_id JOIN OPENJSON(@p_payload,'$.jurisdictions') j ON j.[value]=o.option_value WHERE m.artifact_id=@new_id AND m.status<>'Active';
   INSERT GRAC_New.artifact_jurisdiction_map(artifact_id,reference_option_id,status,entered_by) SELECT DISTINCT @new_id,o.reference_option_id,'Active',@p_usr_id FROM OPENJSON(@p_payload,'$.jurisdictions') j JOIN GRAC_New.reference_option o ON o.option_group='jurisdictions' AND o.option_value=j.[value] WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.artifact_jurisdiction_map m WHERE m.artifact_id=@new_id AND m.reference_option_id=o.reference_option_id);
 END
 ELSE IF @p_entity_type='releases'
 BEGIN
    DECLARE @release_artifact_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.artifactId'));
    IF @release_artifact_id IS NULL OR @release_artifact_id<=0 THROW 50035,'Approve the parent Artifact change request before saving this Release.',1;
    IF @p_id=0
    BEGIN
      DECLARE @release_next_order INT = ISNULL((SELECT MAX(display_order) FROM GRAC_New.release WHERE artifact_id=@release_artifact_id), 0) + 1;
      INSERT GRAC_New.release(artifact_id,version_no,effective_dt,end_dt,release_notes,display_order,status,entered_by)
      VALUES(@release_artifact_id,JSON_VALUE(@p_payload,'$.version'),NULLIF(JSON_VALUE(@p_payload,'$.effectiveDate'),''),NULLIF(JSON_VALUE(@p_payload,'$.endDate'),''),JSON_VALUE(@p_payload,'$.releaseNotes'),@release_next_order,COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),@p_usr_id);
      SET @new_id=SCOPE_IDENTITY();
    END
    ELSE UPDATE GRAC_New.release SET artifact_id=@release_artifact_id,version_no=JSON_VALUE(@p_payload,'$.version'),effective_dt=NULLIF(JSON_VALUE(@p_payload,'$.effectiveDate'),''),end_dt=NULLIF(JSON_VALUE(@p_payload,'$.endDate'),''),release_notes=JSON_VALUE(@p_payload,'$.releaseNotes'),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE release_id=@p_id;
  END
 ELSE IF @p_entity_type='statement-classifications'
 BEGIN
   DECLARE @classification_release_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.releaseId'));
   DECLARE @classification_scheme NVARCHAR(200)=NULLIF(LTRIM(RTRIM(COALESCE(JSON_VALUE(@p_payload,'$.scheme'),JSON_VALUE(@p_payload,'$.classificationScheme')))),'');
   DECLARE @classification_name NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @classification_code NVARCHAR(80)=LEFT(COALESCE(NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.code'))),''),@classification_name),80);
   IF @classification_release_id IS NULL THROW 50038,'Release is required for Statement Classification.',1;
   IF @classification_name IS NULL THROW 50039,'Classification Name is required.',1;
   IF EXISTS(SELECT 1 FROM GRAC_New.statement_classification WHERE release_id=@classification_release_id AND classification_code=@classification_code AND statement_classification_id<>@p_id)
     THROW 50040,'Classification Name already exists for this Release.',1;
   IF @p_id=0
   BEGIN
     INSERT GRAC_New.statement_classification(release_id,classification_code,classification_scheme,classification_name,description,display_order,status,entered_by)
     VALUES(@classification_release_id,@classification_code,@classification_scheme,@classification_name,JSON_VALUE(@p_payload,'$.description'),COALESCE(TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.displayOrder'),'')),0),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
   BEGIN
     UPDATE GRAC_New.statement_classification
       SET release_id=@classification_release_id,
           classification_code=@classification_code,
           classification_scheme=@classification_scheme,
           classification_name=@classification_name,
           description=JSON_VALUE(@p_payload,'$.description'),
           display_order=COALESCE(TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.displayOrder'),'')),display_order),
           status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),
           updated_by=@p_usr_id,
           updated_dt=SYSUTCDATETIME()
     WHERE statement_classification_id=@p_id;
     SET @new_id=@p_id;
   END
 END
 ELSE IF @p_entity_type='source-structure'
 BEGIN
   DECLARE @source_release_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.releaseId'));
   DECLARE @source_parent_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.parentNodeId'),''));
   DECLARE @source_node_level INT=1;
   IF @source_parent_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM GRAC_New.source_structure_node WHERE structure_node_id=@source_parent_id AND release_id=@source_release_id) THROW 50014,'Parent node must belong to the selected release.',1;
   IF @source_parent_id IS NOT NULL SELECT @source_node_level=node_level+1 FROM GRAC_New.source_structure_node WHERE structure_node_id=@source_parent_id;
   IF @p_id=0
   BEGIN
     -- Root nodes (parent NULL) are sequenced within the Release; child nodes are
     -- sequenced within their parent.  ISNULL(MAX,0)+1 starts at 1 when the
     -- scope is empty.
     DECLARE @source_next_order INT =
       ISNULL((SELECT MAX(display_order)
               FROM GRAC_New.source_structure_node
               WHERE release_id = @source_release_id
                 AND (@source_parent_id IS NULL AND parent_node_id IS NULL
                      OR @source_parent_id IS NOT NULL AND parent_node_id = @source_parent_id)), 0) + 1;
     INSERT GRAC_New.source_structure_node(release_id,parent_node_id,node_level,node_type,node_reference,node_title,description,display_order,status,entered_by)
     VALUES(@source_release_id,@source_parent_id,@source_node_level,JSON_VALUE(@p_payload,'$.nodeType'),JSON_VALUE(@p_payload,'$.reference'),JSON_VALUE(@p_payload,'$.title'),JSON_VALUE(@p_payload,'$.description'),@source_next_order,COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE GRAC_New.source_structure_node SET release_id=@source_release_id,parent_node_id=@source_parent_id,node_level=@source_node_level,node_type=JSON_VALUE(@p_payload,'$.nodeType'),node_reference=JSON_VALUE(@p_payload,'$.reference'),node_title=JSON_VALUE(@p_payload,'$.title'),description=JSON_VALUE(@p_payload,'$.description'),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE structure_node_id=@p_id;
 END
 ELSE IF @p_entity_type='framework-statements'
 BEGIN
   DECLARE @statement_release_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.releaseId'));
   DECLARE @statement_node_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.structureNodeId'));
   DECLARE @statement_classification_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.classificationId'),''));
   DECLARE @statement_reference NVARCHAR(160)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.statementReference'))),'');
   IF @statement_release_id IS NULL THROW 50021,'Release is required for Framework Statement.',1;
   IF @statement_node_id IS NULL THROW 50022,'Source Structure Node is required for Framework Statement.',1;
   IF @statement_reference IS NULL THROW 50023,'Statement Reference is required.',1;
   IF NOT EXISTS(SELECT 1 FROM GRAC_New.source_structure_node WHERE structure_node_id=@statement_node_id AND release_id=@statement_release_id)
     THROW 50024,'Source Structure Node must belong to the selected Release.',1;
   IF @statement_classification_id IS NOT NULL
      AND NOT EXISTS(SELECT 1 FROM GRAC_New.statement_classification WHERE statement_classification_id=@statement_classification_id AND release_id=@statement_release_id AND status='Active')
     THROW 50041,'Statement Classification must belong to the selected Release.',1;
   IF EXISTS(SELECT 1 FROM GRAC_New.framework_statement WHERE release_id=@statement_release_id AND statement_reference=@statement_reference AND framework_statement_id<>@p_id)
     THROW 50025,'Statement Reference already exists for this Release.',1;
   IF @p_id=0
   BEGIN
     -- Statements are sequenced within their Source Structure Node.
     DECLARE @statement_next_order INT =
       ISNULL((SELECT MAX(display_order)
               FROM GRAC_New.framework_statement
               WHERE structure_node_id = @statement_node_id), 0) + 1;
     INSERT GRAC_New.framework_statement(release_id,structure_node_id,classification_id,statement_reference,statement_title,statement_text,statement_type,remarks,display_order,status,entered_by)
     VALUES(@statement_release_id,@statement_node_id,@statement_classification_id,@statement_reference,JSON_VALUE(@p_payload,'$.statementTitle'),JSON_VALUE(@p_payload,'$.statementText'),JSON_VALUE(@p_payload,'$.statementType'),JSON_VALUE(@p_payload,'$.remarks'),@statement_next_order,COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
   BEGIN
     -- display_order is no longer user-editable; auto-assigned once at insert.
     UPDATE GRAC_New.framework_statement
       SET release_id=@statement_release_id,
           structure_node_id=@statement_node_id,
           classification_id=@statement_classification_id,
           statement_reference=@statement_reference,
           statement_title=JSON_VALUE(@p_payload,'$.statementTitle'),
           statement_text=JSON_VALUE(@p_payload,'$.statementText'),
           -- Statement Type was removed from the Source Statement form (it was
           -- free text nothing read back).  The column and any bulk-uploaded
           -- values stay, so preserve what is stored when the payload omits the
           -- key instead of nulling it on every edit.
           statement_type=COALESCE(JSON_VALUE(@p_payload,'$.statementType'),statement_type),
           remarks=JSON_VALUE(@p_payload,'$.remarks'),
           status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),
           updated_by=@p_usr_id,
           updated_dt=SYSUTCDATETIME()
     WHERE framework_statement_id=@p_id;
     SET @new_id=@p_id;
   END
 END
ELSE IF @p_entity_type='obligation-mappings'
 BEGIN
   -- Single-row mapping: maps an Obligation to (Requirement, Release, Statement).
   -- Payload: { obligationId, requirementId, releaseId, frameworkStatementId?, status }
   DECLARE @om_obligation_id BIGINT = TRY_CONVERT(BIGINT, JSON_VALUE(@p_payload, '$.obligationId'));
   DECLARE @om_requirement_id BIGINT = TRY_CONVERT(BIGINT, JSON_VALUE(@p_payload, '$.requirementId'));
   DECLARE @om_release_id BIGINT = TRY_CONVERT(BIGINT, JSON_VALUE(@p_payload, '$.releaseId'));
   DECLARE @om_statement_id BIGINT = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload, '$.frameworkStatementId'), N''));
   DECLARE @om_status NVARCHAR(30) = COALESCE(NULLIF(JSON_VALUE(@p_payload, '$.status'), N''), 'Active');

   IF @om_obligation_id IS NULL OR @om_obligation_id <= 0
     THROW 50060, 'Obligation is required.', 1;
   IF @om_requirement_id IS NULL OR @om_requirement_id <= 0
     THROW 50061, 'Requirement is required.', 1;
   IF @om_release_id IS NULL OR @om_release_id <= 0
     THROW 50062, 'Release is required.', 1;
   IF NOT EXISTS(SELECT 1 FROM GRAC_New.requirement_obligation WHERE obligation_id=@om_obligation_id)
     THROW 50060, 'Obligation is required.', 1;
   IF NOT EXISTS(SELECT 1 FROM GRAC_New.requirement WHERE requirement_id=@om_requirement_id)
     THROW 50061, 'Requirement is required.', 1;
   IF NOT EXISTS(SELECT 1 FROM GRAC_New.release WHERE release_id=@om_release_id)
     THROW 50062, 'Release is required.', 1;
   IF @om_statement_id IS NOT NULL
      AND NOT EXISTS(SELECT 1 FROM GRAC_New.framework_statement
                     WHERE framework_statement_id=@om_statement_id AND release_id=@om_release_id)
     THROW 50065, 'Framework Statement must belong to the selected Release.', 1;

   IF @p_id=0
   BEGIN
     -- Idempotent upsert keyed on the 4-tuple.
     DECLARE @om_existing BIGINT = (
       SELECT TOP 1 obligation_map_id FROM GRAC_New.obligation_requirement_release_map
        WHERE obligation_id=@om_obligation_id
          AND requirement_id=@om_requirement_id
          AND release_id=@om_release_id
          AND ISNULL(framework_statement_id, -1) = ISNULL(@om_statement_id, -1));
     IF @om_existing IS NOT NULL
     BEGIN
       UPDATE GRAC_New.obligation_requirement_release_map
       SET status=@om_status, updated_by=@p_usr_id, updated_dt=SYSUTCDATETIME()
       WHERE obligation_map_id=@om_existing;
       SET @new_id=@om_existing;
       SET @audit_action=N'Edit';
     END
     ELSE
     BEGIN
       INSERT GRAC_New.obligation_requirement_release_map(obligation_id, requirement_id, release_id, framework_statement_id, status, entered_by)
       VALUES(@om_obligation_id, @om_requirement_id, @om_release_id, @om_statement_id, @om_status, @p_usr_id);
       SET @new_id=SCOPE_IDENTITY();
     END
   END
   ELSE
   BEGIN
     IF EXISTS(SELECT 1 FROM GRAC_New.obligation_requirement_release_map
               WHERE obligation_id=@om_obligation_id
                 AND requirement_id=@om_requirement_id
                 AND release_id=@om_release_id
                 AND ISNULL(framework_statement_id, -1) = ISNULL(@om_statement_id, -1)
                 AND obligation_map_id<>@p_id)
       THROW 50063, 'This obligation is already mapped to the selected Requirement, Release and Statement.', 1;
     UPDATE GRAC_New.obligation_requirement_release_map
     SET obligation_id=@om_obligation_id, requirement_id=@om_requirement_id, release_id=@om_release_id,
         framework_statement_id=@om_statement_id,
         status=@om_status, updated_by=@p_usr_id, updated_dt=SYSUTCDATETIME()
     WHERE obligation_map_id=@p_id;
   END
 END
 ELSE IF @p_entity_type='obligation-mapping-bulk'
 BEGIN
   -- Requirement-first matrix save.  Payload:
   --   { requirementId: <id>,
   --     mappings: [ { releaseId, frameworkStatementId, obligationId }, ... ] }
   -- Semantics: for the given Requirement, the supplied list is the new
   -- authoritative active set.  Anything currently active for this
   -- Requirement that is NOT in the list is deactivated.  Anything new is
   -- inserted.  Existing rows in the list stay active and are touched.
   DECLARE @bulk_requirement_id BIGINT = TRY_CONVERT(BIGINT, JSON_VALUE(@p_payload, '$.requirementId'));
   DECLARE @bulk_mappings NVARCHAR(MAX) = JSON_QUERY(@p_payload, '$.mappings');
   IF @bulk_requirement_id IS NULL OR @bulk_requirement_id <= 0
     THROW 50061, 'Requirement is required.', 1;
   IF NOT EXISTS(SELECT 1 FROM GRAC_New.requirement WHERE requirement_id=@bulk_requirement_id)
     THROW 50061, 'Requirement is required.', 1;

   DECLARE @bulk_rows TABLE(
     row_no INT IDENTITY PRIMARY KEY,
     release_id BIGINT NOT NULL,
     framework_statement_id BIGINT NULL,
     obligation_id BIGINT NOT NULL);

   IF @bulk_mappings IS NOT NULL
     INSERT @bulk_rows(release_id, framework_statement_id, obligation_id)
     SELECT TRY_CONVERT(BIGINT, JSON_VALUE(j.[value], '$.releaseId')),
            TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(j.[value], '$.frameworkStatementId'), N'')),
            TRY_CONVERT(BIGINT, JSON_VALUE(j.[value], '$.obligationId'))
     FROM OPENJSON(@bulk_mappings) j
     WHERE TRY_CONVERT(BIGINT, JSON_VALUE(j.[value], '$.obligationId')) IS NOT NULL
       AND TRY_CONVERT(BIGINT, JSON_VALUE(j.[value], '$.releaseId')) IS NOT NULL;

   -- Validate every release / statement / obligation in the payload.
   IF EXISTS(SELECT 1 FROM @bulk_rows b
             WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.requirement_obligation ro WHERE ro.obligation_id = b.obligation_id))
     THROW 50060, 'Obligation is required.', 1;
   IF EXISTS(SELECT 1 FROM @bulk_rows b
             WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.release r WHERE r.release_id = b.release_id))
     THROW 50062, 'Release is required.', 1;
   IF EXISTS(SELECT 1 FROM @bulk_rows b
             WHERE b.framework_statement_id IS NOT NULL
               AND NOT EXISTS(SELECT 1 FROM GRAC_New.framework_statement fs
                              WHERE fs.framework_statement_id = b.framework_statement_id
                                AND fs.release_id = b.release_id))
     THROW 50065, 'Framework Statement must belong to the selected Release.', 1;

   -- Block exact duplicates inside the payload (same release+stmt+obligation twice).
   IF EXISTS (
     SELECT release_id, ISNULL(framework_statement_id, -1) fs, obligation_id, COUNT(1) c
     FROM @bulk_rows
     GROUP BY release_id, ISNULL(framework_statement_id, -1), obligation_id
     HAVING COUNT(1) > 1)
     THROW 50063, 'The same Obligation is selected more than once on the same Statement/Release cell.', 1;

   -- Deactivate existing rows for this Requirement that are not in the payload.
   UPDATE existing
   SET status='Inactive', updated_by=@p_usr_id, updated_dt=SYSUTCDATETIME()
   FROM GRAC_New.obligation_requirement_release_map existing
   WHERE existing.requirement_id = @bulk_requirement_id
     AND existing.status = 'Active'
     AND NOT EXISTS (
         SELECT 1 FROM @bulk_rows b
         WHERE b.release_id = existing.release_id
           AND ISNULL(b.framework_statement_id, -1) = ISNULL(existing.framework_statement_id, -1)
           AND b.obligation_id = existing.obligation_id);

   -- Reactivate matching rows that already exist but were Inactive.
   UPDATE existing
   SET status='Active', updated_by=@p_usr_id, updated_dt=SYSUTCDATETIME()
   FROM GRAC_New.obligation_requirement_release_map existing
   JOIN @bulk_rows b
     ON b.release_id = existing.release_id
    AND ISNULL(b.framework_statement_id, -1) = ISNULL(existing.framework_statement_id, -1)
    AND b.obligation_id = existing.obligation_id
   WHERE existing.requirement_id = @bulk_requirement_id
     AND existing.status <> 'Active';

   -- Insert truly new mappings.
   INSERT GRAC_New.obligation_requirement_release_map(obligation_id, requirement_id, release_id, framework_statement_id, status, entered_by)
   SELECT b.obligation_id, @bulk_requirement_id, b.release_id, b.framework_statement_id, 'Active', @p_usr_id
   FROM @bulk_rows b
   WHERE NOT EXISTS (
       SELECT 1 FROM GRAC_New.obligation_requirement_release_map existing
       WHERE existing.requirement_id = @bulk_requirement_id
         AND existing.release_id = b.release_id
         AND ISNULL(existing.framework_statement_id, -1) = ISNULL(b.framework_statement_id, -1)
         AND existing.obligation_id = b.obligation_id);

   SET @new_id = @bulk_requirement_id;
 END
 ELSE IF @p_entity_type='obligations'
 BEGIN
   -- Obligation Master (post-019).  Standalone parent; the link to Requirement
   -- and Release lives in obligation_requirement_release_map.  Evidence rows
   -- remain a one-to-many child via requirement_obligation_evidence.
   -- NOTE on naming: the legacy "obligations" code (now behind the dead key
   -- 'obligations-legacy-framework-statement') still declares @ob_* variables.
   -- T-SQL hoists every DECLARE to procedure scope regardless of whether the
   -- branch is ever entered, so we use @obm_* (obligation master) here to keep
   -- the names unique across the procedure.
   DECLARE @obm_obligation_name NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.obligationName'))), N'');
   DECLARE @obm_execution_frequency_id BIGINT = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.executionFrequencyId'), N''));
   DECLARE @obm_retention_requirement NVARCHAR(250) = NULLIF(JSON_VALUE(@p_payload,'$.retentionRequirement'), N'');
   DECLARE @obm_remarks NVARCHAR(MAX) = JSON_VALUE(@p_payload,'$.remarks');
   DECLARE @obm_status NVARCHAR(30) = COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.status'), N''), 'Active');
   DECLARE @obm_active_status_id BIGINT = (SELECT TOP 1 reference_option_id FROM GRAC_New.reference_option WHERE option_group='status-active' AND option_value='Active');
   DECLARE @obm_evidence_json NVARCHAR(MAX) = JSON_QUERY(@p_payload,'$.evidenceRequirements');
   -- Keywords: accept either an array (tags widget) or a plain CSV string;
   -- persist a de-duplicated, trimmed CSV so search/exports stay stable.
   DECLARE @obm_keywords NVARCHAR(MAX) = NULL;
   IF ISJSON(JSON_QUERY(@p_payload,'$.keywords')) = 1
     SELECT @obm_keywords = STRING_AGG(kw, N', ')
     FROM (
       SELECT DISTINCT LTRIM(RTRIM(j.[value])) kw
       FROM OPENJSON(@p_payload,'$.keywords') j
       WHERE NULLIF(LTRIM(RTRIM(j.[value])),'') IS NOT NULL
     ) d;
   ELSE
     SET @obm_keywords = NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.keywords'))), N'');

   IF @obm_obligation_name IS NULL
     THROW 50064, 'Obligation Name is required.', 1;
   IF @obm_execution_frequency_id IS NOT NULL
      AND NOT EXISTS(SELECT 1 FROM GRAC_New.reference_option ro
                     WHERE ro.reference_option_id=@obm_execution_frequency_id AND ro.option_group='frequency-types' AND ro.status='Active')
     THROW 50018, 'Invalid execution frequency selected.', 1;

   IF @p_id=0
   BEGIN
     INSERT GRAC_New.requirement_obligation(
       obligation_name, obligation_text, execution_frequency_id, retention_requirement, remarks,
       keywords, status_id, status, entered_by)
     VALUES(@obm_obligation_name, @obm_obligation_name, @obm_execution_frequency_id, @obm_retention_requirement, @obm_remarks,
       @obm_keywords, @obm_active_status_id, @obm_status, @p_usr_id);
     SET @new_id = SCOPE_IDENTITY();
   END
   ELSE
   BEGIN
     UPDATE GRAC_New.requirement_obligation
     SET obligation_name        = @obm_obligation_name,
         obligation_text        = COALESCE(@obm_obligation_name, obligation_text),
         execution_frequency_id = @obm_execution_frequency_id,
         retention_requirement  = @obm_retention_requirement,
         remarks                = @obm_remarks,
         keywords               = @obm_keywords,
         status_id              = @obm_active_status_id,
         status                 = @obm_status,
         updated_by             = @p_usr_id,
         updated_dt             = SYSUTCDATETIME()
     WHERE obligation_id = @p_id;
     SET @new_id = @p_id;
   END

   -- Evidence sync.  Each row is identified by (evidence_type_id, frequency_id)
   -- so the same Evidence Type can repeat under one Obligation when the
   -- Assurance Frequency differs.
   IF @obm_evidence_json IS NOT NULL
   BEGIN
     DECLARE @obm_selected_evidence TABLE(
       slot_no INT IDENTITY PRIMARY KEY,
       evidence_type_id INT NOT NULL,
       frequency_id BIGINT NULL,
       retention_requirement NVARCHAR(250) NULL,
       remarks NVARCHAR(MAX) NULL
     );

     INSERT @obm_selected_evidence(evidence_type_id, frequency_id, retention_requirement, remarks)
     SELECT TRY_CONVERT(INT,    JSON_VALUE(j.[value], '$.evidenceTypeId')),
            TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(j.[value], '$.frequencyId'), N'')),
            NULLIF(JSON_VALUE(j.[value], '$.retentionRequirement'), N''),
            NULLIF(JSON_VALUE(j.[value], '$.remarks'), N'')
     FROM OPENJSON(@obm_evidence_json) j
     WHERE TRY_CONVERT(INT, JSON_VALUE(j.[value], '$.evidenceTypeId')) IS NOT NULL;

     -- Block exact duplicates (EvidenceType + AssuranceFrequency) inside the same payload.
     IF EXISTS (
       SELECT evidence_type_id, ISNULL(frequency_id, -1) AS fid, COUNT(1) c
       FROM @obm_selected_evidence
       GROUP BY evidence_type_id, ISNULL(frequency_id, -1)
       HAVING COUNT(1) > 1)
       THROW 50020, 'Duplicate Evidence Type with the same Assurance Frequency is not allowed for the same Obligation.', 1;

     -- Validate Evidence Type and Assurance Frequency masters.
     IF EXISTS(SELECT 1 FROM @obm_selected_evidence s
               WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.evidence_type_master et WHERE et.evidence_type_id=s.evidence_type_id AND et.is_active=1))
       THROW 50019, 'Invalid evidence type selected.', 1;
     IF EXISTS(SELECT 1 FROM @obm_selected_evidence s
               WHERE s.frequency_id IS NOT NULL
                 AND NOT EXISTS(SELECT 1 FROM GRAC_New.reference_option ro
                                WHERE ro.reference_option_id=s.frequency_id AND ro.option_group='frequency-types' AND ro.status='Active'))
       THROW 50018, 'Invalid evidence assurance frequency selected.', 1;

     -- Deactivate evidence rows that are no longer in the payload.
     UPDATE existing
     SET status='Inactive', updated_by=@p_usr_id, updated_dt=SYSUTCDATETIME()
     FROM GRAC_New.requirement_obligation_evidence existing
     WHERE existing.obligation_id=@new_id
       AND existing.status='Active'
       AND NOT EXISTS (
           SELECT 1 FROM @obm_selected_evidence sel
           WHERE sel.evidence_type_id = existing.evidence_type_id
             AND ISNULL(sel.frequency_id, -1) = ISNULL(existing.frequency_id, -1));

     -- Reactivate / refresh existing rows that match the payload pair.
     UPDATE existing
     SET retention_requirement = sel.retention_requirement,
         remarks               = sel.remarks,
         status_id             = @obm_active_status_id,
         status                = 'Active',
         updated_by            = @p_usr_id,
         updated_dt            = SYSUTCDATETIME()
     FROM GRAC_New.requirement_obligation_evidence existing
     JOIN @obm_selected_evidence sel
       ON sel.evidence_type_id = existing.evidence_type_id
      AND ISNULL(sel.frequency_id, -1) = ISNULL(existing.frequency_id, -1)
     WHERE existing.obligation_id = @new_id;

     -- Insert new evidence pairs.
     INSERT GRAC_New.requirement_obligation_evidence(obligation_id, evidence_type_id, frequency_id, retention_requirement, remarks, status_id, status, entered_by)
     SELECT @new_id, sel.evidence_type_id, sel.frequency_id, sel.retention_requirement, sel.remarks, @obm_active_status_id, 'Active', @p_usr_id
     FROM @obm_selected_evidence sel
     WHERE NOT EXISTS (
         SELECT 1 FROM GRAC_New.requirement_obligation_evidence existing
         WHERE existing.obligation_id = @new_id
           AND existing.evidence_type_id = sel.evidence_type_id
           AND ISNULL(existing.frequency_id, -1) = ISNULL(sel.frequency_id, -1));
   END

   -- Intentionally NO intermediate SELECT here.  The procedure's terminal
   -- 'SELECT @new_id Id;' at the very end is the only row the caller sees.
   -- The maker-checker APPROVE path captures that single-column result via
   -- 'INSERT @apply_result(Id) EXEC dbo.cm_manage_repository ...'; emitting
   -- additional columns from this branch breaks that INSERT EXEC with
   -- 'Column name or number of supplied values does not match table definition.'
 END
 ELSE IF @p_entity_type='obligations-legacy-framework-statement'
 BEGIN
   DECLARE @ob_framework_statement_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.frameworkStatementId'));
   IF @ob_framework_statement_id IS NOT NULL THROW 50017,'Obligations must be captured against Requirement + Release, not Framework Statement.',1;
   IF @ob_framework_statement_id IS NOT NULL
   BEGIN
     DECLARE @stmt_release_id BIGINT=NULL;
     DECLARE @stmt_structure_node_id BIGINT=NULL;
     DECLARE @stmt_active_status_id BIGINT=(SELECT TOP 1 reference_option_id FROM GRAC_New.reference_option WHERE option_group='status-active' AND option_value='Active');
     DECLARE @stmt_evidence_json NVARCHAR(MAX)=JSON_QUERY(@p_payload,'$.evidenceRequirements');
     DECLARE @stmt_obligation_text NVARCHAR(MAX)=NULLIF(JSON_VALUE(@p_payload,'$.obligationText'),N'');
     DECLARE @stmt_frequency_type NVARCHAR(40)=NULLIF(JSON_VALUE(@p_payload,'$.frequencyType'),N'');
     DECLARE @stmt_approval_authority NVARCHAR(250)=NULLIF(JSON_VALUE(@p_payload,'$.approvalAuthority'),N'');
     DECLARE @stmt_responsibility NVARCHAR(250)=NULLIF(JSON_VALUE(@p_payload,'$.responsibility'),N'');
     DECLARE @stmt_trigger_event NVARCHAR(500)=NULLIF(JSON_VALUE(@p_payload,'$.triggerEvent'),N'');
     DECLARE @stmt_reporting_target NVARCHAR(250)=NULLIF(JSON_VALUE(@p_payload,'$.reportingTarget'),N'');
     DECLARE @stmt_retention_requirement NVARCHAR(250)=NULLIF(JSON_VALUE(@p_payload,'$.retentionRequirement'),N'');
     DECLARE @stmt_evidence_requirement NVARCHAR(MAX)=NULLIF(JSON_VALUE(@p_payload,'$.evidenceRequirement'),N'');
     SELECT @stmt_release_id=fs.release_id,@stmt_structure_node_id=fs.structure_node_id
     FROM GRAC_New.framework_statement fs
     WHERE fs.framework_statement_id=@ob_framework_statement_id AND fs.status='Active';
     IF @stmt_release_id IS NULL THROW 50017,'Framework Statement is required for obligation capture.',1;
     IF COALESCE(TRY_CONVERT(BIT,JSON_VALUE(@p_payload,'$.isMapped')),1)=0
     BEGIN
       IF @p_id>0
       BEGIN
         UPDATE GRAC_New.obligation SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE obligation_id=@p_id;
         UPDATE GRAC_New.obligation_evidence_type SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE obligation_id=@p_id AND status='Active';
       END
       SET @new_id=COALESCE(@p_id,0);
     END
     ELSE
     BEGIN
       IF @p_id=0
       BEGIN
         INSERT GRAC_New.obligation(framework_statement_id,requirement_id,release_id,structure_node_id,obligation_text,frequency_type,approval_authority,responsibility,trigger_condition,reporting_target,retention_requirement,evidence_requirement,mandatory_flag,evidence_required,status,entered_by)
         VALUES(@ob_framework_statement_id,NULL,@stmt_release_id,@stmt_structure_node_id,@stmt_obligation_text,@stmt_frequency_type,@stmt_approval_authority,@stmt_responsibility,@stmt_trigger_event,@stmt_reporting_target,@stmt_retention_requirement,@stmt_evidence_requirement,CAST(1 AS BIT),CAST(1 AS BIT),N'Active',@p_usr_id);
         SET @new_id=SCOPE_IDENTITY();
       END
       ELSE
       BEGIN
         UPDATE GRAC_New.obligation
           SET framework_statement_id=@ob_framework_statement_id,
               requirement_id=NULL,
               release_id=@stmt_release_id,
               structure_node_id=@stmt_structure_node_id,
               obligation_text=@stmt_obligation_text,
               frequency_type=@stmt_frequency_type,
               approval_authority=@stmt_approval_authority,
               responsibility=@stmt_responsibility,
               trigger_condition=@stmt_trigger_event,
               reporting_target=@stmt_reporting_target,
               retention_requirement=@stmt_retention_requirement,
               evidence_requirement=@stmt_evidence_requirement,
               mandatory_flag=CAST(1 AS BIT),
               evidence_required=CAST(1 AS BIT),
               status=N'Active',
               updated_by=@p_usr_id,
               updated_dt=SYSUTCDATETIME()
         WHERE obligation_id=@p_id;
         SET @new_id=@p_id;
       END
       IF @stmt_evidence_json IS NOT NULL
       BEGIN
         DECLARE @statement_selected_evidence TABLE(
           evidence_type_id INT NOT NULL PRIMARY KEY,
           frequency_id BIGINT NULL,
           retention_requirement NVARCHAR(250) NULL,
           remarks NVARCHAR(MAX) NULL
         );

         IF (
           SELECT COUNT(1)
           FROM OPENJSON(@stmt_evidence_json) j
           WHERE TRY_CONVERT(INT,JSON_VALUE(j.[value],'$.evidenceTypeId')) IS NOT NULL
         ) > (
           SELECT COUNT(DISTINCT TRY_CONVERT(INT,JSON_VALUE(j.[value],'$.evidenceTypeId')))
           FROM OPENJSON(@stmt_evidence_json) j
           WHERE TRY_CONVERT(INT,JSON_VALUE(j.[value],'$.evidenceTypeId')) IS NOT NULL
         ) THROW 50020,'Duplicate Evidence Type is not allowed under the same Framework Statement obligation.',1;

         INSERT @statement_selected_evidence(evidence_type_id,frequency_id,retention_requirement,remarks)
         SELECT parsed.evidence_type_id,
           COALESCE(parsed.frequency_id,freq.reference_option_id),
           parsed.retention_requirement,
           parsed.remarks
         FROM (
           SELECT TRY_CONVERT(INT,JSON_VALUE(j.[value],'$.evidenceTypeId')) evidence_type_id,
             TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(j.[value],'$.frequencyId'),'')) frequency_id,
             NULLIF(JSON_VALUE(j.[value],'$.frequencyId'),'') frequency_value,
             JSON_VALUE(j.[value],'$.retentionRequirement') retention_requirement,
             JSON_VALUE(j.[value],'$.remarks') remarks,
             ROW_NUMBER() OVER(PARTITION BY TRY_CONVERT(INT,JSON_VALUE(j.[value],'$.evidenceTypeId')) ORDER BY (SELECT 1)) rn
           FROM OPENJSON(@stmt_evidence_json) j
         ) parsed
         JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id=parsed.evidence_type_id AND et.is_active=1
         LEFT JOIN GRAC_New.reference_option freq ON freq.option_group='frequency-types' AND freq.status='Active'
           AND (freq.option_value=parsed.frequency_value OR freq.option_label=parsed.frequency_value)
         WHERE parsed.evidence_type_id IS NOT NULL AND parsed.rn=1;

         IF EXISTS(
           SELECT 1 FROM @statement_selected_evidence s
           WHERE s.frequency_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM GRAC_New.reference_option ro WHERE ro.reference_option_id=s.frequency_id AND ro.option_group='frequency-types' AND ro.status='Active')
        ) THROW 50018,'Invalid evidence assurance frequency selected.',1;

         UPDATE existing
           SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
         FROM GRAC_New.obligation_evidence_type existing
         WHERE existing.obligation_id=@new_id
           AND existing.status='Active'
           AND NOT EXISTS(SELECT 1 FROM @statement_selected_evidence selected WHERE selected.evidence_type_id=existing.evidence_type_id);

         UPDATE existing
           SET frequency_id=selected.frequency_id,
               retention_requirement=selected.retention_requirement,
               remarks=selected.remarks,
               status='Active',
               updated_by=@p_usr_id,
               updated_dt=SYSUTCDATETIME()
         FROM GRAC_New.obligation_evidence_type existing
         JOIN @statement_selected_evidence selected ON selected.evidence_type_id=existing.evidence_type_id
         WHERE existing.obligation_id=@new_id;

         INSERT GRAC_New.obligation_evidence_type(obligation_id,evidence_type_id,frequency_id,retention_requirement,remarks,status,entered_by)
         SELECT @new_id,selected.evidence_type_id,selected.frequency_id,selected.retention_requirement,selected.remarks,N'Active',@p_usr_id
         FROM @statement_selected_evidence selected
         WHERE NOT EXISTS(
           SELECT 1 FROM GRAC_New.obligation_evidence_type existing
           WHERE existing.obligation_id=@new_id AND existing.evidence_type_id=selected.evidence_type_id
         );

         UPDATE o
           SET evidence_required=CASE WHEN EXISTS(SELECT 1 FROM @statement_selected_evidence) THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END,
               updated_by=@p_usr_id,
               updated_dt=SYSUTCDATETIME()
         FROM GRAC_New.obligation o
         WHERE o.obligation_id=@new_id;
       END
     END
     IF @new_id > 0
     BEGIN
       SELECT @new_id Id,
         @new_id ObligationId,
         @ob_framework_statement_id FrameworkStatementId,
         @stmt_release_id ReleaseId,
         (SELECT COUNT(1) FROM GRAC_New.obligation_evidence_type saved WHERE saved.obligation_id=@new_id AND saved.status='Active') EvidenceRowCount,
         DB_NAME() DatabaseName,
         N'GRAC_New' SchemaName;
     END
   END
   ELSE
   BEGIN
   DECLARE @ob_requirement_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.requirementId'));
   DECLARE @ob_release_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.releaseId'));
   DECLARE @ob_active_status_id BIGINT=(SELECT TOP 1 reference_option_id FROM GRAC_New.reference_option WHERE option_group='status-active' AND option_value='Active');
   DECLARE @ob_evidence_json NVARCHAR(MAX)=JSON_QUERY(@p_payload,'$.evidenceRequirements');
   DECLARE @ob_obligation_text NVARCHAR(MAX)=NULLIF(JSON_VALUE(@p_payload,'$.obligationText'),N'');
   DECLARE @ob_frequency_type NVARCHAR(40)=NULLIF(JSON_VALUE(@p_payload,'$.frequencyType'),N'');
    DECLARE @ob_approval_authority NVARCHAR(250)=NULLIF(JSON_VALUE(@p_payload,'$.approvalAuthority'),N'');
   DECLARE @ob_responsibility NVARCHAR(250)=NULLIF(JSON_VALUE(@p_payload,'$.responsibility'),N'');
   DECLARE @ob_trigger_event NVARCHAR(500)=NULLIF(JSON_VALUE(@p_payload,'$.triggerEvent'),N'');
   DECLARE @ob_reporting_target NVARCHAR(250)=NULLIF(JSON_VALUE(@p_payload,'$.reportingTarget'),N'');
   DECLARE @ob_retention_requirement NVARCHAR(250)=NULLIF(JSON_VALUE(@p_payload,'$.retentionRequirement'),N'');
   DECLARE @ob_evidence_requirement NVARCHAR(MAX)=NULLIF(JSON_VALUE(@p_payload,'$.evidenceRequirement'),N'');
   IF @ob_requirement_id IS NULL OR @ob_release_id IS NULL THROW 50017,'Requirement and Release are required for obligation mapping.',1;
   IF @p_id=0
     SELECT @p_id=obligation_id FROM GRAC_New.requirement_obligation WHERE requirement_id=@ob_requirement_id AND release_id=@ob_release_id AND status='Active';
   IF COALESCE(TRY_CONVERT(BIT,JSON_VALUE(@p_payload,'$.isMapped')),1)=0
   BEGIN
     IF @p_id>0
     BEGIN
       UPDATE GRAC_New.requirement_obligation SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE obligation_id=@p_id;
       UPDATE GRAC_New.requirement_obligation_evidence SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE obligation_id=@p_id AND status='Active';
       UPDATE o
          SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.obligation o
       JOIN GRAC_New.framework_statement fs ON fs.framework_statement_id=o.framework_statement_id
       WHERE o.requirement_id=@ob_requirement_id
         AND o.release_id=@ob_release_id
         AND o.status='Active';
     END
     SET @new_id=COALESCE(@p_id,0);
   END
   ELSE
   BEGIN
   IF @p_id=0
   BEGIN
     INSERT GRAC_New.requirement_obligation(requirement_id,release_id,obligation_text,frequency_type,approval_authority,responsibility,trigger_condition,reporting_target,retention_requirement,evidence_requirement,status_id,status,entered_by)
     VALUES(@ob_requirement_id,@ob_release_id,@ob_obligation_text,@ob_frequency_type,@ob_approval_authority,@ob_responsibility,@ob_trigger_event,@ob_reporting_target,@ob_retention_requirement,@ob_evidence_requirement,@ob_active_status_id,N'Active',@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
   BEGIN
    UPDATE GRAC_New.requirement_obligation
      SET requirement_id=@ob_requirement_id,release_id=@ob_release_id,
        obligation_text=@ob_obligation_text,frequency_type=@ob_frequency_type,
        approval_authority=@ob_approval_authority,responsibility=@ob_responsibility,
        trigger_condition=@ob_trigger_event,reporting_target=@ob_reporting_target,
        retention_requirement=@ob_retention_requirement,evidence_requirement=@ob_evidence_requirement,
        status_id=@ob_active_status_id,status=N'Active',
        updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE obligation_id=@p_id;
     SET @new_id=@p_id;
   END
   IF @ob_evidence_json IS NOT NULL
   BEGIN
     DECLARE @selected_evidence TABLE(
       evidence_type_id INT NOT NULL PRIMARY KEY,
       frequency_id BIGINT NULL,
       retention_requirement NVARCHAR(250) NULL,
       remarks NVARCHAR(MAX) NULL
     );

     IF (
       SELECT COUNT(1)
       FROM OPENJSON(@ob_evidence_json) j
       WHERE TRY_CONVERT(INT,JSON_VALUE(j.[value],'$.evidenceTypeId')) IS NOT NULL
     ) > (
       SELECT COUNT(DISTINCT TRY_CONVERT(INT,JSON_VALUE(j.[value],'$.evidenceTypeId')))
       FROM OPENJSON(@ob_evidence_json) j
       WHERE TRY_CONVERT(INT,JSON_VALUE(j.[value],'$.evidenceTypeId')) IS NOT NULL
     ) THROW 50020,'Duplicate Evidence Type is not allowed under the same Requirement + Release obligation.',1;

     INSERT @selected_evidence(evidence_type_id,frequency_id,retention_requirement,remarks)
     SELECT parsed.evidence_type_id,
       COALESCE(parsed.frequency_id,freq.reference_option_id),
       parsed.retention_requirement,
       parsed.remarks
     FROM (
       SELECT TRY_CONVERT(INT,JSON_VALUE(j.[value],'$.evidenceTypeId')) evidence_type_id,
         TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(j.[value],'$.frequencyId'),'')) frequency_id,
         NULLIF(JSON_VALUE(j.[value],'$.frequencyId'),'') frequency_value,
         JSON_VALUE(j.[value],'$.retentionRequirement') retention_requirement,
         JSON_VALUE(j.[value],'$.remarks') remarks,
         ROW_NUMBER() OVER(PARTITION BY TRY_CONVERT(INT,JSON_VALUE(j.[value],'$.evidenceTypeId')) ORDER BY (SELECT 1)) rn
       FROM OPENJSON(@ob_evidence_json) j
     ) parsed
     JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id=parsed.evidence_type_id AND et.is_active=1
     LEFT JOIN GRAC_New.reference_option freq ON freq.option_group='frequency-types' AND freq.status='Active'
       AND (freq.option_value=parsed.frequency_value OR freq.option_label=parsed.frequency_value)
     WHERE parsed.evidence_type_id IS NOT NULL AND parsed.rn=1;

     IF EXISTS(
       SELECT 1 FROM @selected_evidence s
       WHERE s.frequency_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM GRAC_New.reference_option ro WHERE ro.reference_option_id=s.frequency_id AND ro.option_group='frequency-types' AND ro.status='Active')
      ) THROW 50018,'Invalid evidence assurance frequency selected.',1;

     UPDATE existing
       SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     FROM GRAC_New.requirement_obligation_evidence existing
     WHERE existing.obligation_id=@new_id
       AND existing.status='Active'
       AND NOT EXISTS(SELECT 1 FROM @selected_evidence selected WHERE selected.evidence_type_id=existing.evidence_type_id);

     UPDATE existing
       SET frequency_id=selected.frequency_id,retention_requirement=selected.retention_requirement,remarks=selected.remarks,
         status_id=@ob_active_status_id,status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     FROM GRAC_New.requirement_obligation_evidence existing
     JOIN @selected_evidence selected ON selected.evidence_type_id=existing.evidence_type_id
     WHERE existing.obligation_id=@new_id;

     INSERT GRAC_New.requirement_obligation_evidence(obligation_id,evidence_type_id,frequency_id,retention_requirement,remarks,status_id,status,entered_by)
     SELECT @new_id,selected.evidence_type_id,selected.frequency_id,selected.retention_requirement,selected.remarks,@ob_active_status_id,N'Active',@p_usr_id
     FROM @selected_evidence selected
     WHERE NOT EXISTS(
       SELECT 1 FROM GRAC_New.requirement_obligation_evidence existing
       WHERE existing.obligation_id=@new_id AND existing.evidence_type_id=selected.evidence_type_id
     );
   END
   END
  -- Final repository model: obligations are maintained at Requirement + Release.
  -- Framework Statements remain source traceability and are not updated from this save path.
   IF @new_id > 0
   BEGIN
     SELECT @new_id Id,
       @new_id ObligationId,
       @ob_requirement_id RequirementId,
       @ob_release_id ReleaseId,
       (SELECT COUNT(1) FROM GRAC_New.requirement_obligation_evidence saved WHERE saved.obligation_id=@new_id AND saved.status='Active') EvidenceRowCount,
       DB_NAME() DatabaseName,
       N'GRAC_New' SchemaName;
   END
   END
 END
 ELSE IF @p_entity_type='control-requirement-mappings'
 BEGIN
   DECLARE @crm_control_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.controlId'));
   IF @crm_control_id IS NULL OR @crm_control_id<=0 THROW 50016,'Control is required.',1;
   UPDATE m SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
   FROM GRAC_New.control_requirement_map m
   WHERE m.control_id=@crm_control_id AND m.status='Active'
     AND NOT EXISTS(SELECT 1 FROM OPENJSON(@p_payload,'$.requirementIds') j WHERE TRY_CONVERT(BIGINT,j.[value])=m.requirement_id);
   UPDATE m SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
   FROM GRAC_New.control_requirement_map m
   JOIN OPENJSON(@p_payload,'$.requirementIds') j ON TRY_CONVERT(BIGINT,j.[value])=m.requirement_id
   WHERE m.control_id=@crm_control_id AND m.status<>'Active';
   INSERT GRAC_New.control_requirement_map(control_id,requirement_id,status,entered_by)
   SELECT @crm_control_id,TRY_CONVERT(BIGINT,j.[value]),'Active',@p_usr_id
   FROM OPENJSON(@p_payload,'$.requirementIds') j
   WHERE TRY_CONVERT(BIGINT,j.[value]) IS NOT NULL
     AND NOT EXISTS(SELECT 1 FROM GRAC_New.control_requirement_map m WHERE m.control_id=@crm_control_id AND m.requirement_id=TRY_CONVERT(BIGINT,j.[value]));
   SELECT @new_id=COALESCE(TRY_CONVERT(BIGINT,SCOPE_IDENTITY()),@crm_control_id);
 END
 ELSE IF @p_entity_type='source-control-mappings'
 BEGIN
   -- Practices - Statement Mapping.  Payload variants:
   --   frameworkStatementId + requirementIds -> framework_statement_requirement_map (new UI)
   --   frameworkStatementId + controlIds     -> framework_statement_control_map     (legacy)
   --   structureNodeId      + controlIds     -> source_control_map                  (Add/Edit Control section)
   DECLARE @map_statement_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.frameworkStatementId'));
   DECLARE @map_structure_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.structureNodeId'));
   DECLARE @has_requirement_ids BIT=CASE WHEN ISJSON(JSON_QUERY(@p_payload,'$.requirementIds'))=1 THEN 1 ELSE 0 END;
   IF @map_statement_id IS NULL AND @map_structure_id IS NULL
     THROW 50015,'A Framework Statement (frameworkStatementId) or Source Structure node (structureNodeId) is required to save a mapping.',1;
   IF @map_statement_id IS NOT NULL AND @has_requirement_ids=1
   BEGIN
     IF NOT EXISTS(SELECT 1 FROM GRAC_New.framework_statement WHERE framework_statement_id=@map_statement_id AND status='Active')
       THROW 50016,'The selected Framework Statement is invalid or inactive.',1;
     IF @p_id=0
     BEGIN
       UPDATE m SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.framework_statement_requirement_map m
       JOIN OPENJSON(@p_payload,'$.requirementIds') j ON TRY_CONVERT(BIGINT,j.[value])=m.requirement_id
       WHERE m.framework_statement_id=@map_statement_id AND m.status<>'Active';
       INSERT GRAC_New.framework_statement_requirement_map(framework_statement_id,requirement_id,status,entered_by)
       SELECT @map_statement_id,TRY_CONVERT(BIGINT,j.[value]),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),@p_usr_id
       FROM OPENJSON(@p_payload,'$.requirementIds') j
       WHERE TRY_CONVERT(BIGINT,j.[value]) IS NOT NULL
         AND NOT EXISTS(SELECT 1 FROM GRAC_New.framework_statement_requirement_map m WHERE m.framework_statement_id=@map_statement_id AND m.requirement_id=TRY_CONVERT(BIGINT,j.[value]));
       SELECT @new_id=COALESCE(TRY_CONVERT(BIGINT,SCOPE_IDENTITY()),(SELECT TOP 1 m.statement_requirement_map_id FROM GRAC_New.framework_statement_requirement_map m JOIN OPENJSON(@p_payload,'$.requirementIds') j ON TRY_CONVERT(BIGINT,j.[value])=m.requirement_id WHERE m.framework_statement_id=@map_statement_id ORDER BY m.statement_requirement_map_id DESC));
     END
     ELSE UPDATE GRAC_New.framework_statement_requirement_map
       SET framework_statement_id=@map_statement_id,
           requirement_id=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.requirementIds[0]')),
           status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),
           updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       WHERE statement_requirement_map_id=@p_id;
   END
   ELSE IF @map_statement_id IS NOT NULL
   BEGIN
     IF NOT EXISTS(SELECT 1 FROM GRAC_New.framework_statement WHERE framework_statement_id=@map_statement_id AND status='Active')
       THROW 50016,'The selected Framework Statement is invalid or inactive.',1;
     IF @p_id=0
     BEGIN
       UPDATE m SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.framework_statement_control_map m
       JOIN OPENJSON(@p_payload,'$.controlIds') j ON TRY_CONVERT(BIGINT,j.[value])=m.control_id
       WHERE m.framework_statement_id=@map_statement_id AND m.status<>'Active';
       INSERT GRAC_New.framework_statement_control_map(framework_statement_id,control_id,status,entered_by)
       SELECT @map_statement_id,TRY_CONVERT(BIGINT,j.[value]),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),@p_usr_id
       FROM OPENJSON(@p_payload,'$.controlIds') j
       WHERE TRY_CONVERT(BIGINT,j.[value]) IS NOT NULL
         AND NOT EXISTS(SELECT 1 FROM GRAC_New.framework_statement_control_map m WHERE m.framework_statement_id=@map_statement_id AND m.control_id=TRY_CONVERT(BIGINT,j.[value]));
       SELECT @new_id=COALESCE(TRY_CONVERT(BIGINT,SCOPE_IDENTITY()),(SELECT TOP 1 m.statement_control_map_id FROM GRAC_New.framework_statement_control_map m JOIN OPENJSON(@p_payload,'$.controlIds') j ON TRY_CONVERT(BIGINT,j.[value])=m.control_id WHERE m.framework_statement_id=@map_statement_id ORDER BY m.statement_control_map_id DESC));
     END
     ELSE UPDATE GRAC_New.framework_statement_control_map
       SET framework_statement_id=@map_statement_id,
           control_id=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.controlIds[0]')),
           status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),
           updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       WHERE statement_control_map_id=@p_id;
   END
   ELSE
   BEGIN
     IF EXISTS(SELECT 1 FROM GRAC_New.source_structure_node WHERE parent_node_id=@map_structure_id AND status='Active') THROW 50015,'Only leaf-level source structure nodes can be mapped to a control.',1;
     IF @p_id=0
     BEGIN
       UPDATE m SET status='Active',release_id=n.release_id,artifact_id=r.artifact_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.source_control_map m JOIN OPENJSON(@p_payload,'$.controlIds') j ON TRY_CONVERT(BIGINT,j.[value])=m.control_id JOIN GRAC_New.source_structure_node n ON n.structure_node_id=@map_structure_id JOIN GRAC_New.release r ON r.release_id=n.release_id
       WHERE m.structure_node_id=@map_structure_id AND m.status<>'Active';
       INSERT GRAC_New.source_control_map(structure_node_id,control_id,release_id,artifact_id,status,entered_by)
       SELECT @map_structure_id,TRY_CONVERT(BIGINT,j.[value]),n.release_id,r.artifact_id,COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),@p_usr_id
       FROM OPENJSON(@p_payload,'$.controlIds') j JOIN GRAC_New.source_structure_node n ON n.structure_node_id=@map_structure_id JOIN GRAC_New.release r ON r.release_id=n.release_id
       WHERE NOT EXISTS(SELECT 1 FROM GRAC_New.source_control_map m WHERE m.structure_node_id=@map_structure_id AND m.control_id=TRY_CONVERT(BIGINT,j.[value]));
       SELECT @new_id=COALESCE(TRY_CONVERT(BIGINT,SCOPE_IDENTITY()),(SELECT TOP 1 m.source_control_map_id FROM GRAC_New.source_control_map m JOIN OPENJSON(@p_payload,'$.controlIds') j ON TRY_CONVERT(BIGINT,j.[value])=m.control_id WHERE m.structure_node_id=@map_structure_id ORDER BY m.source_control_map_id DESC));
     END
     ELSE UPDATE m SET structure_node_id=@map_structure_id,control_id=JSON_VALUE(@p_payload,'$.controlIds[0]'),release_id=n.release_id,artifact_id=r.artifact_id,status=COALESCE(JSON_VALUE(@p_payload,'$.status'),m.status),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
       FROM GRAC_New.source_control_map m JOIN GRAC_New.source_structure_node n ON n.structure_node_id=@map_structure_id JOIN GRAC_New.release r ON r.release_id=n.release_id WHERE m.source_control_map_id=@p_id;
   END
 END
 ELSE IF @p_entity_type='applicability-rules' BEGIN IF @p_id=0 BEGIN INSERT GRAC_New.applicability_rule(artifact_id,release_id,rule_name,rule_expression_json,priority_no,outcome,status,entered_by) VALUES(NULLIF(JSON_VALUE(@p_payload,'$.artifactId'),''),NULLIF(JSON_VALUE(@p_payload,'$.releaseId'),''),JSON_VALUE(@p_payload,'$.name'),JSON_MODIFY('{}','$.expression',JSON_VALUE(@p_payload,'$.expression')),COALESCE(JSON_VALUE(@p_payload,'$.priority'),100),COALESCE(JSON_VALUE(@p_payload,'$.outcome'),'Applicable'),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),@p_usr_id); SET @new_id=SCOPE_IDENTITY(); END ELSE UPDATE GRAC_New.applicability_rule SET artifact_id=NULLIF(JSON_VALUE(@p_payload,'$.artifactId'),''),release_id=NULLIF(JSON_VALUE(@p_payload,'$.releaseId'),''),rule_name=JSON_VALUE(@p_payload,'$.name'),rule_expression_json=JSON_MODIFY('{}','$.expression',JSON_VALUE(@p_payload,'$.expression')),priority_no=COALESCE(JSON_VALUE(@p_payload,'$.priority'),priority_no),outcome=COALESCE(JSON_VALUE(@p_payload,'$.outcome'),outcome),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE applicability_rule_id=@p_id; END
  ELSE IF @p_entity_type='changes' BEGIN IF @p_id=0 BEGIN INSERT GRAC_New.change_event(entity_type,entity_id,change_type,change_summary,effective_dt,severity,status,entered_by) VALUES(JSON_VALUE(@p_payload,'$.entityType'),JSON_VALUE(@p_payload,'$.entityId'),JSON_VALUE(@p_payload,'$.changeType'),JSON_VALUE(@p_payload,'$.summary'),JSON_VALUE(@p_payload,'$.effectiveDate'),COALESCE(JSON_VALUE(@p_payload,'$.severity'),'Medium'),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Open'),@p_usr_id); SET @new_id=SCOPE_IDENTITY(); END ELSE UPDATE GRAC_New.change_event SET entity_type=JSON_VALUE(@p_payload,'$.entityType'),entity_id=JSON_VALUE(@p_payload,'$.entityId'),change_type=JSON_VALUE(@p_payload,'$.changeType'),change_summary=JSON_VALUE(@p_payload,'$.summary'),effective_dt=JSON_VALUE(@p_payload,'$.effectiveDate'),severity=COALESCE(JSON_VALUE(@p_payload,'$.severity'),severity),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE change_event_id=@p_id; END
  ELSE IF @p_entity_type='impact-analysis' BEGIN IF @p_id=0 BEGIN INSERT GRAC_New.impact_analysis(change_event_id,impacted_entity_type,impacted_entity_id,organization_id,impact_summary,recommended_action,status,entered_by) VALUES(JSON_VALUE(@p_payload,'$.changeEventId'),JSON_VALUE(@p_payload,'$.impactedEntityType'),JSON_VALUE(@p_payload,'$.impactedEntityId'),NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''),JSON_VALUE(@p_payload,'$.summary'),JSON_VALUE(@p_payload,'$.recommendedAction'),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Open'),@p_usr_id); SET @new_id=SCOPE_IDENTITY(); END ELSE UPDATE GRAC_New.impact_analysis SET change_event_id=JSON_VALUE(@p_payload,'$.changeEventId'),impacted_entity_type=JSON_VALUE(@p_payload,'$.impactedEntityType'),impacted_entity_id=JSON_VALUE(@p_payload,'$.impactedEntityId'),organization_id=NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''),impact_summary=JSON_VALUE(@p_payload,'$.summary'),recommended_action=JSON_VALUE(@p_payload,'$.recommendedAction'),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE impact_analysis_id=@p_id; END
  ELSE IF @p_entity_type='notifications' BEGIN IF @p_id=0 BEGIN INSERT GRAC_New.notification(impact_analysis_id,organization_id,notification_type,subject,message_body,severity,recommended_action,status,entered_by) VALUES(NULLIF(JSON_VALUE(@p_payload,'$.impactAnalysisId'),''),NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''),JSON_VALUE(@p_payload,'$.type'),JSON_VALUE(@p_payload,'$.subject'),JSON_VALUE(@p_payload,'$.message'),COALESCE(JSON_VALUE(@p_payload,'$.severity'),'Medium'),JSON_VALUE(@p_payload,'$.recommendedAction'),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Pending'),@p_usr_id); SET @new_id=SCOPE_IDENTITY(); END ELSE UPDATE GRAC_New.notification SET impact_analysis_id=NULLIF(JSON_VALUE(@p_payload,'$.impactAnalysisId'),''),organization_id=NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''),notification_type=JSON_VALUE(@p_payload,'$.type'),subject=JSON_VALUE(@p_payload,'$.subject'),message_body=JSON_VALUE(@p_payload,'$.message'),severity=COALESCE(JSON_VALUE(@p_payload,'$.severity'),severity),recommended_action=JSON_VALUE(@p_payload,'$.recommendedAction'),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE notification_id=@p_id; END
  ELSE IF @p_entity_type='approval-workflow'
  BEGIN
    -- The UI dropdown sends cm_entity_master.entity_code in the `moduleName`
    -- payload field.  Resolve to entity_id (canonical) and persist both that and
    -- a denormalized display name pulled from the master.
    DECLARE @workflow_module_code NVARCHAR(100)=NULLIF(JSON_VALUE(@p_payload,'$.moduleName'),N'');
    IF @workflow_module_code IS NULL THROW 50028,'Module Name is required.',1;
    DECLARE @workflow_entity_id BIGINT, @workflow_module_display NVARCHAR(200);
    SELECT @workflow_entity_id=entity_id, @workflow_module_display=entity_name
    FROM GRAC_New.cm_entity_master WHERE entity_code=@workflow_module_code AND status='Active';
    IF @workflow_entity_id IS NULL THROW 50039,'Select a valid Module from the master list.',1;
    IF @p_id=0 AND EXISTS(SELECT 1 FROM GRAC_New.approval_workflow_config WHERE entity_id=@workflow_entity_id)
      THROW 50029,'Approval workflow already exists for this module.',1;
    IF @p_id<>0 AND EXISTS(SELECT 1 FROM GRAC_New.approval_workflow_config WHERE entity_id=@workflow_entity_id AND workflow_config_id<>@p_id)
      THROW 50029,'Approval workflow already exists for this module.',1;
    IF @p_id=0
    BEGIN
      INSERT GRAC_New.approval_workflow_config(module_name,entity_id,maker_roles,maker_users,checker_roles,checker_users,approval_required,self_approval_allowed,minimum_approvers,status,entered_by)
      VALUES(@workflow_module_display,@workflow_entity_id,JSON_VALUE(@p_payload,'$.makerRoles'),JSON_VALUE(@p_payload,'$.makerUsers'),JSON_VALUE(@p_payload,'$.checkerRoles'),JSON_VALUE(@p_payload,'$.checkerUsers'),
        CASE WHEN JSON_VALUE(@p_payload,'$.approvalRequired') IN ('No','false','0') THEN 0 ELSE 1 END,
        CASE WHEN JSON_VALUE(@p_payload,'$.selfApprovalAllowed') IN ('Yes','true','1') THEN 1 ELSE 0 END,
        COALESCE(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.minimumApprovers')),1),
        COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),@p_usr_id);
      SET @new_id=SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
      UPDATE GRAC_New.approval_workflow_config
        SET module_name=@workflow_module_display,entity_id=@workflow_entity_id,
            maker_roles=JSON_VALUE(@p_payload,'$.makerRoles'),maker_users=JSON_VALUE(@p_payload,'$.makerUsers'),
            checker_roles=JSON_VALUE(@p_payload,'$.checkerRoles'),checker_users=JSON_VALUE(@p_payload,'$.checkerUsers'),
            approval_required=CASE WHEN JSON_VALUE(@p_payload,'$.approvalRequired') IN ('No','false','0') THEN 0 ELSE 1 END,
            self_approval_allowed=CASE WHEN JSON_VALUE(@p_payload,'$.selfApprovalAllowed') IN ('Yes','true','1') THEN 1 ELSE 0 END,
            minimum_approvers=COALESCE(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.minimumApprovers')),minimum_approvers),
            status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
      WHERE workflow_config_id=@p_id;
    END
  END
  ELSE IF @p_entity_type='user-management'
  BEGIN
    -- Required fields: userName, loginId, email. passwordHash is enriched by the
    -- API for new users from Security:DefaultUserPassword; the UI never collects it.
    DECLARE @um_user_name NVARCHAR(200) = NULLIF(JSON_VALUE(@p_payload,'$.userName'),N'');
    DECLARE @um_login_id  NVARCHAR(160) = NULLIF(JSON_VALUE(@p_payload,'$.loginId'),N'');
    DECLARE @um_email     NVARCHAR(250) = NULLIF(JSON_VALUE(@p_payload,'$.email'),N'');
    DECLARE @um_password  NVARCHAR(500) = NULLIF(JSON_VALUE(@p_payload,'$.passwordHash'),N'');
    DECLARE @um_remarks   NVARCHAR(MAX) = JSON_VALUE(@p_payload,'$.remarks');
    DECLARE @um_status    NVARCHAR(30)  = COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.status'),N''),'Active');
    IF @um_user_name IS NULL THROW 50043,'User Name is required.',1;
    IF @um_login_id  IS NULL THROW 50044,'Login ID is required.',1;
    IF @um_email     IS NULL THROW 50045,'Email is required.',1;
    IF @p_id=0
    BEGIN
      IF @um_password IS NULL THROW 50030,'Password Hash is required for new users.',1;
      IF EXISTS(SELECT 1 FROM GRAC_New.cm_user WHERE LOWER(login_id)=LOWER(@um_login_id) OR LOWER(email)=LOWER(@um_email))
        THROW 50031,'Login ID or Email already exists.',1;
      INSERT GRAC_New.cm_user(user_name,login_id,email,password_hash,status,remarks,is_password_change_required,entered_by)
      VALUES(@um_user_name,@um_login_id,@um_email,@um_password,@um_status,@um_remarks,1,@p_usr_id);
      SET @new_id=SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
      IF EXISTS(SELECT 1 FROM GRAC_New.cm_user WHERE user_id<>@p_id AND (LOWER(login_id)=LOWER(@um_login_id) OR LOWER(email)=LOWER(@um_email)))
        THROW 50031,'Login ID or Email already exists.',1;
      UPDATE GRAC_New.cm_user
      SET user_name=@um_user_name,login_id=@um_login_id,email=@um_email,
          status=@um_status,remarks=@um_remarks,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
      WHERE user_id=@p_id;
      -- Edit never touches password_hash. The change-password endpoint and the
      -- forgot-password reset are the only legitimate writers.
    END

    -- Synchronise role assignments. Payload `roleIds` is a JSON array of role ids.
    IF ISJSON(JSON_QUERY(@p_payload,'$.roleIds'))=1
    BEGIN
      UPDATE ur SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
      FROM GRAC_New.cm_user_role ur
      WHERE ur.user_id=@new_id AND ur.status='Active'
        AND NOT EXISTS(SELECT 1 FROM OPENJSON(@p_payload,'$.roleIds') j WHERE TRY_CONVERT(BIGINT,j.[value])=ur.role_id);
      UPDATE ur SET status='Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
      FROM GRAC_New.cm_user_role ur
      JOIN OPENJSON(@p_payload,'$.roleIds') j ON TRY_CONVERT(BIGINT,j.[value])=ur.role_id
      WHERE ur.user_id=@new_id AND ur.status<>'Active';
      INSERT GRAC_New.cm_user_role(user_id,role_id,status,entered_by)
      SELECT @new_id,TRY_CONVERT(BIGINT,j.[value]),'Active',@p_usr_id
      FROM OPENJSON(@p_payload,'$.roleIds') j
      WHERE TRY_CONVERT(BIGINT,j.[value]) IS NOT NULL
        AND NOT EXISTS(SELECT 1 FROM GRAC_New.cm_user_role x WHERE x.user_id=@new_id AND x.role_id=TRY_CONVERT(BIGINT,j.[value]));
    END
  END
  ELSE IF @p_entity_type='role-management'
  BEGIN
    DECLARE @rm_role_name NVARCHAR(100) = NULLIF(JSON_VALUE(@p_payload,'$.roleName'),N'');
    DECLARE @rm_description NVARCHAR(500) = JSON_VALUE(@p_payload,'$.description');
    DECLARE @rm_status NVARCHAR(30) = COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.status'),N''),'Active');
    IF @rm_role_name IS NULL THROW 50046,'Role Name is required.',1;
    IF @p_id=0
    BEGIN
      IF EXISTS(SELECT 1 FROM GRAC_New.cm_role WHERE role_name=@rm_role_name) THROW 50032,'Role Name already exists.',1;
      INSERT GRAC_New.cm_role(role_name,description,status,entered_by)
      VALUES(@rm_role_name,@rm_description,@rm_status,@p_usr_id);
      SET @new_id=SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
      IF EXISTS(SELECT 1 FROM GRAC_New.cm_role WHERE role_name=@rm_role_name AND role_id<>@p_id) THROW 50032,'Role Name already exists.',1;
      UPDATE GRAC_New.cm_role
      SET role_name=@rm_role_name,description=@rm_description,status=@rm_status,
          updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
      WHERE role_id=@p_id;
    END
  END
  ELSE IF @p_entity_type='menu-management'
  BEGIN
    DECLARE @mm_parent_menu_id BIGINT = TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.parentMenuId'),N''));
    DECLARE @mm_menu_name NVARCHAR(200) = NULLIF(JSON_VALUE(@p_payload,'$.menuName'),N'');
    DECLARE @mm_menu_code NVARCHAR(100) = NULLIF(JSON_VALUE(@p_payload,'$.menuCode'),N'');
    DECLARE @mm_route_url NVARCHAR(300) = JSON_VALUE(@p_payload,'$.routeUrl');
    DECLARE @mm_display_order INT = COALESCE(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.displayOrder')),0);
    DECLARE @mm_icon NVARCHAR(80) = JSON_VALUE(@p_payload,'$.icon');
    DECLARE @mm_status NVARCHAR(30) = COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.status'),N''),'Active');
    IF @mm_menu_name IS NULL THROW 50047,'Menu Name is required.',1;
    IF @mm_menu_code IS NULL THROW 50048,'Menu Code is required.',1;
    IF @p_id=0
    BEGIN
      IF EXISTS(SELECT 1 FROM GRAC_New.cm_menu WHERE menu_code=@mm_menu_code) THROW 50033,'Menu Code already exists.',1;
      INSERT GRAC_New.cm_menu(parent_menu_id,menu_name,menu_code,route_url,display_order,icon,status,entered_by)
      VALUES(@mm_parent_menu_id,@mm_menu_name,@mm_menu_code,@mm_route_url,@mm_display_order,@mm_icon,@mm_status,@p_usr_id);
      SET @new_id=SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
      IF EXISTS(SELECT 1 FROM GRAC_New.cm_menu WHERE menu_code=@mm_menu_code AND menu_id<>@p_id) THROW 50033,'Menu Code already exists.',1;
      UPDATE GRAC_New.cm_menu
      SET parent_menu_id=@mm_parent_menu_id,menu_name=@mm_menu_name,menu_code=@mm_menu_code,
          route_url=@mm_route_url,display_order=@mm_display_order,icon=@mm_icon,status=@mm_status,
          updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
      WHERE menu_id=@p_id;
    END
  END
  ELSE IF @p_entity_type='role-permissions'
  BEGIN
    DECLARE @rp_role_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.roleId'));
    DECLARE @rp_menu_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.menuId'));
    IF @rp_role_id IS NULL OR @rp_role_id<=0 THROW 50037,'Role is required.',1;
    IF @rp_menu_id IS NULL OR @rp_menu_id<=0 THROW 50038,'Menu is required.',1;
    IF NOT EXISTS(SELECT 1 FROM GRAC_New.cm_role WHERE role_id=@rp_role_id) THROW 50037,'Role is required.',1;
    IF NOT EXISTS(SELECT 1 FROM GRAC_New.cm_menu WHERE menu_id=@rp_menu_id) THROW 50038,'Menu is required.',1;
    DECLARE @rp_can_view BIT=CASE WHEN JSON_VALUE(@p_payload,'$.canView') IN ('Yes','yes','true','True','1') THEN 1 ELSE 0 END;
    DECLARE @rp_can_add BIT=CASE WHEN JSON_VALUE(@p_payload,'$.canAdd') IN ('Yes','yes','true','True','1') THEN 1 ELSE 0 END;
    DECLARE @rp_can_edit BIT=CASE WHEN JSON_VALUE(@p_payload,'$.canEdit') IN ('Yes','yes','true','True','1') THEN 1 ELSE 0 END;
    DECLARE @rp_can_inactive BIT=CASE WHEN JSON_VALUE(@p_payload,'$.canInactive') IN ('Yes','yes','true','True','1') THEN 1 ELSE 0 END;
    DECLARE @rp_can_approve BIT=CASE WHEN JSON_VALUE(@p_payload,'$.canApprove') IN ('Yes','yes','true','True','1') THEN 1 ELSE 0 END;
    DECLARE @rp_status NVARCHAR(30)=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.status'),N''),'Active');
    IF @p_id=0
    BEGIN
      DECLARE @rp_existing_id BIGINT=(SELECT TOP 1 role_permission_id FROM GRAC_New.cm_role_permission WHERE role_id=@rp_role_id AND menu_id=@rp_menu_id);
      IF @rp_existing_id IS NOT NULL
      BEGIN
        -- Idempotent upsert: refresh permission flags and reactivate when the same role/menu pair is re-saved.
        UPDATE GRAC_New.cm_role_permission
        SET can_view=@rp_can_view,can_add=@rp_can_add,can_edit=@rp_can_edit,can_inactive=@rp_can_inactive,can_approve=@rp_can_approve,
            status=@rp_status,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
        WHERE role_permission_id=@rp_existing_id;
        SET @new_id=@rp_existing_id;
        SET @audit_action=N'Edit';
      END
      ELSE
      BEGIN
        INSERT GRAC_New.cm_role_permission(role_id,menu_id,can_view,can_add,can_edit,can_inactive,can_approve,status,entered_by)
        VALUES(@rp_role_id,@rp_menu_id,@rp_can_view,@rp_can_add,@rp_can_edit,@rp_can_inactive,@rp_can_approve,@rp_status,@p_usr_id);
        SET @new_id=SCOPE_IDENTITY();
      END
    END
    ELSE
    BEGIN
      IF EXISTS(SELECT 1 FROM GRAC_New.cm_role_permission WHERE role_id=@rp_role_id AND menu_id=@rp_menu_id AND role_permission_id<>@p_id)
        THROW 50034,'Role permission already exists for this menu.',1;
      UPDATE GRAC_New.cm_role_permission
      SET role_id=@rp_role_id,menu_id=@rp_menu_id,
          can_view=@rp_can_view,can_add=@rp_can_add,can_edit=@rp_can_edit,can_inactive=@rp_can_inactive,can_approve=@rp_can_approve,
          status=@rp_status,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
      WHERE role_permission_id=@p_id;
    END
  END
  ELSE THROW 50003,'Use the typed onboarding procedure or extend cm_manage_repository for this repository area',1;

 IF @new_id>0
 BEGIN
    IF @p_entity_type='authorities' SELECT @after=(SELECT authority_code code,authority_name name,description,jurisdiction,website,status FROM GRAC_New.authority WHERE authority_id=@new_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=COALESCE(@record_reference,(SELECT CONCAT(authority_code,N' - ',authority_name) FROM GRAC_New.authority WHERE authority_id=@new_id));
    ELSE IF @p_entity_type='artifacts' SELECT @after=(SELECT authority_id authorityId,artifact_code code,artifact_name name,description,artifact_category category,status FROM GRAC_New.artifact WHERE artifact_id=@new_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=COALESCE(@record_reference,(SELECT CONCAT(artifact_code,N' - ',artifact_name) FROM GRAC_New.artifact WHERE artifact_id=@new_id));
    ELSE IF @p_entity_type='releases' SELECT @after=(SELECT artifact_id artifactId,version_no version,effective_dt effectiveDate,end_dt endDate,release_notes releaseNotes,status FROM GRAC_New.release WHERE release_id=@new_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=COALESCE(@record_reference,(SELECT CONCAT(a.artifact_name,N' / ',r.version_no) FROM GRAC_New.release r JOIN GRAC_New.artifact a ON a.artifact_id=r.artifact_id WHERE r.release_id=@new_id));
    ELSE IF @p_entity_type='statement-classifications' SELECT @after=(SELECT release_id releaseId,classification_code code,classification_scheme scheme,classification_name name,description,display_order displayOrder,status FROM GRAC_New.statement_classification WHERE statement_classification_id=@new_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=COALESCE(@record_reference,(SELECT classification_name FROM GRAC_New.statement_classification WHERE statement_classification_id=@new_id));
    ELSE IF @p_entity_type='source-structure' SELECT @after=(SELECT release_id releaseId,parent_node_id parentNodeId,node_type nodeType,node_reference reference,node_title title,description,display_order displayOrder,status FROM GRAC_New.source_structure_node WHERE structure_node_id=@new_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=COALESCE(@record_reference,(SELECT CONCAT(node_reference,N' - ',node_title) FROM GRAC_New.source_structure_node WHERE structure_node_id=@new_id));
ELSE IF @p_entity_type='framework-statements' SELECT @after=(SELECT release_id releaseId,structure_node_id structureNodeId,classification_id classificationId,statement_reference statementReference,statement_title statementTitle,statement_text statementText,statement_type statementType,remarks,display_order displayOrder,status FROM GRAC_New.framework_statement WHERE framework_statement_id=@new_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=COALESCE(@record_reference,(SELECT CONCAT(statement_reference,N' - ',statement_title) FROM GRAC_New.framework_statement WHERE framework_statement_id=@new_id));
    ELSE IF @p_entity_type='controls' SELECT @after=(SELECT control_code code,control_name name,control_domain_id domainId,control_sub_domain_id subDomainId,description,objective,status FROM GRAC_New.control WHERE control_id=@new_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=COALESCE(@record_reference,(SELECT CONCAT(control_code,N' - ',control_name) FROM GRAC_New.control WHERE control_id=@new_id));
   ELSE IF @p_entity_type='control-domains' SELECT @after=(SELECT domain_name name,description,status FROM GRAC_New.control_domain WHERE control_domain_id=@new_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=COALESCE(@record_reference,(SELECT domain_name FROM GRAC_New.control_domain WHERE control_domain_id=@new_id));
   ELSE IF @p_entity_type='control-sub-domains' SELECT @after=(SELECT control_domain_id domainId,sub_domain_name name,description,status FROM GRAC_New.control_sub_domain WHERE control_sub_domain_id=@new_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=COALESCE(@record_reference,(SELECT sub_domain_name FROM GRAC_New.control_sub_domain WHERE control_sub_domain_id=@new_id));
    ELSE IF @p_entity_type='requirements' SELECT @after=(SELECT requirement_code code,requirement_name name,requirement_statement statement,objective,COALESCE(keywords,N'') keywords,status FROM GRAC_New.requirement WHERE requirement_id=@new_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=COALESCE(@record_reference,(SELECT CONCAT(requirement_code,N' - ',requirement_name) FROM GRAC_New.requirement WHERE requirement_id=@new_id));
    ELSE IF @p_entity_type='obligations' SELECT @after=(SELECT requirement_id requirementId,release_id releaseId,obligation_text obligationText,frequency_type frequencyType,retention_requirement retentionRequirement,evidence_requirement evidenceRequirement,status FROM GRAC_New.requirement_obligation WHERE obligation_id=@new_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=COALESCE(@record_reference,(SELECT COALESCE(NULLIF(obligation_text,N''),CONCAT(N'Obligation #',obligation_id)) FROM GRAC_New.requirement_obligation WHERE obligation_id=@new_id));
   ELSE IF @p_entity_type='applicability-rules' SELECT @after=(SELECT artifact_id artifactId,release_id releaseId,rule_name name,rule_expression_json expression,priority_no priority,outcome,status FROM GRAC_New.applicability_rule WHERE applicability_rule_id=@new_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=COALESCE(@record_reference,(SELECT rule_name FROM GRAC_New.applicability_rule WHERE applicability_rule_id=@new_id));
   ELSE IF @p_entity_type='changes' SELECT @after=(SELECT entity_type entityType,entity_id entityId,change_type changeType,change_summary summary,effective_dt effectiveDate,severity,status FROM GRAC_New.change_event WHERE change_event_id=@new_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=COALESCE(@record_reference,(SELECT CONCAT(N'CHG-',change_event_id) FROM GRAC_New.change_event WHERE change_event_id=@new_id));
   ELSE IF @p_entity_type='impact-analysis' SELECT @after=(SELECT change_event_id changeEventId,impacted_entity_type impactedEntityType,impacted_entity_id impactedEntityId,organization_id organizationId,impact_summary summary,recommended_action recommendedAction,status FROM GRAC_New.impact_analysis WHERE impact_analysis_id=@new_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=COALESCE(@record_reference,(SELECT CONCAT(N'IMP-',impact_analysis_id) FROM GRAC_New.impact_analysis WHERE impact_analysis_id=@new_id));
    ELSE IF @p_entity_type='notifications' SELECT @after=(SELECT impact_analysis_id impactAnalysisId,organization_id organizationId,notification_type type,subject,message_body message,severity,recommended_action recommendedAction,status FROM GRAC_New.notification WHERE notification_id=@new_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=COALESCE(@record_reference,(SELECT subject FROM GRAC_New.notification WHERE notification_id=@new_id));
    ELSE IF @p_entity_type='approval-workflow' SELECT @after=(SELECT module_name moduleName,maker_roles makerRoles,maker_users makerUsers,checker_roles checkerRoles,checker_users checkerUsers,approval_required approvalRequired,self_approval_allowed selfApprovalAllowed,minimum_approvers minimumApprovers,status FROM GRAC_New.approval_workflow_config WHERE workflow_config_id=@new_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=COALESCE(@record_reference,(SELECT module_name FROM GRAC_New.approval_workflow_config WHERE workflow_config_id=@new_id));
    ELSE IF @p_entity_type='role-permissions' SELECT @after=(SELECT role_id roleId,menu_id menuId,can_view canView,can_add canAdd,can_edit canEdit,can_inactive canInactive,can_approve canApprove,status FROM GRAC_New.cm_role_permission WHERE role_permission_id=@new_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=COALESCE(@record_reference,(SELECT CONCAT(r.role_name,N' / ',m.menu_name) FROM GRAC_New.cm_role_permission rp JOIN GRAC_New.cm_role r ON r.role_id=rp.role_id JOIN GRAC_New.cm_menu m ON m.menu_id=rp.menu_id WHERE rp.role_permission_id=@new_id));
    ELSE IF @p_entity_type='user-management' SELECT @after=(SELECT user_name userName,login_id loginId,email,status,remarks,is_password_change_required isPasswordChangeRequired FROM GRAC_New.cm_user WHERE user_id=@new_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=COALESCE(@record_reference,(SELECT CONCAT(user_name,N' - ',login_id) FROM GRAC_New.cm_user WHERE user_id=@new_id));
    ELSE IF @p_entity_type='role-management' SELECT @after=(SELECT role_name roleName,description,status FROM GRAC_New.cm_role WHERE role_id=@new_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=COALESCE(@record_reference,(SELECT role_name FROM GRAC_New.cm_role WHERE role_id=@new_id));
    ELSE IF @p_entity_type='menu-management' SELECT @after=(SELECT parent_menu_id parentMenuId,menu_name menuName,menu_code menuCode,route_url routeUrl,display_order displayOrder,icon,status FROM GRAC_New.cm_menu WHERE menu_id=@new_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@record_reference=COALESCE(@record_reference,(SELECT menu_name FROM GRAC_New.cm_menu WHERE menu_id=@new_id));
 END

 DECLARE @audit_event_id BIGINT;
 DECLARE @audit_details TABLE(
   field_key NVARCHAR(128) NULL,
   field_name NVARCHAR(128) NOT NULL,
   old_value NVARCHAR(MAX) NULL,
   new_value NVARCHAR(MAX) NULL,
   action_type NVARCHAR(40) NOT NULL
 );

 INSERT GRAC_New.audit_trace_event(entity_type,entity_id,action_type,table_name,record_reference,remarks,before_json,after_json,entered_by)
 VALUES(@p_entity_type,@new_id,@audit_action,@audit_table,@record_reference,JSON_VALUE(@p_payload,'$.remarks'),@before,@after,@p_usr_id);
 SET @audit_event_id=SCOPE_IDENTITY();

 IF @audit_action='Add' OR NULLIF(@before,N'') IS NULL
 BEGIN
   INSERT @audit_details(field_key,field_name,old_value,new_value,action_type)
   SELECT a.[key],
     CASE a.[key]
        WHEN N'code' THEN N'Code'
        WHEN N'name' THEN N'Name'
        WHEN N'authorityId' THEN N'Authority'
       WHEN N'artifactId' THEN N'Artifact'
       WHEN N'releaseId' THEN N'Release'
       WHEN N'parentNodeId' THEN N'Parent Node'
       WHEN N'nodeType' THEN N'Node Type'
       WHEN N'structureNodeId' THEN N'Source Structure'
       WHEN N'statementReference' THEN N'Statement Reference'
       WHEN N'statementTitle' THEN N'Statement Title'
       WHEN N'statementText' THEN N'Statement Text'
       WHEN N'statementType' THEN N'Statement Type'
       WHEN N'classificationId' THEN N'Statement Classification'
       WHEN N'displayOrder' THEN N'Display Order'
       WHEN N'domainId' THEN N'Domain'
       WHEN N'subDomainId' THEN N'Sub Domain'
       WHEN N'requirementId' THEN N'Practice'
       WHEN N'obligationText' THEN N'Obligation Name'
       WHEN N'frequencyType' THEN N'Execution Frequency'
       WHEN N'evidenceRequirement' THEN N'Evidence Requirement'
       WHEN N'retentionRequirement' THEN N'Retention Requirement'
       WHEN N'effectiveDate' THEN N'Effective Date'
       WHEN N'endDate' THEN N'End Date'
       WHEN N'releaseNotes' THEN N'Release Notes'
       WHEN N'changeType' THEN N'Change Type'
       WHEN N'impactedEntityType' THEN N'Impacted Entity Type'
       WHEN N'impactedEntityId' THEN N'Impacted Entity ID'
       WHEN N'recommendedAction' THEN N'Recommended Action'
       WHEN N'roleId' THEN N'Role'
       WHEN N'menuId' THEN N'Menu'
       WHEN N'canView' THEN N'Can View'
       WHEN N'canAdd' THEN N'Can Add'
       WHEN N'canEdit' THEN N'Can Edit'
       WHEN N'canInactive' THEN N'Can Inactive'
       WHEN N'canApprove' THEN N'Can Approve'
        ELSE UPPER(LEFT(a.[key],1))+SUBSTRING(a.[key],2,200)
     END,
     NULL,
     CONVERT(NVARCHAR(MAX),a.[value]),
     @audit_action
   FROM OPENJSON(@after) a
   WHERE a.[key] NOT IN (N'updatedBy',N'updatedDt',N'enteredBy',N'enteredDt')
    AND LEFT(a.[key],2)<>N'__'
     AND ISNULL(CONVERT(NVARCHAR(MAX),a.[value]),N'')<>N'';
 END
 ELSE
 BEGIN
   ;WITH before_values AS (
     SELECT [key],CONVERT(NVARCHAR(MAX),[value]) old_value
     FROM OPENJSON(@before)
     WHERE [key] NOT IN (N'updatedBy',N'updatedDt',N'enteredBy',N'enteredDt')
      AND LEFT([key],2)<>N'__'
   ),
   after_values AS (
     SELECT [key],CONVERT(NVARCHAR(MAX),[value]) new_value
     FROM OPENJSON(@after)
     WHERE [key] NOT IN (N'updatedBy',N'updatedDt',N'enteredBy',N'enteredDt')
      AND LEFT([key],2)<>N'__'
   ),
   changed AS (
     SELECT COALESCE(a.[key],b.[key]) FieldKey,b.old_value OldValue,a.new_value NewValue
     FROM after_values a
     FULL OUTER JOIN before_values b ON b.[key]=a.[key]
     WHERE ISNULL(b.old_value,N'')<>ISNULL(a.new_value,N'')
   )
   INSERT @audit_details(field_key,field_name,old_value,new_value,action_type)
   SELECT changed.FieldKey,
     CASE changed.FieldKey
        WHEN N'code' THEN N'Code'
        WHEN N'name' THEN N'Name'
        WHEN N'authorityId' THEN N'Authority'
       WHEN N'artifactId' THEN N'Artifact'
       WHEN N'releaseId' THEN N'Release'
       WHEN N'parentNodeId' THEN N'Parent Node'
       WHEN N'nodeType' THEN N'Node Type'
       WHEN N'structureNodeId' THEN N'Source Structure'
       WHEN N'statementReference' THEN N'Statement Reference'
       WHEN N'statementTitle' THEN N'Statement Title'
       WHEN N'statementText' THEN N'Statement Text'
       WHEN N'statementType' THEN N'Statement Type'
       WHEN N'classificationId' THEN N'Statement Classification'
       WHEN N'displayOrder' THEN N'Display Order'
       WHEN N'domainId' THEN N'Domain'
       WHEN N'subDomainId' THEN N'Sub Domain'
       WHEN N'requirementId' THEN N'Practice'
       WHEN N'obligationText' THEN N'Obligation Name'
       WHEN N'frequencyType' THEN N'Execution Frequency'
       WHEN N'evidenceRequirement' THEN N'Evidence Requirement'
       WHEN N'retentionRequirement' THEN N'Retention Requirement'
       WHEN N'effectiveDate' THEN N'Effective Date'
       WHEN N'endDate' THEN N'End Date'
       WHEN N'releaseNotes' THEN N'Release Notes'
       WHEN N'changeType' THEN N'Change Type'
        WHEN N'impactedEntityType' THEN N'Impacted Entity Type'
        WHEN N'impactedEntityId' THEN N'Impacted Entity ID'
        WHEN N'recommendedAction' THEN N'Recommended Action'
        WHEN N'roleId' THEN N'Role'
        WHEN N'menuId' THEN N'Menu'
        WHEN N'canView' THEN N'Can View'
        WHEN N'canAdd' THEN N'Can Add'
        WHEN N'canEdit' THEN N'Can Edit'
        WHEN N'canInactive' THEN N'Can Inactive'
        WHEN N'canApprove' THEN N'Can Approve'
        ELSE UPPER(LEFT(changed.FieldKey,1))+SUBSTRING(changed.FieldKey,2,200)
     END,
     changed.OldValue,
     changed.NewValue,
     CASE WHEN changed.FieldKey=N'status' THEN N'Status Change' ELSE @audit_action END
   FROM changed;
 END

 INSERT GRAC_New.audit_trace_detail(audit_event_id,field_name,old_value,new_value,entered_by)
 SELECT @audit_event_id,field_name,old_value,new_value,@p_usr_id
 FROM @audit_details;

 INSERT GRAC_New.audit_trace(audit_event_id,entity_type,entity_id,action_type,table_name,record_reference,remarks,before_json,after_json,entered_by)
 VALUES(@audit_event_id,@p_entity_type,@new_id,@audit_action,@audit_table,@record_reference,JSON_VALUE(@p_payload,'$.remarks'),@before,@after,@p_usr_id);
 COMMIT; SELECT @new_id Id;
END
GO

-- ---------------------------------------------------------------------
-- 2. After: prove the branch compiled and the generator is reachable.
-- ---------------------------------------------------------------------
IF OBJECT_ID('dbo.cm_manage_repository','P') IS NULL
  THROW 51050, 'cm_manage_repository was not created.', 1;
IF NOT EXISTS(SELECT 1 FROM sys.sql_modules WHERE object_id=OBJECT_ID('dbo.cm_manage_repository') AND definition LIKE '%@practice_code%')
  THROW 51050, 'cm_manage_repository does not contain the Practice Code generator.', 1;
SELECT 'cm_manage_repository' AS ObjectName, 'Practice Code auto-generation active' AS Result;
GO
