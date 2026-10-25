# QA tools shared by every game

Four tools that every game wants and that were one game's copy until 2026-10-25. Each is a script in `tools/` that a game's own `tools/<name>.sh` reaches with `cd "$(dirname "$0")/.." && exec ../dot-game/tools/<name>.sh "$@"`, and the game-specific part is a small file. Nothing here is delivered in a pack, so none of it bumps the API level.

## Perf budget: `tools/perf_budget.sh`

Plays each case RUNS times on the GPU box, takes the median of every metric and compares it with `tests/perf_budget.json` (baseline times `1 + tolerance`, past the metric's slack, or past its cap). A baseline taken on another GPU is refused (exit 3), so pin the box with `GPU_BOX` in the game's `perf_run_case`. Exit 0 pass, 1 regression, 2 a run failed, 3 GPU mismatch. `--update` rebases, `--post` sends the result to the nightly panel's /qa (kind perf) through dev01, `--from-runs DIR` re-evaluates saved runs.

The game's `tools/qa.conf` sets `PERF_CASES`, `perf_run_case CASE SECONDS` (prints one `PERF {json}` line with `p50_ms`, `p95_ms`, `p99_ms`, `stall_ms`, `load_s`, `rss_mb`, `gpu`, `resolution` and whatever else it wants to budget), `PERF_METRICS` (`name:slack:cap` words), and optionally `PERF_PACK_DIRS` (summed into `pack_mb`), `PERF_SECONDS` and `perf_prepare`.

## Visual regression: `tools/visual_check.sh` and `visual_compare.py`

Renders each case's shots and compares them with `tests/golden/<case>_<shot>.png`; a failure leaves golden, frame and amplified diff in `.godot/test-logs/visual/`. `--update` re-records, `--post` sends the result and the diffs to /qa (kind visual). `qa.conf` sets `VISUAL_CASES`, `VISUAL_SHOTS` (default `overview eye roof`) and `visual_render CASE`, which must leave `screenshots/<case>_<shot>.png`. Re-record only on the same kind of GPU the goldens came from.

## Netchaos: `tools/netchaos.sh`, `netchaos_tc.sh`, `netchaos_eval.py`

A real dedicated server on this machine and two remote clients plus one local, with only the game's UDP port impaired by `tc netem` (clean, lossy100, jitter200, awful400, bwcap, blackout; limits per profile in `netchaos_eval.py`). The game supplies `tools/netchaos_server.tscn` and `tools/netchaos_client.tscn` whose scripts extend `DotGameNetchaosServer` and `DotGameNetchaosClient` (`addons/dot_game/qa/`) and override a handful of hooks: `_configure`, `_prepare`, `_boot_world`, `_players`, `_net_alive` on the server; `client_scene`, `fire_action`, `_roster` on the client. `NC_SOLID=1` keeps `mp_solidplayers` on. Never edit the rig's scripts or the `.gd` files while a run is in progress (bash reads a script as it runs, and a run that dies leaves netem armed: `netchaos_tc.sh clear <dev>` on each box).

## Which suites a change needs: `dot-ci/scripts/affected.sh`

See dot-ci. It is the other half: what to run after an edit to an addon.
