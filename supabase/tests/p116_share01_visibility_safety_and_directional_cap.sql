begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(14);

select extensions.ok(
  not has_function_privilege('anon','private.resolve_visible_events_for(uuid,timestamptz,timestamptz)','execute'),
  'resolver wrapper is not executable by anon'
);
select extensions.ok(
  not has_function_privilege('authenticated','private.resolve_visible_events_for(uuid,timestamptz,timestamptz)','execute'),
  'resolver wrapper is not executable by authenticated'
);
select extensions.ok(
  not has_function_privilege('authenticated','private.phase15_resolve_visible_events_for_base(uuid,timestamptz,timestamptz)','execute'),
  'private projection base is not executable by authenticated'
);

insert into auth.users(id) values
 ('8b116000-1160-4160-8160-000000000001'),
 ('8b116000-1160-4160-8160-000000000002'),
 ('8b116000-1160-4160-8160-000000000003'),
 ('8b116000-1160-4160-8160-000000000004'),
 ('8b116000-1160-4160-8160-000000000005'),
 ('8b116000-1160-4160-8160-000000000006'),
 ('8b116000-1160-4160-8160-000000000007')
on conflict(id) do nothing;

insert into public.profiles(user_id,display_name,default_visibility) values
 ('8b116000-1160-4160-8160-000000000001','P116 owner','PRIVATE'),
 ('8b116000-1160-4160-8160-000000000002','P116 friend','PRIVATE'),
 ('8b116000-1160-4160-8160-000000000003','P116 suspended viewer','PRIVATE'),
 ('8b116000-1160-4160-8160-000000000004','P116 suspended owner','PRIVATE'),
 ('8b116000-1160-4160-8160-000000000005','P116 second friend','PRIVATE'),
 ('8b116000-1160-4160-8160-000000000006','P116 group-only member','PRIVATE'),
 ('8b116000-1160-4160-8160-000000000007','P116 friend without rule','PRIVATE')
on conflict(user_id) do update
set display_name=excluded.display_name, default_visibility=excluded.default_visibility;

insert into private.user_safety_state(user_id,status) values
 ('8b116000-1160-4160-8160-000000000003','suspended'),
 ('8b116000-1160-4160-8160-000000000004','suspended');

insert into public.friendships(id,requester_user_id,addressee_user_id,status,incarnation) values
 ('8a116000-1160-4160-8160-000000000001','8b116000-1160-4160-8160-000000000001','8b116000-1160-4160-8160-000000000002','accepted','8a116000-1160-4160-8160-000000000011'),
 ('8a116000-1160-4160-8160-000000000002','8b116000-1160-4160-8160-000000000001','8b116000-1160-4160-8160-000000000003','accepted','8a116000-1160-4160-8160-000000000012'),
 ('8a116000-1160-4160-8160-000000000003','8b116000-1160-4160-8160-000000000004','8b116000-1160-4160-8160-000000000005','accepted','8a116000-1160-4160-8160-000000000013'),
 ('8a116000-1160-4160-8160-000000000004','8b116000-1160-4160-8160-000000000001','8b116000-1160-4160-8160-000000000007','accepted','8a116000-1160-4160-8160-000000000014');

insert into public.friend_visibility_rules(
 friendship_id,relationship_incarnation,owner_user_id,friend_user_id,
 target_kind,target_id,target_value,mode,visibility_level
) values
 ('8a116000-1160-4160-8160-000000000001','8a116000-1160-4160-8160-000000000011','8b116000-1160-4160-8160-000000000001','8b116000-1160-4160-8160-000000000002','default',null,null,'explicit','FULL'),
 ('8a116000-1160-4160-8160-000000000001','8a116000-1160-4160-8160-000000000011','8b116000-1160-4160-8160-000000000001','8b116000-1160-4160-8160-000000000002','event','8e116000-1160-4160-8160-000000000002',null,'explicit','BUSY_ONLY'),
 ('8a116000-1160-4160-8160-000000000001','8a116000-1160-4160-8160-000000000011','8b116000-1160-4160-8160-000000000001','8b116000-1160-4160-8160-000000000002','event','8e116000-1160-4160-8160-000000000003',null,'explicit','FULL'),
 ('8a116000-1160-4160-8160-000000000002','8a116000-1160-4160-8160-000000000012','8b116000-1160-4160-8160-000000000001','8b116000-1160-4160-8160-000000000003','default',null,null,'explicit','FULL'),
 ('8a116000-1160-4160-8160-000000000003','8a116000-1160-4160-8160-000000000013','8b116000-1160-4160-8160-000000000004','8b116000-1160-4160-8160-000000000005','default',null,null,'explicit','FULL');

insert into public.calendars(id,owner_user_id,name,default_visibility) values
 ('8d116000-1160-4160-8160-000000000001','8b116000-1160-4160-8160-000000000001','P116 inherited calendar',null),
 ('8d116000-1160-4160-8160-000000000002','8b116000-1160-4160-8160-000000000001','P116 active group calendar',null),
 ('8d116000-1160-4160-8160-000000000003','8b116000-1160-4160-8160-000000000004','P116 suspended owner calendar',null);

insert into public.groups(id,owner_user_id,name,type,event_create_policy,default_visibility,suspended_at) values
 ('8c116000-1160-4160-8160-000000000001','8b116000-1160-4160-8160-000000000001','P116 active group','friends','member','FULL',null),
 ('8c116000-1160-4160-8160-000000000002','8b116000-1160-4160-8160-000000000001','P116 suspended group','friends','member','FULL',null),
 ('8c116000-1160-4160-8160-000000000003','8b116000-1160-4160-8160-000000000001','P116 TITLE_ONLY group','friends','member','TITLE_ONLY',null);
insert into public.group_members(group_id,user_id,role) values
 ('8c116000-1160-4160-8160-000000000001','8b116000-1160-4160-8160-000000000001','owner'),
 ('8c116000-1160-4160-8160-000000000001','8b116000-1160-4160-8160-000000000002','member'),
 ('8c116000-1160-4160-8160-000000000002','8b116000-1160-4160-8160-000000000001','owner'),
 ('8c116000-1160-4160-8160-000000000002','8b116000-1160-4160-8160-000000000002','member'),
 ('8c116000-1160-4160-8160-000000000003','8b116000-1160-4160-8160-000000000001','owner'),
 ('8c116000-1160-4160-8160-000000000003','8b116000-1160-4160-8160-000000000006','member');
update public.groups set suspended_at=now()
where id='8c116000-1160-4160-8160-000000000002';

insert into public.events(id,owner_user_id,calendar_id,group_id,title,kind,start_at,end_at,location,description,visibility_level,moderation_hidden_at,created_by) values
 ('8e116000-1160-4160-8160-000000000001','8b116000-1160-4160-8160-000000000001','8d116000-1160-4160-8160-000000000001',null,'P116 inherited FULL','normal','2031-08-01 01:00+00','2031-08-01 02:00+00','private location','private description',null,null,'8b116000-1160-4160-8160-000000000001'),
 ('8e116000-1160-4160-8160-000000000002','8b116000-1160-4160-8160-000000000001','8d116000-1160-4160-8160-000000000001',null,'P116 capped event','normal','2031-08-02 01:00+00','2031-08-02 02:00+00','private location','private description','FULL',null,'8b116000-1160-4160-8160-000000000001'),
 ('8e116000-1160-4160-8160-000000000003','8b116000-1160-4160-8160-000000000001','8d116000-1160-4160-8160-000000000001',null,'P116 private event','normal','2031-08-03 01:00+00','2031-08-03 02:00+00','private location','private description','PRIVATE',null,'8b116000-1160-4160-8160-000000000001'),
 ('8e116000-1160-4160-8160-000000000004','8b116000-1160-4160-8160-000000000001','8d116000-1160-4160-8160-000000000001',null,'P116 hidden event','normal','2031-08-04 01:00+00','2031-08-04 02:00+00','private location','private description',null,now(),'8b116000-1160-4160-8160-000000000001'),
 ('8e116000-1160-4160-8160-000000000005','8b116000-1160-4160-8160-000000000004','8d116000-1160-4160-8160-000000000003',null,'P116 suspended owner event','normal','2031-08-05 01:00+00','2031-08-05 02:00+00','private location','private description',null,null,'8b116000-1160-4160-8160-000000000004'),
 ('8e116000-1160-4160-8160-000000000006','8b116000-1160-4160-8160-000000000001','8d116000-1160-4160-8160-000000000002','8c116000-1160-4160-8160-000000000001','P116 active group event','group','2031-08-06 01:00+00','2031-08-06 02:00+00','group location','group description',null,null,'8b116000-1160-4160-8160-000000000001'),
 ('8e116000-1160-4160-8160-000000000007','8b116000-1160-4160-8160-000000000001','8d116000-1160-4160-8160-000000000002','8c116000-1160-4160-8160-000000000002','P116 suspended group event','group','2031-08-07 01:00+00','2031-08-07 02:00+00','group location','group description',null,null,'8b116000-1160-4160-8160-000000000001'),
 ('8e116000-1160-4160-8160-000000000008','8b116000-1160-4160-8160-000000000001','8d116000-1160-4160-8160-000000000001',null,'P116 event BUSY_ONLY','normal','2031-08-08 01:00+00','2031-08-08 02:00+00','private location','private description','BUSY_ONLY',null,'8b116000-1160-4160-8160-000000000001'),
 ('8e116000-1160-4160-8160-000000000009','8b116000-1160-4160-8160-000000000001','8d116000-1160-4160-8160-000000000002','8c116000-1160-4160-8160-000000000003','P116 TITLE_ONLY group event','group','2031-08-09 01:00+00','2031-08-09 02:00+00','group private location','group private description',null,null,'8b116000-1160-4160-8160-000000000001'),
 ('8e116000-1160-4160-8160-000000000010','8b116000-1160-4160-8160-000000000001','8d116000-1160-4160-8160-000000000001',null,'P116 missing rule private','normal','2031-08-10 01:00+00','2031-08-10 02:00+00','private location','private description',null,null,'8b116000-1160-4160-8160-000000000001');

set local request.jwt.claim.role='authenticated';
set local request.jwt.claim.sub='8b116000-1160-4160-8160-000000000002';
set local role authenticated;
select extensions.ok(exists(
  select 1 from public.get_visible_events('8b116000-1160-4160-8160-000000000002','2031-08-01 00:00+00','2031-08-08 00:00+00')
  where event_id='8e116000-1160-4160-8160-000000000001' and visibility_level='FULL'
    and title='P116 inherited FULL' and location='private location'
), 'active friend gets inherited FULL when event and calendar overrides are absent');
select extensions.ok(exists(
  select 1 from public.get_visible_events('8b116000-1160-4160-8160-000000000002','2031-08-01 00:00+00','2031-08-08 00:00+00')
  where event_id='8e116000-1160-4160-8160-000000000002' and visibility_level='BUSY_ONLY'
    and title='予定あり' and location is null and description is null
), 'explicit event FULL is capped by the narrower directional friend rule');
select extensions.is((
  select count(*) from public.get_visible_events('8b116000-1160-4160-8160-000000000002','2031-08-01 00:00+00','2031-08-08 00:00+00')
  where event_id='8e116000-1160-4160-8160-000000000003'
),0::bigint,'event PRIVATE remains hidden despite a FULL friend rule');
select extensions.is((
  select count(*) from public.get_visible_events('8b116000-1160-4160-8160-000000000002','2031-08-01 00:00+00','2031-08-08 00:00+00')
  where event_id='8e116000-1160-4160-8160-000000000004'
),0::bigint,'moderation-hidden event is omitted');
select extensions.ok(exists(
  select 1 from public.get_visible_events('8b116000-1160-4160-8160-000000000002','2031-08-01 00:00+00','2031-08-08 00:00+00')
  where event_id='8e116000-1160-4160-8160-000000000006' and visibility_level='FULL'
), 'active group member can see active group event');
select extensions.is((
  select count(*) from public.get_visible_events('8b116000-1160-4160-8160-000000000002','2031-08-01 00:00+00','2031-08-08 00:00+00')
  where event_id='8e116000-1160-4160-8160-000000000007'
),0::bigint,'event in suspended group is omitted');
reset role;

set local request.jwt.claim.sub='8b116000-1160-4160-8160-000000000006';
set local role authenticated;
select extensions.ok(exists(
  select 1 from public.get_visible_events('8b116000-1160-4160-8160-000000000006','2031-08-09 00:00+00','2031-08-10 00:00+00')
  where event_id='8e116000-1160-4160-8160-000000000009' and visibility_level='TITLE_ONLY'
    and title='P116 TITLE_ONLY group event' and location is null and description is null
), 'owner PRIVATE + group TITLE_ONLY resolves TITLE_ONLY for a group-only member');
reset role;

update public.profiles set default_visibility='FULL'
where user_id='8b116000-1160-4160-8160-000000000001';
set local request.jwt.claim.sub='8b116000-1160-4160-8160-000000000002';
set local role authenticated;
select extensions.ok(exists(
  select 1 from public.get_visible_events('8b116000-1160-4160-8160-000000000002','2031-08-08 00:00+00','2031-08-09 00:00+00')
  where event_id='8e116000-1160-4160-8160-000000000008' and visibility_level='BUSY_ONLY'
    and title='予定あり' and location is null and description is null
), 'owner FULL + event BUSY_ONLY remains BUSY_ONLY under friend FULL');
reset role;

set local request.jwt.claim.sub='8b116000-1160-4160-8160-000000000007';
set local role authenticated;
select extensions.is((
  select count(*) from public.get_visible_events('8b116000-1160-4160-8160-000000000007','2031-08-10 00:00+00','2031-08-11 00:00+00')
  where event_id='8e116000-1160-4160-8160-000000000010'
),0::bigint,'inherited friend projection without a directional rule fails closed to PRIVATE');
reset role;

set local request.jwt.claim.sub='8b116000-1160-4160-8160-000000000003';
set local role authenticated;
select extensions.is((
  select count(*) from public.get_visible_events('8b116000-1160-4160-8160-000000000003','2031-08-01 00:00+00','2031-08-08 00:00+00')
  where event_id='8e116000-1160-4160-8160-000000000001'
),0::bigint,'suspended viewer receives no shared projection');
reset role;

set local request.jwt.claim.sub='8b116000-1160-4160-8160-000000000005';
set local role authenticated;
select extensions.is((
  select count(*) from public.get_visible_events('8b116000-1160-4160-8160-000000000005','2031-08-01 00:00+00','2031-08-08 00:00+00')
  where event_id='8e116000-1160-4160-8160-000000000005'
),0::bigint,'active friend receives no suspended owner projection');
reset role;

select * from extensions.finish();
rollback;
