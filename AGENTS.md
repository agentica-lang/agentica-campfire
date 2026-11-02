# agentica-campfire

A port of ONCE Campfire (group chat) in Agentica, on Bond. `docs/plan.md` has the plan and the phases;
`README.md` has the status.

## Map

```text
campfire.agc    the program (`make run`): config from the environment, then the server
src/            config.agc (host and port), web.agc (routes, server), views.agc (EAG templates)
specs/          BDD: *.feature, steps.agc, fixtures/server.agc (the app on a free port)
test/           unit tests (*_test.agc)
agentica.toml   the manifest; Bond is pinned by commit, agentica.lock has its hash
```

## Commands

- `make install` fetches `deps/` from the lock (git ignores `deps/`). `make check`, `make test`, `make run`.
- Agentica 0.22.0 or later. CI pins it with its sha256 (`AGENTICA_VERSION`, `AGENTICA_SHA256` in
  `.github/workflows/ci.yml`).
- To move Bond: `agentica add bond https://github.com/agentica-lang/bond --ref COMMIT`, commit the lock.

## Rules

- BDD first: a behavior is a Gherkin scenario in `specs/` before the code. A test over HTTP uses 127.0.0.1 and port 0.
  Unit tests (`test/`) only for pure helpers.
- Views are EAG templates with `<%@ escape &Bond.escape %>` as the first line, so every `<%= %>` is escaped.
  `<%== %>` only for markup that the program wrote, never for a value of a client.
- `agentica.toml` has `blank_line_after_end = true`: every bare `end` is followed by an empty line.
- No Dockerfile, assets, database or auth yet: each is a later PR of `docs/plan.md` phase 2.
- Campfire's CSS, JS and images are MIT (37signals): keep their notice when a file is copied (see README).
- Code comments say why. Follow `agentica-programming` and `agentica-code-guidelines` for the style.
