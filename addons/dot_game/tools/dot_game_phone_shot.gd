extends SceneTree

## Renders a game's real client at phone size with touch on and writes one PNG. Run through dot_game_phone_shot.sh.
## `--scene=res://x.tscn` (default: the project's main scene), `--touch`, `--size=844x390`, `--out=PATH`,
## `--frames=N` (settle frames, default 150), `--ready=property` (wait until the root's property is set; default `player`),
## `--set=prop=value` (repeatable; `force_offline=true` is always set when the root has it).
## `--call=[NodePath:]method[:arg1,arg2]` (repeatable, once ready; the path is relative to the scene root, none means the root;
## an argument is a Godot literal such as 3 or true, anything else is a string, so a shout is `--call=Hud:shout:Run!`).

const DEFAULT_SIZE := Vector2i(844, 390)

var _scene_path := ""
var _out := "res://screenshots/phone.png"
var _frames := 150
var _ready_property := "player"
var _calls: Array[String] = []
var _node: Node = null
var _seen := 0
var _called := false
var _elapsed := 0.0


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	var size := DEFAULT_SIZE
	var props := {}
	_scene_path = str(ProjectSettings.get_setting("application/run/main_scene", ""))
	for argument in OS.get_cmdline_user_args():
		if argument == "--touch":
			# Before the client exists: the menu reads it while building its Menu button.
			DotPlatform.touch_override = 1
		elif argument.begins_with("--scene="):
			_scene_path = argument.trim_prefix("--scene=")
		elif argument.begins_with("--size="):
			var parts := argument.trim_prefix("--size=").split("x")
			if parts.size() == 2:
				size = Vector2i(int(parts[0]), int(parts[1]))
		elif argument.begins_with("--out="):
			_out = argument.trim_prefix("--out=")
		elif argument.begins_with("--frames="):
			_frames = int(argument.trim_prefix("--frames="))
		elif argument.begins_with("--ready="):
			_ready_property = argument.trim_prefix("--ready=")
		elif argument.begins_with("--call="):
			_calls.append(argument.trim_prefix("--call="))
		elif argument.begins_with("--set="):
			var pair := argument.trim_prefix("--set=").split("=", true, 1)
			if pair.size() == 2:
				props[pair[0]] = str_to_var(pair[1])
	# --resolution sets the window, but the viewport only follows it when nothing scales: say it again.
	root.size = size
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var packed := load(_scene_path) as PackedScene
	if packed == null:
		printerr("phone_shot: scene %s did not load" % _scene_path)
		quit(2)
		return
	_node = packed.instantiate()
	props["force_offline"] = props.get("force_offline", true)
	for key: String in props:
		if key in _node:
			_node.set(key, props[key])
	root.add_child(_node)


func _process(delta: float) -> bool:
	if _node == null:
		return false
	_elapsed += delta
	if _elapsed > 120.0:
		printerr("phone_shot: ", _ready_property, " never became ready")
		quit(3)
		return true
	if _ready_property != "" and _ready_property in _node and not is_instance_valid(_node.get(_ready_property)):
		return false
	if not _called:
		_called = true
		# Once, not per frame: deferred calls still run before this frame is drawn.
		_run_calls.call_deferred()
	_seen += 1
	if _seen < _frames:
		return false
	var image := root.get_texture().get_image()
	if _is_flat(image):
		# A null renderer or a movie writer's first frames give one colour; a file of it looks like a shot.
		printerr("phone_shot: the frame is one flat colour (", image.get_pixel(0, 0), "); not a render")
		quit(4)
		return true
	var path := ProjectSettings.globalize_path(_out)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	image.save_png(path)
	print("wrote ", path, " (", image.get_width(), " x ", image.get_height(), ")")
	quit(0)
	return true


func _run_calls() -> void:
	for spec in _calls:
		_call(spec)


func _call(spec: String) -> void:
	var parts := spec.split(":", true, 2)
	var path := "."
	var method := parts[0]
	var raw := ""
	if parts.size() == 2:
		path = parts[0]
		method = parts[1]
	elif parts.size() == 3:
		path = parts[0]
		method = parts[1]
		raw = parts[2]
	var target := _node.get_node_or_null(path if path != "" else ".")
	if target == null or not target.has_method(method):
		printerr("phone_shot: no %s on %s" % [method, path])
		return
	var values: Array = []
	if raw != "":
		for item in raw.split(","):
			var parsed: Variant = str_to_var(item)
			values.append(item if parsed == null else parsed)
	target.callv(method, values)


func _is_flat(image: Image) -> bool:
	var first := image.get_pixel(0, 0)
	for y in range(0, image.get_height(), 7):
		for x in range(0, image.get_width(), 7):
			if image.get_pixel(x, y) != first:
				return false
	return true
