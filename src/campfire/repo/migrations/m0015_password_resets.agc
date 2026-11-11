## A link in an email to reset a password. Only a hash of its token is kept, so a copy of the database does not give a
## link that works. The token is random and 256 bits, so a plain SHA-256 is enough (no slow hash). `used_at` is set by
## the one request that uses the link, which is what makes it single-use; the row stays for a while so that the next
## request for a link waits (see `Auth.request_password_reset`). It goes with its user.
##
## Rails has no password reset, so this is the one table that a database made by Rails lacks and the app needs. An
## app-only table lives in the list of migrations, last, like the rest, so that a database the app made has it in its
## history; it is also the one thing added to a database that Rails made, which `Database.migrate` does not migrate:
## the statements are written to be run again (`if not exists`) and `Migrations.extensions` hands them over
## (`statements`), so there is one text for both. `specs/schema.feature` leaves it out of the comparison with Rails.

import Migrate from "pkg/db/migrate"
import Rails from "../rails"

## Migration 15: create password resets.
export def migration() -> Migrate.Migration = Migrate.sql(15, "create password resets", statements())

## The statements of the migration, which do nothing when the table is there.
export def statements() -> List[String]
  [password_resets(), "create index if not exists password_resets_user_id on password_resets (user_id)"]
end

def password_resets() -> String
  <<~SQL
    create table if not exists password_resets (
      id integer primary key autoincrement,
      user_id integer not null references users (id) on delete cascade,
      token_digest text not null unique,
      expires_at text not null,
      used_at text,
      created_at text not null default (#{Rails.NOW})
    )
  SQL
end
