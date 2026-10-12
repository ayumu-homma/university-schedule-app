begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(3);

select extensions.ok(
  not has_function_privilege('service_role','public.admin_resolve_report(uuid,text,text,uuid)','EXECUTE'),
  'service role cannot invoke moderation decisions'
);
select extensions.ok(
  has_function_privilege('authenticated','public.admin_resolve_report(uuid,text,text,uuid)','EXECUTE'),
  'authenticated sessions retain the guarded moderation RPC surface'
);
select extensions.ok(
  not has_function_privilege('anon','public.admin_resolve_report(uuid,text,text,uuid)','EXECUTE'),
  'anonymous sessions cannot invoke moderation decisions'
);

select * from extensions.finish();
rollback;
