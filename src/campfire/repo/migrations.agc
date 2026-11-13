## The schema of the app, as ordered migrations for `Migrate.up` (agentica-db), one file per migration in `migrations/`
## and numbered like the file: `m0001_accounts.agc` is version 1. Migrations 1 to 14 create the tables of a Rails
## Campfire (`db/schema.rb` at 90b3300) exactly as Rails writes them, so that a database made by Rails is the same
## schema; the last (15, password resets) is the one table that Rails has not. There has been no release, so the
## history was rewritten to this; once there is one, a change is a new migration.
##
## Foreign keys are on (the driver's default, and `Database.migrate` refuses a connection that has them off), only
## where Rails declares them and with no cascade, as in Rails: a user is never deleted, only deactivated, and the app
## deletes no room or message (a Rails app does it in code, with `dependent: :destroy`).

import Migrate from "pkg/db/migrate"
import M0001 from "migrations/m0001_accounts"
import M0002 from "migrations/m0002_users"
import M0003 from "migrations/m0003_sessions"
import M0004 from "migrations/m0004_rooms"
import M0005 from "migrations/m0005_memberships"
import M0006 from "migrations/m0006_messages"
import M0007 from "migrations/m0007_action_text_rich_texts"
import M0008 from "migrations/m0008_boosts"
import M0009 from "migrations/m0009_message_search_index"
import M0010 from "migrations/m0010_active_storage"
import M0011 from "migrations/m0011_webhooks"
import M0012 from "migrations/m0012_bans"
import M0013 from "migrations/m0013_searches"
import M0014 from "migrations/m0014_push_subscriptions"
import M0015 from "migrations/m0015_password_resets"

## The table where `Migrate` keeps the history of this app. Rails has a `schema_migrations` of its own (a `version`
## column and nothing else), which the default name of `Migrate` would clash with.
HISTORY_TABLE = "agentica_schema_migrations"

## Every migration of the schema, oldest first. `test/migrations_test.agc` checks that it has one per file.
def all() -> List[Migrate.Migration]
  [
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
    M0012.migration(),
    M0013.migration(),
    M0014.migration(),
    M0015.migration(),
  ]
end

## What an app needs of its own in a database that Rails made, which has no other migration run on it: the tables that
## Rails lacks (the password resets), as statements that do nothing when they ran already.
def extensions() -> List[String] = M0015.statements()

## The version of the last migration: the schema version of a database that is up to date. The versions ascend in the
## list (`Migrate.up` refuses a list that does not).
def latest() -> Int = all().last.version
