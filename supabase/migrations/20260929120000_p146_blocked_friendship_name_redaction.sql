create or replace function public.list_friendships()
returns setof jsonb
language sql
security definer
set search_path = pg_catalog, public, private
stable
as $$
  select jsonb_build_object(
    'friendship_id', f.id,
    'requester_user_id', f.requester_user_id,
    'addressee_user_id', f.addressee_user_id,
    'other_user_id', case when f.requester_user_id = auth.uid() then f.addressee_user_id else f.requester_user_id end,
    'other_display_name', case when f.status = 'blocked' then 'ブロック中の利用者' else p.display_name end,
    'viewer_role', case when f.requester_user_id = auth.uid() then 'requester' else 'addressee' end,
    'status', f.status,
    'incarnation', f.incarnation,
    'revision', f.revision,
    'updated_at', f.updated_at
  )
  from public.friendships f
  join public.profiles p on p.user_id = case when f.requester_user_id = auth.uid() then f.addressee_user_id else f.requester_user_id end
  where auth.uid() is not null and (f.requester_user_id = auth.uid() or f.addressee_user_id = auth.uid())
  order by f.updated_at desc;
$$;
