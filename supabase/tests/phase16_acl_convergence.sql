-- Phase 16 append-only ACL convergence checks.
begin;
select plan(9);

select extensions.ok(
  has_table_privilege('authenticated','public.user_courses','SELECT')
  and not has_table_privilege('authenticated','public.user_courses','INSERT')
  and not has_table_privilege('authenticated','public.user_courses','UPDATE')
  and not has_table_privilege('authenticated','public.user_courses','DELETE')
  and not has_table_privilege('anon','public.user_courses','SELECT'),
  'authenticated retains schedule reads while direct user-course writes stay RPC-only'
);
select extensions.ok(
  not has_table_privilege('authenticated','public.course_templates','SELECT')
  and not has_table_privilege('authenticated','public.course_template_edit_proposals','SELECT')
  and not has_table_privilege('authenticated','public.course_template_reports','SELECT')
  and not has_table_privilege('authenticated','public.course_template_duplicate_candidates','SELECT'),
  'template and moderation tables remain redacted from direct authenticated reads'
);
select extensions.ok(
  not has_table_privilege('anon','public.course_templates','SELECT')
  and not has_table_privilege('anon','public.course_template_copy_events','SELECT')
  and not has_table_privilege('authenticated','public.course_template_copy_events','SELECT'),
  'anonymous and authenticated clients cannot read raw template lineage or copy events'
);
select extensions.ok(
  has_table_privilege('service_role','public.course_template_copy_events','SELECT'),
  'service_role retains backend access to copy-event evidence'
);
select extensions.ok(
  has_function_privilege('authenticated','public.submit_university_request(text,text,text)','EXECUTE')
  and not has_function_privilege('public','public.submit_university_request(text,text,text)','EXECUTE')
  and not has_function_privilege('anon','public.submit_university_request(text,text,text)','EXECUTE')
  and not has_function_privilege('service_role','public.submit_university_request(text,text,text)','EXECUTE'),
  'legacy university request RPC remains authenticated-only'
);
select extensions.ok(
  has_function_privilege('authenticated','public.submit_university_request(text,text,text,uuid)','EXECUTE')
  and not has_function_privilege('service_role','public.submit_university_request(text,text,text,uuid)','EXECUTE')
  and not has_function_privilege('service_role','public.publish_course_template(uuid,uuid)','EXECUTE')
  and not has_function_privilege('service_role','public.copy_course_template(uuid,uuid)','EXECUTE'),
  'receipt-backed student RPCs deny service_role browser entry points'
);
select extensions.ok(
  has_function_privilege('authenticated','public.review_course_template_update(uuid,text,bigint,bigint,uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.review_course_template_update(uuid,text,bigint)','EXECUTE')
  and not has_function_privilege('service_role','public.review_course_template_update(uuid,text,bigint,bigint,uuid)','EXECUTE'),
  'only the durable explicit-update overload is callable by authenticated clients'
);
select extensions.ok(
  has_function_privilege('authenticated','public.admin_merge_course_templates(uuid,uuid,bigint,bigint,text,uuid)','EXECUTE')
  and not has_function_privilege('anon','public.admin_merge_course_templates(uuid,uuid,bigint,bigint,text,uuid)','EXECUTE')
  and not has_function_privilege('service_role','public.admin_merge_course_templates(uuid,uuid,bigint,bigint,text,uuid)','EXECUTE'),
  'admin merge is authenticated RPC-only and performs its own admin check'
);
select extensions.ok(
  not has_table_privilege('authenticated','public.audit_logs','SELECT')
  and not has_table_privilege('authenticated','public.reports','SELECT')
  and not has_table_privilege('authenticated','private.global_admins','SELECT'),
  'Phase15 audit, report, and admin registry tables remain hidden'
);

select * from finish();
rollback;
