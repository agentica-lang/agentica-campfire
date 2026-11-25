import Bond from "pkg/bond/bond"
import Config from "../src/campfire/config"
import ObjectStore from "../src/campfire/object_store"
import Web from "../src/campfire_web/web"

private

SECRET = "0123456789abcdef0123456789abcdef"

def config_with(env: ObjectStore.Env, megabytes: String) -> Config.Config
  Config.parse(
    Config.DEFAULT_HOST,
    Config.DEFAULT_PORT,
    Config.DEFAULT_DATA_DIR,
    "",
    SECRET,
    "false",
    max_attachment_mb: megabytes,
    storage: env,
  ).unwrap!
end

# Bond stops the program when the limits are over its cap, so a start that is refused fails this test.
def starts?(config: Config.Config) -> Bool = Bond.uploads(Bond.app(), Web.upload_options(config)).uploads.some?

def main() -> Void
  Test.run([
    Test.test("the upload limits of the largest attachment start, with Disk and with S3") do
      disk = ObjectStore.Env(service: "disk")
      s3 = ObjectStore.Env(
        service: "s3",
        endpoint: "http://127.0.0.1:9000",
        bucket: "files",
        access_key_id: "fake-access-key",
        secret_access_key: "fake-secret-key",
      )

      try Test.assert(starts?(config_with(disk, "")), "the default")
      try Test.assert(starts?(config_with(disk, Config.MAX_MAX_ATTACHMENT_MB.to_s)), "the most with Disk")
      try Test.assert(starts?(config_with(s3, Config.MAX_MAX_ATTACHMENT_MB_S3.to_s)), "the most with S3")
      Test.assert(
        not Config.parse(
          Config.DEFAULT_HOST,
          Config.DEFAULT_PORT,
          Config.DEFAULT_DATA_DIR,
          "",
          SECRET,
          "false",
          max_attachment_mb: (Config.MAX_MAX_ATTACHMENT_MB + 1).to_s,
        ).ok?,
        "one over the most with Disk",
      )
    end,
  ])
end
