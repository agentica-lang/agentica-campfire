# bench

Runs the benchmark of [basecamp/once-campfire-verification](https://github.com/basecamp/once-campfire-verification)
(`bin/benchmark --apps agentica`) on this app. The harness needs Ruby, the SQLite CLI, FFmpeg and Rust 1.98.1,
which a dev box may lack, so `run.sh` runs it in a Debian 13 container (`runner.Dockerfile`).

```sh
bench/run.sh --setup                         # everything but the benchmark
bench/run.sh --apps agentica --preflight     # one round, no load
bench/run.sh --apps agentica                 # the measured run: nothing else may run on the machine
```

`run.sh` does this, and is safe to run again: the clones, the patch and the seed are skipped when done, the runner image and loadgen are cached builds:

1. Under `BENCH_DIR` (`~/apps/bench`): clones the harness at `ec02deb` and clones this repo as
   `once-campfire-agentica`, the checkout that the harness expects next to its own (it runs git there to
   record the revision). Move it with `git -C ~/apps/bench/once-campfire-agentica fetch origin` and
   `checkout --detach REV`.
2. Applies `harness.patch` to the harness: `agentica` in the allowed apps, the image
   `once-campfire-agentica:app` (`AGENTICA_IMAGE` overrides it), a topology entry and a README line. The patch
   is local; nothing is sent upstream.
3. Builds the runner image and `loadgen` (release, locked).
4. Runs `bin/seed` once: it builds the Rails reference image (several GB, minutes) and writes
   `fixtures/default/` of the harness (`db/`, `storage/`, `labels.json`, `reference.env`).
5. Runs `bin/benchmark` with your arguments and, unless you pass them, `--cpus 4-7 --client-cpus 0-3`
   (the harness default is for 16 cores).

The container mounts the Docker socket, uses `--network host`, and sees `BENCH_DIR`, the cache and the
temporary folder at the same paths as the host, since the harness gives host paths to `docker run -v`.
Settings: `BENCH_DIR`, `BENCH_CACHE` (cargo registry; `~/.cache/campfire-bench`), `BENCH_TMPDIR` (the harness
lock file and temporary files; keep it off a small `/tmp`), `CARGO_BUILD_JOBS`.

The app image is not built here, and the harness only runs an existing one. Build it in the clone that the harness reads, at the revision to measure, with that revision as its label; `run.sh` refuses an image whose label is another revision:

```sh
cd ~/apps/bench/once-campfire-agentica
git fetch origin && git checkout --detach REV
docker build --build-arg CAMPFIRE_REVISION="$(git rev-parse HEAD)" -t once-campfire-agentica:app .
```

`AGENTICA_IMAGE` names another tag. The run's `summary.json` has the image id, its labels (the revision and `com.agentica-lang.agentica.version`) and the revision of the clone.
