begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(30);

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
    ('00000000-0000-0000-0000-000000000007'::uuid, 'room-test-7@example.invalid'),
    ('00000000-0000-0000-0000-000000000008'::uuid, 'room-test-8@example.invalid'),
    ('00000000-0000-0000-0000-000000000009'::uuid, 'room-test-9@example.invalid')
) as test_user(id, email)
on conflict (id) do nothing;

insert into cotime_book_private.room_code_reservations (code)
values
  ('HSTA22'),
  ('SNGK22'),
  ('SWPA22'),
  ('TGTB22'),
  ('XPRD22'),
  ('PRGE22'),
  ('STLH22')
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
  ),
  (
    '10000000-0000-0000-0000-000000000007',
    'STLH22',
    '00000000-0000-0000-0000-000000000008',
    now() + interval '24 hours',
    now()
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
  ),
  (
    '10000000-0000-0000-0000-000000000007',
    '00000000-0000-0000-0000-000000000008',
    'Stale host',
    now() - interval '2 hours',
    now() - interval '31 minutes'
  ),
  (
    '10000000-0000-0000-0000-000000000007',
    '00000000-0000-0000-0000-000000000009',
    'Rollout grace member',
    now() - interval '1 hour',
    now() + interval '24 hours'
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

select ok(
  has_schema_privilege(
    'authenticated',
    'cotime_book_private',
    'USAGE'
  )
  and has_function_privilege(
    'authenticated',
    'cotime_book_private.is_active_room_member(uuid)',
    'EXECUTE'
  )
  and has_function_privilege(
    'authenticated',
    'cotime_book_private.can_access_room_topic(text)',
    'EXECUTE'
  ),
  'authenticated can evaluate the private helpers referenced by RLS'
);

select ok(
  not has_function_privilege(
    'anon',
    'cotime_book_private.is_active_room_member(uuid)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'authenticated',
    'cotime_book_private.remove_membership_locked(uuid,uuid,timestamptz,boolean)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'authenticated',
    'cotime_book_private.cleanup_expired_rooms(timestamptz,interval,integer,interval)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'service_role',
    'cotime_book_private.cleanup_expired_rooms(timestamptz,interval,integer,interval)',
    'EXECUTE'
  )
  and to_regprocedure(
    'cotime_book.cleanup_expired_rooms(timestamptz,interval,integer,interval)'
  ) is null,
  'private mutation and cleanup functions are unavailable to API roles'
);

create temporary table host_transfer_lease_before as
select expires_at
from cotime_book.rooms
where id = '10000000-0000-0000-0000-000000000001';

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

select is(
  (
    select expires_at::text
    from cotime_book.rooms
    where id = '10000000-0000-0000-0000-000000000001'
  ),
  (select expires_at::text from host_transfer_lease_before),
  'leaving and host transfer do not renew the room lease'
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
select throws_ok(
  $$select cotime_book.heartbeat_room(
    '10000000-0000-0000-0000-000000000001'
  )$$,
  '42501',
  'Room membership is inactive or expired',
  'heartbeat_room rejects a user who is not a room member'
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
  '{"sub":"00000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
create temporary table repeated_leave_result (result jsonb);
insert into repeated_leave_result
select cotime_book.leave_room('10000000-0000-0000-0000-000000000002');
reset role;

select is(
  (select result ->> 'removed' from repeated_leave_result),
  'false',
  'repeated leave_room is idempotent'
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

update cotime_book.room_members
set has_book = true
where room_id = '10000000-0000-0000-0000-000000000007'
  and user_id = '00000000-0000-0000-0000-000000000008';

create temporary table stale_member_lease_before as
select last_seen_at
from cotime_book.room_members
where room_id = '10000000-0000-0000-0000-000000000007'
  and user_id = '00000000-0000-0000-0000-000000000008';

update cotime_book.rooms
set current_book_hash = repeat('a', 64)
where id = '10000000-0000-0000-0000-000000000007';

select ok(
  (
    select member.last_seen_at = lease.last_seen_at
      and member.has_book = false
      and member.ready_book_hash is null
    from cotime_book.room_members as member
    cross join stale_member_lease_before as lease
    where member.room_id = '10000000-0000-0000-0000-000000000007'
      and member.user_id = '00000000-0000-0000-0000-000000000008'
  ),
  'changing books resets readiness without refreshing an offline member lease'
);

create temporary table lifecycle_cleanup_results (result jsonb);
insert into lifecycle_cleanup_results
select cotime_book_private.cleanup_expired_rooms(
  now(),
  interval '30 days',
  100
);
insert into lifecycle_cleanup_results
select cotime_book_private.cleanup_expired_rooms(
  now(),
  interval '30 days',
  100
);

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

select is(
  (
    select (result ->> 'stale_members_removed')::integer
    from lifecycle_cleanup_results
    order by ctid
    limit 1
  ),
  1,
  'cleanup evicts stale members from an otherwise active room'
);

select is(
  (
    select count(*)::bigint
    from cotime_book.room_members
    where room_id = '10000000-0000-0000-0000-000000000007'
      and user_id = '00000000-0000-0000-0000-000000000008'
  ),
  0::bigint,
  'stale host membership is removed'
);

select is(
  (
    select host_user_id
    from cotime_book.rooms
    where id = '10000000-0000-0000-0000-000000000007'
  ),
  '00000000-0000-0000-0000-000000000009'::uuid,
  'stale host eviction transfers ownership to a live member'
);

select ok(
  (
    select is_active and closed_at is null
    from cotime_book.rooms
    where id = '10000000-0000-0000-0000-000000000007'
  ),
  'stale-member cleanup keeps a room with a live member active'
);

select is(
  (
    select count(*)::bigint
    from cotime_book.room_members
    where room_id = '10000000-0000-0000-0000-000000000007'
      and user_id = '00000000-0000-0000-0000-000000000009'
  ),
  1::bigint,
  'cleanup preserves a legacy member during the rollout grace window'
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
  ),
  'every room has an opaque channel identity'
);

select is(
  (
    select count(*)::bigint
    from cron.job
    where jobname = 'cotime_book-room-lifecycle'
      and schedule = '*/10 * * * *'
      and command = 'select cotime_book_private.cleanup_expired_rooms();'
  ),
  1::bigint,
  'room lifecycle cleanup has one automatic Cron schedule'
);

select * from finish();
rollback;
