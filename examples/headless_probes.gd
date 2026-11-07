extends Node

## DotLoadProbe and DotAudioProbe: the hooks reach the loop, the gate/body columns and the exit are right.

const CHECKS := 12

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


class Gate:
	extends RefCounted

	var open_at := 3
	var ticks := 0

	func is_open() -> bool:
		return ticks >= open_at


class Client:
	extends Node

	var gate := Gate.new()
	var player: Node3D = null

	func _ready() -> void:
		player = Node3D.new()
		add_child(player)

	func _process(_delta: float) -> void:
		gate.ticks += 1
		if gate.is_open():
			player.position.x += 1.0


class Load:
	extends DotLoadProbe

	var lines: Array[String] = []
	var shots: Array[int] = []
	var started := false
	var finished := 0

	func _default_frames() -> int:
		return 6

	func _make_client() -> Node:
		return Client.new()

	func _started() -> void:
		started = true

	func _finish() -> void:
		finished += 1

	func report(line: String) -> void:
		lines.append(line)

	func _save_shot() -> void:
		shots.append(frame)


class Cues:
	extends RefCounted

	var ok := true


class Sink:
	extends RefCounted

	var bank := {&"a": null, &"b": null}


class Manager:
	extends RefCounted

	var sink := Sink.new()
	var played: Array[StringName] = []

	func play_at(id: StringName, _at: Vector3) -> int:
		played.append(id)
		return 0 if id == &"mute" else 7


class Audio:
	extends Node

	var manager := Manager.new()

	func setup() -> Cues:
		return Cues.new()


class Sound:
	extends DotAudioProbe

	var lines: Array[String] = []
	var exit := -1
	var after_called := false
	var cues: Array[StringName] = [&"a", &"b"]
	var length := 0.5

	func _make_audio() -> Node:
		var a := Audio.new()
		a.manager.sink.bank = {&"a": _wave(length), &"b": _wave(length), &"mute": _wave(length)}
		return a

	func _wave(seconds: float) -> AudioStream:
		var w := AudioStreamWAV.new()
		w.format = AudioStreamWAV.FORMAT_8_BITS
		w.mix_rate = 8000
		var bytes := PackedByteArray()
		bytes.resize(int(8000 * seconds))
		w.data = bytes
		return w

	func _cue_ids() -> Array[StringName]:
		return cues

	func _after_cues(_sink: Object) -> bool:
		after_called = true
		return true

	func report(line: String) -> void:
		lines.append(line)

	func _finish(passed: bool) -> void:
		exit = 0 if passed else 1


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
	print("dot-game: probes")
	var lp := Load.new()
	add_child(lp)
	for _i in 12:
		await get_tree().process_frame
		if lp.frame >= 6:
			break
	_check(lp.started and lp.client != null, "the client is built and in the tree before frame 1")
	_check(lp.frames == 6 and lp.lines.size() >= 6, "the default frame count is the hook's, one line a frame")
	_check(lp.lines.size() > 0 and lp.lines[0].contains("covered=true") and lp.lines[0].contains("gate=true"), "an unopened gate covers")
	_check(lp.lines.size() > 3 and lp.lines[3].contains("covered=false"), "the gate lifting uncovers")
	_check(lp.lines.size() > 4 and lp.lines[4].contains("moved=1.000"), "a body that moves reports the distance")
	_check(lp.lines.size() > 0 and lp.lines[0].contains("player=true") and lp.lines[0].contains("hud=false"), "the default columns")
	_check(lp.shots == [4], "frame 4, which is also the frame the gate lifts, is shot once")
	_check(lp.finished >= 1, "the probe finishes through _finish once _done says so")
	lp.queue_free()

	var sp := Sound.new()
	add_child(sp)
	for _i in 30:
		await get_tree().process_frame
		if sp.exit >= 0:
			break
	_check(sp.exit == 0 and sp.after_called, "every cue baked and voiced passes, then the game's checks run")
	_check(sp.lines.size() == 3 and sp.lines[1].contains("a baked=") and sp.lines[1].contains("voice=7"), "one line a cue")
	sp.queue_free()

	var bad := Sound.new()
	bad.cues = [&"a", &"mute"]
	add_child(bad)
	for _i in 30:
		await get_tree().process_frame
		if bad.exit >= 0:
			break
	_check(bad.exit == 1, "a cue that got no voice fails the probe")
	var short := Sound.new()
	short.length = 0.01
	add_child(short)
	for _i in 30:
		await get_tree().process_frame
		if short.exit >= 0:
			break
	_check(short.exit == 1, "a cue shorter than the minimum fails the probe")
	bad.queue_free()
	short.queue_free()

	if _passed + _failed != CHECKS:
		_failed += 1
		_failures.append("ran %d checks, expected %d" % [_passed + _failed - 1, CHECKS])
	for f in _failures:
		print("FAIL: ", f)
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
