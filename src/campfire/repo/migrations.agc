## The schema of the app, as ordered migrations for `Migrate.up` (agentica-db), one file per migration in `migrations/`
## and numbered like the file: `m0001_accounts.agc` is version 1. The first three create the tables of a Rails Campfire
## (accounts, users, sessions) exactly as Rails writes them, so that a database made by Rails is the same schema; the
## rest are tables that still have the shape of this app and move to the Rails schema in the next step (rooms,
## memberships, messages, boosts, the search index, attachments, webhooks) or that Rails has not (password resets).
## There has been no release, so the history was rewritten to this; once there is one, a change is a new migration.
##
## Foreign keys are on (the driver's default, and `Database.migrate` refuses a connection that has them off): a user is
## never deleted, only deactivated, so the keys to `users` refuse a delete, and what hangs from a room or a message goes
## with it.

import Migrate from "pkg/db/migrate"
import M0001 from "migrations/m0001_accounts"
import M0002 from "migrations/m0002_users"
import M0003 from "migrations/m0003_sessions"
import M0004 from "migrations/m0004_rooms"
import M0005 from "migrations/m0005_memberships"
import M0006 from "migrations/m0006_messages"
import M0007 from "migrations/m0007_boosts"
import M0008 from "migrations/m0008_message_search_index"
import M0009 from "migrations/m0009_attachments"
import M0010 from "migrations/m0010_webhooks"
import M0011 from "migrations/m0011_password_resets"

## The table where `Migrate` keeps the history of this app. Rails has a `schema_migrations` of its own (a `version`
## column and nothing else), which the default name of `Migrate` would clash with.
export HISTORY_TABLE = "agentica_schema_migrations"

## Every migration of the schema, oldest first. `test/migrations_test.agc` checks that it has one per file.
export def all() -> List[Migrate.Migration]
  return [
    M0001.migration(),
    M0002.migration(),
    M0003.migration(),
    M0004.migration(),
    M0005.migration(),
    M0006.migration(),
    M0007.migration(),
    M0008.migration(),
    M0009.migration(),
    M0010.migration(),
    M0011.migration(),
  ]
end

## What an app needs of its own in a database that Rails made, which has no other migration run on it: the tables that
## Rails lacks (the password resets), as statements that do nothing when they ran already.
export def extensions() -> List[String]
  return M0011.statements()
end

## The version of the last migration: the schema version of a database that is up to date. The versions ascend in the
## list (`Migrate.up` refuses a list that does not).
export def latest() -> Int
  return all().last.version
end
