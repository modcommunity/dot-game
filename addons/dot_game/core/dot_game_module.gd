@tool
class_name DotGameModule
extends DotModule

## The order a server game is built in, written once: game object, netcode and bridge, identity, services, roster, one tick, then the reverse on unload.
##
## Subclass it and fill in the classes and numbers that are yours. It holds no rules (those are dot-match's and dot-objective's); something belongs here only if every game would write it the same way.
## [codeblock]
## extends DotGameModule
## func _module_name() -> String: return "mygame"
## func _game_service() -> StringName: return MyGame.SERVICE
## func _net_config() -> DotNetConfig:
##     var c := DotNetConfig.new()
##     c.tick_rate = game.tick_rate
##     return c
## func _make_bridge() -> Node: return MyBridge.new()
## [/codeblock]
##
## Nothing optional is named: dot-map, dot-vote, dot-platform and a game's services are reached by duck-typing or path, because a script naming an absent class fails to parse.

const CHANNEL := "game.module"

## Where dot-platform's module is loaded from, by path: the module host constructs the module itself, so a pre-built instance would be thrown away.
const PLATFORM_MODULE_PATH := "res://addons/dot_platform/dot_platform_module.gd"
const LOOK_MUTE_SCRIPT := "res://addons/dot_voice/runtime/dot_voice_look_mute.gd"
## dot-cloud's server auto-update, loaded by path: dot-cloud is not a dependency.
const AUTO_UPDATE_SCRIPT := "res://addons/dot_cloud/server/dot_cloud_auto_update.gd"
const AUTO_UPDATE_SERVICE := &"dot_cloud_autoupdate"

## A seat's client went behind its loading cover (joined, or a map change began) or came out (lifted, timed out, left). [param seat] is the userid.
signal loading_changed(seat: int, loading: bool)

## The property a game object may declare to be handed [method is_peer_loading]: `var peer_loading_fn: Callable`. Assigned before [method _game_load], cleared at unload.
const PEER_LOADING_PROPERTY := &"peer_loading_fn"

## Seconds a seat may stay loading before it counts as loaded anyway, with a warning.
@export var load_timeout_sec: float = 30.0

## After a map change, seconds to wait for a client's cover to go up again before counting it loaded.
@export var reload_grace_sec: float = 5.0

## The game object, resolved from [DotRegistry] under [method _game_service].
var game: Object = null

## The netcode, or null for a game that declared no [method _net_config].
var net: DotNetManager = null

## The game's own bridge between itself and [member net]. Duck-typed.
var bridge: Node = null

## The NPC level-of-detail and sense-thread cvars, once the game called [method attach_npc_lod].
var npc_lod: DotGameNpcLod = null

## The identity layer, when [method _make_identity] returned one.
var identity: Node = null

## Chat, voice and moderation, when [method _make_services] returned one.
var services: Node = null

## Who is in the game, as opposed to who is connected.
var roster: DotGameRoster = null

## Authoritative ticks since load. The number the bridge is driven with.
var tick: int = 0

## [method report_map] said once that this server cannot take a map.
var _warned_no_map_report := false

## The per-map settings, built on the first [method report_map] when [method _map_config_keys] names any.
var map_config: DotGameMapConfig = null
## Assign to handle a DotMapWorld's `script.*` events; its per-map switches join [method _map_config_keys] and it restores on a map change and on unload.
var map_scripts: DotGameMapScripts = null

## The map [method report_map] last reported; a different one re-marks every seat loading.
var _reported_map := ""

## Whether this module put its handler on the server's envelope, and the game's property.
var _handles_cover := false
var _set_peer_loading := false


## The [DotRegistry] name the game object publishes itself under. Required; `&""` means a scene-only game with no object.
func _game_service() -> StringName:
	return &""


## What to tell somebody whose game object is not there; override to name the class and the call.
func _game_missing_hint() -> String:
	return (
		"create it and call setup() before loading this module, and make sure it "
		+ "registers itself under '%s'" % String(_game_service())
	)


## The netcode settings, or null for a game that does not replicate. No default: tick and snapshot rates are the game's own numbers.
func _net_config() -> DotNetConfig:
	return null


## The operator's limits on [method _net_config] (see [method DotGameNetcode.cap]); the default reads [constant DotGameNetcode.CEILING_META] off the server. An empty dictionary changes nothing.
func _net_ceiling() -> Dictionary:
	if server != null and server.has_meta(DotGameNetcode.CEILING_META):
		var v: Variant = server.get_meta(DotGameNetcode.CEILING_META)
		if v is Dictionary:
			return v
	return {}


## The game's bridge to the netcode. Required with a netcode. Duck-typed: `attach(game, net) -> DotResult`, `open_link(server)`, and `server_tick(tick)` if driven.
func _make_bridge() -> Node:
	return null


## Content, profiles, avatars and admission. Optional; needs `setup() -> DotResult`. Null for none.
func _make_identity() -> Node:
	return null


## Whether to load dot-platform's module after the identity layer is up; off for a game with its own admission flow.
func _wants_platform_module() -> bool:
	return true


## Chat, voice and moderation. Optional; needs `setup(server, game, link) -> DotResult` (link is the bridge's or null).
func _make_services() -> Node:
	return null


## Everything this game adds that the skeleton does not know. Runs last, after everything else is up; a failure refuses to load.
func _game_load() -> DotResult:
	return DotResult.success(null)


## Anything [method _game_load] set up that the [DotModule] helpers do not undo (commands, cvars and hooks they registered are removed for you).
func _game_unload() -> void:
	pass


## The server went to sleep ([param hibernating] true) or woke, after every clock this module found has heard it.
## Votes and map sessions under this module are followed for you ([method _follow_hibernation]); a game's own round timer or warmup is a rule, so reset it here.
func _game_hibernation(_hibernating: bool) -> void:
	pass


## This game's own columns on the Tab board for one player (kills, points, a side), merged into that player's row of dot-server's roster.
## The server's half of the scoreboard: only the server knows some numbers. Keyed by the session; [member roster] finds the player.
func _game_board_fields(_session: Object) -> Dictionary:
	return {}


## Everything else on the board: `"teams"`, a `"header"`, `"rows"` for non-session players. Optional.
func _game_board_extra() -> Dictionary:
	return {}


## Wires a DotNpcSpawner to `sv_threads_npc` and the `npc_lod*` / `npc_sense_quiet` cvars (all off by default; see [DotGameNpcLod]). Call it once the spawner is in the tree; [param players] returns the positions NPCs measure distance from (default: the spawner's candidates).
func attach_npc_lod(spawner: Object, players: Callable = Callable()) -> DotGameNpcLod:
	if npc_lod != null:
		npc_lod.release()
	npc_lod = DotGameNpcLod.attach(self, console, spawner, server.config if server != null else null, players)
	return npc_lod


## One authoritative tick, after the bridge has been driven.
## The game's simulation runs inside the netcode's tick, so this cannot come first. Drive clocks from this tick, not the frame, so a stalled server loses no map time.
func _game_tick(_tick: int, _delta: float) -> void:
	pass


## Builds the game, in the one order that works.
## The netcode is fatal and everything after it is not: no netcode accepts players into nothing, but an unreadable punishment file must not take the whole server down.
func _module_load() -> DotResult:
	var service := _game_service()

	if service != &"":
		game = DotRegistry.get_node_service(service)

		if game == null:
						# Refusing is right: a module that did nothing admits players into a match that does not exist.
			return DotResult.fail(
				DotError.CODE_STATE,
				"No game is registered under '%s'." % String(service),
				_game_missing_hint()
			)

	var config := _net_config()

	if config != null:
		var capped := DotGameNetcode.cap(config, _net_ceiling())

		if not capped.is_empty():
			DotLog.info(CHANNEL, "operator net limits applied", {
				"module": String(_module_name()), "changes": "; ".join(capped),
			})

		DotGameNetcode.follow_server_threads(config, server.config if server != null else null)

		var built := DotGameNetcode.build(
			self, server, game, config, _make_bridge()
		)

		if not built.ok:
			return built.wrap("the netcode could not start")

		net = built.value["net"]
		bridge = built.value["bridge"]
		_bind_avatar_hooks()

	var identified: DotResult = await _build_identity()
	DotLog.result(CHANNEL, "the identity layer", identified)

	var serviced: DotResult = await _build_services()
	DotLog.result(CHANNEL, "chat, voice and moderation", serviced)

	_build_roster()

	var loaded: DotResult = await _game_load()

	if not loaded.ok:
				# The game refused, so everything built above it comes down; else a ticking netcode outlives the module.
		_teardown()
		return loaded

	var blocked := _build_noblock()
	if not blocked.ok:
		_teardown()
		return blocked

	_advertise_avatar_content()
	_advertise_site_server()
	_follow_hibernation()
	_attach_board()
	start_auto_update(server)

	log_info("%s loaded" % _module_name(), describe())
	return DotResult.success(null)


## Hands dot-server's Tab board this game's columns. Asked, not assumed: an older dot-server lacks the properties.
func _attach_board() -> void:
	if server == null or not ("scoreboard_fields" in server):
		return
	server.set(&"scoreboard_fields", func(session: Object) -> Dictionary: return _game_board_fields(session))
	server.set(&"scoreboard_extra", func() -> Dictionary: return _game_board_extra())


## Takes them back. The server outlives this game, and the next one is not asked about it.
func _detach_board() -> void:
	if server == null or not ("scoreboard_fields" in server):
		return
	var fields: Callable = server.get(&"scoreboard_fields")
	if fields.is_valid() and fields.get_object() == self:
		server.set(&"scoreboard_fields", Callable())
		server.set(&"scoreboard_extra", Callable())


## Builds the identity layer and loads dot-platform beside it.
func _build_identity() -> DotResult:
	identity = _make_identity()

	if identity == null:
		return DotResult.success(null)

	identity.name = "Identity"
	add_child(identity)

	if not identity.has_method("setup"):
		_drop(identity)
		identity = null
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"The identity layer has no setup()."
		)

				# Awaited and typed: an un-awaited coroutine returns at its first suspension.
	var ready: Variant = await identity.call("setup")

	if not (ready is DotResult) or not (ready as DotResult).ok:
		_drop(identity)
		identity = null
		return ready if ready is DotResult else DotResult.fail(
			DotError.CODE_INTERNAL, "The identity layer's setup() returned no result."
		)

	if _wants_platform_module() and server != null and server.modules != null:
		if not server.modules.has_module("platform"):
						# Awaited: a module's `_module_load` may be a coroutine, and dot-platform's is.
			var loaded: DotResult = await server.modules.load_module(
				PLATFORM_MODULE_PATH
			)

			_loaded_platform = loaded.ok

			if not loaded.ok:
								# Reported, not fatal: without the platform module everybody is a guest.
				DotLog.result(CHANNEL, "the platform module", loaded)

	return DotResult.success(identity)


## Builds the services layer over whatever link the bridge opened.
func _build_services() -> DotResult:
	services = _make_services()

	if services == null:
		return DotResult.success(null)

	services.name = "Services"

				# Before `setup`: the services build their relay inside it.
	if identity != null and "backbone" in identity and "backbone" in services:
		services.set("backbone", identity.get("backbone"))

	add_child(services)

	if not services.has_method("setup"):
		_drop(services)
		services = null
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED, "The services layer has no setup()."
		)

	var link: Object = bridge.get("link") if bridge != null else null
	var ready: Variant = await services.call("setup", server, game, link)

	if not (ready is DotResult) or not (ready as DotResult).ok:
		_drop(services)
		services = null
		return ready if ready is DotResult else DotResult.fail(
			DotError.CODE_INTERNAL, "The services layer's setup() returned no result."
		)

		# The bridge is the only thing that names both ends of the voice path, so it is set here.
	if bridge != null and "voice_relay_fn" in bridge and services.has_method("relay_voice"):
		bridge.set("voice_relay_fn", Callable(services, "relay_voice"))

				# Voice enable/mode on the router, replicated so clients hide the talk key; read back so content.yml wins. Duck-typed.
	var router: Variant = services.get("voice") if "voice" in services else null
	if router is Object and (router as Object).has_method("bind_cvars"):
		var _voice_cvars: Variant = (router as Object).call(
			"bind_cvars", Callable(self, "add_cvar"), DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
		)

		# The look-to-gag and look-to-mute switches, so every game's server has them.
		var look_script := load(LOOK_MUTE_SCRIPT) if ResourceLoader.exists(LOOK_MUTE_SCRIPT) else null
		if look_script is Script and (look_script as Script).has_method("cvar_specs"):
			for spec in (look_script as Object).call("cvar_specs"):
				var _made := add_cvar(
					String(spec["name"]), String(spec["value"]), String(spec["description"]),
					DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
				)

	return DotResult.success(services)


## Wires the roster to the bridge and to whatever else wants to know.
func _build_roster() -> void:
	roster = DotGameRoster.new()
	roster.server = server
	roster.load_timeout_sec = load_timeout_sec
	roster.reload_grace_sec = reload_grace_sec
	roster.loading_changed.connect(_on_loading_changed)
	_handle_cover_reports()

	if game != null and PEER_LOADING_PROPERTY in game:
		game.set(PEER_LOADING_PROPERTY, Callable(self, "is_peer_loading"))
		_set_peer_loading = true

	if bridge != null:
		roster.add_fn = func(session: DotClientSession) -> Variant:
			if bridge == null or not bridge.has_method("add_player"):
				return null
			return bridge.call(
				"add_player",
				session.peer_id,
				session.userid,
				session.display_name
			)

		roster.remove_fn = func(session: DotClientSession) -> void:
			if bridge != null and bridge.has_method("remove_peer"):
				bridge.call("remove_peer", session.peer_id)
			if noblock != null:
				noblock.rules.call(&"forget", session.userid)

	roster.follow(services)
	_follow_avatar_loadouts()

		# Through the module's helper, so it is unhooked on unload; a stale hook crashes the next spawn.
	hook_post("client_spawn", _on_client_spawn)

	if server != null:
		server.client_disconnected.connect(roster.on_client_disconnected)


## Puts this module's handler for [constant DotGameRoster.COVER_KIND] on the server's envelope.
## A kind on the existing envelope, because the RPC set is frozen and each game's bridge is its own. Duck-typed and optional: a client that predates it is released by the timeout.
func _handle_cover_reports() -> void:
	if server == null or not ("envelope" in server):
		return
	var env: Object = server.get(&"envelope")
	if env == null or not env.has_method("register"):
		return
	env.call("register", DotGameRoster.COVER_KIND, Callable(self, "_on_cover_report"), false)
	_handles_cover = true


func _release_cover_reports() -> void:
	if not _handles_cover:
		return
	_handles_cover = false
	var env: Object = server.get(&"envelope") if server != null else null
	if env != null and env.has_method("handle"):
				# The kind stays known (an advert cannot be taken back); with no handler the envelope drops it.
		env.call("handle", DotGameRoster.COVER_KIND, Callable())


func _on_cover_report(peer_id: int, payload: Dictionary) -> void:
	var covered: Variant = payload.get("covered")
	if roster == null or not (covered is bool):
		return
	roster.report_cover(peer_id, covered)


func _on_loading_changed(seat: int, loading: bool) -> void:
	loading_changed.emit(seat, loading)


## Whether [param seat]'s client is still behind its loading cover (joined, or a map change began, until it says the cover lifted), at most [member load_timeout_sec]. False for bots and anybody not in the game.
## What a hazard asks before it hurts somebody and round counting before it counts somebody out.
func is_loading(seat: int) -> bool:
	return roster != null and roster.is_loading(seat)


## [method is_loading] by peer id, which is what most server game code holds.
func is_peer_loading(peer_id: int) -> bool:
	return roster != null and roster.is_peer_loading(peer_id)


## Whether [param seat] may be damaged, eliminated or counted out now: not while loading; override to add reasons (a spawn shield).
func can_be_harmed(seat: int) -> bool:
	return not is_loading(seat)


## [method can_be_harmed] by peer id.
func can_peer_be_harmed(peer_id: int) -> bool:
	if roster == null:
		return true
	var seat := roster.seat_of_peer(peer_id)
	return seat < 0 or can_be_harmed(seat)


## Every seat still loading, sorted.
func loading_seats() -> PackedInt32Array:
	return roster.loading_seats() if roster != null else PackedInt32Array()


## A map change this game drives without [method report_map]: every seat is loading again until its client reports.
func mark_reloading() -> void:
	if roster != null:
		roster.mark_reloading()


## The spawn hook, kept here rather than handed to the roster directly.
##
## Moderation records are checked here, not at connect: dot-server's mute dies with its session, so a muted player would reconnect and talk.
func _on_client_spawn(event: DotEvent) -> void:
	if roster == null:
		return

		# Through the roster: `client_spawn` carries `userid` and `name`, not `peer_id`.
	var session := roster.session_of(event.get_int("userid"))

	if session == null:
		return

	if services != null and services.has_method("check_admission"):
		var admitted: Variant = services.call("check_admission", session)

		if admitted is DotResult and not (admitted as DotResult).ok:
			server.kick(session, (admitted as DotResult).error.message)
			return

	roster.add(session)


## One authoritative tick.
func _physics_process(delta: float) -> void:
	if not loaded or Engine.is_editor_hint():
		return

		# Before the tick gate: a timeout is wall-clock.
	if roster != null:
		roster.poll_loading()

	if not _can_tick():
		return

	tick += 1

	# The cvars are live: a config this addon filled in follows them; the game's own does not.
	if net != null and server != null and net.config != null:
		DotGameNetcode.follow_server_threads(net.config, server.config)

	if npc_lod != null:
		npc_lod.follow(delta)

	if bridge != null and bridge.has_method("server_tick"):
		bridge.call("server_tick", tick)

	_game_tick(tick, delta)


## Whether this frame may tick at all, asked before the counter moves. A game whose world can vanish under a loaded module answers false instead of overriding `_physics_process`.
func _can_tick() -> bool:
	return true


## Hands the server's hibernation to every clock under this module, and to [method _game_hibernation].
##
## Found, not registered: after [method _game_load] the subtree is searched for anything with `follow_hibernation(server)` (dot-vote's director, dot-map's session), so a game cannot forget it. Harmless twice; nothing on a server without the signal.
func _follow_hibernation() -> void:
	if server == null or not server.has_signal("hibernation_changed"):
		return

	var followed := 0

	for node in find_children("*", "", true, false):
		if node.has_method("follow_hibernation") and bool(node.call("follow_hibernation", server)):
			followed += 1

	if not server.hibernation_changed.is_connected(_on_hibernation_changed):
		server.hibernation_changed.connect(_on_hibernation_changed)

	DotLog.debug(CHANNEL, "following the server's hibernation", {
		"clocks": followed, "hibernating": server.is_hibernating(),
	})


func _on_hibernation_changed(hibernating: bool) -> void:
	_game_hibernation(hibernating)


## Tells the server which map this game is on, for A2S, DQP and the backbone report; "" clears it. Returns whether the server took it.
##
## Called by the game, which alone knows what it calls a map; the server forgets it on every unload. Duck-typed: an older server reports nothing and this says so once.
func report_map(map_id: String) -> bool:
	if map_id != _reported_map:
		_apply_map_config(map_id)
		# A different map is a map change; the first report is not one.
	if map_id != _reported_map and _reported_map != "":
		mark_reloading()
	_reported_map = map_id

	if server == null or server.games == null:
		return false

	if not server.games.has_method("set_current_map"):
		if not _warned_no_map_report:
			_warned_no_map_report = true
			DotLog.info(CHANNEL, "this server cannot be told the map; listings show the game", {
				"map": map_id,
			})
		return false

	server.games.call("set_current_map", map_id)
	return true


## The cvars a map's file may set: key -> `{type, min, max}` (dot-map's docs/map-config.md). Empty, the default, means this game takes no per-map settings.
func _map_config_keys() -> Dictionary:
	return {}


## The weakest layer: key -> value for a map with no file (the converter's defaults).
func _map_config_defaults() -> Dictionary:
	return {}


## The `cfg/game/<game>/dot_map/` folder's game name (the repository's, such as `game-arena`): `DotAddonConfig.game` when the host set it, else the module's name.
func _map_config_game() -> String:
	return DotAddonConfig.game if DotAddonConfig.game != "" else String(_module_name())


## The key's current value; the server console's cvar unless overridden.
func _map_config_get(key: String) -> Variant:
	if map_scripts != null and map_scripts.owns_key(key):
		return map_scripts.config_get(key)
	var cv: DotConVar = console.find_cvar(key) if console != null else null
	return cv.get_string() if cv != null else null


## Applies one value; false refuses it. The server console's cvar unless overridden.
func _map_config_set(key: String, value: Variant) -> bool:
	if map_scripts != null and map_scripts.owns_key(key):
		return map_scripts.config_set(key, value)
	return console != null and console.set_cvar(key, str(value)).ok


func _apply_map_config(map_id: String) -> void:
	if map_scripts != null:
		if map_scripts.console == null:
			map_scripts.console = console
		map_scripts.map_changed()
	if map_config == null:
		var keys := _map_config_keys()
		if map_scripts != null:
			keys.merge(map_scripts.config_keys())
		var defaults := _map_config_defaults()
		if keys.is_empty() and defaults.is_empty():
			return
		map_config = DotGameMapConfig.new()
		map_config.game_id = _map_config_game()
		map_config.keys = keys
		map_config.defaults = defaults
		map_config.get_fn = _map_config_get
		map_config.set_fn = _map_config_set
	map_config.apply(map_id)


func _module_unload() -> void:
	_game_unload()
	_teardown()


## Starts dot-cloud's auto-update once per headless server process, under the server. No-op without dot-cloud, on a listen server and in a browser.
static func start_auto_update(host: DotServer) -> Node:
	return DotGameModuleWiring.start_auto_update(host)


## Every delivered pack the server's games run, as `{id, version}` (games, dependencies, maps).
static func watched_packs(host: Object) -> Array:
	return DotGameModuleWiring.watched_packs(host)


## The block rules (teammates pass, enemies stop) when the game has a `body_rules`; null when off.
var noblock: DotGameNoblock = null


## Has the roster tell the relay's loadouts who joins and leaves.
func _follow_avatar_loadouts() -> void:
	DotGameModuleWiring.follow_loadouts(self)


func _bind_avatar_hooks() -> void:
	DotGameModuleWiring.bind_hooks(self)


## The avatar actions [param peer_id] may play as ids, or null for what the server read from the backbone. Default asks the game object.
func _avatar_actions_equipped(peer_id: int) -> Variant:
	if game != null and game.has_method(&"_avatar_actions_equipped"):
		return game.call(&"_avatar_actions_equipped", peer_id)
	return null


## True refuses [param id] for [param peer_id] now. Default asks the game object, else allows.
func _avatar_action_veto(peer_id: int, id: String) -> bool:
	if game != null and game.has_method(&"_avatar_action_veto"):
		return bool(game.call(&"_avatar_action_veto", peer_id, id))
	return false


## This server's id on the site, advertised as [constant DotGameAvatarContent.SERVER_CVAR]; 0 while unknown. Default: dot-auth's `server:<id>` audience.
func _site_server_id() -> int:
	var auth: Object = DotRegistry.get_service(&"dot_auth_server")
	if auth != null and auth.has_method(&"join_audience"):
		return DotGameAvatarContent.server_id_from_audience(String(auth.call(&"join_audience")))
	return 0


## Seconds between looks for the site id while dot-auth has not read it yet, and how many looks.
var site_server_retry_sec: float = 5.0
var site_server_retries: int = 24


func _advertise_site_server() -> void:
	DotGameModuleWiring.advertise_site_server(self)


## Content ids a client must download before it connects, published as `sv_avatar_content`. Default none.
func _avatar_content_required() -> Array:
	return []


func _advertise_avatar_content() -> void:
	DotGameModuleWiring.advertise_content(self)


## Whether to wire dot-team's block rules. A game with its own `block_rules` wired by hand is left alone.
func _noblock_enabled() -> bool:
	return game != null and "body_rules" in game and game.get("body_rules") != null \
		and not ("block_rules" in game and game.get("block_rules") != null)


## `(player id) -> side id` for teammates ("" or null for none); the game's `team_of` by default.
func _noblock_side(id: Variant) -> Variant:
	if game == null or not game.has_method(&"team_of"):
		return ""
	var team := int(game.call(&"team_of", int(id)))
	return str(team) if team > 0 else ""


## The game's `DotProfileRuntime`, so the workbench lists the `noblock` kind; null for none.
func _noblock_runtime() -> Object:
	return null


func _build_noblock() -> DotResult:
	return DotGameModuleWiring.build_noblock(self)


## Everything the sequence built, in the reverse order it was built in: the netcode is what the rest attached to, so freeing it first leaves them calling a freed object.
func _teardown() -> void:
	_detach_board()
	_release_cover_reports()

	if _set_peer_loading and game != null and is_instance_valid(game):
		game.set(PEER_LOADING_PROPERTY, Callable())
	_set_peer_loading = false
	_reported_map = ""
	if map_scripts != null:
		map_scripts.restore()
	if map_config != null:
		map_config.restore()
		map_config = null

	if server != null and server.hibernation_changed.is_connected(_on_hibernation_changed):
		server.hibernation_changed.disconnect(_on_hibernation_changed)

	if server != null and roster != null:
		if server.client_disconnected.is_connected(roster.on_client_disconnected):
			server.client_disconnected.disconnect(roster.on_client_disconnected)

	if roster != null:
		if roster.loading_changed.is_connected(_on_loading_changed):
			roster.loading_changed.disconnect(_on_loading_changed)
		roster.clear()
		roster = null

	_drop(services)
	services = null

		# The platform module goes with the identity layer that loaded it: it holds that layer's
		# hub, and left loaded it asked the freed hub to admit the next player (signal 11).
	if _loaded_platform and server != null and server.modules != null \
			and server.modules.has_module("platform"):
		server.modules.unload_module("platform")
	_loaded_platform = false

	_drop(identity)
	identity = null

	# The bridge before the manager it attached to.
	_drop(bridge)
	bridge = null

	if net != null:
		net.stop()
		_drop(net)
		net = null

	noblock = null
	game = null
	tick = 0


## Whether this module loaded dot-platform's module, and so has to unload it.
var _loaded_platform := false


func _drop(child: Node) -> void:
	if child == null or not is_instance_valid(child):
		return
	if child.get_parent() == self:
		remove_child(child)
	child.queue_free()


## Extends [DotModule]'s rather than replacing it: the base reports the counts the module host and `modules` read.
func describe() -> Dictionary:
	var out := super.describe()

	out.merge({
		"game": game != null,
		"netcode": net != null,
		"identity": identity != null,
		"services": services != null,
		"tick": tick,
		"loading": Array(loading_seats()),
	}, true)

	if roster != null:
		out["roster"] = roster.describe()

	return out


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray([
		"module     %s" % _module_name(),
		"game       %s" % ("yes" if game != null else "no"),
		"netcode    %s" % ("yes" if net != null else "no"),
		"identity   %s" % ("yes" if identity != null else "no"),
		"services   %s" % ("yes" if services != null else "no"),
		"tick       %d" % tick,
	])

	if map_config != null:
		lines.append_array(map_config.describe_lines())

	if roster != null:
		lines.append_array(roster.describe_lines())

	return lines
