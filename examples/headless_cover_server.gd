extends Node

## DotCoverServer: a subclass's hooks reach the config, the server runs, _boot runs after it.

const CHECKS := 7

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


class Cover:
	extends DotCoverServer

	var booted := false
	var state_at_boot := -1
	var dir_at_boot := ""
	var asked: Array[String] = []

	func _default_port() -> int:
		return 27991

	func _max_players() -> int:
		asked.append("max")
		return 6

	func _hostname() -> String:
		asked.append("host")
		return "selftest cover"

	func _boot(dir: String) -> void:
		booted = true
		dir_at_boot = dir
		state_at_boot = server.state


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what)


func _run() -> void:
	print("dot-game: cover server")
	var c := Cover.new()
	add_child(c)
	for _i in 120:
		await get_tree().process_frame
		if c.booted:
			break
	_check(c.booted, "_boot ran")
	_check(c.server != null and c.server.name == &"Server", "the server is named Server")
	_check(c.state_at_boot == DotServer.State.RUNNING, "_boot runs once the server is RUNNING")
	_check(c.port == 27991 and c.server.config.port == 27991, "the default port is the hook's")
	# DotServer applies its cvars over the config once running, so the hooks are checked by being asked.
	_check(c.asked.has("max") and c.asked.has("host"), "the max_players and hostname hooks were asked")
	_check(c.server.state == DotServer.State.RUNNING, "the server is running")
	_check(c.server.config.admins_path.begins_with(c.dir_at_boot), "state files live in the scratch dir")
	c.queue_free()

	if _passed + _failed != CHECKS:
		_failed += 1
		_failures.append("ran %d checks, expected %d" % [_passed + _failed - 1, CHECKS])
	for f in _failures:
		print("FAIL: ", f)
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
