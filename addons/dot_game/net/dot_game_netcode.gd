@tool
class_name DotGameNetcode
extends Object

## Builds a server's [DotNetManager] and attaches the game's bridge to it.
##
## [b]Five games wrote this function and they wrote it the same way.[/b] A manager with
## [code]is_server[/code], [code]local_peer_id = 1[/code], [code]auto_tick = false[/code]
## and [code]config_file = ""[/code]; a [DotNetConfig] the game supplies; [method
## DotNetManager.setup]; a bridge; [code]attach(game, net)[/code];
## [code]open_link(server)[/code]; [method DotNetMessageRegistry.seal]; [method
## DotNetManager.start]. The only parts that differ between them are the config numbers
## and the bridge's class, and both are arguments here.
##
## [b]Four of those constants are load-bearing and each one has a failure behind it.[/b]
##
## [code]auto_tick = false[/code] -- the game's tick has to happen INSIDE the netcode's,
## between applying each peer's inputs and building the snapshot, which is what the
## bridge's [code]server_tick[/code] arranges. A manager ticking itself as well moves
## every player twice, and what that looks like is a game running at double speed only
## when somebody is connected.
##
## [code]config_file = ""[/code] -- the manager reads a JSON file by default, so a
## server with a stale [code]user://dot_net.json[/code] runs at a tick rate the game did
## not choose and nothing says so. A game's netcode settings are the game's.
##
## [code]local_peer_id = 1[/code] -- the authority's id in Godot's multiplayer is 1, and
## the bridge routes by it.
##
## [method DotNetMessageRegistry.seal] LAST, after the bridge has registered its message
## types: wire ids are assigned from a sort of the registered names, so a type
## registered after the seal renumbers every id above it and silently reinterprets every
## message. The seal is what turns that from a mystery into a refusal.
##
## [codeblock]
## var built := DotGameNetcode.build(self, server, game, config, MyBridge.new())
## if not built.ok:
##     return built.wrap("the netcode could not start")
## net = built.value["net"]
## bridge = built.value["bridge"]
## [/codeblock]

const CHANNEL := "game.netcode"

## The [DotServer] meta an operator tool sets to a [Dictionary] of [DotNetConfig] property
## -> number, read by [method DotGameModule._net_ceiling]. Meta on the server, not a
## registry entry or a static: a process may hold a server and a client (or two servers),
## and the ceiling belongs to the one whose operator wrote it.
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
const OVERRIDE_KEYS: PackedStringArray = ["interpolation_buffer"]


## Builds the manager, attaches the bridge, seals the schema and starts.
##
## [param parent] is the node both are added under -- normally the module, so they go
## away with it. [param bridge] is duck-typed on purpose: it is the game's own class,
## this addon must not know its name, and what is required of it is
## [code]attach(game, net) -> DotResult[/code] and [code]open_link(server)[/code].
##
## Returns a [Dictionary] with [code]net[/code] and [code]bridge[/code], so a caller
## gets both halves from one call and cannot end up holding a manager whose bridge
## failed to attach.
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

	# Under the DotServer node, whose name is the first half of the RPC routing: the
	# client parents its copy under DotClientLink, which is named to match. A bridge
	# opened anywhere else is addressed by a path the other end does not have, and every
	# message lands nowhere with no error on either side.
	if server != null and bridge.has_method("open_link"):
		bridge.call("open_link", server)

	# [b]A client whose message schema cannot work with this one is dropped, in words.[/b]
	# dot-net compares the two tables when the client's arrives and refuses a pair where
	# either lacks a type the other REQUIRES -- but it owns no socket, so it can only say
	# so. Without this the client would sit in the game with nothing it sends decoded and
	# nothing it is sent understood; with it, it is disconnected with the sentence dot-net
	# chose, which says who has to update.
	if server != null:
		net.peer_schema_refused.connect(func(peer_id: int, error: DotError) -> void:
			refuse_peer(server, peer_id, error))

	# Avatar actions ride on every game's manager; the type is not required, so a client that
	# never registered it still plays.
	var avatar := DotGameAvatarActionRelay.serve(net, game)
	if not avatar.ok:
		DotLog.warn(CHANNEL, "avatar actions not served", {"why": avatar.error.message})

	# After the bridge, never before: see the class note.
	net.messages.seal()

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


## Copies the server's snapshot worker count ([method DotServerConfig.net_snapshot_workers],
## cvars [code]sv_threads_net[/code] and [code]sv_worker_threads[/code]) into
## [member DotNetConfig.snapshot_workers], unless the game set one itself.
##
## [b]An explicit value in the game's config wins, and 0 is "not set"[/b]: dot-net's default is
## off, so a game that wrote a number meant it and an operator's switch must not undo it. Returns
## whether [param config] follows the server (the caller calls this again each tick so the
## cvars stay live, and only for a config that does). [param server_config] is duck-typed so
## this addon does not need dot-server's class to parse.
static func follow_server_threads(config: DotNetConfig, server_config: Object) -> bool:
	if config == null:
		return false
	if config.snapshot_workers != 0 and not config.has_meta(THREADS_FOLLOW_META):
		return false
	if server_config == null or not server_config.has_method("net_snapshot_workers"):
		return false
	config.set_meta(THREADS_FOLLOW_META, true)
	config.snapshot_workers = int(server_config.call("net_snapshot_workers"))
	return true


## Marks a [DotNetConfig] whose snapshot_workers this addon wrote, so a later call knows the
## value is its own and not the game's.
const THREADS_FOLLOW_META := &"dot_game_follows_server_threads"


## Applies an operator's [param ceiling] to the game's [param config], in place.
##
## [b]Effective value = min(game, operator), and 0 on either side means no limit from that
## side[/b] (dot-net reads [code]<= 0[/code] as unlimited for the budget, the packet rate
## and the entity cap), so a game that is unlimited takes the operator's number and an
## operator who wrote 0 leaves the game's. Keys absent from the ceiling are untouched.
## The snapshot rate is further forced to a divisor of the tick rate, because
## [method DotNetConfig.validate] refuses a rate above the tick and warns on an uneven one.
##
## Returns one line per thing changed, for the caller to log.
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


## Disconnects a peer whose message schema this server cannot play with.
##
## Public for a game on dot-game that builds its own [DotNetManager]. The four games
## that do not link dot-game carry the same three lines in their modules.
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
## [b]Every failure path unwinds what it built.[/b] A half-built netcode left parented is
## a manager that ticks, a bridge with an open link, or both, under a module that
## reported it could not load -- and the module is then unloaded while its children go on
## running. `queue_free` rather than `free`, because the failing call above may still be
## on the stack.
static func _drop(parent: Node, child: Node) -> void:
	if child == null or not is_instance_valid(child):
		return
	if child.get_parent() == parent:
		parent.remove_child(child)
	child.queue_free()
