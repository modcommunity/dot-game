# QA tools shared by every game

Five tools that every game wants and that were one game's copy until 2026-10-25. Each is a script in `tools/` that a game's own `tools/<name>.sh` reaches with `cd "$(dirname "$0")/.." && exec ../dot-game/tools/<name>.sh "$@"`, and the game-specific part is a small file. Nothing here is delivered in a pack, so none of it bumps the API level.

## Perf budget: `tools/perf_budget.sh`

Plays each case RUNS times on the GPU box, takes the median of every metric and compares it with `tests/perf_budget.json` (baseline times `1 + tolerance`, past the metric's slack, or past its cap). A baseline taken on another GPU is refused (exit 3), so pin the box with `GPU_BOX` in the game's `perf_run_case`. Exit 0 pass, 1 regression, 2 a run failed, 3 GPU mismatch. `--update` rebases, `--post` sends the result to the nightly panel's /qa (kind perf) through dev01, `--from-runs DIR` re-evaluates saved runs.

The game's `tools/qa.conf` sets `PERF_CASES`, `perf_run_case CASE SECONDS` (prints one `PERF {json}` line with `p50_ms`, `p95_ms`, `p99_ms`, `stall_ms`, `load_s`, `rss_mb`, `gpu`, `resolution` and whatever else it wants to budget), `PERF_METRICS` (`name:slack:cap` words), and optionally `PERF_PACK_DIRS` (summed into `pack_mb`), `PERF_SECONDS` and `perf_prepare`.

## Visual regression: `tools/visual_check.sh` and `visual_compare.py`

Renders each case's shots and compares them with `tests/golden/<case>_<shot>.png`; a failure leaves golden, frame and amplified diff in `.godot/test-logs/visual/`. `--update` re-records, `--post` sends the result and the diffs to /qa (kind visual). `qa.conf` sets `VISUAL_CASES`, `VISUAL_SHOTS` (default `overview eye roof`) and `visual_render CASE`, which must leave `screenshots/<case>_<shot>.png`. Re-record only on the same kind of GPU the goldens came from.

## Netchaos: `tools/netchaos.sh`, `netchaos_tc.sh`, `netchaos_eval.py`

A real dedicated server on this machine and two remote clients plus one local, with only the game's UDP port impaired by `tc netem` (clean, lossy100, jitter200, awful400, bwcap, blackout; limits per profile in `netchaos_eval.py`). The game supplies `tools/netchaos_server.tscn` and `tools/netchaos_client.tscn` whose scripts extend `DotGameNetchaosServer` and `DotGameNetchaosClient` (`addons/dot_game/qa/`) and override a handful of hooks: `_configure`, `_prepare`, `_boot_world`, `_players`, `_net_alive` on the server; `client_scene`, `fire_action`, `_roster` on the client. `NC_SOLID=1` keeps `mp_solidplayers` on. Each direction has its own netem (dport matches to band 3, sport to band 2), so with `--remote 0`, where both directions cross `lo`, bwcap is still 256 kbit each way; one shared queue halved it and tail-dropped inputs behind snapshots, which read as 3.5 m wall mispredictions. In blackout the first snapshot after the dark seconds corrects by up to speed times their length (the server ran them on neutral input): the eval reports that resume correction per client and judges the worst-correction limit on the rest (`RESUME_S`, `NC_BLACKOUT_AT`/`NC_BLACKOUT_S` from `netchaos.sh`). Never edit the rig's scripts or the `.gd` files while a run is in progress (bash reads a script as it runs, and a run that dies leaves netem armed: `netchaos_tc.sh clear <dev>` on each box).

## Client prediction bench: `DotGameClientBench`

`addons/dot_game/qa/dot_game_client_bench.gd`: the real client scene in one process, the game's dedicated server in a second, dot-net's latency relay between them, and a printout of replays, skipped reconciles, mismatches by variable (`--mismatches`), replayed ticks, fps and the clock. It found arena's float32 rewind bug, which made browser clients replay on nearly every snapshot. A game adds `tools/client_bench.tscn` (one Node) with a script extending the class and overriding `_configure` (`client_scene`, the pilot's actions), `_prepare` (scratch settings) and `_boot_server` (build the server under the node, add the bots, return its `DotNetManager`; `make_server_config` helps). Run `heavy -- timeout 600 godot --headless --path . res://tools/client_bench.tscn -- --play --bots 8 --delay 40 --burn 14 --seconds 20 --mismatches`; `--timeline` (a line every 2 s), `--raw-input` (predict on the sampled command), `--jitter`, `--tick` too; `--delay` is milliseconds each way, `--burn MS` spends MS of wall time in every frame before the client runs (a slow device). The server is the same scene with `--role server`, killed at the end. game-playground's `tools/client_bench.gd` is the smallest example.

## Phone frame: `addons/dot_game/tools/dot_game_phone_shot.sh`

One 844x390 frame of the game's real offline client with touch forced on (`DotPlatform.touch_override`), so the HUD, the touch Menu button and the touch buttons are all built and the overlap between them can be looked at. The script instances a scene (default: the project's main scene; `--scene=`), sets `force_offline`, waits for the root's `player` (`--ready=`), settles `--frames` frames and writes `screenshots/phone.png` (`--out=`). `--set=prop=value`, `--call=method`, `--size=WxH`, `--no-touch`. A game's `tools/phone_shot.sh` is one line: `exec bash "$(dirname "$0")/../addons/dot_game/tools/dot_game_phone_shot.sh" "$@"`. It needs xvfb (`--headless` renders nothing), so run it through `heavy`. It refuses to write a frame that is one flat colour.

`MOVIE=1` runs it under `--write-movie`, as the filmstrip tools do; a settled frame comes out the same as without it. A grey frame is a capture taken before the client has drawn (a 2D client that builds over several frames, or a `--headless` run, whose renderer is null), so the tool waits for the ready property, settles N frames and refuses a flat single-colour image (exit 4) instead of writing it. A 3D map in Forward+ on llvmpipe can pass the heavy memory cap and be OOM-killed with no message: set `RENDERER=gl_compatibility`.

## Which suites a change needs: `dot-ci/scripts/affected.sh`

See dot-ci. It is the other half: what to run after an edit to an addon.

Netchaos runs on dev01's nightly: `Netchaos arena` and `Netchaos ZZ` nightly with the default profiles, and `Netchaos full weekly` (Sundays 02:00) with all six. The jobs are rows in the nightly database, documented in `~/stack/nightly/README.md`; each ends in `tools/netchaos.sh --post`.

A `godot --script` tool that writes project files (`dot_game_cfg_templates.gd`, any generator) is run as `GPU_OFFLOAD=0 heavy -- ...`: `heavy` may offload it to a staging box, which writes its own copy of the files, not yours.
