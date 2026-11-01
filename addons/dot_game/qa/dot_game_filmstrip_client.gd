extends SceneTree

## Plays one clip of tools/filmstrip_scenarios.json through the game's real offline client for `--write-movie`.
## Run by dot_game_filmstrip_run.sh with user args `<clip> [game args]`. The file's "defaults" or a clip's "fields" set:
## `client` (res:// script of the client root), `client_props` (set before it enters the tree, e.g. force_offline),
## `ready_property` (client property that is non-null once playable, default "player"; "" waits only `warmup`),
## `warmup` (seconds after ready before the clip, default 2), `move_actions` [forward, back, left, right] input actions.
## Steps: `move` [x, y] and `buttons` (input action names held), `event` "call:<method>" calls it on the client.

var _clip: DotScenario = null
var _client: Node = null
var _moves: Array = ["dot_fps_forward", "dot_fps_back", "dot_fps_left", "dot_fps_right"]
var _ready_property := "player"
var _warmup := 2.0
var _all := 0
var _start_frame := 0
var _waited := 0.0
var _ready_for := -1.0
var _time := 0.0
var _prev := -1.0
var _held: Dictionary = {}
var _started := false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var clips := DotScenario.load_file("res://tools/filmstrip_scenarios.json")
	if args.is_empty() or not clips.has(args[0]):
		printerr("filmstrip: clip %s not in %s" % [str(args), str(clips.keys())])
		quit(2)
		return
	_clip = clips[args[0]]
	var f := _clip.fields
	_moves = f.get("move_actions", _moves)
	_ready_property = str(f.get("ready_property", _ready_property))
	_warmup = float(f.get("warmup", _warmup))
	var script: GDScript = load(str(f.get("client", "")))
	if script == null:
		printerr("filmstrip: client script %s did not load" % str(f.get("client", "")))
		quit(2)
		return
	_client = script.new()
	_client.name = "Client"
	var props: Dictionary = f.get("client_props", {"force_offline": true})
	for key: String in props:
		_client.set(key, props[key])
	root.add_child(_client)


func _process(delta: float) -> bool:
	_all += 1
	if _clip == null or not is_instance_valid(_client):
		return false
	if not _started:
		_waited += delta
		if _waited > 120.0:
			printerr("filmstrip: client never became playable (property '%s')" % _ready_property)
			quit(3)
			return true
		if _ready_property != "" and not is_instance_valid(_client.get(_ready_property)):
			return false
		_ready_for = maxf(_ready_for, 0.0) + delta
		if _ready_for < _warmup:
			return false
		_started = true
		_start_frame = _all
		return false
	_time += delta
	_drive(_clip.state_at(_time))
	for step: Dictionary in _clip.events_between(_prev, _time):
		var event := String(step["event"])
		if event.begins_with("call:") and _client.has_method(event.substr(5)):
			_client.call(event.substr(5))
	_prev = _time
	if _time >= _clip.duration:
		print("FILMSTRIP_CLIP start_frame=%d frames=%d" % [_start_frame, _all - _start_frame])
		_drive({"move": [0.0, 0.0], "buttons": []})
		return true
	return false


func _drive(state: Dictionary) -> void:
	var move: Array = state["move"]
	var wanted := {}
	wanted[_moves[0]] = float(move[1]) < -0.1
	wanted[_moves[1]] = float(move[1]) > 0.1
	wanted[_moves[2]] = float(move[0]) < -0.1
	wanted[_moves[3]] = float(move[0]) > 0.1
	for button: String in state["buttons"]:
		wanted[button] = true
	for action: String in _held:
		if not wanted.has(action):
			wanted[action] = false
	for action: String in wanted:
		if not InputMap.has_action(action):
			continue
		if wanted[action]:
			Input.action_press(action)
		else:
			Input.action_release(action)
	_held = wanted.duplicate()
