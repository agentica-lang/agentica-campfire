# Makes `campfire.sqlite3`: a database as Rails Campfire (basecamp/once-campfire at 90b3300) leaves it. It loads that
# commit's db/schema.rb (`schema.rb` here) through Active Record, then writes the rows that the specs sign in with.
# `schema.rb` is copied from that commit (MIT, copyright 37signals, LLC: `LICENSE.37signals`). Run it with `make.sh`;
# the output is committed, so the specs need no Ruby.
require "active_record"
require "bcrypt"
require "securerandom"

path = ARGV.fetch(0)
File.delete(path) if File.exist?(path)
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: path)
ActiveRecord::Migration.verbose = false

# The schema file names Rails 8.2, which has no release yet; the DDL that 8.0 writes for it is the same.
source = File.read(File.join(__dir__, "schema.rb")).sub("ActiveRecord::Schema[8.2]", "ActiveRecord::Schema[8.0]")
eval(source)

class Account < ActiveRecord::Base; end
class Session < ActiveRecord::Base; end
class User < ActiveRecord::Base
  enum :status, %i[ active deactivated banned ], default: :active
  enum :role, %i[ member administrator bot ]
end

digest = BCrypt::Password.create("secret123456", cost: 12).to_s
at = Time.utc(2026, 3, 1, 9, 0, 0, 123_456)
ActiveRecord::Base.record_timestamps = false

stamp = { created_at: at, updated_at: at }
Account.create!(name: "37signals", join_code: "CRMu-l8Ge-KB9B", **stamp)
david = User.create!(name: "David", email_address: "david@37signals.com", password_digest: digest, role: :administrator, **stamp)
User.create!(name: "JZ", email_address: "jz@37signals.com", password_digest: digest, bio: "Designer", **stamp)
User.create!(name: "Bender Bot", bot_token: "benderbot123", role: :bot, **stamp)
User.create!(name: "Rita Lopez", email_address: "rita-deactivated-00000000-0000-4000-8000-000000000000@37signals.com",
             password_digest: digest, status: :deactivated, **stamp)
User.create!(name: "Mallory Banned", email_address: "mallory@example.com", password_digest: digest, status: :banned, **stamp)
Session.create!(user_id: david.id, token: "AxJs94fteQ5Autv2VrKsH68c", user_agent: "Mozilla/5.0", ip_address: "127.0.0.1",
                last_active_at: at, **stamp)

ActiveRecord::Base.connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
ActiveRecord::Base.connection.execute("PRAGMA journal_mode = DELETE")
