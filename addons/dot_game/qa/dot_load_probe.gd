class_name DotLoadProbe
extends Node

## Boots a game's solo client and prints, per rendered frame, what a player would see: whether the
## map, the player and the camera exist, where the body is, and whether the load gate still covers
## the screen. A body that moves while uncovered, or a frame with no player, is the glitch. Tool-only
## (a pack never calls it, so no API level). Ten games had their own copy; they differed in the
## client class, how it is set up, which node holds the gate, and the columns after `covered=`.
## A game's tools/load_probe.gd extends this and overrides those hooks; tools/load_probe.tscn is a
## one-script scene. Needs xvfb-run, never --headless:
## [codeblock]
## xvfb-run -a godot --path . res://tools/load_probe.tscn -- [--frames=90] [--shot=N]
## [/codeblock]

## The client being probed.
var client: Node = null
var frames := 0
var shot := -1
var frame := 0

var _last := Vector3.ZERO
var _was_covered := true


## The frame count when --frames is not given.
func _default_frames() -> int:
	return 90


## Build the client, set it up (offline, staged load...) and return it, not yet in the tree.
func _make_client() -> Node:
	return null


## The load gate, or null. Default: the client's `gate`.
func _gate() -> Object:
	return client.get("gate")


## True while the gate still covers the screen.
func _covered(gate: Object) -> bool:
	return gate != null and not gate.is_open()


## The body being watched, or null. Default: the client's `player`.
func _body() -> Node3D:
	return client.get("player") as Node3D


## The columns between `covered=` and `pos=`.
func _columns(gate: Object) -> String:
	var cam: Object = client.get("camera")
	return "player=%s cam=%s hud=%s" % [_body() != null, cam != null and cam.is_inside_tree(), client.get("hud") != null]


## The whole line for a frame; override to change the layout (`gate=` first, `moved=` last by default).
func _line(gate: Object, covered: bool, pos: Vector3, moved: float) -> String:
	return "frame %3d gate=%s covered=%s %s pos=%s moved=%.3f" % [frame, gate != null, covered, _columns(gate), pos, moved]


## Whether to save a screenshot on this frame. Default: the --shot frame, else frame 4 and the frame the gate lifts.
func _shot_wanted(lifted: bool) -> bool:
	return frame == shot or (shot < 0 and (frame == 4 or lifted))


## Where a screenshot of [member frame] goes.
func _shot_path() -> String:
	return "res://screenshots/load_probe_%d.png" % frame


## Called once the client exists in the tree, before the first frame.
func _started() -> void:
	pass


## Whether the probe stops after this frame; [member frames] by default.
func _done(_lifted: bool) -> bool:
	return frame >= frames


## What the probe ends with, once [method _done] says so.
func _finish() -> void:
	get_tree().quit(0)


## Where a line goes.
func report(line: String) -> void:
	print(line)


func _save_shot() -> void:
	var path := ProjectSettings.globalize_path(_shot_path())
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	get_viewport().get_texture().get_image().save_png(path)


func _ready() -> void:
	frames = _default_frames()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--frames="):
			frames = int(a.get_slice("=", 1))
		if a.begins_with("--shot="):
			shot = int(a.get_slice("=", 1))
	client = _make_client()
	add_child(client)
	_started()


func _process(_delta: float) -> void:
	if client == null:
		return
	frame += 1
	var gate := _gate()
	var covered := _covered(gate)
	var body := _body()
	var pos := body.global_position if body != null else Vector3.ZERO
	var moved := pos.distance_to(_last)
	_last = pos
	report(_line(gate, covered, pos, moved))
	var lifted := _was_covered and not covered
	_was_covered = covered
	if _shot_wanted(lifted):
		_save_shot()
	if _done(lifted):
		_finish()
