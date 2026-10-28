class_name DotGameAvatarContent
extends RefCounted

## The avatar and action files a server requires, advertised as one notify cvar (in the query
## rules, [code]entry.rules[CVAR][/code]) and fetched by the client before it connects.

## Comma-separated content ids ([code]avatar/<id>/<version>[/code], [code]action/<id>/<version>[/code]).
const CVAR := "sv_avatar_content"

const FETCHER := "res://addons/dot_user_avatar/actions/dot_avatar_content_fetcher.gd"

## Longest advertisement read; the fetcher then caps the id count.
const MAX_TEXT := 4096

## The server's numeric id on the site (its integration credential's `server:<id>`), a notify and
## replicated cvar, so a browser row and a joined client both know which library to read.
const SERVER_CVAR := "sv_site_server"


static func format(ids: Array) -> String:
	var parts := PackedStringArray()
	for id in ids:
		parts.append(String(id))
	return ",".join(parts)


## The ids in an advertisement, unvalidated (the fetcher refuses a malformed one by name).
static func parse(text: String) -> Array:
	var out := []
	for part in text.left(MAX_TEXT).split(",", false):
		var id := part.strip_edges()
		if id != "":
			out.append(id)
	return out


## The ids a server's query rules advertise; empty when it advertises none.
static func ids_from_rules(rules: Dictionary) -> Array:
	return parse(String(rules.get(CVAR, "")))


## The site server id a server's query rules (or a link's replicated cvars) advertise; 0 for none.
static func server_id_from_rules(rules: Dictionary) -> int:
	var text := String(rules.get(SERVER_CVAR, "")).strip_edges()
	return int(text) if text.is_valid_int() and int(text) > 0 else 0


## The site the client signs in against: the registry's `dot_auth_client` (the shell's) or
## `dot_backbone_client` config `backbone_url`; "" when neither is placed.
static func default_site_url() -> String:
	for service: StringName in [&"dot_auth_client", &"dot_backbone_client"]:
		var client: Object = DotRegistry.get_service(service)
		var cfg: Variant = client.get("config") if client != null else null
		if cfg is Object and "backbone_url" in cfg and String(cfg.get("backbone_url")).strip_edges() != "":
			return String(cfg.get("backbone_url")).strip_edges().trim_suffix("/")
	return ""


## The site id from [param audience] (`server:<id>`), 0 for anything else (an `app:` credential).
static func server_id_from_audience(audience: String) -> int:
	if not audience.begins_with("server:"):
		return 0
	var text := audience.trim_prefix("server:")
	return int(text) if text.is_valid_int() and int(text) > 0 else 0


static func available() -> bool:
	return ResourceLoader.exists(FETCHER)


## Fetches [param ids] through dot-user-avatar's fetcher (by path) holding [param gate]. The result is
## the fetcher's: on failure the gate stays held with the reason and the caller must not connect.
## Success value is the number of files downloaded; [param fetcher_out] receives the fetcher.
static func prepare(host: Node, ids: Array, base_url: String, server_id: int, gate: Object, http: DotHttp, fetcher_out: Array = []) -> DotResult:
	if ids.is_empty():
		return DotResult.success(0)
	if not available():
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "The server requires avatar files, and dot-user-avatar is not in this build.")
	var fetcher: RefCounted = (load(FETCHER) as GDScript).new()
	var own: DotHttp = null
	if http == null:
		own = DotHttp.new()
		host.add_child(own)
		http = own
	fetcher.set(&"http", http)
	if gate != null:
		fetcher.set(&"gate", gate)
	fetcher_out.append(fetcher)
	var res: DotResult = await fetcher.call(&"prepare", base_url, server_id, ids)
	if own != null and is_instance_valid(own):
		own.queue_free()
	return res


## One uploaded action's clip, fetched mid-game for [DotGameAvatarActionClient] from the site's
## library (cached in [param library], read again at most once a minute); the server only names an id.
## Success is a Node3D the caller owns.
static func fetch_clip(host: Node, http: DotHttp, base_url: String, server_id: int, entry: Dictionary, library: Dictionary) -> DotResult:
	var id := String(entry.get("id", ""))
	if not available():
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "dot-user-avatar is not in this build.")
	if base_url == "" or server_id <= 0:
		return DotResult.fail(DotError.CODE_STATE, "No site to fetch avatar clips from.")
	var script := load(FETCHER) as GDScript
	var now := Time.get_ticks_msec()
	var rows: Dictionary = library.get("rows", {})
	if not rows.has(id) and (not library.has("at") or now - int(library["at"]) > 60000):
		library["at"] = now
		var own: DotHttp = http
		if own == null:
			own = DotHttp.new()
			host.add_child(own)
		var lib: DotResult = await own.get_json("%s/api/avatar/v1/library?server=%d" % [base_url.trim_suffix("/"), server_id])
		if http == null and is_instance_valid(own):
			own.queue_free()
		if not lib.ok:
			return lib.wrap("reading the avatar library")
		rows = script.call(&"index_library", lib.value)
		library["rows"] = rows
	if not rows.has(id):
		return DotResult.fail(DotError.CODE_INVALID, "the site's library does not list this action", id)
	var fetcher: RefCounted = script.new()
	var mine: DotHttp = http
	if mine == null:
		mine = DotHttp.new()
		host.add_child(mine)
	fetcher.set(&"http", mine)
	var got: DotResult = await fetcher.call(&"fetch_rows", [rows[id]])
	if http == null and is_instance_valid(mine):
		mine.queue_free()
	if not got.ok:
		return got
	return fetcher.get(&"cache").call(&"load_scene", id)
