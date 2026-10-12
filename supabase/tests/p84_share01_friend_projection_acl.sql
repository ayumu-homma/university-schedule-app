begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(16);

select extensions.ok(
  to_regprocedure('public.get_friend_schedule(uuid,uuid,timestamptz,timestamptz)') is not null,
  'friend schedule RPC exists at current head'
);
select extensions.ok(
  not has_function_privilege('anon','public.get_friend_schedule(uuid,uuid,timestamptz,timestamptz)','execute'),
  'anonymous cannot execute friend schedule RPC'
);
select extensions.ok(
  not has_function_privilege('public','public.get_friend_schedule(uuid,uuid,timestamptz,timestamptz)','execute'),
  'PUBLIC cannot execute friend schedule RPC'
);
select extensions.ok(
  has_function_privilege('authenticated','public.get_friend_schedule(uuid,uuid,timestamptz,timestamptz)','execute'),
  'authenticated can execute friend schedule RPC'
);

select extensions.ok(
  to_regprocedure('public.get_visible_events(uuid,timestamptz,timestamptz)') is not null,
  'event projection RPC exists at current head'
);
select extensions.ok(
  not has_function_privilege('anon','public.get_visible_events(uuid,timestamptz,timestamptz)','execute'),
  'anonymous cannot execute event projection RPC'
);
select extensions.ok(
  not has_function_privilege('public','public.get_visible_events(uuid,timestamptz,timestamptz)','execute'),
  'PUBLIC cannot execute event projection RPC'
);
select extensions.ok(
  has_function_privilege('authenticated','public.get_visible_events(uuid,timestamptz,timestamptz)','execute'),
  'authenticated can execute event projection RPC'
);

select extensions.ok(
  to_regprocedure('public.set_friend_visibility(uuid,uuid,uuid,text,uuid,public.visibility_level,bigint,uuid,text)') is not null,
  'visibility mutation RPC exists at current head'
);
select extensions.ok(
  not has_function_privilege('anon','public.set_friend_visibility(uuid,uuid,uuid,text,uuid,public.visibility_level,bigint,uuid,text)','execute'),
  'anonymous cannot execute visibility mutation RPC'
);
select extensions.ok(
  not has_function_privilege('public','public.set_friend_visibility(uuid,uuid,uuid,text,uuid,public.visibility_level,bigint,uuid,text)','execute'),
  'PUBLIC cannot execute visibility mutation RPC'
);
select extensions.ok(
  has_function_privilege('authenticated','public.set_friend_visibility(uuid,uuid,uuid,text,uuid,public.visibility_level,bigint,uuid,text)','execute'),
  'authenticated can execute visibility mutation RPC'
);

select extensions.ok(
  to_regprocedure('private.resolve_visible_events_for(uuid,timestamptz,timestamptz)') is not null,
  'private event resolver exists at current head'
);
select extensions.ok(
  not has_function_privilege('anon','private.resolve_visible_events_for(uuid,timestamptz,timestamptz)','execute'),
  'anonymous cannot execute private event resolver'
);
select extensions.ok(
  not has_function_privilege('authenticated','private.resolve_visible_events_for(uuid,timestamptz,timestamptz)','execute'),
  'authenticated cannot execute private event resolver'
);
select extensions.ok(
  not has_function_privilege('public','private.resolve_visible_events_for(uuid,timestamptz,timestamptz)','execute'),
  'PUBLIC cannot execute private event resolver'
);

select * from extensions.finish();
rollback;
