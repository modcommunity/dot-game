extends Node

## State and checks every section of game_selftest.gd shares.

const TestGame := preload("../fixtures/test_game.gd")
const TestModule := preload("../fixtures/test_module.gd")
const TestHookServices := preload("../fixtures/test_hook_services.gd")
const TestLink := preload("../fixtures/test_link.gd")
const MODULE_PATH := "res://examples/fixtures/test_module.gd"

const ClientSettings := preload("../fixtures/test_client_settings.gd")
const ClientChat := preload("../fixtures/test_chat_box.gd")
const CONSOLE_KIT_FIXTURE := "res://examples/fixtures/test_console_kit.gd"
const PORT := 27919

var _entered := 0
var _completed := 0
var _passed := 0
var _failed := 0
var _failures: Array[String] = []

var _server: DotServer = null
var _game: Node = null
var _module: DotGameModule = null

## userid -> session, for the roster's substituted lookup.
var _sessions: Dictionary = {}


func _make_game() -> void:
	_game = TestGame.new()
	_game.name = "TestGame"
	add_child(_game)


func _load_module() -> DotResult:
	return await _server.modules.load_module(MODULE_PATH)


func _unload_module() -> void:
	if _server != null and _server.modules != null:
		if _server.modules.has_module("testgame"):
			_server.modules.unload_module("testgame")


func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(ok: bool, label: String, detail: String = "") -> bool:
	if ok:
		_passed += 1
		print("  ok    %s" % label)
	else:
		_failed += 1
		print("  FAIL  %s%s" % [label, "" if detail == "" else "  -- " + detail])
		_failures.append(label)
	return ok


func _teardown() -> void:
	_unload_module()
	if _server != null:
		_server.shutdown("test over")
