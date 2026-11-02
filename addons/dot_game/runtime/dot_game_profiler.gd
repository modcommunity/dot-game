extends RefCounted

## Places dot-profiler for a game, client and server, from one spot so no game wires it.
## No class_name: callers preload it. dot-profiler is optional and located by path, so a build without it parses and runs.

const CHANNEL := "game.profiler"
const SCRIPT := "res://addons/dot_profiler/runtime/dot_profiler.gd"
const SERVER_SCRIPT := "res://addons/dot_profiler/runtime/dot_profiler_server.gd"
const NODE_NAME := "Profiler"
const OFF_FLAG := "--no-profiler"
const OFF_ENV := "DOT_GAME_PROFILER"


## False when the operator turned the placement off: `--no-profiler` or DOT_GAME_PROFILER=0.
static func wanted() -> bool:
	if OFF_FLAG in OS.get_cmdline_user_args() or OFF_FLAG in OS.get_cmdline_args():
		return false
	return OS.get_environment(OFF_ENV) != "0"


## Adds the profiler under [param host] (the Performance tab then appears in the menu). Null when it is off, not in this build, or already placed.
## It watches no frames until profiler_enabled or a recording turns that on, so an idle one costs nothing.
static func add(host: Node) -> Node:
	if not wanted() or not ResourceLoader.exists(SCRIPT) or host.get_node_or_null(NODE_NAME) != null:
		return null
	if DotRegistry.get_service(&"dot_profiler") != null:
		return null
	var script: Variant = load(SCRIPT)
	if not (script is GDScript):
		return null
	var node: Node = (script as GDScript).new()
	node.name = NODE_NAME
	host.add_child(node)
	DotLog.debug(CHANNEL, "profiler placed", {"host": str(host.get_path())})
	return node


## Registers profiler_* and the record/stop commands on a client's local console source.
static func bind_client_console(node: Node, local: Object) -> void:
	if node != null and local != null:
		node.call(&"bind_console", local)


## Installs sv_profiler_* on the server's console. Failure is logged and leaves the profiler placed.
static func install_server(node: Node) -> void:
	if node == null or not ResourceLoader.exists(SERVER_SCRIPT):
		return
	var script: Variant = load(SERVER_SCRIPT)
	if not (script is GDScript):
		return
	var res: Variant = ((script as GDScript).new() as Object).call(&"install", node)
	if res is DotResult and not (res as DotResult).ok:
		DotLog.info(CHANNEL, "server profiler commands not installed", {"why": (res as DotResult).error.message})
