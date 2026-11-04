# Makes the Active Storage side of an avatar as Rails Campfire (basecamp/once-campfire at 90b3300) leaves it:
# `avatar.sql`, the rows of `active_storage_blobs`, `active_storage_attachments` and `active_storage_variant_records`
# for the avatar of user 1, and `storage/`, the files of the Disk service (`storage/xx/yy/KEY`). The model is the one
# of `User::Avatar`: `has_one_attached :avatar` with the variant `:square`, resized to 512 and converted to WebP,
# which `User#avatar_variant` makes and Campfire serves (`Users::AvatarsController`). Run it with `make_avatar.sh`;
# the output is committed, so the specs need no Ruby.
require "fileutils"
require "tmpdir"
require "logger"
require "rails"
require "active_record/railtie"
require "active_storage/engine"
require "vips"

out = ARGV.fetch(0)
WORK = Dir.mktmpdir
work = WORK
ENV["DATABASE_URL"] = "sqlite3:#{File.join(work, 'db.sqlite3')}"

class FixtureApp < Rails::Application
  config.root = WORK
  config.load_defaults 8.0
  config.eager_load = false
  config.logger = Logger.new(nil)
  config.secret_key_base = "x" * 64
  config.active_storage.variant_processor = :vips
  config.active_storage.service = :local
  config.active_storage.service_configurations = { local: { service: "Disk", root: File.join(ENV.fetch("STORAGE_ROOT"), "files") } }
end

FixtureApp.initialize!
ActiveRecord::Migration.verbose = false
source = File.read(File.join(__dir__, "schema.rb")).sub("ActiveRecord::Schema[8.2]", "ActiveRecord::Schema[8.0]")
eval(source)

class User < ActiveRecord::Base
  has_one_attached :avatar do |attachable|
    attachable.variant :square, resize_to_limit: [ 512, 512 ], format: :webp
  end

  def avatar_variant
    avatar.variant(:square).processed if avatar.variable?
  end
end

x = Vips::Image.xyz(640, 480)
photo = x[0].bandjoin([ x[1] * (255.0 / 479), (x[0] * 0) + 96 ]).cast(:uchar)
jpeg = File.join(work, "moon.jpg")
photo.write_to_file(jpeg)

user = User.create!(name: "Jason", email_address: "jason@example.com", password_digest: "x")
raise "the avatar must be user 1" unless user.id == 1
user.avatar.attach(io: File.open(jpeg), filename: "moon.jpg", content_type: "image/jpeg")
user.avatar.analyze
variant = user.avatar_variant
raise "no variant" unless variant

lines = %w[ active_storage_blobs active_storage_variant_records active_storage_attachments ].flat_map do |table|
  ActiveRecord::Base.connection.select_all("select * from #{table} order by id").map do |row|
    values = row.values.map { |value| value.nil? ? "null" : ActiveRecord::Base.connection.quote(value) }
    "insert into #{table} (#{row.keys.join(', ')}) values (#{values.join(', ')});"
  end
end
File.write(File.join(out, "avatar.sql"), lines.join("\n") + "\n")
FileUtils.rm_rf(File.join(out, "storage"))
FileUtils.cp_r(File.join(ENV.fetch("STORAGE_ROOT"), "files"), File.join(out, "storage"))
puts "variant key #{variant.key}"
