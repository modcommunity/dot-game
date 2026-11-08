@tool
class_name DotGameNetcode
extends Object

## Builds a server's [DotNetManager] and attaches the game's bridge to it.
##
## `auto_tick = false` because the game's tick runs inside the netcode's (a second ticker doubles speed), `config_file = ""` so a stale user file cannot change the game's rates, `local_peer_id = 1` as the authority. [method DotNetMessageRegistry.seal] runs LAST: a type registered after it renumbers every wire id.

const CHANNEL := "game.netcode"

const _Relevance := preload("res://addons/dot_game/net/dot_game_relevance.gd")

## The [DotServer] meta an operator tool sets to a [Dictionary] of [DotNetConfig] property -> number, read by [method DotGameModule._net_ceiling].
## Meta rather than a static: a process may hold two servers, and the ceiling belongs to its operator's.
const CEILING_META := &"dot_net_ceiling"

## Properties where the operator's number is a ceiling (0 on either side = no limit from
## that side). Resource limits: an operator protecting a link or a box wants "no more
## than", and a game that asks for less is already inside it.
const CEILING_KEYS: PackedStringArray = [
	"per_client_budget", "per_client_packet_rate", "mtu", "max_entities_per_snapshot",
	"snapshot_rate",
]

## Properties where a number the operator wrote REPLACES the game's. The interpolation
## buffer is a smoothness-versus-latency trade, not a resource limit: a ceiling could only
## shorten it, but the operator who sets it is on a jittery network and wants it longer.
const OVERRIDE_KEYS: PackedStringArray = ["interpolation_buffer", "far_every", "far_distance"]

## Ceilings in metres: the smaller of the operator's and the game's relevance radius (0 is no limit).
const RADIUS_CEILING_KEYS: PackedStringArray = ["interest_radius"]


## Builds the manager, attaches the bridge, seals the schema and starts.
##
## [param parent] is what both are added under. [param bridge] is duck-typed (this addon cannot know its class): it needs `attach(game, net) -> DotResult` and `open_link(server)`. Returns a [Dictionary] with [code]net[/code] and [code]bridge[/code].
static func build(
	parent: Node,
	server: DotServer,
	game: Object,
	config: DotNetConfig,
	bridge: Node
) -> DotResult:
	if parent == null:
		return DotResult.fail(DotError.CODE_INVALID, "No parent to build under.")

	if config == null:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A game has to say what its netcode is.",
			"tick rate, snapshot rate and world extent are the game's numbers, not "
			+ "this addon's -- there is no default that is right for two games"
		)

	if bridge == null:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A game has to supply the bridge between itself and the netcode."
		)

	var net := DotNetManager.new()
	net.name = "Net"
	net.is_server = true
	net.local_peer_id = 1
	net.auto_tick = false
	net.config_file = ""
	net.config = config
	parent.add_child(net)

	var started := net.setup()

	if not started.ok:
		_drop(parent, net)
		return started.wrap("the netcode manager would not set up")

	bridge.name = "Bridge"
	parent.add_child(bridge)

	if not bridge.has_method("attach"):
		_drop(parent, bridge)
		_drop(parent, net)
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"The bridge does not speak the bridge interface.",
			"no attach(game, net) on %s" % bridge.get_class()
		)

	var attached: Variant = bridge.call("attach", game, net)

	if not (attached is DotResult):
		_drop(parent, bridge)
		_drop(parent, net)
		return DotResult.fail(
			DotError.CODE_INTERNAL,
			"The bridge's attach() returned something that is not a DotResult.",
			str(attached)
		)

	if not (attached as DotResult).ok:
		_drop(parent, bridge)
		_drop(parent, net)
		return (attached as DotResult).wrap("the bridge would not attach")

		# Under the DotServer node: its name is half the RPC route, and the client parents its
		# copy under a matching DotClientLink. Elsewhere, messages land nowhere with no error.
	if server != null and bridge.has_method("open_link"):
		bridge.call("open_link", server)

		# [b]A client whose message schema cannot work with this one is dropped, in words.[/b]
		# dot-net only compares the tables and owns no socket; without this the client would sit
		# in the game with nothing decoded.
	if server != null:
		net.peer_schema_refused.connect(func(peer_id: int, error: DotError) -> void:
			refuse_peer(server, peer_id, error))

	# Avatar actions ride on every game's manager; the type is not required, so a client that
	# never registered it still plays.
	var avatar := DotGameAvatarActionRelay.serve(net, game)
	if not avatar.ok:
		DotLog.warn(CHANNEL, "avatar actions not served", {"why": avatar.error.message})

	# The remote workbench frame; inert until a DotGameWorkbench calls serve_remote and sv_workbench_remote is 1.
	var bench := DotGameWorkbenchRemote.serve(net)
	if not bench.ok:
		DotLog.warn(CHANNEL, "remote workbench not served", {"why": bench.error.message})

	# After the bridge, never before: see the class note.
	net.messages.seal()
	if server != null:
		_Relevance.bind(server.console, net, server.get_meta(CEILING_META, {}) if server.has_meta(CEILING_META) else {})

	var running := net.start()

	if not running.ok:
		_drop(parent, bridge)
		_drop(parent, net)
		return running.wrap("the netcode would not start")

	DotLog.info(CHANNEL, "netcode ready", {
		"tick_rate": config.tick_rate,
		"snapshot_rate": config.snapshot_rate,
		"schema": net.messages.schema_hash().substr(0, 12),
	})

	return DotResult.success({"net": net, "bridge": bridge})


## See [method DotGameModule.use_map_visibility].
static func attach_visibility(net: Object, world: Object, bounds: AABB = AABB()) -> bool:
	return _Relevance.attach_visibility(net, world, bounds)


## Copies the server's snapshot worker count ([method DotServerConfig.net_snapshot_workers]) into [member DotNetConfig.snapshot_workers], unless the game set one itself.
##
## An explicit game value wins (0 is "not set"). Returns whether [param config] follows the server, so the caller re-calls it each tick only for a config that does. [param server_config] is duck-typed.
static func follow_server_threads(config: DotNetConfig, server_config: Object) -> bool:
	if config == null:
		return false
	_follow_server_native(config, server_config)
	if config.snapshot_workers != 0 and not config.has_meta(THREADS_FOLLOW_META):
		return false
	if server_config == null or not server_config.has_method("net_snapshot_workers"):
		return false
	config.set_meta(THREADS_FOLLOW_META, true)
	config.snapshot_workers = int(server_config.call("net_snapshot_workers"))
	return true


## ORs the server's [code]net_native[/code] and [code]net_native_interest[/code] cvars into [member DotNetConfig.native] and [member DotNetConfig.native_interest]: the game's own
## true (its config, DOT_NET_NATIVE, --net-native) stays on whatever the operator says.
static func _follow_server_native(config: DotNetConfig, server_config: Object) -> void:
	if server_config == null or not ("net_native" in server_config):
		return
	if not config.has_meta(NATIVE_OWN_META):
		config.set_meta(NATIVE_OWN_META, config.native)
	config.native = bool(config.get_meta(NATIVE_OWN_META)) or bool(server_config.get("net_native"))
	if "net_native_interest" in server_config:
		if not config.has_meta(NATIVE_INTEREST_OWN_META):
			config.set_meta(NATIVE_INTEREST_OWN_META, config.native_interest)
		config.native_interest = bool(config.get_meta(NATIVE_INTEREST_OWN_META)) \
			or bool(server_config.get("net_native_interest"))


## What [member DotNetConfig.native] was before this addon first followed the server.
const NATIVE_OWN_META := &"dot_game_native_own"
const NATIVE_INTEREST_OWN_META := &"dot_game_native_interest_own"


const _MapThreads := preload("res://addons/dot_game/runtime/dot_game_map_threads.gd")


## Registers `map_load_threads` on [param console] when it is missing, then copies its value into dot-map's default worker count; call it before the first world loads and every tick after. A no-op without a console or dot-map.
static func follow_map_threads(console: DotConsole) -> void:
	if console == null:
		return
	if console.find_cvar(_MapThreads.CVAR) == null:
		var _cv := _MapThreads.ensure_cvar(console)
	_MapThreads.follow(console)


## Marks a [DotNetConfig] whose snapshot_workers this addon wrote, so a later call knows the
## value is its own and not the game's.
const THREADS_FOLLOW_META := &"dot_game_follows_server_threads"


## Applies an operator's [param ceiling] to the game's [param config], in place; returns one line per change, for the caller to log.
##
## Effective value is min(game, operator) and 0 on either side means no limit from that side. The snapshot rate is forced to a divisor of the tick rate, which [method DotNetConfig.validate] requires.
static func cap(config: DotNetConfig, ceiling: Dictionary) -> PackedStringArray:
	var changes := PackedStringArray()

	if config == null:
		return changes

	for key in OVERRIDE_KEYS:
		if not ceiling.has(key):
			continue
		var wanted: Variant = ceiling[key]
		if not is_equal_approx(float(config.get(key)), float(wanted)):
			changes.append("%s %s -> %s (operator)" % [key, config.get(key), wanted])
			config.set(key, wanted)

	# Off unless the operator asks: spreads peers over the ticks between snapshots, which only
	# helps when the snapshot rate is under the tick rate (sv_tickrate 30 with a snapshot cap of 15).
	if ceiling.has("stagger_snapshots") and config.stagger_snapshots != (int(ceiling["stagger_snapshots"]) != 0):
		config.stagger_snapshots = int(ceiling["stagger_snapshots"]) != 0
		changes.append("stagger_snapshots -> %s (operator)" % config.stagger_snapshots)

	for key in CEILING_KEYS:
		if not ceiling.has(key) or key == "snapshot_rate":
			continue
		var limit := int(ceiling[key])
		var have := int(config.get(key))
		if limit <= 0:
			continue
		if have <= 0 or have > limit:
			changes.append("%s %d -> %d" % [key, have, limit])
			config.set(key, limit)

	for key in RADIUS_CEILING_KEYS:
		if not ceiling.has(key) or float(ceiling[key]) <= 0.0:
			continue
		var cap_m := float(ceiling[key])
		if float(config.get(key)) <= 0.0 or float(config.get(key)) > cap_m:
			changes.append("%s %s -> %s" % [key, config.get(key), cap_m])
			config.set(key, cap_m)

	var rate := config.snapshot_rate
	if ceiling.has("snapshot_rate") and int(ceiling["snapshot_rate"]) > 0:
		rate = mini(rate, int(ceiling["snapshot_rate"]))
	rate = mini(rate, config.tick_rate)
	while rate > 1 and config.tick_rate % rate != 0:
		rate -= 1
	rate = maxi(rate, 1)
	# Only when the operator asked: a game's own uneven rate is its business (validate warns).
	if rate != config.snapshot_rate and ceiling.has("snapshot_rate"):
		changes.append("snapshot_rate %d -> %d (tick %d)" % [config.snapshot_rate, rate, config.tick_rate])
		config.snapshot_rate = rate

	return changes


## Snapshot rate by server size: the most slots up to which a rate is kept, and the rate cap past it. A snapshot costs about peers times entities, so it grows with the square of the team.
const AUTO_RATE_TIERS: Array[Vector2i] = [Vector2i(32, 0), Vector2i(64, 20), Vector2i(128, 16), Vector2i(4096, 10)]


## Lowers [member DotNetConfig.snapshot_rate] for a server of [param slots] (see [constant AUTO_RATE_TIERS]) to a divisor of the tick rate, never raises it. It also staggers the peers over the ticks between snapshots, so the cost is not one spike. Cvar `net_snapshot_auto` 0 turns it off; an operator's own `snapshot_rate` ceiling is applied before this and still wins. Returns the change as a log line, or "".
static func adapt_snapshot_rate(config: DotNetConfig, slots: int) -> String:
	if config == null:
		return ""
	var limit := 0
	for tier in AUTO_RATE_TIERS:
		if slots <= tier.x:
			limit = tier.y
			break
	if limit <= 0 or config.snapshot_rate <= limit:
		return ""
	var rate := mini(limit, config.tick_rate)
	while rate > 1 and config.tick_rate % rate != 0:
		rate -= 1
	if rate >= config.snapshot_rate:
		return ""
	var line := "snapshot_rate %d -> %d (%d slots, tick %d)" % [config.snapshot_rate, rate, slots, config.tick_rate]
	config.snapshot_rate = rate
	if config.ticks_per_snapshot() > 1:
		config.stagger_snapshots = true
		line += ", staggered"
	return line


## Disconnects a peer whose message schema this server cannot play with.
##
## Public for a game that builds its own [DotNetManager].
static func refuse_peer(server: DotServer, peer_id: int, error: DotError) -> void:
	if server == null:
		return
	var session := server.session_of(peer_id)
	if session == null:
		return
	DotLog.info(CHANNEL, "client refused: its game messages cannot work with this server's", {
		"user": session.label(), "why": error.message, "detail": error.detail,
	})
	server.kick(session, error.message, error)


## Removes and frees a node this builder put in the tree.
##
## Every failure path unwinds what it built, so a failed load leaves no ticking manager. `queue_free`, because the failing call may still be on the stack.
static func _drop(parent: Node, child: Node) -> void:
	if child == null or not is_instance_valid(child):
		return
	if child.get_parent() == parent:
		parent.remove_child(child)
	child.queue_free()
