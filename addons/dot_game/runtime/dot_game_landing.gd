extends Node

## The thump of a landing and the strength of the camera kick, for every first-person game: [DotGameClient] adds one in `setup()`. It follows each dot-player-controller `DotFpsController` that enters the tree, plays dot-audio's landing stock chosen by impact (`DotAudioStock.landing_id`) at the body, scaled by `cl_landing_volume`, and sets the controller view's `landing_strength` from `cl_landing_kick`. dot-audio is loaded by path; without it or a `DotAudioManager` in the registry nothing plays. No class_name: the client preloads it.

const CHANNEL := "game.client.landing"
const RULES_SCRIPT := "res://addons/dot_audio/core/dot_audio_landing_rules.gd"
const STOCK_SCRIPT := "res://addons/dot_audio/core/dot_audio_stock.gd"
const AUDIO_SERVICE := &"dot_audio"
const CVAR_KICK := "cl_landing_kick"
const CONTROLLER_CLASS := &"DotFpsController"

## `DotAudioLandingRules` (volume, minimum impact); built from dot-audio when unset.
var rules: RefCounted = null
## `func() -> Object`: the audio manager (`play_at`); the registry's by default.
var manager_fn: Callable = Callable()
## `func(impact) -> StringName`: the stock id for an impact; dot-audio's `landing_id` by default.
var id_fn: Callable = Callable()
## `func(node) -> bool`: what counts as a controller; unset is [method is_controller].
var controller_fn: Callable = Callable()
## `func() -> Object`: dot-audio's `DotAudioSurfRules`; a landing on a surf ramp is silent when it says so. Unset plays every landing.
var surf_rules_fn: Callable = Callable()
## Multiplier for the camera kick, from [constant CVAR_KICK].
var kick: float = 1.0:
	set(value):
		kick = clampf(value, 0.0, 2.0)
		_apply_kick()

## Landings played, for describe.
var played: int = 0

var _controllers: Dictionary = {}
var _console_bound: bool = false


## Builds the rules when unset and follows every controller in the tree. False without dot-audio.
func start() -> bool:
	if rules == null:
		if not ResourceLoader.exists(RULES_SCRIPT):
			DotLog.debug(CHANNEL, "dot-audio is not in this build: no landing sounds")
			return false
		var script: Variant = load(RULES_SCRIPT)
		if not (script is GDScript):
			return false
		rules = (script as GDScript).new() as RefCounted
	if not get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.connect(_on_node_added)
	_scan(get_tree().root)
	return true


func _exit_tree() -> void:
	var tree := get_tree()
	if tree != null and tree.node_added.is_connected(_on_node_added):
		tree.node_added.disconnect(_on_node_added)


## Registers `cl_landing_volume` and `cl_landing_kick` on a dot-console local source (`add_var`), or on the console's own sources. True when bound.
func bind_console(console: Object) -> bool:
	if console == null or rules == null:
		return false
	var target: Object = console if console.has_method(&"add_var") else null
	if target == null and console.has_method(&"sources"):
		for source: Variant in console.call(&"sources"):
			if source is Object and (source as Object).has_method(&"add_var"):
				target = source
				break
	if target == null:
		return false
	target.call(&"add_var", &"cl_landing_volume", "Landing thump volume: 0 off, 1 stock level",
		func() -> Variant: return rules.get(&"volume"),
		func(v: Variant) -> void: rules.set(&"volume", float(str(v))))
	target.call(&"add_var", StringName(CVAR_KICK), "Camera kick on a landing: 0 none, 1 normal, 2 double",
		func() -> Variant: return kick,
		func(v: Variant) -> void: kick = float(str(v)))
	_console_bound = true
	return true


func _scan(node: Node) -> void:
	_on_node_added(node)
	for child in node.get_children():
		_scan(child)


func _on_node_added(node: Node) -> void:
	if not (controller_fn.call(node) if controller_fn.is_valid() else is_controller(node)):
		return
	if _controllers.has(node.get_instance_id()):
		return
	_controllers[node.get_instance_id()] = weakref(node)
	if node.has_signal(&"landed"):
		node.connect(&"landed", _on_landed.bind(node))
	_apply_kick()


## Whether [param node] is a `DotFpsController` or a subclass, by script, so dot-game names no dot-player-controller class.
static func is_controller(node: Node) -> bool:
	var script: Script = node.get_script() as Script
	while script != null:
		if script.get_global_name() == CONTROLLER_CLASS:
			return true
		script = script.get_base_script()
	return false


func _apply_kick() -> void:
	for id: int in _controllers.keys():
		var controller: Object = (_controllers[id] as WeakRef).get_ref()
		if controller == null or not is_instance_valid(controller):
			var _gone := _controllers.erase(id)
			continue
		var view: Variant = controller.get(&"view")
		if view is Object and "landing_strength" in (view as Object):
			(view as Object).set(&"landing_strength", kick)


func _on_landed(impact: float, controller: Node) -> void:
	if rules == null:
		return
	var scale: float = float(rules.call(&"volume_for", impact))
	if scale <= 0.0:
		return
	if _on_surf_ramp(controller):
		return
	var m: Object = manager_fn.call() if manager_fn.is_valid() else DotRegistry.get_node_service(AUDIO_SERVICE)
	if m == null or not is_instance_valid(m):
		return
	var id: StringName = id_fn.call(impact) if id_fn.is_valid() else _stock_id(impact)
	var body := controller.get_parent() as Node3D
	var at: Vector3 = body.global_position if body != null and body.is_inside_tree() else Vector3.ZERO
	var _handle: Variant = m.call(&"play_at", id, at, scale)
	played += 1


func _on_surf_ramp(controller: Node) -> bool:
	var sr: Object = surf_rules_fn.call() if surf_rules_fn.is_valid() else null
	var body := controller.get_parent() as Node3D
	return sr != null and body != null and bool(sr.get(&"mute_steps")) and bool(sr.call(&"is_surfing", body))


func _stock_id(impact: float) -> StringName:
	if not ResourceLoader.exists(STOCK_SCRIPT):
		return &"landing_medium"
	return (load(STOCK_SCRIPT) as GDScript).call(&"landing_id", impact)


func describe() -> Dictionary:
	return {"followed": _controllers.size(), "played": played, "kick": kick, "console": _console_bound}
