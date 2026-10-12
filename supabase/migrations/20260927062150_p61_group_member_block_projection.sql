-- P61: expose only the symmetric blocked-member projection for one active
-- group the authenticated caller belongs to. No direction or actor is returned.
begin;

create or replace function public.list_group_member_blocked_users(p_group_id uuid)
returns table(user_id uuid)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
begin
  if actor is null or auth.role() <> 'authenticated'
     or not private.safety_actor_active(actor)
     or not private.safety_group_active(p_group_id)
     or not exists (
       select 1
       from public.group_members viewer_membership
       where viewer_membership.group_id = p_group_id
         and viewer_membership.user_id = actor
     ) then
    raise exception 'group access denied' using errcode = '42501';
  end if;

  return query
  select member.user_id
  from public.group_members member
  where member.group_id = p_group_id
    and member.user_id <> actor
    and exists (
      select 1
      from public.blocks block_edge
      where (block_edge.blocker_user_id = actor
             and block_edge.blocked_user_id = member.user_id)
         or (block_edge.blocker_user_id = member.user_id
             and block_edge.blocked_user_id = actor)
    )
  order by member.user_id;
end;
$$;

revoke all on function public.list_group_member_blocked_users(uuid)
  from public, anon, service_role;
grant execute on function public.list_group_member_blocked_users(uuid)
  to authenticated;

commit;
