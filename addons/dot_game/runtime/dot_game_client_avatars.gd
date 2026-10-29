class_name DotGameClientAvatars
extends RefCounted

## What [DotGameClient] does for avatar actions and the files a server advertises; the client keeps the state.

const CHANNEL := "game.client"
## The node service a client is published under once it knows its figures, so an addon can find a player's figure.
const SERVICE := &"dot_game_client"
const FIGURE_META := &"dot_game_figure_fn"


static func prepare_content(c: DotGameClient, rules: Dictionary, base_url: String, server_id: int, http: DotHttp = null) -> DotResult:
	var ids := DotGameAvatarContent.ids_from_rules(rules)
	if server_id <= 0:
		server_id = DotGameAvatarContent.server_id_from_rules(rules)
	c.avatar_site_url = base_url
	c.avatar_server_id = server_id
	var kept := []
	var res: DotResult = await DotGameAvatarContent.prepare(c, ids, base_url, server_id, c.gate, http, kept)
	if not kept.is_empty():
		c.avatar_fetcher = kept[0]
	if not res.ok:
		DotLog.warn(CHANNEL, "avatar content not ready; not connecting", {"why": res.error.message})
	return res


static func add_actions(c: DotGameClient, net: DotNetManager, figure_fn: Callable, backbone_actions: Variant = null) -> DotResult:
	publish_figures(c, figure_fn)
	var path := "res://addons/dot_user_avatar/actions/dot_avatar_action_input.gd"
	if not ResourceLoader.exists(path):
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "dot-user-avatar is not in this build.")
	var script := load(path) as GDScript
	script.call(&"ensure_actions")
	var input: Node = script.new()
	if backbone_actions != null:
		var read: DotResult = (load("res://addons/dot_user_avatar/actions/dot_avatar_actions.gd") as GDScript).call(&"from_backbone", backbone_actions)
		if read.ok:
			input.set(&"actions", read.value)
		else:
			DotLog.warn(CHANNEL, "avatar actions unreadable; starter set", {"why": read.error.message})
	c.add_child(input)
	var client := DotGameAvatarActionClient.new()
	c.avatar_actions = client
	client.blocked_fn = c.is_input_blocked
	client.content_fn = func(entry: Dictionary) -> DotResult:
		return await DotGameAvatarContent.fetch_clip(c, null, c.avatar_site(), c.avatar_server(), entry, c._avatar_library)
	client.url_fn = func(id: String) -> String:
		return String((c._avatar_library.get("rows", {}) as Dictionary).get(id, {}).get("url", ""))
	client.wearable_row_fn = func(id: String) -> Dictionary:
		return (c._avatar_library.get("rows", {}) as Dictionary).get(id, {})
	c.add_child(client)
	client.attach(net, input, figure_fn)
	if c.console != null and is_instance_valid(c.console) and ResourceLoader.exists(DotGameClient.LOCAL_SCRIPT):
		var local: Object = (load(DotGameClient.LOCAL_SCRIPT) as GDScript).new()
		input.call(&"register_console", local)
		c.console.call(&"add_source", local)
	return DotResult.success(client)


static func server(c: DotGameClient) -> int:
	if c.avatar_server_id > 0:
		return c.avatar_server_id
	var source: Object = c.link if c.link != null else DotRegistry.get_service(DotGameClient.LINK_SERVICE)
	var cvars: Variant = source.get(&"replicated_cvars") if source != null and is_instance_valid(source) else null
	return DotGameAvatarContent.server_id_from_rules(cvars) if cvars is Dictionary else 0


static func read_actions(http: DotHttp, user_key: String, headers: Dictionary) -> DotResult:
	var path := "res://addons/dot_user_avatar/net/dot_avatar_sync.gd"
	if http == null or not ResourceLoader.exists(path):
		return DotResult.success(null)
	return await (load(path) as GDScript).call(&"fetch_actions", http, user_key, headers)


## Publishes [param c] as [constant SERVICE] with [param figure_fn] (peer id -> figure); add_avatar_actions does it.
static func publish_figures(c: DotGameClient, figure_fn: Callable) -> void:
	c.set_meta(FIGURE_META, figure_fn)
	DotRegistry.register(SERVICE, c)


## The figure of [param peer_id] in the published client, or null.
static func figure_of(peer_id: int) -> Node:
	var c: Object = DotRegistry.get_service(SERVICE)
	if c == null or not is_instance_valid(c) or not c.has_meta(FIGURE_META):
		return null
	var fn: Callable = c.get_meta(FIGURE_META)
	var figure: Variant = fn.call(peer_id) if fn.is_valid() else null
	return figure as Node if figure is Node and is_instance_valid(figure) else null
