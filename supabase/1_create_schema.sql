-- Step 1/3: create and expose the CoTime Book application schema.

create schema if not exists cotime_book;

grant usage on schema cotime_book to authenticated, service_role;
revoke usage on schema cotime_book from anon;

-- Keep the shared schemas required by other apps and add CoTime Book.
alter role authenticator set pgrst.db_schemas =
  'public, graphql_public, cotime_book';

notify pgrst, 'reload config';
