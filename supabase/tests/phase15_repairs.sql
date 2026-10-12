begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(5);

select extensions.ok(
  pg_get_functiondef('private.record_schedule_change()'::regprocedure) not like '%bound_entity_type=''event'' and new.group_id is not null%',
  'schedule change trigger guards event-only group_id access'
);

insert into auth.users(id) values
  ('f2711111-1111-4111-8111-111111111111'),
  ('f2722222-2222-4222-8222-222222222222')
on conflict(id) do nothing;

-- This insert exercises the assignment trigger with a NEW record that has no
-- group_id column.  The old Phase 11 trigger raised before writing the row.
insert into public.assignments(id,owner_user_id,title,due_at)
values ('f2733333-3333-4333-8333-333333333333','f2711111-1111-4111-8111-111111111111','Phase 15 trigger regression','2026-10-01 10:00+09');
select extensions.ok(
  exists(select 1 from public.assignments where id='f2733333-3333-4333-8333-333333333333'),
  'non-event schedule row is accepted by record_schedule_change'
);

select extensions.ok(
  pg_get_functiondef('public.set_group_event_rsvp(uuid,text,uuid)'::regprocedure) like '%on conflict on constraint event_participants_pkey%',
  'RSVP upsert names the primary-key constraint explicitly'
);

insert into public.groups(id,owner_user_id,name,type,event_create_policy)
values ('f2744444-4444-4444-8444-444444444444','f2711111-1111-4111-8111-111111111111','Phase 15 RSVP regression','other','member');
insert into public.group_members(group_id,user_id,role) values
  ('f2744444-4444-4444-8444-444444444444','f2711111-1111-4111-8111-111111111111','owner'),
  ('f2744444-4444-4444-8444-444444444444','f2722222-2222-4222-8222-222222222222','member');
insert into public.calendars(id,owner_user_id,group_id,name)
values ('f2755555-5555-4555-8555-555555555555','f2711111-1111-4111-8111-111111111111','f2744444-4444-4444-8444-444444444444','Phase 15 RSVP regression');
insert into public.events(id,owner_user_id,calendar_id,group_id,title,kind,start_at,end_at,timezone,created_by)
values ('f2766666-6666-4666-8666-666666666666','f2711111-1111-4111-8111-111111111111','f2755555-5555-4555-8555-555555555555','f2744444-4444-4444-8444-444444444444','RSVP target','group','2026-10-02 10:00+09','2026-10-02 11:00+09','Asia/Tokyo','f2711111-1111-4111-8111-111111111111');

set local request.jwt.claim.sub='f2722222-2222-4222-8222-222222222222';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is(
  (select status from public.set_group_event_rsvp('f2766666-6666-4666-8666-666666666666','attending','f2777777-7777-4777-8777-777777777777')),
  'attending'::text,
  'RSVP upsert succeeds with explicit conflict constraint'
);
select public.set_group_event_rsvp('f2766666-6666-4666-8666-666666666666','attending','f2777777-7777-4777-8777-777777777777');
reset role;
select extensions.is(
  (select count(*) from public.event_participants where event_id='f2766666-6666-4666-8666-666666666666' and user_id='f2722222-2222-4222-8222-222222222222'),
  1::bigint,
  'exact RSVP replay remains idempotent'
);

select * from extensions.finish();
rollback;
