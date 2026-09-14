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
