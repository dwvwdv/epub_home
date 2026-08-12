begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(18);

insert into auth.users (
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at
)
select
  test_user.id,
  'authenticated',
  'authenticated',
  test_user.email,
  '',
  now(),
  '{}'::jsonb,
  '{}'::jsonb,
  now(),
  now()
from (
  values
    ('00000000-0000-0000-0000-000000000001'::uuid, 'room-test-1@example.invalid'),
    ('00000000-0000-0000-0000-000000000002'::uuid, 'room-test-2@example.invalid'),
    ('00000000-0000-0000-0000-000000000003'::uuid, 'room-test-3@example.invalid'),
    ('00000000-0000-0000-0000-000000000004'::uuid, 'room-test-4@example.invalid'),
    ('00000000-0000-0000-0000-000000000005'::uuid, 'room-test-5@example.invalid'),
    ('00000000-0000-0000-0000-000000000006'::uuid, 'room-test-6@example.invalid'),
    ('00000000-0000-0000-0000-000000000007'::uuid, 'room-test-7@example.invalid')
) as test_user(id, email)
on conflict (id) do nothing;

insert into cotime_book_private.room_code_reservations (code)
values ('HSTA22'), ('SNGK22'), ('SWPA22'), ('TGTB22'), ('XPRD22'), ('PRGE22')
on conflict (code) do nothing;

insert into cotime_book.rooms (
  id,
  code,
  host_user_id,
  expires_at,
  last_activity_at
)
values
  (
    '10000000-0000-0000-0000-000000000001',
    'HSTA22',
    '00000000-0000-0000-0000-000000000001',
    now() + interval '24 hours',
    now()
  ),
  (
    '10000000-0000-0000-0000-000000000002',
    'SNGK22',
    '00000000-0000-0000-0000-000000000003',
    now() + interval '24 hours',
    now()
  ),
  (
    '10000000-0000-0000-0000-000000000003',
    'SWPA22',
    '00000000-0000-0000-0000-000000000004',
    now() + interval '24 hours',
    now()
  ),
  (
    '10000000-0000-0000-0000-000000000004',
    'TGTB22',
    '00000000-0000-0000-0000-000000000005',
    now() + interval '24 hours',
    now()
  ),
  (
    '10000000-0000-0000-0000-000000000005',
    'XPRD22',
    '00000000-0000-0000-0000-000000000006',
    now() - interval '1 minute',
    now() - interval '25 hours'
  ),
  (
    '10000000-0000-0000-0000-000000000006',
    'PRGE22',
    '00000000-0000-0000-0000-000000000007',
    now() - interval '31 days',
    now() - interval '31 days'
  );

update cotime_book.rooms
set is_active = false,
    closed_at = now() - interval '31 days'
where id = '10000000-0000-0000-0000-000000000006';

insert into cotime_book.room_members (
  room_id,
  user_id,
  nickname,
  joined_at,
  last_seen_at
)
values
  (
    '10000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000001',
    'Host',
    now() - interval '2 minutes',
    now()
  ),
  (
    '10000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000002',
    'Next host',
    now() - interval '1 minute',
    now()
  ),
  (
    '10000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000003',
    'Solo',
    now(),
    now()
  ),
  (
    '10000000-0000-0000-0000-000000000003',
    '00000000-0000-0000-0000-000000000004',
    'Switcher',
    now(),
    now()
  ),
  (
    '10000000-0000-0000-0000-000000000004',
    '00000000-0000-0000-0000-000000000005',
    'Target host',
    now(),
    now()
  ),
  (
    '10000000-0000-0000-0000-000000000005',
    '00000000-0000-0000-0000-000000000006',
    'Expired',
    now() - interval '25 hours',
    now() - interval '25 hours'
  );

select ok(
  exists (
    select 1
    from pg_constraint
    where conrelid = 'cotime_book.room_members'::regclass
      and conname = 'room_members_user_id_fkey'
  ),
  'room member auth foreign key exists'
);

select ok(
  not has_table_privilege('authenticated', 'cotime_book.room_members', 'DELETE'),
  'authenticated cannot directly delete memberships'
);

select ok(
  to_regprocedure('cotime_book.is_room_member(uuid)') is null
  and to_regprocedure('cotime_book.can_access_room_topic(text)') is null,
  'authorization helpers are not exposed as app RPCs'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select cotime_book.leave_room('10000000-0000-0000-0000-000000000001');
reset role;

select is(
  (
    select count(*)::bigint
    from cotime_book.room_members
    where room_id = '10000000-0000-0000-0000-000000000001'
      and user_id = '00000000-0000-0000-0000-000000000001'
  ),
  0::bigint,
  'host membership is removed by leave_room'
);

select is(
  (
    select host_user_id
    from cotime_book.rooms
    where id = '10000000-0000-0000-0000-000000000001'
  ),
  '00000000-0000-0000-0000-000000000002'::uuid,
  'host ownership transfers to the earliest remaining member'
);

select ok(
  (
    select is_active and closed_at is null
    from cotime_book.rooms
    where id = '10000000-0000-0000-0000-000000000001'
  ),
  'room remains active after host transfer'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',
  true
);
select is(
  (
    select count(*)::bigint
    from cotime_book.rooms
    where id = '10000000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'active room member can read the room through RLS'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
select is(
  (
    select count(*)::bigint
    from cotime_book.rooms
    where id = '10000000-0000-0000-0000-000000000001'
  ),
  0::bigint,
  'non-member cannot read another room through RLS'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
select cotime_book.leave_room('10000000-0000-0000-0000-000000000002');
reset role;

select is(
  (
    select count(*)::bigint
    from cotime_book.room_members
    where room_id = '10000000-0000-0000-0000-000000000002'
  ),
  0::bigint,
  'last membership is removed'
);

select ok(
  (
    select not is_active and closed_at is not null
    from cotime_book.rooms
    where id = '10000000-0000-0000-0000-000000000002'
  ),
  'last member leaving closes the room'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000004","role":"authenticated"}',
  true
);
select cotime_book.join_room('TGTB22', 'Switcher', 3);
reset role;

select is(
  (
    select room_id
    from cotime_book.room_members
    where user_id = '00000000-0000-0000-0000-000000000004'
  ),
  '10000000-0000-0000-0000-000000000004'::uuid,
  'join_room atomically moves the user to the target room'
);

select ok(
  (
    select not is_active and closed_at is not null
    from cotime_book.rooms
    where id = '10000000-0000-0000-0000-000000000003'
  ),
  'switching rooms closes the abandoned solo room'
);

select is(
  (
    select count(*)::bigint
    from cotime_book.room_members
    where user_id = '00000000-0000-0000-0000-000000000004'
  ),
  1::bigint,
  'a user has exactly one active membership row'
);

create temporary table lifecycle_cleanup_results (result jsonb);
insert into lifecycle_cleanup_results
select cotime_book.cleanup_expired_rooms(now(), interval '30 days', 100);
insert into lifecycle_cleanup_results
select cotime_book.cleanup_expired_rooms(now(), interval '30 days', 100);

select is(
  (
    select (result ->> 'closed_rooms')::integer
    from lifecycle_cleanup_results
    order by ctid
    limit 1
  ),
  1,
  'cleanup closes the expired active room'
);

select is(
  (
    select (result ->> 'closed_rooms')::integer
    from lifecycle_cleanup_results
    order by ctid desc
    limit 1
  ),
  0,
  'cleanup is idempotent for already-closed rooms'
);

select ok(
  not exists (
    select 1
    from cotime_book.rooms
    where id = '10000000-0000-0000-0000-000000000006'
  ),
  'inactive room is hard-deleted after retention'
);

select ok(
  exists (
    select 1
    from cotime_book_private.room_code_reservations
    where code = 'PRGE22'
  ),
  'hard deletion retains the room code reservation'
);

select ok(
  not exists (
    select 1
    from cotime_book.rooms
    where channel_id is null
       or channel_secret !~ '^[0-9a-f]{64}$'
  ),
  'every room has a high-entropy channel identity'
);

select * from finish();
rollback;
