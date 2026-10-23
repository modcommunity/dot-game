@tool
class_name DotGameModule
extends DotModule

## The order a server game is built in, written once.
##
## [b]Five games wrote this and they wrote the same thing.[/b] Resolve the game object
## out of [DotRegistry] and refuse to load without it; build the netcode and its bridge;
## load identity; build the services layer; keep a roster; drive one authoritative tick;
## unload it all in the reverse order. Between the five, the parts that actually differ
## are the classes being constructed and the numbers in the netcode config -- everything
## else was 200 lines of identical prose per game, including the comments explaining why
## the order is what it is.
##
## Subclass it and fill in what is yours:
##
## [codeblock]
## extends DotGameModule
##
## const MyBridge := preload("net/my_bridge.gd")
##
## func _module_name() -> String: return "mygame"
## func _game_service() -> StringName: return MyGame.SERVICE
##
## func _net_config() -> DotNetConfig:
##     var c := DotNetConfig.new()
##     c.tick_rate = game.tick_rate
##     c.snapshot_rate = 32
##     return c
##
## func _make_bridge() -> Node: return MyBridge.new()
##
## func _game_load() -> DotResult:
##     add_command("mygame_status", _cmd_status, "Show the match state")
##     return DotResult.success(null)
## [/codeblock]
##
## [b]What this is NOT.[/b] It holds no rules. Whether a round has ended, what a team is,
## what the objective is and who won are dot-match's and dot-objective's, and they stay
## theirs -- a game is free to use neither. This is the scaffolding those sit in, and the
## test for whether something belongs here is whether all five games would write it the
## same way with only the class names changed.
##
## [b]Nothing optional is named.[/b] dot-map, dot-vote, dot-platform and a game's own
## services are reached by duck-typing or by path, because a script that mentions an
## absent [code]class_name[/code] fails to parse and takes down everything referencing
## it. dot-core, dot-server and dot-net are declared dependencies and are named freely.

const CHANNEL := "game.module"

## Where dot-platform's module is loaded from, when a game asks for it.
##
## [b]By path, and it has to be.[/b] [method DotModuleHost.load_module] takes a path and
## constructs the module itself -- it must, because that is the shape that lets an
## operator name a module in a config file -- so a pre-built instance with its fields
## already assigned is thrown away and a fresh one made with them null. The hub is found
## through [DotRegistry] by the module it builds, which is why an identity layer has to
## register it.
const PLATFORM_MODULE_PATH := "res://addons/dot_platform/dot_platform_module.gd"
const LOOK_MUTE_SCRIPT := "res://addons/dot_voice/runtime/dot_voice_look_mute.gd"
## dot-cloud's server auto-update, loaded by path: dot-cloud is not a dependency.
const AUTO_UPDATE_SCRIPT := "res://addons/dot_cloud/server/dot_cloud_auto_update.gd"
const AUTO_UPDATE_SERVICE := &"dot_cloud_autoupdate"

## A seat's client went behind its loading cover ([param loading] true: it joined, or a map
## change began) or came out of it (its cover lifted, it timed out, it left). [param seat] is
## the userid, as everywhere in [DotGameRoster].
signal loading_changed(seat: int, loading: bool)

## The property a game object may declare to be handed [method is_peer_loading]:
## [code]var peer_loading_fn: Callable[/code]. Assigned before [method _game_load], cleared
## at unload. How a hazard inside the game asks without holding the module.
const PEER_LOADING_PROPERTY := &"peer_loading_fn"

## Seconds a seat may stay loading before it counts as loaded anyway, with a warning: the
## bound on how long anybody is unharmable, and what releases a client too old to say.
@export var load_timeout_sec: float = 30.0

## After a map change ([method report_map] with a new map, or [method mark_reloading]),
## seconds to wait for a client to say its cover went up again before counting it loaded.
@export var reload_grace_sec: float = 5.0

# --- What the skeleton holds ----------------------------------------------

## The game object, resolved from [DotRegistry] under [method _game_service].
var game: Object = null

## The netcode, or null for a game that declared no [method _net_config].
var net: DotNetManager = null

## The game's own bridge between itself and [member net]. Duck-typed.
var bridge: Node = null

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

## The map [method report_map] last reported; a different one re-marks every seat loading.
var _reported_map := ""

## Whether this module put its handler on the server's envelope, and the game's property.
var _handles_cover := false
var _set_peer_loading := false


# --- Subclass interface ----------------------------------------------------

## The [DotRegistry] name the game object publishes itself under. Required.
##
## Returning [code]&""[/code] means this module has no game object to find, which is
## legitimate for a game that is only a scene -- the rest of the sequence still runs.
func _game_service() -> StringName:
	return &""


## What to tell somebody whose game object is not there.
##
## The default names the service and says what to do. Override to name the class and
## the call, which is what the person reading the log actually needs.
func _game_missing_hint() -> String:
	return (
		"create it and call setup() before loading this module, and make sure it "
		+ "registers itself under '%s'" % String(_game_service())
	)


## The netcode settings, or null for a game that does not replicate.
##
## [b]There is no default and there must not be.[/b] Tick rate, snapshot rate and world
## extent are the game's own numbers; a default that is right for a deathmatch is wrong
## for a lobby, and a game running at a rate it did not choose is the kind of wrong
## nothing reports.
func _net_config() -> DotNetConfig:
	return null


## The operator's limits on [method _net_config], as a [DotNetConfig] property -> number
## [Dictionary]; see [method DotGameNetcode.cap] for the rule.
##
## The default reads [constant DotGameNetcode.CEILING_META] off the server, which is how a
## host (dot-server-deploy) hands its cfg over without the game knowing it exists. Override
## to source it elsewhere; an empty dictionary changes nothing.
func _net_ceiling() -> Dictionary:
	if server != null and server.has_meta(DotGameNetcode.CEILING_META):
		var v: Variant = server.get_meta(DotGameNetcode.CEILING_META)
		if v is Dictionary:
			return v
	return {}


## The game's bridge to the netcode. Required when [method _net_config] returns one.
##
## Duck-typed: it needs [code]attach(game, net) -> DotResult[/code] and
## [code]open_link(server)[/code], and [code]server_tick(tick)[/code] if it wants to be
## driven.
func _make_bridge() -> Node:
	return null


## Content, profiles, avatars and admission. Optional.
##
## Needs [code]setup() -> DotResult[/code]. Return null for a game that has none.
func _make_identity() -> Node:
	return null


## Whether to load dot-platform's module after the identity layer is up.
##
## On by default because every game in this family wants it and each one wrote the same
## four lines; a game with its own admission flow turns it off and loads its own.
func _wants_platform_module() -> bool:
	return true


## Chat, voice and moderation. Optional.
##
## Needs [code]setup(server, game, link) -> DotResult[/code], where `link` is the
## bridge's link or null.
func _make_services() -> Node:
	return null


## Everything this game wants that the skeleton does not know about.
##
## Runs LAST, after the netcode, identity, services and roster are up, so a command
## registered here can rely on all of them. Return a failure to refuse to load.
func _game_load() -> DotResult:
	return DotResult.success(null)


## Anything [method _game_load] set up that the helpers do not undo.
##
## Commands, cvars and hooks registered through [DotModule]'s helpers are already
## removed for you. This is for the rest.
func _game_unload() -> void:
	pass


## The server went to sleep ([param hibernating] true) or woke up, after every clock this
## module found has heard it. Optional.
##
## [b]For what only the game knows is a clock.[/b] A vote's [code]DotVoteDirector[/code] and
## a [code]DotMapSession[/code] anywhere under this module are followed for you (see
## [method _follow_hibernation]); a round timer, a warmup or a course clock in the game's
## own objects is not, because what "starting again" means for those is a rule, and rules
## are not this addon's. Reset them here on [code]false[/code]. Something that lives outside
## this module and has [code]follow_hibernation(server)[/code] can be handed the server here
## too, though [method _game_load] is the better place for that.
func _game_hibernation(_hibernating: bool) -> void:
	pass


## This game's own columns on the Tab board for one player: kills, points, a side, a
## status. Merged into that player's row of dot-server's roster, which already carries the
## name, score, ping and time connected. Optional; nothing added by default.
##
## [b]The server's half of every game's scoreboard[/b], and the only half that has to be
## here: a number only the server knows (money in a bank, a best time in a store) cannot
## be drawn by a client any other way. Keyed by the session; [member roster] is how a game
## finds its own player for one. dot-menu's `DotMenuScoreboard` draws the result.
func _game_board_fields(_session: Object) -> Dictionary:
	return {}


## Everything else on the board: `"teams"` (`[{id, name, color, score}]`), a `"header"`
## of the round's facts, `"rows"` for players who are not sessions. Optional.
func _game_board_extra() -> Dictionary:
	return {}


## One authoritative tick, after the bridge has been driven.
##
## [b]The bridge ticks first and this cannot be the other way round.[/b] The game's own
## simulation happens INSIDE the netcode's tick -- between applying each peer's inputs
## and building the snapshot -- which is what the bridge arranges. Anything a game wants
## to do with wall-clock-ish time (a map clock, a vote clock) belongs here, driven by the
## simulated tick rather than by the frame, so a server that stalls does not lose that
## time off its map and a test can run an hour of them in a second.
func _game_tick(_tick: int, _delta: float) -> void:
	pass


# --- The sequence ----------------------------------------------------------

## Builds the game, in the one order that works.
##
## [b]Netcode is fatal and everything after it is not, and that split is the whole
## design.[/b] A game with no netcode is a server that accepts players into nothing, so
## refusing to load is the honest answer. A game with no chat, no rotation and no vote is
## a server nobody stays on -- but it is a server, and taking the whole thing down
## because a punishment file was unreadable means a permissions mistake costs the players
## the game they came for.
func _module_load() -> DotResult:
	var service := _game_service()

	if service != &"":
		game = DotRegistry.get_node_service(service)

		if game == null:
			# Refusing is right: a module that loaded and did nothing leaves a server
			# admitting players into a match that does not exist, and the symptom is
			# players who connect and never spawn.
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

	var identified: DotResult = await _build_identity()
	DotLog.result(CHANNEL, "the identity layer", identified)

	var serviced: DotResult = await _build_services()
	DotLog.result(CHANNEL, "chat, voice and moderation", serviced)

	_build_roster()

	var loaded: DotResult = await _game_load()

	if not loaded.ok:
		# The game refused, so everything built above it comes down -- otherwise a
		# module that reported it could not load leaves a ticking netcode and an open
		# link behind, under a node the host is about to free.
		_teardown()
		return loaded

	_follow_hibernation()
	_attach_board()
	start_auto_update(server)

	log_info("%s loaded" % _module_name(), describe())
	return DotResult.success(null)


## Hands dot-server's Tab board this game's columns. Asked rather than assumed: a game pack
## runs on whatever dot-server the host has, and one from before the roster has neither
## property, which a plain assignment would turn into a script error at load.
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

	# Awaited and typed. Everything in this chain may reach a network -- a content
	# source, a profile store, an avatar store -- so every one of them is a coroutine,
	# and an un-awaited GDScript coroutine returns at its first suspension: the check
	# below would be testing a property of a Signal.
	var ready: Variant = await identity.call("setup")

	if not (ready is DotResult) or not (ready as DotResult).ok:
		_drop(identity)
		identity = null
		return ready if ready is DotResult else DotResult.fail(
			DotError.CODE_INTERNAL, "The identity layer's setup() returned no result."
		)

	if _wants_platform_module() and server != null and server.modules != null:
		if not server.modules.has_module("platform"):
			# Awaited: loading a module runs its `_module_load`, which is allowed to be
			# a coroutine and for dot-platform is one.
			var loaded: DotResult = await server.modules.load_module(
				PLATFORM_MODULE_PATH
			)

			_loaded_platform = loaded.ok

			if not loaded.ok:
				# Reported, not fatal. A server without the platform module is a
				# server where everybody is a guest, which is a configuration rather
				# than a breakage.
				DotLog.result(CHANNEL, "the platform module", loaded)

	return DotResult.success(identity)


## Builds the services layer over whatever link the bridge opened.
func _build_services() -> DotResult:
	services = _make_services()

	if services == null:
		return DotResult.success(null)

	services.name = "Services"

	# [b]Before `setup`, not after.[/b] A services layer builds its relay inside setup,
	# and a backbone assigned afterwards is one the relay has already decided it does not
	# have -- the same ordering mistake that left dot-server's audit log unopened in
	# every default configuration.
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

	# Voice arrives on the link, is relayed by the router, and goes back out on the
	# link. The bridge is the only thing that names both ends, which is why this is set
	# here rather than either of them knowing about the other.
	if bridge != null and "voice_relay_fn" in bridge and services.has_method("relay_voice"):
		bridge.set("voice_relay_fn", Callable(services, "relay_voice"))

	# sv_voice_enable and sv_voice_mode, on the router: enforced there, replicated so every
	# client hides its talk key while voice is off. Registered through this module so they go
	# when it unloads, and read back so a value content.yml set before the game loaded wins.
	# Duck-typed: dot-voice is loaded by path, and an older one has no bind_cvars.
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

	roster.follow(services)

	# Through the module's own helper, so it is unhooked when this unloads: a hook left
	# pointing at a freed module is a server that crashes on the next spawn.
	hook_post("client_spawn", _on_client_spawn)

	if server != null:
		server.client_disconnected.connect(roster.on_client_disconnected)


## Puts this module's handler for [constant DotGameRoster.COVER_KIND] on the server's envelope.
##
## [b]A kind on the existing envelope, not a new RPC or a dot-net message.[/b] The RPC set is
## frozen (a new one is a protocol break for every shipped client), and the game's bridge is
## each game's own, so a kind here is the one channel every client already has. Optional, so
## a client that predates it joins and is released by the timeout. Duck-typed, so a game
## still loads on a dot-server from before the envelope. A client only sends a kind the
## server advertised at its challenge, so a client that joined before any game on this base
## loaded is not heard from either: the timeout covers it the same way.
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
		# The kind stays known (an advert already sent cannot be taken back); with no
		# handler the envelope drops an arrival with a DEBUG line.
		env.call("handle", DotGameRoster.COVER_KIND, Callable())


func _on_cover_report(peer_id: int, payload: Dictionary) -> void:
	var covered: Variant = payload.get("covered")
	if roster == null or not (covered is bool):
		return
	roster.report_cover(peer_id, covered)


func _on_loading_changed(seat: int, loading: bool) -> void:
	loading_changed.emit(seat, loading)


# --- Still loading -------------------------------------------------------------------

## Whether [param seat]'s client is still behind its loading cover: from joining until the
## client says its cover lifted, and again from a map change until it says so again, at most
## [member load_timeout_sec]. False for bots, anybody not in the game, and offline.
##
## [b]What a hazard asks before it hurts somebody[/b], and what round counting asks before
## it counts somebody out: a player still loading cannot see, and has been frozen by their
## own client.
func is_loading(seat: int) -> bool:
	return roster != null and roster.is_loading(seat)


## [method is_loading] by peer id, which is what most server game code holds.
func is_peer_loading(peer_id: int) -> bool:
	return roster != null and roster.is_peer_loading(peer_id)


## Whether [param seat] may be damaged, eliminated or counted out now. Not while loading, by
## default; override to add the game's own reasons (a spawn shield).
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


## A map change this game drives without [method report_map] (a new round's layout, a
## rebuilt level): every seat is loading again until its client reports. [method report_map]
## with a different map calls this for you.
func mark_reloading() -> void:
	if roster != null:
		roster.mark_reloading()


## The spawn hook, kept here rather than handed to the roster directly.
##
## dot-moderation's records are checked between the event and the roster, and they are
## checked HERE rather than at connect: dot-server's own mute is two booleans on a
## session and a session dies with its connection, so a muted player reconnects and
## talks. Both gates run -- dot-server's admission first, this second.
func _on_client_spawn(event: DotEvent) -> void:
	if roster == null:
		return

	# Through the roster, which owns the lookup: `client_spawn` carries `userid` and
	# `name` and NOT `peer_id`, and that one field is what two games in this family got
	# wrong. It is written once, in [DotGameRoster], where a suite can substitute it.
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

	# Before the tick gate: a timeout is wall-clock, and a world that cannot tick is no
	# reason to keep somebody marked loading past it.
	if roster != null:
		roster.poll_loading()

	if not _can_tick():
		return

	tick += 1

	# The cvars are live: a config this addon filled in follows them; the game's own does not.
	if net != null and server != null and net.config != null:
		DotGameNetcode.follow_server_threads(net.config, server.config)

	if bridge != null and bridge.has_method("server_tick"):
		bridge.call("server_tick", tick)

	_game_tick(tick, delta)


## Whether this frame may tick at all. Asked before the counter moves, so a skipped frame
## is not a tick anybody sees.
##
## [b]True by default.[/b] A game whose world can go away underneath a loaded module —
## a game change frees the scene before the module hears about it, and a freed Object is
## not null — answers false while there is nothing to tick, rather than
## overriding `_physics_process` and re-implementing the order above.
func _can_tick() -> bool:
	return true


## Hands the server's hibernation to every clock under this module, and to
## [method _game_hibernation].
##
## [b]Found, not registered.[/b] Every game here builds its vote as a child of its module —
## a wrapper holding a [code]DotVoteDirector[/code] — and each would otherwise write the same
## line to follow the server, and the one that forgot it would run its map clock out over an
## empty room and hand the first player a map with a minute left. So after
## [method _game_load] the subtree is searched for anything answering
## [code]follow_hibernation(server)[/code] (dot-vote's director, dot-map's session) and each
## is handed the server, which is duck-typed on both ends. Calling it twice is harmless.
##
## A server from before [signal DotServer.hibernation_changed] has no such signal and nothing
## is followed; the game runs as it always did.
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


## Tells the server which map this game is on, so A2S and DQP print it in their map field
## and the backbone report carries it. "" clears it.
##
## [b]Called by the game, because only the game knows what it calls a map[/b] — a course,
## an arena from a rotation, a round's layout, a mode's preset. A game that never calls it
## is listed under its own name, which is right for a game with one map. The server forgets
## the map every time a game unloads, so a game that changes map calls this again rather
## than once at load.
##
## [b]Duck-typed[/b], so a game built against this addon still loads on a server from before
## `DotGameManager.set_current_map` existed; it reports nothing there and says so once.
## Returns whether the server took it.
func report_map(map_id: String) -> bool:
	# A different map is a map change: every client covers for it, so every seat is loading
	# again. The first report is not one (nobody has seen a map yet), and the same map again
	# changes nothing.
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


func _module_unload() -> void:
	_game_unload()
	_teardown()


## Starts dot-cloud's auto-update once per headless server process, under the server so a
## game change keeps it. A no-op without dot-cloud, on a listen server and in a browser.
static func start_auto_update(host: DotServer) -> Node:
	if host == null or not DotPlatform.is_headless() or not ResourceLoader.exists(AUTO_UPDATE_SCRIPT):
		return null
	var existing := DotRegistry.get_node_service(AUTO_UPDATE_SERVICE)
	if existing != null:
		return existing
	var script := load(AUTO_UPDATE_SCRIPT) as Script
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


## Every delivered pack the server's games run, as `{id, version}`: each game's own, its
## dependencies, server dependencies and maps. Games built into the binary add nothing.
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


## Everything the sequence built, in the reverse order it was built in.
##
## [b]Reverse, and the order is not cosmetic.[/b] Services hold a callable the bridge
## calls, the roster holds subsystems it notifies, and the netcode is what everything
## else was attached to -- so tearing the netcode down first leaves each of the others
## calling into a freed object for as long as it takes them to notice, which is never.
func _teardown() -> void:
	_detach_board()
	_release_cover_reports()

	if _set_peer_loading and game != null and is_instance_valid(game):
		game.set(PEER_LOADING_PROPERTY, Callable())
	_set_peer_loading = false
	_reported_map = ""

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

	# [b]The platform module goes with the identity layer that loaded it.[/b] It holds the
	# hub `identity` built, and a game change frees that hub: left loaded, the module asked
	# the freed hub to admit the next player who connected, which crashed the server
	# (signal 11, on the first spawn after `changelevel` away from mg-buses-from-hell).
	# Unloaded here, the next game that wants one loads its own over its own hub.
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


## [b]Extends [DotModule]'s rather than replacing it.[/b] The base reports the counts a
## module host and the `modules` command read -- `commands` among them, which
## [method DotModuleHost.load_module] used to index blindly -- and an override that
## starts from an empty Dictionary silently removes them from every caller. The family
## convention is that `describe()` is a dump of runtime state; a subclass adds to that
## dump, it does not become it.
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

	if roster != null:
		lines.append_array(roster.describe_lines())

	return lines
