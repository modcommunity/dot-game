class_name DotAudioProbe
extends Node

## Under xvfb-run (never --headless, whose audio driver is Dummy): does the game make a noise?
## Bakes the game's audio bank as a client does, plays each cue three metres in front of the
## listener, and fails if one baked to nothing or got no voice. Tool-only (a pack never calls it,
## so no API level). Five games had their own copy of this loop; they differed in the audio class,
## the cue ids, the shortest length that counts, and what they checked after the cues. A game's
## tools/audio_probe.gd extends this and overrides those; tools/audio_probe.tscn is a one-script
## scene. dot-audio is duck-typed, not required: the audio node needs `setup()` returning a
## DotResult-like with `ok`, and a `manager` with `sink`, `play_at(id, pos)` and, on the sink, `bank`.
## [codeblock]
## xvfb-run -a godot --path . res://tools/audio_probe.tscn
## [/codeblock]

var audio: Node = null
var ok := true


## Build the game's audio node (not yet in the tree).
func _make_audio() -> Node:
	return null


## The cue ids to play.
func _cue_ids() -> Array[StringName]:
	return []


## The shortest baked length, in seconds, that counts as a sound.
func _min_length() -> float:
	return 0.05


## Where each cue is played, relative to the listener.
func _cue_position() -> Vector3:
	return Vector3(0, 0, -3)


## The game's own checks once the cues have played; return false to fail. Awaited.
func _after_cues(_sink: Object) -> bool:
	return true


## Where a line goes.
func report(line: String) -> void:
	print(line)


## What the probe ends with; the exit code is 0 for a pass, 1 for a failure.
func _finish(passed: bool) -> void:
	get_tree().quit(0 if passed else 1)


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	audio = _make_audio()
	add_child(audio)
	var ready_now: Variant = audio.call("setup")
	var manager: Object = audio.get("manager")
	var sink: Object = manager.get("sink") if manager != null else null
	ok = bool(ready_now.get("ok")) and sink != null and "bank" in sink
	report("driver=%s sink=%s" % [AudioServer.get_driver_name(), sink != null])
	if not ok:
		_finish(false)
		return

	for id in _cue_ids():
		var stream: Variant = (sink.get("bank") as Dictionary).get(id)
		var length := (stream as AudioStream).get_length() if stream is AudioStream else 0.0
		var voice := int(manager.call("play_at", id, _cue_position()))
		await get_tree().process_frame
		report("%s baked=%.2f s voice=%d" % [id, length, voice])
		ok = ok and length > _min_length() and voice != 0

	ok = (await _after_cues(sink)) and ok
	_finish(ok)
