class_name DotGamePerfBench
extends Node

## A solo-client benchmark any game shares: its real client scene offline on a fixed map, mode, bot count and seed, recorded by the
## client's own dot-profiler, so the report has the same per-system table as a player's `profiler_record`, plus a sidecar of engine
## numbers (draw calls, objects, physics, tick rate, renderer, adapter). A game's `tools/perf_bench.gd` extends this and sets
## `client_scene` in `_configure`; the hooks below cover the rest. Run it windowed on a GPU box with the game's `tools/perf_bench.sh`
## (which execs dot-game's `tools/perf_bench.sh`), not headless: headless has no renderer, so the render cost reads as zero.
##
## Flags (after `--`): `--map ID --mode ID --bots N --seconds S --warmup S --seed N --out DIR --tag T`; every `--key value` pair is also
## in [member args] (without the dashes) for a subclass's own flags. Prints `PERF_BENCH_REPORT {json}` (the profiler report without
## spikes and samples, as the run may be on another box), `PERF_BENCH_SIDECAR {json}` and `PERF_BENCH {json}` (paths and tag).

## The game's client scene (`res://game/x.tscn`). Required.
var client_scene := ""
var map := ""
var mode := ""
var bots := 31
var seconds := 30.0
var warmup := 20.0
var seed_value := 1
var out_dir := "user://perf-bench"
var tag := ""
## Every `--key value` pair, keyed without the dashes, values as strings.
var args := {}
var client: Node = null
var profiler: Node = null
## Per-frame sums while recording, for the sidecar.
var _acc := {}
var _frames := 0
var _steps0 := 0
var _usec0 := 0


## Sets `client_scene` and the game's defaults (map, mode, bots) before the flags are read.
func _configure() -> void:
	pass


## Before the client is added: `force_offline`, `offline_bots` and the like. The flags are already parsed.
func _setup_client(c: Node) -> void:
	c.set("force_offline", true)
	c.set("offline_bots", bots)


## After the client is added and its gate is open: pick the map and mode (the way the game's own menu does), warm caches.
## May await. A game that boots straight into `map` needs nothing.
func _select(_game: Object) -> void:
	pass


## After the selection, before the warm-up: start a pilot that drives the player.
func _start_pilot(_game: Object) -> void:
	pass


## Named unit counts for the profiler's `profiler_groups` (`add_counter(name, callable, prefix)`).
func _add_counters(_game: Object) -> void:
	pass


## Just before recording starts and right after it ends: a game's own timers on, then off.
func _record_begin() -> void:
	pass


func _record_end() -> void:
	pass


## Extra sidecar keys from the game; merged over the engine numbers.
func _sidecar_extra(_game: Object) -> Dictionary:
	return {}


func _ready() -> void:
	_configure()
	var user_args := OS.get_cmdline_user_args()
	for i in range(user_args.size() - 1):
		if not user_args[i].begins_with("--"):
			continue
		var key := user_args[i].substr(2)
		var v := user_args[i + 1]
		args[key] = v
		match key:
			"map": map = v
			"mode": mode = v
			"bots": bots = int(v)
			"seconds": seconds = float(v)
			"warmup": warmup = float(v)
			"seed": seed_value = int(v)
			"out": out_dir = v
			"tag": tag = v
	seed(seed_value)
	_run.call_deferred()


func say(text: String) -> void:
	print("PERF_BENCH_LOG t=%.1f %s" % [Time.get_ticks_msec() / 1000.0, text])


func wait(sec: float) -> void:
	await get_tree().create_timer(sec, true, false, true).timeout


## Waits for the client's loading gate (`gate.is_open()`), when it has one.
func wait_gate(limit: float) -> void:
	var t := 0.0
	while t < limit:
		var gate: Variant = client.get("gate")
		if gate == null or (gate as Object).call("is_open"):
			return
		await wait(0.5)
		t += 0.5


func _players(game: Object) -> int:
	if game != null and game.has_method("players"):
		return (game.call("players") as Array).size()
	return 0


func _run() -> void:
	if client_scene == "":
		say("client_scene not set (override _configure)")
		get_tree().quit(2)
		return
	client = (load(client_scene) as PackedScene).instantiate()
	_setup_client(client)
	add_child(client)
	await wait_gate(120.0)
	await _select(client.get("game"))
	var game: Object = client.get("game")
	_start_pilot(game)
	say("map %s mode %s players %d, warming %.0f s" % [map, mode, _players(game), warmup])
	await wait(warmup)
	profiler = DotRegistry.get_service(&"dot_profiler")
	if profiler == null:
		profiler = preload("../runtime/dot_game_profiler.gd").add(self)
		say("client has no profiler; placed one")
	if profiler == null:
		say("dot-profiler is not in this build")
		get_tree().quit(1)
		return
	profiler.config.record_dir = out_dir
	profiler.config.keep_recordings = 500
	profiler.config.budget_ms = 33.0
	_add_counters(game)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_record_begin()
	_steps0 = Engine.get_physics_frames()
	_usec0 = Time.get_ticks_usec()
	var started: DotResult = profiler.start_recording(seconds)
	if not started.ok:
		say("recording did not start: %s" % started.error.message)
		get_tree().quit(1)
		return
	var players0 := _players(game)
	while profiler.is_recording():
		await get_tree().process_frame
		_sample()
	await get_tree().process_frame
	_record_end()
	var path: String = profiler.last_saved_path()
	var side := _sidecar(game, players0)
	var side_path := ProjectSettings.globalize_path(path).get_basename() + ".bench.json"
	var f := FileAccess.open(side_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(side, " "))
		f.close()
	var report: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if report is Dictionary:
		(report as Dictionary).erase("spikes")
		(report as Dictionary).erase("samples")
	print("PERF_BENCH_REPORT %s" % JSON.stringify(report))
	print("PERF_BENCH_SIDECAR %s" % JSON.stringify(side))
	print("PERF_BENCH %s" % JSON.stringify({"report": ProjectSettings.globalize_path(path), "sidecar": side_path, "tag": tag}))
	get_tree().quit(0)


func _add(key: String, v: float) -> void:
	_acc[key] = float(_acc.get(key, 0.0)) + v


func _sample() -> void:
	_frames += 1
	var vp := get_viewport().get_viewport_rid()
	_add("render_cpu_ms", RenderingServer.viewport_get_measured_render_time_cpu(vp) + RenderingServer.get_frame_setup_time_cpu())
	_add("render_gpu_ms", RenderingServer.viewport_get_measured_render_time_gpu(vp))
	_add("draw_calls", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_add("objects", Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	_add("primitives", Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	_add("phys_active", Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
	_add("phys_pairs", Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))
	_add("phys_islands", Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT))
	_add("nodes", Performance.get_monitor(Performance.OBJECT_NODE_COUNT))


## Frames recorded so far (for a subclass dividing its own totals).
func frames_recorded() -> float:
	return maxf(_frames, 1.0)


## Engine numbers the per-system table does not hold: renderer, physics server, host.
func _sidecar(game: Object, players0: int) -> Dictionary:
	var n := frames_recorded()
	var per_frame := {}
	for k: String in _acc:
		per_frame[k] = snappedf(float(_acc[k]) / n, 0.001)
	var size := get_viewport().get_visible_rect().size
	var side := {
		"map": map, "mode": mode, "bots": bots, "seed": seed_value, "seconds": seconds, "warmup": warmup,
		"tag": tag, "players": players0,
		"host": OS.get_environment("HOSTNAME") if OS.get_environment("HOSTNAME") != "" else OS.get_environment("HOST"),
		"display": DisplayServer.get_name(), "adapter": RenderingServer.get_video_adapter_name(),
		"renderer": RenderingServer.get_current_rendering_method(), "window": [size.x, size.y],
		"vsync": DisplayServer.window_get_vsync_mode(), "cpu": OS.get_processor_name(), "threads": OS.get_processor_count(),
		"physics_engine": str(ProjectSettings.get_setting("physics/3d/physics_engine", "")),
		"tick_hz": Engine.physics_ticks_per_second, "frames": _frames,
		"ticks_per_frame": snappedf(float(Engine.get_physics_frames() - _steps0) / n, 0.001),
		"ticks_per_sec": snappedf(float(Engine.get_physics_frames() - _steps0) * 1000000.0 / maxf(Time.get_ticks_usec() - _usec0, 1.0), 0.01),
		"per_frame": per_frame,
	}
	if game != null and game.get("mode") != null:
		side["mode"] = String(game.get("mode").id)
	side.merge(_sidecar_extra(game), true)
	return side
