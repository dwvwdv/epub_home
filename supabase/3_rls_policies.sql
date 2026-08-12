-- Step 3/3: least-privilege grants, RLS, and private Realtime authorization.

alter table cotime_book.rooms enable row level security;
alter table cotime_book.room_members enable row level security;
alter table cotime_book.profiles enable row level security;

revoke all on schema cotime_book from public, anon, authenticated, service_role;
grant usage on schema cotime_book to authenticated, service_role;

revoke all on all tables in schema cotime_book
  from public, anon, authenticated, service_role;
grant select on cotime_book.rooms, cotime_book.room_members, cotime_book.profiles
  to authenticated;
grant update (current_book_title, current_book_hash, current_cfi, updated_at)
  on cotime_book.rooms to authenticated;
grant update (nickname, avatar_color_index, has_book)
  on cotime_book.room_members to authenticated;
grant delete on cotime_book.room_members to authenticated;
grant insert (id, nickname), update (nickname)
  on cotime_book.profiles to authenticated;
grant all on all tables in schema cotime_book to service_role;

revoke all on all functions in schema cotime_book
  from public, anon, authenticated, service_role;
grant execute on function cotime_book.is_room_member(uuid)
  to authenticated, service_role;
grant execute on function cotime_book.can_access_room_topic(text)
  to authenticated, service_role;
grant execute on function cotime_book.create_room(text, integer)
  to authenticated, service_role;
grant execute on function cotime_book.join_room(text, text, integer)
  to authenticated, service_role;

alter default privileges for role postgres in schema cotime_book
  revoke all on tables from public, anon, authenticated;
alter default privileges for role postgres in schema cotime_book
  revoke all on functions from public, anon, authenticated;
alter default privileges for role postgres in schema cotime_book
  revoke all on sequences from public, anon, authenticated;

create policy "Members can read their rooms"
on cotime_book.rooms for select
to authenticated
using ((select cotime_book.is_room_member(id)));

create policy "Members can update room reading state"
on cotime_book.rooms for update
to authenticated
using ((select cotime_book.is_room_member(id)))
with check ((select cotime_book.is_room_member(id)));

create policy "Members can read room memberships"
on cotime_book.room_members for select
to authenticated
using ((select cotime_book.is_room_member(room_id)));

create policy "Users can update own membership"
on cotime_book.room_members for update
to authenticated
using ((select auth.uid()) = user_id)
with check (
  (select auth.uid()) = user_id
  and (select cotime_book.is_room_member(room_id))
);

create policy "Users can leave rooms"
on cotime_book.room_members for delete
to authenticated
using ((select auth.uid()) = user_id);

create policy "Users can read own profile"
on cotime_book.profiles for select
to authenticated
using ((select auth.uid()) = id);

create policy "Users can create own profile"
on cotime_book.profiles for insert
to authenticated
with check ((select auth.uid()) = id);

create policy "Users can update own profile"
on cotime_book.profiles for update
to authenticated
using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

drop policy if exists "CoTime members can receive room events"
  on realtime.messages;
create policy "CoTime members can receive room events"
on realtime.messages for select
to authenticated
using (
  realtime.messages.extension in ('broadcast', 'presence')
  and (select cotime_book.can_access_room_topic((select realtime.topic())))
);

drop policy if exists "CoTime members can send room events"
  on realtime.messages;
create policy "CoTime members can send room events"
on realtime.messages for insert
to authenticated
with check (
  realtime.messages.extension in ('broadcast', 'presence')
  and (select cotime_book.can_access_room_topic((select realtime.topic())))
);

notify pgrst, 'reload schema';
