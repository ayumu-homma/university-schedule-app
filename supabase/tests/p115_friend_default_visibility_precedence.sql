begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(3);

-- §29 default-level cases need no calendar or event override. All fixtures are
-- synthetic; this test is intended for the fresh isolated P115 database only.
insert into auth.users(id) values
 ('8b115000-1150-4150-8150-000000000001'),
 ('8b115000-1150-4150-8150-000000000002'),
 ('8b115000-1150-4150-8150-000000000003'),
 ('8b115000-1150-4150-8150-000000000004'),
 ('8b115000-1150-4150-8150-000000000005');

insert into public.profiles(user_id,display_name,default_visibility) values
 ('8b115000-1150-4150-8150-000000000001','P115 private owner','PRIVATE'),
 ('8b115000-1150-4150-8150-000000000002','P115 full friend','PRIVATE'),
 ('8b115000-1150-4150-8150-000000000003','P115 busy friend','PRIVATE'),
 ('8b115000-1150-4150-8150-000000000004','P115 busy owner','BUSY_ONLY'),
 ('8b115000-1150-4150-8150-000000000005','P115 full friend 2','PRIVATE')
on conflict (user_id) do update
set display_name = excluded.display_name,
    default_visibility = excluded.default_visibility;

insert into public.friendships(id,requester_user_id,addressee_user_id,status,incarnation)
values
 ('8a115000-1150-4150-8150-000000000001','8b115000-1150-4150-8150-000000000001','8b115000-1150-4150-8150-000000000002','accepted','8a115000-1150-4150-8150-000000000011'),
 ('8a115000-1150-4150-8150-000000000002','8b115000-1150-4150-8150-000000000001','8b115000-1150-4150-8150-000000000003','accepted','8a115000-1150-4150-8150-000000000012'),
 ('8a115000-1150-4150-8150-000000000003','8b115000-1150-4150-8150-000000000004','8b115000-1150-4150-8150-000000000005','accepted','8a115000-1150-4150-8150-000000000013');

insert into public.friend_visibility_rules(
 friendship_id,relationship_incarnation,owner_user_id,friend_user_id,
 target_kind,target_id,target_value,mode,visibility_level
) values
 ('8a115000-1150-4150-8150-000000000001','8a115000-1150-4150-8150-000000000011','8b115000-1150-4150-8150-000000000001','8b115000-1150-4150-8150-000000000002','default',null,null,'explicit','FULL'),
 ('8a115000-1150-4150-8150-000000000002','8a115000-1150-4150-8150-000000000012','8b115000-1150-4150-8150-000000000001','8b115000-1150-4150-8150-000000000003','default',null,null,'explicit','BUSY_ONLY'),
 ('8a115000-1150-4150-8150-000000000003','8a115000-1150-4150-8150-000000000013','8b115000-1150-4150-8150-000000000004','8b115000-1150-4150-8150-000000000005','default',null,null,'explicit','FULL');

insert into public.calendars(id,owner_user_id,name,default_visibility) values
 ('8d115000-1150-4150-8150-000000000001','8b115000-1150-4150-8150-000000000001','P115 inherited calendar A',null),
 ('8d115000-1150-4150-8150-000000000002','8b115000-1150-4150-8150-000000000004','P115 inherited calendar B',null);

insert into public.events(id,owner_user_id,calendar_id,title,kind,start_at,end_at,location,description,visibility_level,created_by) values
 ('8e115000-1150-4150-8150-000000000001','8b115000-1150-4150-8150-000000000001','8d115000-1150-4150-8150-000000000001','P115 FULL title','normal','2031-07-01 01:00+00','2031-07-01 02:00+00','P115 FULL location','P115 FULL description',null,'8b115000-1150-4150-8150-000000000001'),
 ('8e115000-1150-4150-8150-000000000002','8b115000-1150-4150-8150-000000000001','8d115000-1150-4150-8150-000000000001','P115 BUSY title','normal','2031-07-02 01:00+00','2031-07-02 02:00+00','P115 BUSY location','P115 BUSY description',null,'8b115000-1150-4150-8150-000000000001'),
 ('8e115000-1150-4150-8150-000000000003','8b115000-1150-4150-8150-000000000004','8d115000-1150-4150-8150-000000000002','P115 BUSY-owner title','normal','2031-07-03 01:00+00','2031-07-03 02:00+00','P115 BUSY-owner location','P115 BUSY-owner description',null,'8b115000-1150-4150-8150-000000000004');

set local request.jwt.claim.role='authenticated';
set local request.jwt.claim.sub='8b115000-1150-4150-8150-000000000002';
set local role authenticated;
select extensions.ok(exists(
  select 1 from public.get_visible_events('8b115000-1150-4150-8150-000000000002','2031-07-01 00:00+00','2031-07-02 00:00+00')
  where event_id='8e115000-1150-4150-8150-000000000001' and visibility_level='FULL'
    and title='P115 FULL title' and location='P115 FULL location' and description='P115 FULL description'
), 'owner PRIVATE + friend FULL with no calendar/event override resolves FULL');
reset role;

set local request.jwt.claim.sub='8b115000-1150-4150-8150-000000000003';
set local role authenticated;
select extensions.ok(exists(
  select 1 from public.get_visible_events('8b115000-1150-4150-8150-000000000003','2031-07-02 00:00+00','2031-07-03 00:00+00')
  where event_id='8e115000-1150-4150-8150-000000000002' and visibility_level='BUSY_ONLY'
    and title='予定あり' and location is null and description is null
), 'owner PRIVATE + friend BUSY_ONLY with no calendar/event override resolves BUSY_ONLY');
reset role;

set local request.jwt.claim.sub='8b115000-1150-4150-8150-000000000005';
set local role authenticated;
select extensions.ok(exists(
  select 1 from public.get_visible_events('8b115000-1150-4150-8150-000000000005','2031-07-03 00:00+00','2031-07-04 00:00+00')
  where event_id='8e115000-1150-4150-8150-000000000003' and visibility_level='FULL'
    and title='P115 BUSY-owner title' and location='P115 BUSY-owner location' and description='P115 BUSY-owner description'
), 'owner BUSY_ONLY + friend FULL with no calendar/event override resolves FULL');
reset role;

select * from extensions.finish();
rollback;
