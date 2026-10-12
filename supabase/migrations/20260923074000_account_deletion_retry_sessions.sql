-- Preserve caller sessions until the irreversible Auth Admin step so a failed
-- Storage deletion can be retried by the same authenticated owner.
begin;

create or replace function public.prepare_account_deletion_database(p_operation_id uuid)
returns jsonb language plpgsql volatile security definer
set search_path=pg_catalog,public,private,auth,storage as $$
declare o private.account_deletion_operations%rowtype; action_row jsonb; v_group_id uuid;
  successor uuid; actor uuid; manifest jsonb; fk record;
begin
  select * into o from private.account_deletion_operations where operation_id=p_operation_id for update;
  if not found then raise exception 'deletion operation unavailable' using errcode='42501'; end if;
  if o.phase in ('object_cleanup','auth_delete','complete') then
    return jsonb_build_object('operation_id',o.operation_id,'phase',o.phase,
      'user_id',o.user_id,'objects',o.object_manifest);
  end if;
  actor:=o.user_id;
  perform pg_advisory_xact_lock(hashtextextended('safety-user:'||actor::text,9010));
  if not exists(select 1 from private.user_safety_state s where s.user_id=actor
      and s.status='deletion_pending') then
    raise exception 'account is not pending deletion' using errcode='42501';
  end if;

  select coalesce(jsonb_agg(x.item order by x.bucket_id,x.name),'[]'::jsonb) into manifest
  from (
    select distinct so.bucket_id,so.name,
      jsonb_build_object('bucket_id',so.bucket_id,'name',so.name) item
    from storage.objects so
    where so.owner_id=actor::text
       or (so.bucket_id='schedule-documents' and so.name like actor::text||'/%')
    union
    select 'schedule-documents',ds.storage_path,
      jsonb_build_object('bucket_id','schedule-documents','name',ds.storage_path)
    from public.document_sources ds where ds.owner_user_id=actor
  ) x;

  -- Explicitly transfer or disband owned groups as the user confirmed.
  for action_row in select value from jsonb_array_elements(o.group_actions) loop
    v_group_id:=(action_row->>'group_id')::uuid;
    successor:=nullif(action_row->>'successor_id','')::uuid;
    perform pg_advisory_xact_lock(hashtextextended('group:'||v_group_id::text,9010));
    perform pg_advisory_xact_lock(hashtextextended('safety-group:'||v_group_id::text,9010));
    if action_row->>'action'='transfer' then
      if not exists(select 1 from public.groups g join public.group_members gm
          on gm.group_id=g.id and gm.user_id=successor
        where g.id=v_group_id and g.owner_user_id=actor and private.safety_actor_active(successor)) then
        raise exception 'group transfer target changed; retry required' using errcode='40001';
      end if;
      update public.groups set owner_user_id=successor,updated_at=clock_timestamp() where id=v_group_id;
      delete from public.group_members gm where gm.group_id=v_group_id and gm.user_id=actor;
      update public.group_members gm set role='owner' where gm.group_id=v_group_id and gm.user_id=successor;
      update public.events e set owner_user_id=successor where e.group_id=v_group_id and e.owner_user_id=actor;
      update public.calendars c set owner_user_id=successor where c.group_id=v_group_id and c.owner_user_id=actor;
      insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata)
        values(actor,'account_deletion_group_transfer','group',v_group_id,
          jsonb_build_object('operation_id',p_operation_id,'successor_user_id',successor));
    else
      delete from public.group_invitations gi where gi.group_id=v_group_id;
      delete from public.group_targeted_invitations gti where gti.group_id=v_group_id;
      delete from public.event_reactions r using public.events e
        where r.event_id=e.id and e.group_id=v_group_id;
      delete from public.event_participants ep using public.events e
        where ep.event_id=e.id and e.group_id=v_group_id;
      delete from public.event_comments c using public.events e
        where c.event_id=e.id and e.group_id=v_group_id;
      delete from public.events e where e.group_id=v_group_id;
      delete from public.calendars c where c.group_id=v_group_id;
      delete from public.group_members gm where gm.group_id=v_group_id;
      delete from public.groups g where g.id=v_group_id and g.owner_user_id=actor;
      insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata)
        values(actor,'account_deletion_group_disband','group',v_group_id,
          jsonb_build_object('operation_id',p_operation_id,'confirmed_by_owner',true));
    end if;
  end loop;

  -- Preserve other members' events/calendars in non-owned groups by handing
  -- their ownership to the current group owner; delete personal schedule data.
  update public.events e set owner_user_id=g.owner_user_id
    from public.groups g where e.owner_user_id=actor and e.group_id=g.id;
  delete from public.event_reactions r using public.events e
    where r.event_id=e.id and e.owner_user_id=actor and e.group_id is null;
  delete from public.event_participants ep using public.events e
    where ep.event_id=e.id and e.owner_user_id=actor and e.group_id is null;
  delete from public.event_comments c using public.events e
    where c.event_id=e.id and e.owner_user_id=actor and e.group_id is null;
  delete from public.events where owner_user_id=actor and group_id is null;
  update public.event_comments set body='[削除済みユーザー]',author_user_id=null
    where author_user_id=actor;
  update public.calendars c set owner_user_id=g.owner_user_id
    from public.groups g where c.owner_user_id=actor and c.group_id=g.id;
  delete from public.calendars where owner_user_id=actor and group_id is null;
  delete from public.assignments where owner_user_id=actor;
  delete from public.user_courses where owner_user_id=actor;
  delete from public.period_settings where owner_user_id=actor;
  delete from public.exams where owner_user_id=actor;
  delete from public.terms where owner_user_id=actor;
  delete from public.friendships where requester_user_id=actor or addressee_user_id=actor;
  delete from public.blocks where blocker_user_id=actor or blocked_user_id=actor;
  delete from public.reports where reporter_user_id=actor;
  delete from public.course_template_reports where reported_by=actor;
  delete from public.university_requests where requested_by=actor;
  delete from public.group_invitations where created_by=actor;
  delete from public.course_template_copy_events where copied_by=actor;
  delete from public.event_comments where author_user_id=actor;

  -- Null surviving attribution where nullable; delete only rows whose schema
  -- requires an Auth identity. This catalog-derived pass covers later user FKs.
  for fk in
    select n.nspname,c.relname,a.attname,a.attnotnull
    from pg_constraint f join pg_class c on c.oid=f.conrelid
      join pg_namespace n on n.oid=c.relnamespace
      join unnest(f.conkey) with ordinality k(attnum,ord) on true
      join pg_attribute a on a.attrelid=c.oid and a.attnum=k.attnum
    where f.contype='f' and f.confrelid='auth.users'::regclass
    -- Keep Auth sessions alive while Storage cleanup is retryable. Auth Admin
    -- deleteUser removes these together with the identity at the final gate.
    and not (n.nspname='auth' and c.relname in ('sessions','refresh_tokens'))
    and not (n.nspname='private' and c.relname in
      ('account_deletion_operations','user_safety_state','user_safety_notices'))
    order by n.nspname,c.relname,a.attname
  loop
    if fk.attnotnull then
      execute format('delete from %I.%I where %I=$1',fk.nspname,fk.relname,fk.attname) using actor;
    else
      execute format('update %I.%I set %I=null where %I=$1',fk.nspname,fk.relname,fk.attname,fk.attname) using actor;
    end if;
  end loop;
  delete from private.user_safety_notices where recipient_user_id=actor or created_by=actor;
  update private.user_safety_state set changed_by=null where changed_by=actor;
  update public.groups set suspended_by=null where suspended_by=actor;
  update private.account_deletion_operations set phase='object_cleanup',object_manifest=manifest,
    attempts=attempts+1,last_error_code=null,updated_at=clock_timestamp()
    where operation_id=p_operation_id;
  return jsonb_build_object('operation_id',p_operation_id,'phase','object_cleanup',
    'user_id',actor,'objects',manifest);
end;
$$;

revoke all on function public.prepare_account_deletion_database(uuid) from public,anon,authenticated;
grant execute on function public.prepare_account_deletion_database(uuid) to service_role;
notify pgrst,'reload schema';

commit;
