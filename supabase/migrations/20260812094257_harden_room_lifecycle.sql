-- Forward-only room lifecycle hardening.
--
-- This migration intentionally does not modify any previously-applied migration.
-- It repairs existing room/member drift before adding stricter constraints, then
-- replaces direct membership deletion with serialized RPC operations.

create schema if not exists cotime_book_private;

revoke all on schema cotime_book_private
  from public, anon, authenticated, service_role;

create table if not exists cotime_book_private.room_code_reservations (
  code varchar(6) primary key,
  created_at timestamptz not null default now(),
  constraint room_code_reservations_code_format
    check (code ~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$')
);

revoke all on cotime_book_private.room_code_reservations
  from public, anon, authenticated, service_role;
alter table cotime_book_private.room_code_reservations
  enable row level security;

alter default privileges for role postgres in schema cotime_book_private
  revoke all on tables from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema cotime_book_private
  revoke all on functions from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema cotime_book_private
  revoke all on sequences from public, anon, authenticated, service_role;

alter table cotime_book.rooms
  add column if not exists channel_id uuid,
  add column if not exists closed_at timestamptz,
  add column if not exists expires_at timestamptz,
  add column if not exists last_activity_at timestamptz,
  add column if not exists revision bigint;

alter table cotime_book.room_members
  add column if not exists ready_book_hash varchar(64),
  add column if not exists last_seen_at timestamptz;

-- Fail clearly instead of silently changing an externally shared room code.
do $$
begin
  if exists (
    select 1
    from cotime_book.rooms
    group by upper(btrim(code))
    having count(*) > 1
  ) then
    raise exception 'Cannot normalize duplicate CoTime Book room codes';
  end if;
end
$$;

update cotime_book.rooms
set code = upper(btrim(code)),
    current_book_hash = lower(current_book_hash)
where code is distinct from upper(btrim(code))
   or current_book_hash is distinct from lower(current_book_hash);

do $$
begin
  if exists (
    select 1
    from cotime_book.rooms
    where code !~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$'
  ) then
    raise exception 'Cannot migrate invalid CoTime Book room codes';
  end if;
end
$$;

update cotime_book.rooms
set created_at = coalesce(created_at, now()),
    updated_at = coalesce(updated_at, created_at, now()),
    is_active = coalesce(is_active, false),
    channel_id = coalesce(channel_id, extensions.gen_random_uuid()),
    last_activity_at = coalesce(last_activity_at, updated_at, created_at, now()),
    revision = greatest(coalesce(revision, 0), 0);

update cotime_book.rooms
set closed_at = case
      when is_active then null
      else coalesce(closed_at, updated_at, now())
    end,
    expires_at = case
      when is_active then coalesce(
        expires_at,
        -- Legacy clients do not heartbeat. Give rooms that predate this
        -- migration one deployment window before automatic cleanup begins.
        now() + interval '24 hours'
      )
      else coalesce(expires_at, closed_at, updated_at, now())
    end;

-- Reserve every historical code before any room can be purged.
insert into cotime_book_private.room_code_reservations (code, created_at)
select code, min(created_at)
from cotime_book.rooms
group by code
on conflict (code) do nothing;

update cotime_book.room_members
set nickname = case
      when char_length(btrim(coalesce(nickname, ''))) = 0 then 'Reader'
      else left(btrim(nickname), 30)
    end,
    avatar_color_index = least(greatest(coalesce(avatar_color_index, 0), 0), 7),
    has_book = coalesce(has_book, false),
    joined_at = coalesce(joined_at, now()),
    -- Existing app versions do not heartbeat. A future timestamp is a
    -- one-time rollout grace; the first new-client heartbeat replaces it with
    -- the real observation time and normal 30-minute eviction resumes.
    last_seen_at = coalesce(last_seen_at, now() + interval '24 hours'),
    ready_book_hash = case
      when ready_book_hash ~ '^[0-9a-fA-F]{64}$' then lower(ready_book_hash)
      else null
    end;

update cotime_book.room_members as member
set ready_book_hash = room.current_book_hash
from cotime_book.rooms as room
where room.id = member.room_id
  and member.has_book = true
  and room.current_book_hash ~ '^[0-9a-f]{64}$';

update cotime_book.rooms
set current_book_hash = null,
    current_cfi = null
where current_book_hash is not null
  and current_book_hash !~ '^[0-9a-f]{64}$';

delete from cotime_book.room_members as member
where member.room_id is null
   or not exists (
     select 1
     from cotime_book.rooms as room
     where room.id = member.room_id
   )
   or not exists (
     select 1
     from auth.users as app_user
     where app_user.id = member.user_id
   );

-- The replacement RPCs serialize on the parent room row. Remove the old
-- AFTER DELETE trigger before repairing duplicate memberships.
drop trigger if exists deactivate_empty_room_after_member_delete
  on cotime_book.room_members;
drop function if exists cotime_book.deactivate_empty_room();

-- Inactive rooms must not retain an active membership lease.
delete from cotime_book.room_members as member
using cotime_book.rooms as room
where room.id = member.room_id
  and room.is_active = false;

-- A client can represent only one current room. Keep the membership belonging
-- to that user's most recently active room and remove older leaked rows.
with ranked_memberships as (
  select
    member.id,
    row_number() over (
      partition by member.user_id
      order by
        room.last_activity_at desc,
        member.last_seen_at desc,
        member.joined_at desc,
        room.id
    ) as membership_rank
  from cotime_book.room_members as member
  join cotime_book.rooms as room on room.id = member.room_id
  where room.is_active = true
)
delete from cotime_book.room_members as member
using ranked_memberships as ranked
where member.id = ranked.id
  and ranked.membership_rank > 1;

-- Repair host ownership after duplicate memberships were removed.
update cotime_book.rooms as room
set host_user_id = (
      select member.user_id
      from cotime_book.room_members as member
      where member.room_id = room.id
      order by member.joined_at, member.user_id
      limit 1
    ),
    updated_at = now(),
    revision = room.revision + 1
where room.is_active = true
  and not exists (
    select 1
    from cotime_book.room_members as host_member
    where host_member.room_id = room.id
      and host_member.user_id = room.host_user_id
  )
  and exists (
    select 1
    from cotime_book.room_members as replacement
    where replacement.room_id = room.id
  );

update cotime_book.rooms as room
set is_active = false,
    closed_at = coalesce(room.closed_at, now()),
    expires_at = least(room.expires_at, now()),
    updated_at = now(),
    revision = room.revision + 1
where room.is_active = true
  and not exists (
    select 1
    from cotime_book.room_members as member
    where member.room_id = room.id
  );

-- If an auth user was already removed, transfer ownership to a valid member.
update cotime_book.rooms as room
set host_user_id = (
      select member.user_id
      from cotime_book.room_members as member
      join auth.users as app_user on app_user.id = member.user_id
      where member.room_id = room.id
      order by member.joined_at, member.user_id
      limit 1
    ),
    updated_at = now(),
    revision = room.revision + 1
where not exists (
    select 1 from auth.users as host_user where host_user.id = room.host_user_id
  )
  and exists (
    select 1
    from cotime_book.room_members as member
    join auth.users as app_user on app_user.id = member.user_id
    where member.room_id = room.id
  );

-- A room with no valid owner cannot satisfy the ownership invariant. Its code
-- remains permanently reserved, and ON DELETE CASCADE removes memberships.
delete from cotime_book.rooms as room
where not exists (
  select 1 from auth.users as host_user where host_user.id = room.host_user_id
);

alter table cotime_book.rooms
  alter column code set not null,
  alter column host_user_id set not null,
  alter column is_active set not null,
  alter column is_active set default true,
  alter column created_at set not null,
  alter column created_at set default now(),
  alter column updated_at set not null,
  alter column updated_at set default now(),
  alter column channel_id set not null,
  alter column channel_id set default extensions.gen_random_uuid(),
  alter column expires_at set not null,
  alter column expires_at set default (now() + interval '24 hours'),
  alter column last_activity_at set not null,
  alter column last_activity_at set default now(),
  alter column revision set not null,
  alter column revision set default 0;

alter table cotime_book.room_members
  alter column room_id set not null,
  alter column user_id set not null,
  alter column nickname set not null,
  alter column avatar_color_index set not null,
  alter column avatar_color_index set default 0,
  alter column has_book set not null,
  alter column has_book set default false,
  alter column joined_at set not null,
  alter column joined_at set default now(),
  alter column last_seen_at set not null,
  alter column last_seen_at set default now();

alter table cotime_book.rooms
  add constraint rooms_code_format
    check (code ~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$'),
  add constraint rooms_current_book_hash_format
    check (
      current_book_hash is null
      or current_book_hash ~ '^[0-9a-f]{64}$'
    ),
  add constraint rooms_revision_nonnegative
    check (revision >= 0),
  add constraint rooms_lifecycle_consistent
    check (
      (is_active = true and closed_at is null)
      or (is_active = false and closed_at is not null)
    ),
  add constraint rooms_host_user_id_fkey
    foreign key (host_user_id) references auth.users(id) on delete cascade,
  add constraint rooms_code_reservation_fkey
    foreign key (code)
    references cotime_book_private.room_code_reservations(code)
    on delete restrict;

alter table cotime_book.room_members
  add constraint room_members_user_id_fkey
    foreign key (user_id) references auth.users(id) on delete cascade,
  add constraint room_members_nickname_length
    check (char_length(btrim(nickname)) between 1 and 30),
  add constraint room_members_avatar_color_range
    check (avatar_color_index between 0 and 7),
  add constraint room_members_ready_book_hash_format
    check (
      ready_book_hash is null
      or ready_book_hash ~ '^[0-9a-f]{64}$'
    );

create unique index if not exists rooms_channel_id_key
  on cotime_book.rooms (channel_id);
create unique index if not exists room_members_one_room_per_user
  on cotime_book.room_members (user_id);
create index if not exists room_members_last_seen_idx
  on cotime_book.room_members (last_seen_at, room_id, user_id);
create index if not exists room_members_room_joined_idx
  on cotime_book.room_members (room_id, joined_at, id);
create index if not exists rooms_host_user_id_idx
  on cotime_book.rooms (host_user_id);
create index if not exists rooms_expiration_idx
  on cotime_book.rooms (expires_at, id)
  where is_active = true;
create index if not exists rooms_closed_at_idx
  on cotime_book.rooms (closed_at, id)
  where is_active = false;

create or replace function cotime_book_private.is_active_room_member(
  target_room_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from cotime_book.rooms as room
    join cotime_book.room_members as member on member.room_id = room.id
    where room.id = target_room_id
      and room.is_active = true
      and room.closed_at is null
      and room.expires_at > now()
      and member.user_id = (select auth.uid())
  );
$$;

create or replace function cotime_book_private.can_access_room_topic(
  target_topic text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from cotime_book.rooms as room
    join cotime_book.room_members as member on member.room_id = room.id
    where target_topic in (
        'cotime_book:room:' || room.code,
        'cotime_book:room:' || room.channel_id::text
      )
      and room.is_active = true
      and room.closed_at is null
      and room.expires_at > now()
      and member.user_id = (select auth.uid())
  );
$$;

create or replace function cotime_book_private.remove_membership_locked(
  target_room_id uuid,
  target_user_id uuid,
  action_at timestamptz default now(),
  touch_activity boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  removed_count integer;
  leaving_host boolean;
  replacement_host uuid;
  current_host uuid;
  room_closed boolean := false;
begin
  if action_at is null or touch_activity is null then
    raise exception 'Membership removal options are required'
      using errcode = '22023';
  end if;

  -- Callers lock rooms in UUID order. Re-locking an already held row is safe and
  -- protects this helper if it is reused by another privileged function.
  perform 1
  from cotime_book.rooms
  where id = target_room_id
  for update;

  select room.host_user_id = target_user_id
  into leaving_host
  from cotime_book.rooms as room
  where room.id = target_room_id;

  delete from cotime_book.room_members
  where room_id = target_room_id
    and user_id = target_user_id;
  get diagnostics removed_count = row_count;

  if removed_count = 0 then
    return jsonb_build_object(
      'removed', false,
      'room_id', target_room_id,
      'room_closed', false
    );
  end if;

  select member.user_id
  into replacement_host
  from cotime_book.room_members as member
  where member.room_id = target_room_id
  order by member.joined_at, member.user_id
  limit 1;

  if replacement_host is null then
    update cotime_book.rooms
    set is_active = false,
        closed_at = coalesce(closed_at, action_at),
        expires_at = least(expires_at, action_at),
        updated_at = action_at,
        revision = revision + 1
    where id = target_room_id;
    room_closed := true;
  elsif leaving_host then
    update cotime_book.rooms
    set host_user_id = replacement_host,
        last_activity_at = case
          when touch_activity then action_at
          else last_activity_at
        end,
        expires_at = case
          when touch_activity then action_at + interval '24 hours'
          else expires_at
        end,
        updated_at = action_at,
        revision = revision + 1
    where id = target_room_id;
  else
    update cotime_book.rooms
    set last_activity_at = case
          when touch_activity then action_at
          else last_activity_at
        end,
        expires_at = case
          when touch_activity then action_at + interval '24 hours'
          else expires_at
        end,
        updated_at = action_at,
        revision = revision + 1
    where id = target_room_id
      and is_active = true;
  end if;

  select room.host_user_id
  into current_host
  from cotime_book.rooms as room
  where room.id = target_room_id;

  return jsonb_build_object(
    'removed', true,
    'room_id', target_room_id,
    'room_closed', room_closed,
    'new_host_user_id', case when room_closed then null else current_host end
  );
end;
$$;

create or replace function cotime_book.create_room(
  p_nickname text,
  p_avatar_color_index integer default 0
)
returns cotime_book.rooms
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  previous_room_id uuid;
  created_room cotime_book.rooms;
  generated_code text;
  random_bytes bytea;
  attempt integer;
begin
  if current_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if char_length(btrim(coalesce(p_nickname, ''))) not between 1 and 30 then
    raise exception 'Nickname must contain between 1 and 30 characters'
      using errcode = '22023';
  end if;
  if p_avatar_color_index not between 0 and 7 then
    raise exception 'Avatar color index must be between 0 and 7'
      using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(current_user_id::text, 0)
  );

  -- Lock every previous parent in a stable order before deleting children.
  perform room.id
  from cotime_book.rooms as room
  join cotime_book.room_members as member on member.room_id = room.id
  where member.user_id = current_user_id
  order by room.id
  for update of room;

  for previous_room_id in
    select member.room_id
    from cotime_book.room_members as member
    where member.user_id = current_user_id
    order by member.room_id
  loop
    perform cotime_book_private.remove_membership_locked(
      previous_room_id,
      current_user_id
    );
  end loop;

  for attempt in 1..20 loop
    random_bytes := extensions.gen_random_bytes(6);
    select string_agg(
      substr(
        'ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
        (get_byte(random_bytes, character_index - 1) % 32) + 1,
        1
      ),
      '' order by character_index
    )
    into generated_code
    from generate_series(1, 6) as generated(character_index);

    begin
      insert into cotime_book_private.room_code_reservations (code)
      values (generated_code);
      exit;
    exception when unique_violation then
      generated_code := null;
    end;
  end loop;

  if generated_code is null then
    raise exception 'Unable to allocate a unique room code'
      using errcode = '55000';
  end if;

  insert into cotime_book.rooms (
    code,
    host_user_id,
    expires_at,
    last_activity_at
  ) values (
    generated_code,
    current_user_id,
    now() + interval '24 hours',
    now()
  )
  returning * into created_room;

  insert into cotime_book.room_members (
    room_id,
    user_id,
    nickname,
    avatar_color_index,
    last_seen_at
  ) values (
    created_room.id,
    current_user_id,
    btrim(p_nickname),
    p_avatar_color_index,
    now()
  );

  return created_room;
end;
$$;

create or replace function cotime_book.join_room(
  p_code text,
  p_nickname text,
  p_avatar_color_index integer default 0
)
returns cotime_book.rooms
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  target_room_id uuid;
  previous_room_id uuid;
  joined_room cotime_book.rooms;
begin
  if current_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if char_length(btrim(coalesce(p_nickname, ''))) not between 1 and 30 then
    raise exception 'Nickname must contain between 1 and 30 characters'
      using errcode = '22023';
  end if;
  if p_avatar_color_index not between 0 and 7 then
    raise exception 'Avatar color index must be between 0 and 7'
      using errcode = '22023';
  end if;

  select room.id
  into target_room_id
  from cotime_book.rooms as room
  where room.code = upper(btrim(p_code));

  if target_room_id is null then
    raise exception 'Room not found or no longer active'
      using errcode = 'P0002';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(current_user_id::text, 0)
  );

  -- Include both the destination and all previous rooms in one ordered lock set.
  perform room.id
  from cotime_book.rooms as room
  where room.id = target_room_id
     or exists (
       select 1
       from cotime_book.room_members as member
       where member.room_id = room.id
         and member.user_id = current_user_id
     )
  order by room.id
  for update;

  select room.*
  into joined_room
  from cotime_book.rooms as room
  where room.id = target_room_id
    and room.is_active = true
    and room.closed_at is null
    and room.expires_at > now();

  if joined_room.id is null then
    raise exception 'Room not found or no longer active'
      using errcode = 'P0002';
  end if;

  for previous_room_id in
    select member.room_id
    from cotime_book.room_members as member
    where member.user_id = current_user_id
      and member.room_id <> target_room_id
    order by member.room_id
  loop
    perform cotime_book_private.remove_membership_locked(
      previous_room_id,
      current_user_id
    );
  end loop;

  insert into cotime_book.room_members (
    room_id,
    user_id,
    nickname,
    avatar_color_index,
    last_seen_at
  ) values (
    target_room_id,
    current_user_id,
    btrim(p_nickname),
    p_avatar_color_index,
    now()
  )
  on conflict (room_id, user_id) do update
  set nickname = excluded.nickname,
      avatar_color_index = excluded.avatar_color_index,
      last_seen_at = now();

  update cotime_book.rooms
  set last_activity_at = now(),
      expires_at = now() + interval '24 hours',
      updated_at = now(),
      revision = revision + 1
  where id = target_room_id
  returning * into joined_room;

  return joined_room;
end;
$$;

create or replace function cotime_book.leave_room(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  leave_result jsonb;
begin
  if current_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(current_user_id::text, 0)
  );

  perform 1
  from cotime_book.rooms
  where id = p_room_id
  for update;

  leave_result := cotime_book_private.remove_membership_locked(
    p_room_id,
    current_user_id
  );
  return leave_result;
end;
$$;

create or replace function cotime_book.heartbeat_room(p_room_id uuid)
returns cotime_book.rooms
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  active_room cotime_book.rooms;
begin
  if current_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select room.*
  into active_room
  from cotime_book.rooms as room
  where room.id = p_room_id
  for update;

  if active_room.id is null
     or active_room.is_active = false
     or active_room.closed_at is not null
     or active_room.expires_at <= now()
     or not exists (
       select 1
       from cotime_book.room_members as member
       where member.room_id = p_room_id
         and member.user_id = current_user_id
     ) then
    raise exception 'Room membership is inactive or expired'
      using errcode = '42501';
  end if;

  update cotime_book.room_members
  set last_seen_at = now()
  where room_id = p_room_id
    and user_id = current_user_id;

  update cotime_book.rooms
  set last_activity_at = now(),
      expires_at = now() + interval '24 hours',
      updated_at = now()
  where id = p_room_id
  returning * into active_room;

  return active_room;
end;
$$;

create or replace function cotime_book_private.cleanup_expired_rooms(
  p_now timestamptz default now(),
  p_inactive_retention interval default interval '30 days',
  p_limit integer default 100,
  p_member_stale_after interval default interval '30 minutes'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  expired_room_ids uuid[] := array[]::uuid[];
  purge_room_ids uuid[] := array[]::uuid[];
  stale_room_id uuid;
  stale_user_id uuid;
  removal_result jsonb;
  stale_member_count integer := 0;
  closed_count integer := 0;
  deleted_count integer := 0;
begin
  if p_now is null then
    raise exception 'Cleanup time is required' using errcode = '22023';
  end if;
  if p_limit is null or p_limit not between 1 and 10000 then
    raise exception 'Cleanup limit must be between 1 and 10000'
      using errcode = '22023';
  end if;
  if p_inactive_retention is null
     or p_inactive_retention < interval '1 day' then
    raise exception 'Inactive retention must be at least one day'
      using errcode = '22023';
  end if;
  if p_member_stale_after is null
     or p_member_stale_after < interval '15 minutes' then
    raise exception 'Member stale interval must be at least 15 minutes'
      using errcode = '22023';
  end if;

  select coalesce(array_agg(expired.id), array[]::uuid[])
  into expired_room_ids
  from (
    select room.id
    from cotime_book.rooms as room
    where room.is_active = true
      and room.expires_at <= p_now
    order by room.expires_at, room.id
    for update skip locked
    limit p_limit
  ) as expired;

  update cotime_book.rooms
  set is_active = false,
      closed_at = coalesce(closed_at, p_now),
      expires_at = least(expires_at, p_now),
      updated_at = p_now,
      revision = revision + 1
  where id = any(expired_room_ids);
  get diagnostics closed_count = row_count;

  delete from cotime_book.room_members
  where room_id = any(expired_room_ids);

  -- Serialize stale-member eviction on the same parent lock used by heartbeat,
  -- join, and explicit leave. A heartbeat committed before this lock refreshes
  -- last_seen_at; one arriving afterwards observes the removed membership.
  for stale_room_id in
    select room.id
    from cotime_book.rooms as room
    where room.is_active = true
      and exists (
        select 1
        from cotime_book.room_members as member
        where member.room_id = room.id
          and member.last_seen_at <= p_now - p_member_stale_after
      )
    order by room.id
    for update skip locked
    limit p_limit
  loop
    for stale_user_id in
      select member.user_id
      from cotime_book.room_members as member
      where member.room_id = stale_room_id
        and member.last_seen_at <= p_now - p_member_stale_after
      order by member.joined_at, member.user_id
    loop
      removal_result := cotime_book_private.remove_membership_locked(
        stale_room_id,
        stale_user_id,
        p_now,
        false
      );
      if (removal_result ->> 'removed')::boolean then
        stale_member_count := stale_member_count + 1;
      end if;
      if (removal_result ->> 'room_closed')::boolean then
        closed_count := closed_count + 1;
      end if;
    end loop;
  end loop;

  select coalesce(array_agg(purge.id), array[]::uuid[])
  into purge_room_ids
  from (
    select room.id
    from cotime_book.rooms as room
    where room.is_active = false
      and room.closed_at <= p_now - p_inactive_retention
    order by room.closed_at, room.id
    for update skip locked
    limit p_limit
  ) as purge;

  delete from cotime_book.rooms
  where id = any(purge_room_ids);
  get diagnostics deleted_count = row_count;

  return jsonb_build_object(
    'stale_members_removed', stale_member_count,
    'closed_rooms', closed_count,
    'deleted_rooms', deleted_count
  );
end;
$$;

create or replace function cotime_book_private.touch_room_reading_state()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.current_book_hash is distinct from old.current_book_hash then
    update cotime_book.room_members
    set has_book = false,
        ready_book_hash = null
    where room_id = old.id
      and (has_book = true or ready_book_hash is not null);
  end if;

  new.updated_at := now();
  new.last_activity_at := now();
  new.expires_at := now() + interval '24 hours';
  new.revision := old.revision + 1;
  return new;
end;
$$;

drop trigger if exists touch_room_reading_state_before_update
  on cotime_book.rooms;
create trigger touch_room_reading_state_before_update
before update of current_book_title, current_book_hash, current_cfi
on cotime_book.rooms
for each row execute function cotime_book_private.touch_room_reading_state();

create or replace function cotime_book_private.touch_member_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.has_book is distinct from old.has_book then
    if new.has_book then
      select room.current_book_hash
      into new.ready_book_hash
      from cotime_book.rooms as room
      where room.id = new.room_id;
    else
      new.ready_book_hash := null;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists touch_member_status_before_update
  on cotime_book.room_members;
create trigger touch_member_status_before_update
before update of nickname, avatar_color_index, has_book
on cotime_book.room_members
for each row execute function cotime_book_private.touch_member_status();

drop policy if exists "Members can read their rooms" on cotime_book.rooms;
create policy "Members can read their rooms"
on cotime_book.rooms for select
to authenticated
using ((select cotime_book_private.is_active_room_member(id)));

drop policy if exists "Members can update room reading state" on cotime_book.rooms;
create policy "Members can update room reading state"
on cotime_book.rooms for update
to authenticated
using ((select cotime_book_private.is_active_room_member(id)))
with check ((select cotime_book_private.is_active_room_member(id)));

drop policy if exists "Members can read room memberships"
  on cotime_book.room_members;
create policy "Members can read room memberships"
on cotime_book.room_members for select
to authenticated
using ((select cotime_book_private.is_active_room_member(room_id)));

drop policy if exists "Users can update own membership"
  on cotime_book.room_members;
create policy "Users can update own membership"
on cotime_book.room_members for update
to authenticated
using (
  (select auth.uid()) = user_id
  and (select cotime_book_private.is_active_room_member(room_id))
)
with check (
  (select auth.uid()) = user_id
  and (select cotime_book_private.is_active_room_member(room_id))
);

drop policy if exists "Users can leave rooms" on cotime_book.room_members;
revoke delete on cotime_book.room_members from authenticated;
revoke update (updated_at) on cotime_book.rooms from authenticated;

drop policy if exists "CoTime members can receive room events"
  on realtime.messages;
create policy "CoTime members can receive room events"
on realtime.messages for select
to authenticated
using (
  realtime.messages.extension in ('broadcast', 'presence')
  and (
    select cotime_book_private.can_access_room_topic(
      (select realtime.topic())
    )
  )
);

drop policy if exists "CoTime members can send room events"
  on realtime.messages;
create policy "CoTime members can send room events"
on realtime.messages for insert
to authenticated
with check (
  realtime.messages.extension in ('broadcast', 'presence')
  and (
    select cotime_book_private.can_access_room_topic(
      (select realtime.topic())
    )
  )
);

-- Authorization helpers no longer need to be exposed as Data API RPCs.
drop function if exists cotime_book.is_room_member(uuid);
drop function if exists cotime_book.can_access_room_topic(text);

revoke all on all functions in schema cotime_book_private
  from public, anon, authenticated, service_role;

-- These helpers are referenced from RLS policies. PostgreSQL still checks
-- EXECUTE at policy evaluation time, while the private schema remains outside
-- PostgREST's exposed schemas so neither helper becomes a Data API RPC.
grant usage on schema cotime_book_private to authenticated;
grant execute on function cotime_book_private.is_active_room_member(uuid)
  to authenticated;
grant execute on function cotime_book_private.can_access_room_topic(text)
  to authenticated;

revoke all on function cotime_book.create_room(text, integer)
  from public, anon, authenticated, service_role;
revoke all on function cotime_book.join_room(text, text, integer)
  from public, anon, authenticated, service_role;
revoke all on function cotime_book.leave_room(uuid)
  from public, anon, authenticated, service_role;
revoke all on function cotime_book.heartbeat_room(uuid)
  from public, anon, authenticated, service_role;
grant execute on function cotime_book.create_room(text, integer)
  to authenticated, service_role;
grant execute on function cotime_book.join_room(text, text, integer)
  to authenticated, service_role;
grant execute on function cotime_book.leave_room(uuid)
  to authenticated, service_role;
grant execute on function cotime_book.heartbeat_room(uuid)
  to authenticated, service_role;
-- Supabase Cron runs in the database as postgres. Use a project-specific named
-- job so a repeated migration/recovery updates only this app's schedule.
create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;

do $cron_schedule$
declare
  existing_job_id bigint;
begin
  for existing_job_id in
    select job.jobid
    from cron.job as job
    where job.jobname = 'cotime_book-room-lifecycle'
  loop
    perform cron.unschedule(existing_job_id);
  end loop;

  perform cron.schedule(
    'cotime_book-room-lifecycle',
    '*/10 * * * *',
    'select cotime_book_private.cleanup_expired_rooms();'
  );
end
$cron_schedule$;

notify pgrst, 'reload schema';
