extends RefCounted

## [DotGameClient]'s opt-in map culling: dot-map's DotMapVisibility over a converted map, by path, and the `vis_mode` console variable. No class_name: the client preloads it.

const CHANNEL := "game.client.vis"
const VIS_SCRIPT := "res://addons/dot_map/bsp/dot_map_visibility.gd"
const MODES := ["off", "pvs", "occluders", "both"]
const VAR_NAME := &"vis_mode"
const _Threads := preload("res://addons/dot_game/runtime/dot_game_map_threads.gd")


## Remembers [param world] and [param drawn] and builds the culling when the mode is not off. Null when off, without dot-map, or when the map has no visibility data.
static func attach(c: DotGameClient, world: RefCounted, drawn: Node3D, parent: Node) -> Node:
	detach(c)
	c._vis_world = world
	c._vis_drawn = weakref(drawn)
	c._vis_parent = weakref(parent if parent != null else drawn)
	if c.vis_mode != "off":
		_build(c)
	return c.visibility


## Frees the culling and forgets the map: call when the map is unloaded.
static func detach(c: DotGameClient) -> void:
	if c.visibility != null and is_instance_valid(c.visibility):
		c.visibility.queue_free()
	c.visibility = null
	c._vis_world = null
	c._vis_drawn = null
	c._vis_parent = null


## Sets the mode and follows it on the attached map. False for an unknown name.
static func set_mode(c: DotGameClient, text: String) -> bool:
	var mode := text.strip_edges().to_lower()
	if not MODES.has(mode):
		return false
	c.vis_mode = mode
	if c.visibility != null and is_instance_valid(c.visibility):
		c.visibility.call(&"set_mode", c.visibility.call(&"parse_mode", mode))
	elif mode != "off" and c._vis_world != null:
		_build(c)
	return true


static func _build(c: DotGameClient) -> void:
	var drawn: Node3D = c._vis_drawn.get_ref() if c._vis_drawn != null else null
	var parent: Node = c._vis_parent.get_ref() if c._vis_parent != null else null
	if drawn == null or parent == null:
		return
	if not ResourceLoader.exists(VIS_SCRIPT):
		DotLog.info(CHANNEL, "dot-map is not in this build: no map culling")
		return
	var vis: Node = (load(VIS_SCRIPT) as GDScript).new()
	vis.name = "MapVisibility"
	vis.set(&"mode", vis.call(&"parse_mode", c.vis_mode))
	parent.add_child(vis)
	var res: Variant = vis.call(&"setup", c._vis_world, drawn)
	if res is DotResult and not (res as DotResult).ok:
		DotLog.info(CHANNEL, "map culling is off for this map", {"why": (res as DotResult).error.message})
		vis.queue_free()
		return
	c.visibility = vis
	DotLog.debug(CHANNEL, "map culling on", {"mode": c.vis_mode})


## The client console's own variable source that does not already claim [param name], or null.
static func local_source(c: DotGameClient, name: StringName) -> Object:
	if c.console == null or not c.console.has_method(&"sources"):
		return null
	var local: Object = null
	for s: Object in c.console.call(&"sources"):
		if s.has_method(&"add_var"):
			if s.has_method(&"claims") and bool(s.call(&"claims", String(name))):
				return null
			local = s
	return local


## Adds `vis_mode` and `map_load_threads` to the client console's own variables unless the game already has one there. True when `vis_mode` was added.
static func add_console_var(c: DotGameClient) -> bool:
	var threads := local_source(c, StringName(_Threads.CVAR))
	if threads != null:
		_Threads.add_client_var(threads)
	var local := local_source(c, VAR_NAME)
	if local == null:
		return false
	local.call(&"add_var", VAR_NAME, "Map culling: off (default), pvs, occluders or both",
		func() -> Variant: return c.vis_mode,
		func(v: Variant) -> Variant:
			if set_mode(c, str(v)):
				return DotResult.success(c.vis_mode)
			return DotResult.fail(DotError.CODE_INVALID, "vis_mode is one of %s" % ", ".join(MODES)))
	return true


## Applies a [code]--vis_mode=[/code] user argument.
static func apply_cmdline(c: DotGameClient) -> void:
	_Threads.apply_cmdline()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--vis_mode="):
			var _v := set_mode(c, a.get_slice("=", 1))
