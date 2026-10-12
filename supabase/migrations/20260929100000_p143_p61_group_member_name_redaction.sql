-- P61: do not send a blocked group member's profile name to clients.
-- Keep group membership rows available; replace only the display projection.
begin;

create or replace function public.list_group_members(p_group_id uuid)
returns table(group_id uuid, user_id uuid, display_name text, role text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
begin
  if actor is null
     or not private.group_member(p_group_id, actor) then
    raise exception 'group access denied' using errcode = '42501';
  end if;

  return query
  select member.group_id,
         member.user_id,
         case
           when member.user_id <> actor and exists (
             select 1
             from public.blocks edge
             where (edge.blocker_user_id = actor
                    and edge.blocked_user_id = member.user_id)
                or (edge.blocker_user_id = member.user_id
                    and edge.blocked_user_id = actor)
           ) then 'ブロック中のメンバー'::text
           else coalesce(profile.display_name, '利用者')
         end,
         member.role
  from public.group_members member
  left join public.profiles profile on profile.user_id = member.user_id
  where member.group_id = p_group_id
  order by member.joined_at;
end;
$$;

commit;
