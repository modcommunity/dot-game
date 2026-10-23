extends Node

## DotGameMapScripts: the script.* events of a dot-map world handled, refused when forged, restored on a map change.
##
## [codeblock]
## godot --headless --path . res://examples/headless_mapscripts.tscn
## [/codeblock]

const CHECKS := 21
const FIXTURE_CFG := "res://examples/fixtures/mapcfg"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


class ScriptModule extends DotGameModule:
	func _module_name() -> String:
		return "test-game"

	func _map_config_game() -> String:
		return "test-game"


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-game: map script events")
	if not ResourceLoader.exists(DotGameMapScripts.SCRIPT_PATH):
		print("SKIPPED: dot-map is not linked into this project (addons/dot_map)")
		get_tree().quit(0)
		return

	DotAddonConfig.config_root = ProjectSettings.globalize_path(FIXTURE_CFG)
	var console := DotConsole.new()
	add_child(console)
	console.cvar("sv_runspeed", "300", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("sv_walkspeed", "0.5", "", DotConVar.FLAG_ARCHIVE)
	var run := console.find_cvar("sv_runspeed")
	var walk := console.find_cvar("sv_walkspeed")

	var s := DotGameMapScripts.new()
	s.console = console
	_check(not s.handle("effect.fire", {}), "a non-script event is not this handler's")
	_check(s.handle("script.set_player_speed", {"kind": "run", "value": 250.0}) and run.get_float() == 250.0, "run speed is set through sv_runspeed")
	_check(s.handle("script.set_player_speed", {"kind": "walk", "value": 125.0}) and absf(walk.get_float() - 0.5) < 0.001, "walk speed is a fraction of the run speed")
	_check(s.handle("script.set_player_speed", {"kind": "run", "value": 5000.0}) and run.get_float() == 1000.0, "a speed in dot-map's range but above the game's cap is clamped")
	s.restore()
	_check(run.get_float() == 300.0 and absf(walk.get_float() - 0.5) < 0.001, "restore puts the speeds back")

	print("forged")
	_check(not s.handle("script.set_player_speed", {"kind": "run", "value": 99999.0}) and run.get_float() == 300.0, "an out-of-range speed is refused")
	_check(not s.handle("script.set_player_speed", {"kind": "fly", "value": 100.0}), "an unknown speed kind is refused")
	_check(not s.handle("script.set_player_speed", {"kind": "run"}), "a missing argument is refused")
	_check(not s.handle("script.set_player_speed", {"kind": "run", "value": 100.0, "extra": 1}), "an extra argument is refused")
	_check(not s.handle("script.exec", {"cmd": "quit"}), "an operation outside the table is refused")
	_check(not s.handle("script.set_player_speed", {"kind": "run", "value": "fast"}), "a non-numeric speed is refused")
	_check(run.get_float() == 300.0, "no forged event changed a cvar")

	print("hooks")
	var kills := [0]
	var cleaned := [-1.0]
	s.kill_fn = func() -> int:
		kills[0] += 1
		return 3
	s.cleanup_fn = func(d: float) -> void: cleaned[0] = d
	_check(s.handle("script.kill_players", {}) and kills[0] == 1, "kill_players calls kill_fn")
	_check(s.handle("script.cleanup_map", {"delay": 5.0}) and cleaned[0] == 5.0, "cleanup_map calls cleanup_fn with the delay")
	_check(not s.handle("script.cleanup_map", {"delay": 600.0}) and cleaned[0] == 5.0, "an out-of-range delay is refused")
	var plain := DotGameMapScripts.new()
	_check(plain.handle("script.kill_players", {}) and plain.handle("script.cleanup_map", {"delay": 0.0}), "the defaults log and succeed without hooks")
	s.enabled = false
	_check(not s.handle("script.kill_players", {}) and kills[0] == 1, "the master switch drops every event")
	s.enabled = true

	print("per-map switches")
	var module := ScriptModule.new()
	module.console = console
	module.map_scripts = s
	add_child(module)
	module.report_map("quiet_map")
	_check(not s.handle("script.kill_players", {}) and kills[0] == 1, "a map's yml turns kill_players off")
	_check(s.handle("script.cleanup_map", {"delay": 1.0}), "the other operations stay on")
	s.handle("script.set_player_speed", {"kind": "run", "value": 200.0})
	module.report_map("other_map")
	_check(s.handle("script.kill_players", {}) and kills[0] == 2, "the next map has the switch back")
	_check(run.get_float() == 300.0, "a map change restores the script's speed")
	module._teardown()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	module.free()
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what)
		print("  FAIL  %s" % what)
