class_name DotGameAvatarContent
extends RefCounted

## The avatar and action files a server requires, advertised as one notify cvar and fetched
## by the client before it connects.
##
## The cvar rides the server's query rules, so a browser row already carries it as
## [code]entry.rules[CVAR][/code]; nothing else on the handshake changes.

const CHANNEL := "game.avatar_content"

## Comma-separated content ids ([code]avatar/<id>/<version>[/code], [code]action/<id>/<version>[/code]).
const CVAR := "sv_avatar_content"

const FETCHER := "res://addons/dot_user_avatar/actions/dot_avatar_content_fetcher.gd"

## Longest advertisement read; the fetcher then caps the id count.
const MAX_TEXT := 4096


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
