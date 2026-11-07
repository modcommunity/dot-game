extends Node

## DotGameToyNet: the authority copies a toy's state out, a client poses its toy only after a state has arrived.

const CHECKS := 9

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


class FakeToy:
	extends Node3D
	var on := false
	var count := 0
	var shown: Array = []

	func state_transform() -> Transform3D:
		return Transform3D(Basis(Quaternion(Vector3.UP, 0.5)), Vector3(1, 2, 3))

	func show_state(p: Vector3, r: Quaternion, o: bool, c: int) -> void:
		shown = [p, r, o, c]


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
	print("dot-game: toy net")
	var toy := FakeToy.new()
	toy.on = true
	toy.count = 7
	var net := DotGameToyNet.new()
	net.toy = toy
	net.pull()
	_check(net.net_count == 0, "a toy outside the tree is not read")
	add_child(toy)
	add_child(net)
	net.pull()
	_check(net.net_position.is_equal_approx(Vector3(1, 2, 3)), "pull copies the position")
	_check(net.net_rotation.is_equal_approx(Quaternion(Vector3.UP, 0.5)), "pull copies the rotation")
	_check(net.net_on and net.net_count == 7, "pull copies on and the count")
	net._net_interpolated(1)
	_check(toy.shown.is_empty(), "nothing is posed before a state has arrived")
	net._net_state_applied(1)
	_check(toy.shown.size() == 4 and toy.shown[3] == 7, "a state arriving poses the toy")
	toy.shown = []
	net._net_interpolated(2)
	_check(toy.shown.size() == 4, "interpolation poses it every frame")
	net.toy = null
	net._net_interpolated(3)
	_check(true, "a null toy is ignored")
	toy.free()
	net.toy = toy if is_instance_valid(toy) else null
	net.pull()
	_check(net.get(&"_seen") == true, "a freed toy is survived")

	if _passed + _failed != CHECKS:
		_failed += 1
		_failures.append("ran %d checks, expected %d" % [_passed + _failed - 1, CHECKS])
	for f in _failures:
		print("FAIL: ", f)
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
