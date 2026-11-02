## The program of the features: the app on 127.0.0.1 and a free port. It says the port on its first line.

import Config from "../../src/config"
import Web from "../../src/web"

def main() -> Void
  config = Config.parse("127.0.0.1", "0").unwrap!
  Web.run(config).unwrap!
end
