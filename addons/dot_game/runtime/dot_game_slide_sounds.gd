extends Node

## The scrape of a sliding player, for every first-person game: [DotGameClient] adds one in `setup()`. It finds each dot-player-controller `DotFpsController` as it enters the tree, keeps dot-audio's `DotAudioSlide` on those bodies, follows the server's `sv_slide_sounds` and the player's `slide_volume`. dot-audio is loaded by path; without it, or without a `DotAudioManager` in the registry, nothing plays. No class_name: the client preloads it.

const CHANNEL := "game.client.slide"
const SLIDE_SCRIPT := "res://addons/dot_audio/runtime/dot_audio_slide.gd"
const SURF_SCRIPT := "res://addons/dot_audio/runtime/dot_audio_surf.gd"
const SURF_RULES_SCRIPT := "res://addons/dot_audio/core/dot_audio_surf_rules.gd"
const DEF_SCRIPT := "res://addons/dot_settings/core/dot_settings_def.gd"
const SCHEMA_SCRIPT := "res://addons/dot_settings/core/dot_settings_schema.gd"
const STOCK_SCRIPT := "res://addons/dot_menu/stock/dot_menu_stock.gd"
const CVAR := "sv_slide_sounds"
const SETTING := &"slide_volume"
const CONTROLLER_CLASS := &"DotFpsController"

## The slide node (dot-audio's `DotAudioSlide`, or a stand-in); built by [method start] when unset.
var slide: Node = null
## `func() -> Object`: the game link whose replicated cvars to follow; null offline.
var link_fn: Callable = Callable()
## `func() -> Object`: a settings manager (`changed` signal, `get_float`) holding [constant SETTING].
var settings_fn: Callable = Callable()
## `func(node) -> bool`: what counts as a controller; unset is [method is_controller]. A suite swaps it.
var controller_fn: Callable = Callable()
## dot-audio's `DotAudioSurf` (the glide on a ramp), built by [method start] when dot-audio ships it.
var surf: Node = null
## The `DotAudioSurfRules` behind [member surf] and its replicated `sv_surf_*` cvars; shared with [DotGameLanding] to mute landings.
var surf_rules: RefCounted = null
## The server's switch, from [constant CVAR].
var enabled: bool = true

var _controllers: Dictionary = {}
var _bound_link: Object = null
var _bound_settings: Object = null


## The server cvar's name, value, description and flags, for the module that binds it.
static func cvar_spec() -> Dictionary:
	return {
		"name": CVAR, "value": "1",
		"description": "Whether sliding scrapes the ground audibly (1) or is silent (0)",
	}


## Adds [constant SETTING] to a `DotSettingsSchema` that lacks it. Null is a no-op.
static func declare(schema: Object) -> void:
	if schema == null or schema.call(&"has", SETTING):
		return
	var def_script: Variant = load(DEF_SCRIPT) if ResourceLoader.exists(DEF_SCRIPT) else null
	if not (def_script is GDScript):
		return
	var def: Object = (def_script as GDScript).call(&"number", SETTING, 1.0, 0.0, 1.0, &"audio")
	if def != null and def.has_method(&"with_description"):
		def = def.call(&"with_description", "How loud sliding scrapes the ground.")
	var _added: Variant = schema.call(&"add", def)


## Declares [constant SETTING] on a dot-menu settings node's schema before its `setup()`, building the stock schema first when the node has none.
static func declare_on(menu_settings: Object) -> void:
	if menu_settings == null or not ("schema" in menu_settings):
		return
	var schema: Object = menu_settings.get(&"schema")
	if schema == null:
		if not ResourceLoader.exists(SCHEMA_SCRIPT) or not ResourceLoader.exists(STOCK_SCRIPT):
			return
		schema = (load(SCHEMA_SCRIPT) as GDScript).new()
		var _stock: Variant = (load(STOCK_SCRIPT) as GDScript).call(&"declare", schema)
		menu_settings.set(&"schema", schema)
	declare(schema)


## Builds the slide node when unset and starts following every controller in the tree. False (and a debug line) without dot-audio.
func start() -> bool:
	if slide == null:
		if not ResourceLoader.exists(SLIDE_SCRIPT):
			DotLog.debug(CHANNEL, "dot-audio is not in this build: no slide sounds")
			return false
		var script: Variant = load(SLIDE_SCRIPT)
		if not (script is GDScript):
			return false
		slide = (script as GDScript).new() as Node
		slide.name = "Slide"
	if slide.get_parent() == null:
		add_child(slide)
	_start_surf()
	if not get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.connect(_on_node_added)
	_scan(get_tree().root)
	return true


func _start_surf() -> void:
	if surf != null or not ResourceLoader.exists(SURF_SCRIPT) or not ResourceLoader.exists(SURF_RULES_SCRIPT):
		return
	var node: Variant = load(SURF_SCRIPT).new()
	if not (node is Node):
		return
	surf = node as Node
	surf.name = "Surf"
	surf_rules = load(SURF_RULES_SCRIPT).new() as RefCounted
	surf.set(&"rules", surf_rules)
	add_child(surf)


## The `sv_surf_*` cvar specs (name, value, description, range) of dot-audio, or none without it.
static func surf_cvar_specs() -> Array:
	if not ResourceLoader.exists(SURF_RULES_SCRIPT):
		return []
	return (load(SURF_RULES_SCRIPT) as GDScript).call(&"cvar_specs")


func _exit_tree() -> void:
	var tree := get_tree()
	if tree != null and tree.node_added.is_connected(_on_node_added):
		tree.node_added.disconnect(_on_node_added)


func _scan(node: Node) -> void:
	_on_node_added(node)
	for child in node.get_children():
		_scan(child)


func _on_node_added(node: Node) -> void:
	if (controller_fn.call(node) if controller_fn.is_valid() else is_controller(node)):
		_controllers[node.get_instance_id()] = weakref(node)


## Whether [param node] is a `DotFpsController` or a subclass of one, by script, so dot-game names no dot-player-controller class.
static func is_controller(node: Node) -> bool:
	var script: Script = node.get_script() as Script
	while script != null:
		if script.get_global_name() == CONTROLLER_CLASS:
			return true
		script = script.get_base_script()
	return false


var _bodies: Array = []


## The bodies being followed, one per live controller; the array is reused each call.
func bodies() -> Array:
	var out := _bodies
	out.clear()
	for id: int in _controllers.keys():
		var controller: Node = (_controllers[id] as WeakRef).get_ref()
		if controller == null or not is_instance_valid(controller) or not controller.is_inside_tree():
			if controller == null or not is_instance_valid(controller):
				var _gone := _controllers.erase(id)
			continue
		var body := controller.get_parent() as Node3D
		if body != null:
			out.append(body)
	return out


func _sliding(body: Node3D) -> bool:
	for child in body.get_children():
		if _controllers.has(child.get_instance_id()):
			var state: Variant = child.get("state")
			return state != null and state.has_method(&"is_sliding") and bool(state.call(&"is_sliding"))
	return false


func _process(_delta: float) -> void:
	if slide == null:
		return
	_bind()
	slide.set(&"enabled", enabled)
	slide.call(&"keep", bodies(), _sliding)
	if surf != null:
		surf.call(&"keep_surfers", bodies())


func _bind() -> void:
	var l: Object = link_fn.call() if link_fn.is_valid() else null
	if l != _bound_link and l != null and is_instance_valid(l):
		_bound_link = l
		if l.has_method(&"replicated_cvar") and l.has_signal(&"replicated_cvar_changed"):
			var held := String(l.call(&"replicated_cvar", CVAR, ""))
			if held != "":
				enabled = held != "0"
			if surf_rules != null:
				for spec: Dictionary in surf_cvar_specs():
					var v := String(l.call(&"replicated_cvar", String(spec["name"]), ""))
					if v != "":
						surf_rules.call(&"apply_cvar", String(spec["name"]), v)
			if not l.is_connected(&"replicated_cvar_changed", _on_cvar):
				l.connect(&"replicated_cvar_changed", _on_cvar)
	var s: Object = settings_fn.call() if settings_fn.is_valid() else null
	if s != _bound_settings and s != null and is_instance_valid(s):
		_bound_settings = s
		if s.has_signal(&"changed"):
			if not s.is_connected(&"changed", _on_setting):
				s.connect(&"changed", _on_setting)
		if s.has_method(&"get_float"):
			slide.set(&"volume", float(s.call(&"get_float", SETTING, 1.0)))


func _on_cvar(cvar_name: String, value: String) -> void:
	if cvar_name == CVAR:
		enabled = value != "0"
	elif surf_rules != null and cvar_name.begins_with("sv_surf_"):
		surf_rules.call(&"apply_cvar", cvar_name, value)


func _on_setting(key: StringName, value: Variant, _why: StringName) -> void:
	if key == SETTING and slide != null:
		slide.set(&"volume", float(value))
