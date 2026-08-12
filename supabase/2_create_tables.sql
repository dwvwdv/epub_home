-- Step 2/3: preserve existing data while moving tables into cotime_book,
-- then add atomic room operations and lifecycle triggers.

drop policy if exists "Anyone can read active rooms" on public.rooms;
drop policy if exists "Authenticated users can create rooms" on public.rooms;
drop policy if exists "Host can update room" on public.rooms;
drop policy if exists "Members can update room reading state" on public.rooms;
drop policy if exists "Anyone can read members of active rooms" on public.room_members;
drop policy if exists "Users can join rooms" on public.room_members;
drop policy if exists "Users can update own membership" on public.room_members;
drop policy if exists "Users can leave rooms" on public.room_members;
drop policy if exists "Users can read own profile" on public.profiles;
drop policy if exists "Users can create own profile" on public.profiles;
drop policy if exists "Users can update own profile" on public.profiles;

alter table public.profiles set schema cotime_book;
alter table public.rooms set schema cotime_book;
alter table public.room_members set schema cotime_book;

update cotime_book.rooms as room
set is_active = false,
    updated_at = now()
where room.is_active = true
  and not exists (
    select 1
    from cotime_book.room_members as member
    where member.room_id = room.id
  );

create or replace function cotime_book.is_room_member(target_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from cotime_book.room_members as member
    where member.room_id = target_room_id
      and member.user_id = (select auth.uid())
  );
$$;

create or replace function cotime_book.can_access_room_topic(target_topic text)
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
    where target_topic = 'room:' || room.code
      and room.is_active = true
      and member.user_id = (select auth.uid())
  );
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
  created_room cotime_book.rooms;
  generated_code text;
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

  for attempt in 1..20 loop
    select string_agg(
      substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', floor(random() * 32)::integer + 1, 1),
      '' order by position
    )
    into generated_code
    from generate_series(1, 6) as position;

    begin
      insert into cotime_book.rooms (code, host_user_id)
      values (generated_code, current_user_id)
      returning * into created_room;
      exit;
    exception when unique_violation then
      created_room := null;
    end;
  end loop;

  if created_room.id is null then
    raise exception 'Unable to allocate a unique room code'
      using errcode = '55000';
  end if;

  insert into cotime_book.room_members (
    room_id,
    user_id,
    nickname,
    avatar_color_index
  ) values (
    created_room.id,
    current_user_id,
    btrim(p_nickname),
    p_avatar_color_index
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

  select room.*
  into joined_room
  from cotime_book.rooms as room
  where room.code = upper(btrim(p_code))
    and room.is_active = true
  for update;

  if joined_room.id is null then
    raise exception 'Room not found or no longer active'
      using errcode = 'P0002';
  end if;

  insert into cotime_book.room_members (
    room_id,
    user_id,
    nickname,
    avatar_color_index
  ) values (
    joined_room.id,
    current_user_id,
    btrim(p_nickname),
    p_avatar_color_index
  )
  on conflict (room_id, user_id) do update
  set nickname = excluded.nickname,
      avatar_color_index = excluded.avatar_color_index;

  return joined_room;
end;
$$;

create or replace function cotime_book.deactivate_empty_room()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update cotime_book.rooms
  set is_active = false,
      updated_at = now()
  where id = old.room_id
    and not exists (
      select 1
      from cotime_book.room_members
      where room_id = old.room_id
    );
  return old;
end;
$$;

drop trigger if exists deactivate_empty_room_after_member_delete
  on cotime_book.room_members;
create trigger deactivate_empty_room_after_member_delete
after delete on cotime_book.room_members
for each row execute function cotime_book.deactivate_empty_room();
