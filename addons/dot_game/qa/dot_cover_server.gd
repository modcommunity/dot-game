class_name DotCoverServer
extends Node

## A headless dedicated server for a game's tools/render_cover.gd to join, left running:
## `godot --headless --path . res://tools/cover_server.tscn -- --port 27399`. Tool-only (a pack never
## calls it, so no API level). Seven games each had their own copy of this boot; the DotServer
## and its config are the same in all of them, so a game's tools/cover_server.gd extends this and
## overrides only the hooks. Name the scene's root CoverServer, like render_cover's, so the RPC path
## to "Server" is the same on both sides.

## The DotServer this booted, named "Server".
var server: DotServer = null
## The port serving; --port wins over [method _default_port].
var port := 0


## The port when --port is not given.
func _default_port() -> int:
	return 27399


## The server's max_players; 0 leaves DotServerConfig's default.
func _max_players() -> int:
	return 0


func _hostname() -> String:
	return "cover test"


## The game's half of the boot, awaited once the server is RUNNING: build the world, add the game,
## load the module. [param dir] is this run's scratch directory (absolute, empty). Print the line
## a tool waits for; the default prints none.
func _boot(_dir: String) -> void:
	pass


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


## The value after [param name] on the command line past `--`, or [param fallback].
func arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback


## The common game-module boot: add the descriptor [code]game_descriptor()[/code] of the script at
## [param module_path] to the game list, change to it, load the module. Returns the two results
## as {"game": DotResult, "module": DotResult}.
func boot_descriptor_module(module_path: String) -> Dictionary:
	var descriptor: DotGameDescriptor = (load(module_path) as GDScript).call("game_descriptor")
	server.games.add_game(descriptor)
	var changed: DotResult = await server.games.change_game(descriptor.game_id, "boot")
	var loaded: DotResult = await server.modules.load_module(module_path)
	print("cover_server: game=%s module=%s port=%d" % [changed.ok, loaded.ok, port])
	return {"game": changed, "module": loaded}


func _run() -> void:
	var dir := ProjectSettings.globalize_path("user://cover_server")
	DotPaths.remove_tree(dir)
	DirAccess.make_dir_recursive_absolute(dir)

	port = int(arg("--port", str(_default_port())))
	var config := DotServerConfig.new()
	config.autoexec_config = ""
	config.hostname = _hostname()
	config.hibernate_when_empty = false
	config.rcon_password = ""
	config.query_enabled = false
	config.port = port
	if _max_players() > 0:
		config.max_players = _max_players()
	config.admins_path = "%s/admins.json" % dir
	config.bans_path = "%s/bans.json" % dir
	config.audit_log_path = "%s/audit.jsonl" % dir
	config.stdin_console_enabled = false

	server = DotServer.new()
	server.name = "Server"
	server.config = config
	add_child(server)
	for _i in 60:
		await get_tree().process_frame
		if server.state == DotServer.State.RUNNING:
			break
	await _boot(dir)
