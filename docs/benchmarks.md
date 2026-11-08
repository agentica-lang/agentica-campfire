# Benchmarks

The benchmark is the one of
[basecamp/once-campfire-verification](https://github.com/basecamp/once-campfire-verification)
(`bin/benchmark`), run on this app next to Rails Campfire. The README has the latest numbers. The
steps to set it up and run it, and what `bench/run.sh` does, are in [bench/README.md](../bench/README.md).

## Method

- The numbers are requests per second (`req/s`); higher is better.
- Each sample is 16 concurrent clients for 8 seconds, after a warm-up of 2 seconds with 4 clients.
  The table shows the median of the rounds. The default is 3 rounds, which alternate between the apps.
- The client asks for gzip, and the harness checks every response and every acknowledged write.
- The server runs on CPUs 4-7 and the client on CPUs 0-3 (`--cpus 4-7 --client-cpus 0-3`, the
  defaults of `bench/run.sh`; the harness default is for 16 cores).
- Nothing else may run on the machine while it measures.
- The routes are `room_show`, `messages_page`, `sidebar`, `search` and `post_message`. `bench/run.sh --routes a,b`
  runs a subset; the latest run in the README leaves out `post_message` (the README says why).

## Reproduce

```sh
docker build -t once-campfire-agentica:app .
bench/run.sh --setup
bench/run.sh --apps rails,agentica
```
