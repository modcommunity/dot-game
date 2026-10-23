extends Node

## Per-map settings through dot-game: a game declares keys, report_map and map_changed apply them, the next map restores them.
##
## [codeblock]
## godot --headless --path . res://examples/headless_mapcfg.tscn
## [/codeblock]
##
## The cvars start away from the files' values, so "got them" cannot be a default showing through.

const CHECKS := 16
const FIXTURE_CFG := "res://examples/fixtures/mapcfg"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


class SurfModule extends DotGameModule:
	func _module_name() -> String:
		return "test-game"

	func _map_config_game() -> String:
		return "test-game"

	func _map_config_keys() -> Dictionary:
		return {"test_air": {"type": "float", "min": 0.0, "max": 1000.0}, "test_bad_type": {"type": "int"}, "test_default": {"type": "int"}}

	func _map_config_defaults() -> Dictionary:
		return {"test_default": 7}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-game: per-map settings")
	if not ResourceLoader.exists(DotGameMapConfig.SCRIPT_PATH):
		print("SKIPPED: dot-map is not linked into this project (addons/dot_map)")
		get_tree().quit(0)
		return

	DotAddonConfig.config_root = ProjectSettings.globalize_path(FIXTURE_CFG)
	var console := DotConsole.new()
	add_child(console)
	console.cvar("test_air", "90", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("test_other", "5", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("test_bad_type", "3", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("test_default", "1", "", DotConVar.FLAG_ARCHIVE)
	var air := console.find_cvar("test_air")

	print("server: DotGameModule.report_map")
	var module := SurfModule.new()
	module.console = console
	add_child(module)
	module.report_map("dm_plain")
	_check(air.get_float() == 90.0, "a map with no file leaves the cvar alone")
	_check(console.find_cvar("test_default").get_int() == 7, "the declared default applies to a map without a file")
	module.report_map("surf_beginner")
	_check(air.get_float() == 150.0, "a wildcard file sets test_air")
	_check(console.find_cvar("test_other").get_int() == 5, "a key outside the whitelist is untouched")
	_check(console.find_cvar("test_bad_type").get_int() == 3, "a value of the wrong type is rejected")
	_check(console.find_cvar("test_default").get_int() == 7, "the default stays under a file that does not name it")
	module.report_map("surf_special")
	_check(air.get_float() == 200.0, "an exact file beats the wildcard")
	module.report_map("dm_plain")
	_check(air.get_float() == 90.0, "the next map has the previous value back")
	module.report_map("surf_x")
	_check(air.get_float() == 150.0, "another surf map gets the wildcard again")
	module.report_map("dm_plain")
	module._teardown()
	_check(air.get_float() == 90.0 and module.map_config == null, "teardown restores and drops the config")

	print("client: DotGameClient.map_changed")
	var client := DotGameClient.new()
	client.map_config_keys = {"test_air": {"type": "float"}}
	client.map_config_game = "test-game"
	client.map_config_get_fn = func(k: String) -> Variant: return console.get_string(k)
	client.map_config_set_fn = func(k: String, v: Variant) -> bool: return console.set_cvar(k, str(v)).ok
	client.map_changed("surf_a")
	_check(air.get_float() == 150.0, "the client applies the map's file")
	client.map_changed("dm_plain")
	_check(air.get_float() == 90.0, "the client restores on the next map")
	client.map_changed("surf_a")
	client.restore_map_config()
	_check(air.get_float() == 90.0, "restore_map_config (the disconnect path) puts the settings back without leaving the tree")

	print("helper: for_console")
	var cfg := DotGameMapConfig.for_console("test-game", console, {"test_air": {"type": "float"}})
	var got := cfg.apply("surf_b")
	_check(got.size() == 1 and air.get_float() == 150.0, "for_console applies (%s)" % [got])
	_check(cfg.restore() == 1 and air.get_float() == 90.0, "restore puts it back")
	_check(DotGameMapConfig.new().apply("surf_b").is_empty(), "an undeclared game applies nothing")

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	module.free()
	client.free()
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
