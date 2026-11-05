#!/usr/bin/env bash
# Runs bin/benchmark of basecamp/once-campfire-verification for this app, inside a Debian 13 container
# that holds the tools a dev box may lack (see runner.Dockerfile). README.md has the layout and the steps.
#
#   bench/run.sh --setup                      checkout, patch, image, loadgen and seed; no benchmark
#   bench/run.sh --apps agentica --preflight  setup, then bin/benchmark with these arguments
#
# Settings (environment): BENCH_DIR (default ~/apps/bench), BENCH_TMPDIR (outside /tmp, which is a small
# tmpfs on many boxes), BENCH_CACHE (the cargo registry), CARGO_BUILD_JOBS (passed on to cargo).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)

# The harness pins its own revision: the numbers of a run name it, so a newer one is a different benchmark.
harness_url=https://github.com/basecamp/once-campfire-verification.git
harness_rev=ec02deb

bench_dir=${BENCH_DIR:-$HOME/apps/bench}
harness=$bench_dir/once-campfire-verification
# The harness looks for the app next to itself as ../once-campfire-<name>, and runs git in it.
app=$bench_dir/once-campfire-agentica
cache=${BENCH_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/campfire-bench}
tmp=${BENCH_TMPDIR:-$cache/tmp}
image=campfire-bench-runner:debian13

setup_only=false
args=()
for arg in "$@"; do
  if [ "$arg" = --setup ]; then setup_only=true; else args+=("$arg"); fi
done

mkdir -p "$bench_dir" "$cache/cargo" "$cache/home" "$tmp"
# Absolute paths: the container mounts each one at the same path, and a relative one would be a named volume.
bench_dir=$(cd "$bench_dir" && pwd); cache=$(cd "$cache" && pwd); tmp=$(cd "$tmp" && pwd)
harness=$bench_dir/once-campfire-verification
app=$bench_dir/once-campfire-agentica

if [ ! -d "$harness/.git" ]; then
  git clone --quiet "$harness_url" "$harness"
fi
if [ "$(git -C "$harness" rev-parse HEAD)" != "$(git -C "$harness" rev-parse "$harness_rev^{commit}" 2>/dev/null || true)" ]; then
  git -C "$harness" fetch --quiet origin
  git -C "$harness" checkout --quiet "$harness_rev"
fi

# A clone, not a worktree: a worktree's .git file points outside the mount that the container sees.
# Move it to another revision with `git -C $app fetch origin && git -C $app checkout --detach REV`.
if [ ! -d "$app/.git" ]; then
  git clone --quiet "$repo" "$app"
  # A later fetch should see the published repo, not this checkout (often a worktree that goes away).
  git -C "$app" remote set-url origin "$(git -C "$repo" remote get-url origin)"
  git -C "$app" checkout --quiet --detach "$(git -C "$repo" rev-parse HEAD)"
fi

# The patch adds agentica to the harness; it is local until the owner allows an upstream PR.
if git -C "$harness" apply --check "$here/harness.patch" 2>/dev/null; then
  git -C "$harness" apply "$here/harness.patch"
elif ! git -C "$harness" apply --reverse --check "$here/harness.patch" 2>/dev/null; then
  echo "bench/harness.patch neither applies to nor is applied in $harness" >&2
  exit 1
fi

docker build --quiet --file "$here/runner.Dockerfile" --tag "$image" "$here" >/dev/null

# The harness hands host paths to `docker run -v`, so everything it reads lives at the same absolute path
# in the container as on the host; the socket gives it the host's Docker, and --network host puts 127.0.0.1
# of the container on the host, where the apps listen. The user is the caller's, so no file is root's.
# LANG: without a UTF-8 locale Ruby tags gunzipped response bodies as US-ASCII and fails on the Rails pages.
extra_env=()
if [ -n "${CARGO_BUILD_JOBS:-}" ]; then extra_env+=(--env "CARGO_BUILD_JOBS=$CARGO_BUILD_JOBS"); fi

in_container() {
  docker run --rm --init --network host \
    --user "$(id -u):$(id -g)" --group-add "$(stat -c %g /var/run/docker.sock)" \
    --volume /var/run/docker.sock:/var/run/docker.sock \
    --volume "$bench_dir:$bench_dir" --volume "$cache:$cache" --volume "$tmp:$tmp" \
    --env HOME="$cache/home" --env TMPDIR="$tmp" --env CARGO_HOME="$cache/cargo" --env LANG=C.UTF-8 \
    "${extra_env[@]}" \
    --workdir "$harness" "$image" "$@"
}

in_container cargo build --release --locked --manifest-path loadgen/Cargo.toml

# bin/seed refuses an existing output and copies the finished one into place at the end; a copy cut short
# leaves a partial folder that needs `rm -rf fixtures/default`. It builds the Rails reference image: several
# GB and minutes, once.
if [ ! -e "$harness/fixtures/default" ]; then
  in_container bin/seed
fi

if $setup_only; then exit 0; fi

# What a run measured: the harness revision is recorded by bin/benchmark, the patch and the app are not.
echo "harness.patch sha256 $(sha256sum "$here/harness.patch" | cut -d' ' -f1)"
echo "app $(git -C "$app" rev-parse HEAD)"

# This box has 8 cores: the harness defaults (8-11 and 12-15) are for 16.
defaults=()
case " ${args[*]:-} " in *" --cpus"*) ;; *) defaults+=(--cpus 4-7) ;; esac
case " ${args[*]:-} " in *" --client-cpus"*) ;; *) defaults+=(--client-cpus 0-3) ;; esac

in_container bin/benchmark "${defaults[@]}" "${args[@]}"
