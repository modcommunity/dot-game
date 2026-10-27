extends Node

## DotGameLockedContent: no lock does nothing, a lock is handed to ensure_locked behind the gate, a failure releases the gate, the switch.

const Stub := preload("res://examples/fixtures/locked_cloud_stub.gd")
const DIR := "user://locked_content_test"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


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
	print("dot-game: locked content")
	DotGameLockedContent.lock_override = ""
	var gate := DotLoadGate.new()
	add_child(gate)
	gate.hold(&"other", "x")
	var cloud: Node = Stub.new()
	add_child(cloud)

	var none: DotResult = await DotGameLockedContent.run(cloud, gate)
	_check(none.ok and none.value == null, "no lock file: nothing to do")
	_check(cloud.calls.is_empty() and not gate.is_holding(DotGameLockedContent.REASON), "no lock file: dot-cloud not called, gate untouched")

	DotPaths.write_bytes(DIR + "/content.lock.json", '{"format":1,"packs":[]}'.to_utf8_buffer())
	DotGameLockedContent.lock_override = DIR + "/content.lock.json"
	_check(DotGameLockedContent.find_lock() == DIR + "/content.lock.json", "an override names the lock")
	cloud.gate = gate
	var got: DotResult = await DotGameLockedContent.run(cloud, gate)
	_check(cloud.held_during, "the gate is held while it mounts")
	_check(got.ok and got.value["mounted"] == ["me/pack@1.0.0"], "the report is returned")
	_check(cloud.calls.size() == 1 and cloud.calls[0]["lock"] == DIR + "/content.lock.json", "ensure_locked got the lock path")
	_check(not gate.is_holding(DotGameLockedContent.REASON), "the gate is released afterwards")

	cloud.fail = true
	got = await DotGameLockedContent.run(cloud, gate)
	_check(not got.ok and not gate.is_holding(DotGameLockedContent.REASON), "a failure is returned and does not keep the gate shut")

	got = await DotGameLockedContent.run(null, gate)
	_check(got.ok and got.value == null, "a lock with no cloud client is skipped")

	DotGameLockedContent.lock_override = DIR + "/missing.json"
	_check(DotGameLockedContent.find_lock() == "", "a named lock that is not there is no lock")
	_check(not DotGameLockedContent.disabled_by_cmdline(), "on by default")

	DotGameLockedContent.lock_override = ""
	DotPaths.remove_tree(DIR)
	print("dot-game locked content: %d passed, %d failed" % [_passed, _failed])
	for f in _failures:
		print("FAIL: ", f)
	get_tree().quit(1 if _failed > 0 else 0)
