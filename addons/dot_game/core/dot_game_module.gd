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

	log_info("%s loaded" % _module_name(), describe())
	return DotResult.success(null)


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

	return DotResult.success(services)


## Wires the roster to the bridge and to whatever else wants to know.
func _build_roster() -> void:
	roster = DotGameRoster.new()
	roster.server = server

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

	tick += 1

	if bridge != null and bridge.has_method("server_tick"):
		bridge.call("server_tick", tick)

	_game_tick(tick, delta)


func _module_unload() -> void:
	_game_unload()
	_teardown()


## Everything the sequence built, in the reverse order it was built in.
##
## [b]Reverse, and the order is not cosmetic.[/b] Services hold a callable the bridge
## calls, the roster holds subsystems it notifies, and the netcode is what everything
## else was attached to -- so tearing the netcode down first leaves each of the others
## calling into a freed object for as long as it takes them to notice, which is never.
func _teardown() -> void:
	if server != null and roster != null:
		if server.client_disconnected.is_connected(roster.on_client_disconnected):
			server.client_disconnected.disconnect(roster.on_client_disconnected)

	if roster != null:
		roster.clear()
		roster = null

	_drop(services)
	services = null

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
