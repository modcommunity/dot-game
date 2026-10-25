class_name DotGameModuleWiring
extends RefCounted

## What [DotGameModule] wires for avatars and noblock once its pieces exist; the hooks a game overrides stay on the module.

const CHANNEL := "game.module"


## The roster tells the relay's loadouts who joins and leaves, so each equipped set is read and told to everybody.
static func follow_loadouts(m: DotGameModule) -> void:
	var relay: Variant = m.net.get_meta(DotGameAvatarActionRelay.NET_META, null) if m.net != null else null
	if relay is DotGameAvatarActionRelay and (relay as DotGameAvatarActionRelay).loadouts != null:
		(relay as DotGameAvatarActionRelay).loadouts.server = m.server
		m.roster.follow((relay as DotGameAvatarActionRelay).loadouts)


## The relay asks the module, which defers to the game object when it does not override; the netcode only knows the game.
static func bind_hooks(m: DotGameModule) -> void:
	var relay: Variant = m.net.get_meta(DotGameAvatarActionRelay.NET_META, null) if m.net != null else null
	if relay is DotGameAvatarActionRelay:
		(relay as DotGameAvatarActionRelay).equipped_fn = m._avatar_actions_equipped
		(relay as DotGameAvatarActionRelay).veto_fn = m._avatar_action_veto


## Publishes the site server id, and keeps looking while dot-auth has not read it.
static func advertise_site_server(m: DotGameModule) -> void:
	if m.console == null:
		return
	var id := m._site_server_id()
	var cv := m.add_cvar(DotGameAvatarContent.SERVER_CVAR, str(id),
		"This server's id on the site, where clients read its avatar library.",
		DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)
	if cv == null or id > 0 or m.site_server_retries <= 0 or not m.is_inside_tree():
		return
	# A Timer child, so a module freed mid-wait takes the retry with it.
	var timer := Timer.new()
	timer.name = "SiteServerRetry"
	timer.wait_time = maxf(0.05, m.site_server_retry_sec)
	m.add_child(timer)
	var left := [m.site_server_retries]
	timer.timeout.connect(func() -> void:
		var found: int = m._site_server_id()
		left[0] -= 1
		if found > 0:
			var _set := cv.set_value(str(found))
		if found > 0 or left[0] <= 0:
			timer.queue_free())
	timer.start()


## Publishes the files a client must fetch before it joins, as `sv_avatar_content`.
static func advertise_content(m: DotGameModule) -> void:
	var ids: Array = m._avatar_content_required()
	if ids.is_empty() or m.console == null:
		return
	var made := m.add_cvar(DotGameAvatarContent.CVAR, DotGameAvatarContent.format(ids),
		"Avatar and action files a client downloads before it joins.", DotConVar.FLAG_NOTIFY)
	if made == null:
		DotLog.warn(CHANNEL, "avatar content not advertised: no cvar")


## Builds the block rules when the game has a `body_rules`; null in the result when off.
static func build_noblock(m: DotGameModule) -> DotResult:
	if not m._noblock_enabled():
		DotLog.debug(CHANNEL, "noblock off: no body_rules, or the game wires its own")
		return DotResult.success(null)
	if not DotGameNoblock.available():
		DotLog.warn(CHANNEL, "noblock unavailable: dot-team is not in this build (players block each other)")
		return DotResult.success(null)
	var made := DotGameNoblock.create(String(m._map_config_game()), Callable(m, "_noblock_side"))
	if not made.ok:
		return made
	var built: DotGameNoblock = made.value
	var bound := built.bind(m.add_cvar, m, m._noblock_runtime())
	if not bound.ok:
		return bound.wrap("noblock")
	built.feed(m.game.get("body_rules"))
	if "block_rules" in m.game:
		m.game.set("block_rules", built.rules)
	m.noblock = built
	return DotResult.success(built)


## Starts dot-cloud's auto-update once per headless server process, under the server. No-op without dot-cloud, on a listen server and in a browser.
static func start_auto_update(host: DotServer) -> Node:
	if host == null or not DotPlatform.is_headless() or not ResourceLoader.exists(DotGameModule.AUTO_UPDATE_SCRIPT):
		return null
	var existing := DotRegistry.get_node_service(DotGameModule.AUTO_UPDATE_SERVICE)
	if existing != null:
		return existing
	var script := load(DotGameModule.AUTO_UPDATE_SCRIPT) as Script
	if script == null or not bool(script.call("supported")):
		return null
	var node: Node = script.new()
	node.name = "DotCloudAutoUpdate"
	node.set("watch_fn", func() -> Array: return watched_packs(host))
	node.set("players_fn", func() -> int: return host.sessions().size())
	node.set("warn_fn", func(text: String) -> void: host.broadcast_message(text))
	node.set("restart_fn", func(code: int, reason: String) -> void:
		host.shutdown("Server restarting to update (%s)" % reason)
		host.get_tree().quit(code))
	host.add_child(node)
	node.call("bind_console", host.console)
	return node


## Every delivered pack the server's games run, as `{id, version}` (games, dependencies, maps).
static func watched_packs(host: Object) -> Array:
	var out: Array = []
	var manager: Object = host.get(&"games") if host != null else null
	var listed: Variant = manager.get(&"games") if manager != null else null
	if not (listed is Array):
		return out
	for d: Variant in listed:
		if not (d is DotGameDescriptor) or not (d as DotGameDescriptor).needs_delivered_content():
			continue
		out.append({"id": d.effective_content_id(), "version": d.version})
		for list_name: StringName in [&"dependencies", &"server_dependencies", &"maps"]:
			if not (list_name in d):
				continue
			for key: String in d.get(list_name):
				var parts := DotGameDescriptor.split_key(key)
				out.append({"id": parts[0], "version": parts[1]})
	return out
