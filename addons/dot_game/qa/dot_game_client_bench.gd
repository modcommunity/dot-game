class_name DotGameClientBench
extends Node

## Measures a connected client's prediction (replays, skipped reconciles, mismatches) against a real
## server in a second process behind a latency relay. A game extends it in `tools/client_bench.gd`;
## flags, hooks and the command are in docs/qa.md.

## The game's client scene, instanced once the link plays.
var client_scene := ""
## Actions the default pilot holds or taps; empty for none.
var forward_action := &"dot_fps_forward"
var strafe_actions: Array[StringName] = [&"dot_fps_left", &"dot_fps_right"]
var jump_action := &"dot_fps_jump"
var fire_action := &""
## The server game's tick rate (60 is dot-server's sv_tickrate).
var tick_rate := 60

var _role := "client"
var _bots := 3
var _delay := 30.0
var _jitter := 0.0
var _seconds := 15.0
var _burn_ms := 0.0
var _port := 27198
var _play := false
var _server_pid := -1
var _relay: Object = null
var _client: Node = null
var _keepalive: Variant = null
var _mm_seen := -1
var _mm_rows: Array = []


## Override: set [member client_scene] and the pilot's actions.
func _configure() -> void:
	pass


## Override: scratch settings so the run leaves the player's saved ones alone; keep the result alive.
func _prepare(_label: String) -> Variant:
	return null


## Override (server role): build the game's dedicated server under this node, add [param bots] bots and
## return its [DotNetManager]. [method make_server_config] gives a config that fits the bench.
func _boot_server(_bots_wanted: int, _data_dir: String) -> DotNetManager:
	return null


## Override: whether the client is playing and may be measured. Default: a live player and a synced clock.
func _client_playing() -> bool:
	var p = _client.get("player")
	var n = _client.get("net")
	return p != null and (not p.has_method(&"is_alive") or p.is_alive()) and n != null and n.clock.is_synced()


## A server config bound to loopback on the bench port with nothing optional running.
func make_server_config(data_dir: String) -> DotServerConfig:
	var config := DotServerConfig.new()
	config.hostname = "client bench"
	config.port = _port
	config.bind_address = "127.0.0.1"
	config.transport_mode = "dual"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % data_dir
	config.bans_path = "%s/bans.json" % data_dir
	config.audit_log_path = "%s/audit.jsonl" % data_dir
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""
	config.query_enabled = false
	config.enet_share_udp_port = false
	config.stdin_console_enabled = false
	config.log_level = "error"
	return config


func _ready() -> void:
	_configure()
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--role": _role = args[i + 1]
			"--bots": _bots = int(args[i + 1])
			"--delay": _delay = float(args[i + 1])
			"--jitter": _jitter = float(args[i + 1])
			"--seconds": _seconds = float(args[i + 1])
			"--burn": _burn_ms = float(args[i + 1])
			"--port": _port = int(args[i + 1])
			"--tick": tick_rate = int(args[i + 1])
	_play = "--play" in args
	DotLog.set_level(DotLog.Level.ERROR)
	_keepalive = _prepare("client_bench_" + _role)
	if _role == "server":
		_serve.call_deferred()
	else:
		_run.call_deferred()


func _serve() -> void:
	var data := "user://client_bench_server"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(data))
	var net := await _boot_server(_bots, data)
	if net == null:
		printerr("client_bench server: _boot_server returned no DotNetManager")
		get_tree().quit(1)
		return
	print("client_bench server: ready on %d with %d bots" % [_port, _bots])
	var last: Dictionary = net.perf_counters()
	var t0 := Time.get_ticks_usec()
	while true:
		await get_tree().create_timer(5.0).timeout
		var now: Dictionary = net.perf_counters()
		var secs := (Time.get_ticks_usec() - t0) / 1.0e6
		var ticks := maxi(1, int(now[&"server_ticks"]) - int(last[&"server_ticks"]))
		print("server: %.1f ticks/s (declared %d) | sim %.3f ms/tick | entities %d" % [
			ticks / secs, net.config.tick_rate,
			(int(now[&"server_sim_usec"]) - int(last[&"server_sim_usec"])) / 1000.0 / ticks, net.registry.all().size()])
		last = now
		t0 = Time.get_ticks_usec()


## Burns wall time at the top of every frame, before anything of the client's runs.
class Burner extends Node:
	var ms := 0.0

	func _process(_delta: float) -> void:
		var until := Time.get_ticks_usec() + int(ms * 1000.0)
		while Time.get_ticks_usec() < until:
			pass


## `--play`: runs, strafes in bursts, turns, jumps and fires, so prediction covers more than standing.
class Pilot extends Node:
	var forward := &""
	var strafes: Array[StringName] = []
	var jump := &""
	var fire := &""
	var _t := 0.0
	var _next := 0.0
	var _rng := RandomNumberGenerator.new()

	func _ready() -> void:
		_rng.seed = 20261017
		_press(forward)
		_press(fire)

	func _press(a: StringName) -> void:
		if a != &"" and InputMap.has_action(a):
			Input.action_press(a)

	func _process(delta: float) -> void:
		_t += delta
		var turn := InputEventMouseMotion.new()
		turn.relative = Vector2(sin(_t * 0.7) * 6.0, sin(_t * 1.3) * 1.5)
		Input.parse_input_event(turn)
		if _t < _next:
			return
		_next = _t + _rng.randf_range(0.3, 1.2)
		for a in strafes + [jump]:
			if a != &"" and InputMap.has_action(a):
				Input.action_release(a)
		var pick := _rng.randi_range(0, strafes.size() + 1)
		if pick < strafes.size():
			_press(strafes[pick])
		elif pick == strafes.size():
			_press(jump)
		elif fire != &"" and InputMap.has_action(fire):
			if _rng.randf() < 0.5:
				Input.action_release(fire)
			else:
				Input.action_press(fire)


func _run() -> void:
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
		get_tree().current_scene.scene_file_path, "--", "--role", "server", "--port", str(_port),
		"--bots", str(_bots), "--tick", str(tick_rate)])
	_server_pid = OS.create_process(OS.get_executable_path(), args)
	if _server_pid <= 0:
		return _fail("could not start the server")
	await get_tree().create_timer(6.0).timeout

	_relay = (load("res://addons/dot_net/testing/dot_net_udp_relay.gd") as GDScript).new()
	_relay.seed = 20261016
	_relay.up.configure(0.0, _delay, _jitter)
	_relay.down.configure(0.0, _delay, _jitter)
	var relayed: DotResult = _relay.start(0, "127.0.0.1", _port)
	if not relayed.ok:
		return _fail("relay: %s" % relayed.error)

	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Bench"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % _relay.port()
	add_child(link)
	link.connect_to_server("127.0.0.1:%d" % _port)
	var t := 0.0
	while not link.is_playing() and t < 30.0:
		await get_tree().create_timer(0.25).timeout
		t += 0.25
	if not link.is_playing():
		return _fail("never connected")

	var burner := Burner.new()
	burner.ms = _burn_ms
	burner.process_priority = -1000
	add_child(burner)
	_client = (load(client_scene) as PackedScene).instantiate()
	_client.set("mouse_capture_override", true)
	add_child(_client)
	t = 0.0
	while t < 40.0:
		await get_tree().create_timer(0.05).timeout
		t += 0.05
		if _client_playing():
			break
	var net = _client.get("net")
	if "--raw-input" in OS.get_cmdline_user_args() and net != null and "predict_wire_input" in net.config:
		net.config.predict_wire_input = false
	if _play:
		var pilot := Pilot.new()
		pilot.forward = forward_action
		pilot.strafes = strafe_actions
		pilot.jump = jump_action
		pilot.fire = fire_action
		pilot.process_priority = -999
		add_child(pilot)
	await get_tree().create_timer(3.0).timeout
	Engine.max_fps = 0
	await _measure()
	link.disconnect_from_server("done")
	_finish(0)


func _note_mismatch(last: Dictionary) -> void:
	if last.is_empty() or int(last["tick"]) == _mm_seen:
		return
	_mm_seen = int(last["tick"])
	var a: Variant = last["predicted"]
	var b: Variant = last["received"]
	var d := -1.0
	if a is Vector3 and b is Vector3:
		d = (a as Vector3).distance_to(b as Vector3)
	var p = _client.get("player")
	_mm_rows.append([_mm_seen, String(last["property"]), d, p != null and (not p.has_method(&"is_alive") or p.is_alive()), a, b])


func _print_mismatches() -> void:
	var buckets := {"<2cm": 0, "2-10cm": 0, "10cm-1m": 0, ">1m": 0, "other": 0}
	var by_prop := {}
	for r in _mm_rows:
		by_prop[r[1]] = int(by_prop.get(r[1], 0)) + 1
		var d: float = r[2]
		var k := "other" if d < 0.0 else ("<2cm" if d < 0.02 else ("2-10cm" if d < 0.1 else ("10cm-1m" if d < 1.0 else ">1m")))
		buckets[k] += 1
	print("  mismatches seen %d %s %s" % [_mm_rows.size(), by_prop, buckets])
	for r in _mm_rows.slice(0, 25):
		print("    tick %d %-20s %.4f alive %s pred %s recv %s" % r)


func _measure() -> void:
	var args := OS.get_cmdline_user_args()
	var net: DotNetManager = _client.get("net")
	if net == null:
		printerr("client_bench: the client scene has no `net`")
		return
	var frames := PackedFloat32Array()
	var lead_sum := 0.0
	var start := Time.get_ticks_usec()
	var last := start
	var perf0: Dictionary = net.perf_counters()
	var line_perf := perf0
	var line_mm: Dictionary = {}
	var next_line := start + 2000000
	while (Time.get_ticks_usec() - start) / 1.0e6 < _seconds:
		await get_tree().process_frame
		if "--timeline" in args and Time.get_ticks_usec() >= next_line:
			next_line += 2000000
			var pc: Dictionary = net.perf_counters()
			var mm: Dictionary = net.predictor.describe().get("mismatches", {})
			var diff := {}
			for k in mm:
				var dv := int(mm[k]) - int(line_mm.get(k, 0))
				if dv > 0:
					diff[k] = dv
			print("  t=%4.1f replays %d skipped %d ticks %d %s" % [(Time.get_ticks_usec() - start) / 1e6,
				int(pc[&"reconciles"]) - int(line_perf[&"reconciles"]) - (int(pc[&"skipped"]) - int(line_perf[&"skipped"])),
				int(pc[&"skipped"]) - int(line_perf[&"skipped"]), int(pc[&"replayed_ticks"]) - int(line_perf[&"replayed_ticks"]), diff])
			line_perf = pc
			line_mm = mm
		if "--mismatches" in args:
			_note_mismatch(net.predictor.describe().get("last_mismatch", {}))
		var now := Time.get_ticks_usec()
		frames.append((now - last) / 1000.0)
		last = now
		lead_sum += float(net.clock.describe().get("lead", 0.0))
	var n := frames.size()
	var sorted := frames.duplicate()
	sorted.sort()
	var elapsed := (Time.get_ticks_usec() - start) / 1.0e6
	if "--mismatches" in args:
		_print_mismatches()
	print("client_bench: delay %d ms each way, burn %.1f ms, %d bots, %.0f s" % [roundi(_delay), _burn_ms, _bots, elapsed])
	print("  fps %.1f | frame p50 %.1f p95 %.1f max %.1f ms" % [n / elapsed, sorted[n / 2], sorted[int(n * 0.95)], sorted[n - 1]])
	var p1: Dictionary = net.perf_counters()
	var d := func(k: StringName) -> float: return float(int(p1[k]) - int(perf0[k]))
	print("  net: snapshots %.1f/frame | replays %.0f (skipped %.0f of %.0f reconciles) | replayed %.2f ticks/frame" % [
		d.call(&"snapshots") / n, d.call(&"reconciles") - d.call(&"skipped"), d.call(&"skipped"),
		d.call(&"reconciles"), d.call(&"replayed_ticks") / n])
	print("  predictor %s | predicted identities %d" % [net.predictor.describe(), net.registry.predicted().size()])
	var clock: Dictionary = net.clock.describe()
	print("  input lead %.1f ticks avg | clock rtt %s ms, jitter %s, snaps %s, catch-ups %s" % [lead_sum / n,
		clock.get("rtt_ms"), clock.get("jitter_ms"), clock.get("snaps"), clock.get("catch_ups")])


func _fail(why: String) -> void:
	printerr("client_bench: ", why)
	_finish(1)


func _finish(code: int) -> void:
	if _relay != null:
		_relay.stop()
	if _server_pid > 0:
		var _k := OS.kill(_server_pid)
	get_tree().quit(code)
