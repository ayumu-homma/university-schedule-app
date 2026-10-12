begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(11);

-- The rows intentionally cover both values of realtime.messages.private. The
-- authorization contract is the broadcast extension plus exact owner topic;
-- message.private is a transport/storage detail and is not an owner boundary.
insert into realtime.messages (topic, event, payload, extension, private)
values
  (
    'schedule-sync:61111111-1111-4111-8111-111111111111',
    'invalidate',
    '{"cursor": 101}'::jsonb,
    'broadcast',
    true
  ),
  (
    'schedule-sync:61111111-1111-4111-8111-111111111111',
    'invalidate',
    '{"cursor": 102}'::jsonb,
    'broadcast',
    false
  ),
  (
    'schedule-sync:61111111-1111-4111-8111-111111111111',
    'invalidate',
    '{"cursor": 103}'::jsonb,
    'broadcast',
    default
  ),
  (
    'schedule-sync:61111111-1111-4111-8111-111111111111',
    'presence',
    '{}'::jsonb,
    'presence',
    true
  ),
  (
    'schedule-sync:62222222-2222-4222-8222-222222222222',
    'invalidate',
    '{"cursor": 201}'::jsonb,
    'broadcast',
    true
  ),
  (
    'schedule-sync:62222222-2222-4222-8222-222222222222',
    'invalidate',
    '{"cursor": 202}'::jsonb,
    'broadcast',
    false
  ),
  (
    'schedule-sync:62222222-2222-4222-8222-222222222222',
    'invalidate',
    '{"cursor": 203}'::jsonb,
    'broadcast',
    default
  );

select extensions.ok(
  exists (
    select 1
    from pg_catalog.pg_policy p
    where p.polrelid = 'realtime.messages'::regclass
      and p.polname = 'schedule_sync_broadcast_receive'
      and p.polcmd = 'r'
      and pg_get_expr(p.polqual, p.polrelid) like '%extension%'
      and pg_get_expr(p.polqual, p.polrelid) like '%topic%'
      and pg_get_expr(p.polqual, p.polrelid) like '%realtime.topic()%'
      and pg_get_expr(p.polqual, p.polrelid) like '%auth.uid()%'
      and pg_get_expr(p.polqual, p.polrelid) not like '%private%'
  ),
  'Realtime policy uses broadcast extension and exact auth.uid topic without private flag'
);

set local request.jwt.claims =
  '{"sub":"61111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '61111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select set_config(
  'realtime.topic',
  'schedule-sync:61111111-1111-4111-8111-111111111111',
  true
);

select extensions.is(
  (select count(*) from realtime.messages),
  3::bigint,
  'owner A receives private=true, explicit-false, and default-false broadcast rows'
);

select extensions.is(
  (select count(*) from realtime.messages
   where topic = 'schedule-sync:62222222-2222-4222-8222-222222222222'),
  0::bigint,
  'requesting own A topic does not reveal B rows'
);

select extensions.is(
  (select count(*) from realtime.messages where extension = 'presence'),
  0::bigint,
  'owner A cannot receive non-broadcast extension rows'
);

select set_config(
  'realtime.topic',
  'schedule-sync:62222222-2222-4222-8222-222222222222',
  true
);
set local request.jwt.claims =
  '{"sub":"62222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = '62222222-2222-4222-8222-222222222222';

select extensions.is(
  (select count(*) from realtime.messages),
  3::bigint,
  'owner B receives private=true, explicit-false, and default-false broadcast rows'
);

select set_config('realtime.topic', 'schedule-sync:61111111-1111-4111-8111-111111111111', true);
select extensions.is(
  (select count(*) from realtime.messages),
  0::bigint,
  'owner B cannot receive owner A requested topic'
);

set local request.jwt.claims =
  '{"sub":"61111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '61111111-1111-4111-8111-111111111111';
select set_config('realtime.topic', 'schedule-sync:62222222-2222-4222-8222-222222222222', true);

select extensions.is(
  (select count(*) from realtime.messages),
  0::bigint,
  'owner A cannot receive owner B rows under a requested B topic'
);

select set_config('realtime.topic', 'schedule-sync:61111111-1111-4111-8111-111111111111', true);
set local request.jwt.claims = '{"role":"authenticated"}';
reset request.jwt.claim.sub;

select extensions.is(
  (select count(*) from realtime.messages),
  0::bigint,
  'missing auth uid cannot receive an owner topic'
);

set local request.jwt.claims =
  '{"sub":"61111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '61111111-1111-4111-8111-111111111111';
select set_config('realtime.topic', 'schedule-syncx:61111111-1111-4111-8111-111111111111', true);

select extensions.is(
  (select count(*) from realtime.messages),
  0::bigint,
  'wrong topic prefix is denied'
);

select set_config('realtime.topic', 'schedule-sync:61111111-1111-4111-8111-111111111111:suffix', true);

select extensions.is(
  (select count(*) from realtime.messages),
  0::bigint,
  'topic suffix guessing is denied'
);

select set_config('realtime.topic', 'schedule-sync:61111111-1111-4111-8111-111111111111', true);
select extensions.throws_ok(
  $sql$
    insert into realtime.messages (
      topic, event, payload, extension, private
    ) values (
      'schedule-sync:61111111-1111-4111-8111-111111111111',
      'client-probe',
      '{}'::jsonb,
      'broadcast',
      false
    )
  $sql$,
  '42501',
  null,
  'authenticated clients cannot insert realtime messages directly'
);

select extensions.finish();
rollback;
