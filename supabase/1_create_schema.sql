-- Step 1/3: create and expose the CoTime Book application schema.

create schema if not exists cotime_book;

grant usage on schema cotime_book to authenticated, service_role;
revoke usage on schema cotime_book from anon;

-- Expose CoTime Book without removing schemas used by other apps.
do $$
declare
  configured_schemas text;
  merged_schemas text;
begin
  select regexp_replace(setting, '^(pgrst[.]db_schemas=)+', '')
  into configured_schemas
  from pg_db_role_setting as role_setting
  join pg_roles as role on role.oid = role_setting.setrole
  cross join lateral unnest(role_setting.setconfig) as config(setting)
  where role.rolname = 'authenticator'
    and role_setting.setdatabase = 0
    and setting like 'pgrst.db_schemas=%'
  limit 1;

  with candidates as (
    select btrim(value) as schema_name, ordinal::bigint as priority
    from string_to_table(
      coalesce(configured_schemas, 'public, graphql_public'),
      ','
    ) with ordinality as current_entry(value, ordinal)

    union all

    select 'driftread', 100000
    where to_regnamespace('driftread') is not null

    union all

    select 'cotime_book', 100001
  ),
  deduplicated as (
    select schema_name, min(priority) as priority
    from candidates
    where schema_name <> ''
    group by schema_name
  )
  select string_agg(schema_name, ', ' order by priority)
  into merged_schemas
  from deduplicated;

  execute format(
    'alter role authenticator set pgrst.db_schemas = %L',
    merged_schemas
  );
end
$$;

notify pgrst, 'reload config';
