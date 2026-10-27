extends RefCounted

## [DotGameClient]'s render quality: dot-fx's [DotFxRenderQuality] on the client, so every game gets
## anisotropic filtering, anti-aliasing and mip bias from the player's menu and the `--render-*` cvars.
## No class_name: the client preloads it. dot-fx is optional and found by path.

const CHANNEL := "game.client"
const SCRIPT := "res://addons/dot_fx/runtime/dot_fx_render_quality.gd"


## Adds the node and follows the settings, or returns null when dot-fx is not in this build or a game already has one.
static func add(c: DotGameClient, store: Object) -> Node:
	if not ResourceLoader.exists(SCRIPT) or c.get_node_or_null("RenderQuality") != null:
		return null
	var script: Variant = load(SCRIPT)
	if not (script is GDScript):
		return null
	var node: Node = (script as GDScript).new()
	node.name = "RenderQuality"
	c.add_child(node)
	# The player's menu first, then the operator's `--render-*` over it; a later menu change wins.
	if store != null and store.has_signal(&"changed"):
		node.call(&"follow", store)
	node.call(&"load_layers")
	DotLog.debug(CHANNEL, "render quality applied", {"state": node.call(&"describe")})
	return node
