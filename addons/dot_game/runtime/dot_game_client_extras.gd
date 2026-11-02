class_name DotGameClientExtras
extends RefCounted

## The optional parts [DotGameClient] adds in setup: profiler, render quality, landing, slide sounds, latency, chat and team-menu wiring.

const _Vis := preload("res://addons/dot_game/runtime/dot_game_client_vis.gd")
const _RenderQuality := preload("res://addons/dot_game/runtime/dot_game_render_quality.gd")
const _Profiler := preload("res://addons/dot_game/runtime/dot_game_profiler.gd")


static func add_profiler(c: DotGameClient) -> void:
	if not c.use_profiler:
		return
	c.profiler = _Profiler.add(c)
	if c.profiler == null:
		return
	if not bind_profiler_console(c):
		# A game that builds its own console registers it later; bind then (deferred, so its own commands are on it).
		DotRegistry.signals().service_registered.connect(
			func(service: StringName, _instance: Object) -> void:
				if service == &"dot_console":
					bind_profiler_console.call_deferred(c))


static func bind_profiler_console(c: DotGameClient) -> bool:
	if c._profiler_bound or c.profiler == null or not is_instance_valid(c.profiler):
		return c._profiler_bound
	var con: Object = c.console if c.console != null and is_instance_valid(c.console) else DotRegistry.get_service(&"dot_console")
	if con == null or not con.has_method(&"sources"):
		return false
	var local: Object = null
	for s: Object in con.call(&"sources"):
		if s.has_method(&"add_var"):
			if s.has_method(&"claims") and bool(s.call(&"claims", "profiler_enabled")):
				c._profiler_bound = true
				return true
			local = s
	if local == null:
		return false
	_Profiler.bind_client_console(c.profiler, local)
	c._profiler_bound = true
	return true


static func add_render_quality(c: DotGameClient) -> void:
	if not c.use_render_quality or c.gate_only:
		return
	var store: Object = null
	if c.settings != null and is_instance_valid(c.settings):
		store = c.settings.get(&"settings")
	c.render_quality = preload("res://addons/dot_game/runtime/dot_game_client_render.gd").add(c, store)


static func add_landing(c: DotGameClient) -> void:
	if not c.use_landing:
		return
	var node: Node = preload("res://addons/dot_game/runtime/dot_game_landing.gd").new()
	node.name = "Landing"
	node.set(&"surf_rules_fn", func() -> Object: return c.slide_sounds.get(&"surf_rules") if c.slide_sounds != null and is_instance_valid(c.slide_sounds) else null)
	c.add_child(node)
	if node.call(&"start"):
		c.landing = node
		if c.console != null and is_instance_valid(c.console):
			var _bound: Variant = node.call(&"bind_console", c.console)
	else:
		node.queue_free()


static func add_slide_sounds(c: DotGameClient) -> void:
	if not c.use_slide_sounds:
		return
	var node: Node = preload("res://addons/dot_game/runtime/dot_game_slide_sounds.gd").new()
	node.name = "SlideSounds"
	node.set(&"link_fn", func() -> Object: return c.link)
	node.set(&"settings_fn", func() -> Object:
		if c.slide_settings != null:
			return c.slide_settings
		return c.settings.get(&"settings") if c.settings != null and is_instance_valid(c.settings) else null)
	c.add_child(node)
	if node.call(&"start"):
		c.slide_sounds = node
	else:
		node.queue_free()


## Finds the client's DotNetManager in the registry now or when it registers (a server's is skipped).
static func watch_latency_net(c: DotGameClient) -> void:
	var bus := DotRegistry.signals()
	if not bus.service_registered.is_connected(c._on_latency_service):
		bus.service_registered.connect(c._on_latency_service)
	for service_name in DotRegistry.names():
		on_latency_service(service_name, DotRegistry.get_service(service_name), c)


static func on_latency_service(service_name: StringName, instance: Object, client: DotGameClient) -> void:
	if not String(service_name).begins_with(String(DotNetManager.SERVICE)) or not (instance is DotNetManager):
		return
	if (instance as DotNetManager).is_server:
		return
	client.add_latency(instance as DotNetManager)


static func bind_latency(c: DotGameClient) -> void:
	if c._latency_net == null or c._latency_net.latency == null or c._latency_bound == c._latency_net:
		return
	var latency := c._latency_net.latency
	var source: Object = c.link if c.link != null else DotRegistry.get_service(DotGameClient.LINK_SERVICE)
	var _followed := latency.follow_cvars(source)
	var local := _Vis.local_source(c, StringName(latency.CVAR_BASELINE))
	if local == null:
		return
	c._latency_bound = c._latency_net
	var _bound := latency.bind_client_cvar(func(n: String, _d: String, help: String, _f: int) -> Object:
		local.call(&"add_var", StringName(n), help,
			func() -> Variant: return latency.requested,
			func(v: Variant) -> Variant:
				if latency.set_cvar(n, str(v)):
					return DotResult.success(latency.requested)
				return DotResult.fail(DotError.CODE_INVALID, "%s takes seconds, e.g. 0.1" % n))
		return null)


static func wire_chat(c: DotGameClient) -> void:
	if c.chat == null:
		return
	if not c.chat.is_inside_tree():
		c.add_child(c.chat)
	# typing_changed(bool) on DotGameChatClient, opened(channel) / closed() on dot-ui's box.
	for signal_name: StringName in [&"typing_changed", &"opened", &"closed"]:
		if c.chat.has_signal(signal_name):
			c.chat.connect(signal_name, c._refresh_blocked)


static func wire_team_menu(c: DotGameClient) -> void:
	# By name and only when unset: an older dot-menu has no team menu, and a game's own offer stays.
	if not c.use_team_menu or c.menu == null or not c.menu.has_method(&"use_teams"):
		return
	if &"teams" in c.menu and c.menu.get(&"teams") != null:
		return
	var teams: Variant = c.menu.call(&"use_teams")
	if teams is Object and &"default_when_unwired" in (teams as Object):
		(teams as Object).set(&"default_when_unwired", c.team_menu_default_when_unwired)


## The body of [method DotGameClient.add_console]: the kit's console, then the client's own vars on it.
static func build_console(c: DotGameClient, manager: Object) -> Node:
	if not ResourceLoader.exists(c.console_kit_path):
		DotLog.info(DotGameClient.CHANNEL, "dot-console is not in this build: no console")
		return null
	var kit: Variant = load(c.console_kit_path)
	if not (kit is GDScript):
		DotLog.warn(DotGameClient.CHANNEL, "dot-console's kit would not load", {"path": c.console_kit_path})
		return null
	if manager == null and c.settings != null:
		var got: Variant = c.settings.get(&"settings")
		manager = got if got is Object else null
	var built: Variant = (kit as GDScript).call(&"build", c, manager, c.menu)
	c.console = built if built is Node else null
	var _v := _Vis.add_console_var(c)
	var quality := _Vis.local_source(c, &"r_msaa")
	if quality != null:
		_RenderQuality.add_client_vars(quality, func() -> void: _RenderQuality.apply(c.get_viewport(), c.get_tree().root))
	DotGameClientStats.add_console_var(c)
	if c._latency_net != null:
		bind_latency(c)
	return c.console


static func map_changed(c: DotGameClient, map_id: String) -> void:
	if c.map_config == null:
		if (c.map_config_keys.is_empty() and c.map_config_defaults.is_empty()) \
				or not c.map_config_get_fn.is_valid() or not c.map_config_set_fn.is_valid():
			return
		c.map_config = DotGameMapConfig.new()
		c.map_config.game_id = c.map_config_game if c.map_config_game != "" else DotAddonConfig.game
		c.map_config.keys = c.map_config_keys
		c.map_config.defaults = c.map_config_defaults
		c.map_config.get_fn = c.map_config_get_fn
		c.map_config.set_fn = c.map_config_set_fn
	c.map_config.apply(map_id)


## The sound, landing, render-quality and latency parts a client adds after its menu.
static func add_late_parts(c: DotGameClient) -> void:
	add_slide_sounds(c)
	add_landing(c)
	add_render_quality(c)
	watch_latency_net(c)
