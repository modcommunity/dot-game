class_name DotGameNetchaosServer
extends Node

## The dedicated server of `tools/netchaos.sh` (this addon's tools/): dual-stack on all interfaces,
## one `TRUTH` line a second, and on the `stop` file in `--data` it writes `truth.json` (every
## player's final position, the net totals, the worst frame) and quits. A game's
## `tools/netchaos_server.gd` extends this: [method _boot_world] builds its world with
## [method boot_server] and loads its module, [method _players] lists the seated players.
##
## godot --headless --path . res://tools/netchaos_server.tscn -- --port 27210 --data /tmp/x [--map ID]

var port := 27210
var data_dir := ""
var map_id := ""
var solid := ""
## Set by [method _boot_world]: the loaded game module, which exposes `net` (a DotNetManager).
var module: Object = null
var server: DotServer = null

var _next_truth := 1.0
var _clock := 0.0
var _worst_frame := 0.0
var _frames := 0
var _snap := {}
var _keepalive: Variant = null


## Override: nothing needed before the arguments are read.
func _configure() -> void:
	pass


## Override: keep what it returns alive (the game's scratch settings).
func _prepare(_label: String) -> Variant:
	return null


## Override: build the world, call [method boot_server], load the module into [member module],
## apply [member solid] to mp_solidplayers if set, and start the game. Print nothing; [method _ready]
## announces readiness.
func _boot_world() -> void:
	pass


## Override: the seated players, each with `display_name`, `player_id`, `controller.state.position`
## and `is_alive()`.
func _players() -> Array:
	return []


## Override: whether the net replicates the player as alive, or null when unknown.
func _net_alive(_p: Object) -> Variant:
	return null


func _ready() -> void:
	_configure()
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--port": port = int(args[i + 1])
			"--data": data_dir = args[i + 1]
			"--map": map_id = args[i + 1]
			"--solid": solid = args[i + 1]
	name = "Netchaos"  # RPC paths must match the client's root name
	DotLog.set_level(DotLog.Level.WARN)
	_keepalive = _prepare("netchaos_server")
	_boot.call_deferred()


func _boot() -> void:
	DirAccess.make_dir_recursive_absolute(data_dir)
	await _boot_world()
	if module == null:
		printerr("netchaos server: the game did not load its module")
		get_tree().quit(1)
		return
	print("netchaos server: ready on udp/%d" % port)


## A booted dual-stack [DotServer] on all interfaces with no console, rcon, query or hibernation.
## [param startup_config] is a path to a cfg file (a game that needs `sv_tickrate`), or empty.
func boot_server(startup_config := "") -> DotResult:
	var config := DotServerConfig.new()
	config.hostname = "netchaos"
	config.port = port
	config.bind_address = "*"
	config.transport_mode = "dual"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % data_dir
	config.bans_path = "%s/bans.json" % data_dir
	config.audit_log_path = "%s/audit.jsonl" % data_dir
	config.hibernate_when_empty = false
	config.startup_config = startup_config
	config.autoexec_config = ""
	config.query_enabled = false
	config.enet_share_udp_port = false
	config.stdin_console_enabled = false
	config.log_level = "warn"
	server = DotServer.new()
	server.name = "Server"
	server.config = config
	server.config_file = ""
	server.auto_boot = false
	add_child(server)
	var booted: DotResult = await server.boot()
	if not booted.ok:
		printerr("netchaos server: ", booted.error)
	return booted


func _truth() -> Dictionary:
	var players := {}
	for p in _players():
		var pos: Vector3 = p.controller.state.position
		players[p.display_name] = [snappedf(pos.x, 0.001), snappedf(pos.y, 0.001), snappedf(pos.z, 0.001), p.is_alive(), _net_alive(p)]
	return {"unix": Time.get_unix_time_from_system(), "players": players}


func _process(delta: float) -> void:
	if module == null:
		return
	_clock += delta
	_frames += 1
	_worst_frame = maxf(_worst_frame, delta * 1000.0)
	if _snap.is_empty() and FileAccess.file_exists("%s/truth_at" % data_dir):
		var at := FileAccess.get_file_as_string("%s/truth_at" % data_dir).to_float()
		if at > 0.0 and Time.get_unix_time_from_system() >= at:
			_snap = _capture()
	if FileAccess.file_exists("%s/stop" % data_dir):
		_finish()
		return
	if _clock >= _next_truth:
		_next_truth += 1.0
		print("TRUTH ", JSON.stringify(_truth()))


## The settled world, taken at `truth_at` while the clients are still connected.
func _capture() -> Dictionary:
	var out := _truth()
	var net_d: Dictionary = module.net.describe() if module.get("net") != null else {}
	out["server"] = {"seconds": _clock, "frames": _frames, "worst_frame_ms": _worst_frame,
		"peers": net_d.get("peers", -1), "stats": net_d.get("stats", {}), "solid": solid}
	return out


func _finish() -> void:
	var out := _snap if not _snap.is_empty() else _capture()
	out["server"]["worst_frame_ms"] = _worst_frame
	var f := FileAccess.open("%s/truth.json" % data_dir, FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	set_process(false)
	print("netchaos server: stopped")
	get_tree().quit()
