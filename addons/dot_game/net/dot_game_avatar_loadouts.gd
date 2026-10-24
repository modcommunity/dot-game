class_name DotGameAvatarLoadouts
extends Node

## The server's copy of every player's equipped emotes, poses and gestures, read from the
## backbone's avatar read with the server's own credential, checked, and told to every client.
##
## A client cannot read another player's loadout (that needs the server's token) and must never
## be believed about its own, so the server reads it once per join ([method add_peer]), keeps the
## ids for [DotGameAvatarActionRelay] to check requests against, and sends
## [DotGameAvatarLoadoutMessage] to everybody; a late joiner gets everyone already in. Without a
## credential, a site-issued key or an answer, a player has no loadout and plays the starter set.
## Built by [method DotGameAvatarActionRelay.serve]; the roster follows it.

const CHANNEL := "game.avatar_loadout"

## The scoped key's shape (dot-user-avatar's DotAvatarKey), checked before it reaches a URL.
const _KEY_RE := "^[A-Za-z0-9_-]{8,128}$"
const _CONTENT_RE := "^action/[1-9][0-9]{0,9}/[1-9][0-9]{0,9}$"

## Built-in ids by wire kind (0 emote, 1 pose, 2 gesture): the site's BUILTIN_AVATAR_ACTIONS.
const STARTER_KINDS := {
	"cheer": 0, "dance": 0, "clap": 0, "bow": 0,
	"sit": 1, "salute": 1, "arms_crossed": 1, "hands_on_hips": 1,
	"wave": 2, "point": 2, "thumbs_up": 2, "nod": 2, "shrug": 2,
}
const STARTER_LOOPS: PackedStringArray = ["dance", "clap", "sit", "salute", "arms_crossed", "hands_on_hips"]

## Per kind, as the site caps it (AVATAR_ACTION_EQUIP_MAX).
const MAX_PER_KIND := 8

## Reads in flight at once; the rest wait in a queue of at most [constant MAX_QUEUE].
var max_concurrent: int = 2
const MAX_QUEUE := 128

## A peer is read again ([method refresh]) at most this often.
var refresh_min_sec: float = 30.0

## The dot-server whose sessions hold the identities; the key is the `scoped_key` claim.
var server: Object = null
var net: DotNetManager = null
var relay: RefCounted = null

## Overrides of the credential found as the registry's `dot_backbone_client`.
var base_url: String = ""
var token: String = ""

## func(peer_id: int) -> String: the player's backbone key, "" for none. Default: the session's claim.
var key_fn: Callable = Callable()

## func(key: String) -> DotResult (may await): the avatar read's `actions`, or null. Default: HTTP.
var fetch_fn: Callable = Callable()

## Milliseconds; replaced by a suite.
var now_fn: Callable = Callable(Time, &"get_ticks_msec")

var reads: int = 0
var refused: int = 0

var _loadouts: Dictionary = {}
var _peers: Dictionary = {}
var _gen: Dictionary = {}
var _read_at: Dictionary = {}
var _queue: Array[int] = []
var _in_flight := 0
var _http: DotHttp = null
static var _key_re: RegEx = null
static var _content_re: RegEx = null


## The roster's join: tell [param peer_id] everyone's loadout, then read theirs.
func add_peer(peer_id: int) -> void:
	_peers[peer_id] = true
	_gen[peer_id] = int(_gen.get(peer_id, 0)) + 1
	for other: int in _loadouts:
		if other != peer_id:
			_send(other, _loadouts[other], peer_id)
	var _q := refresh(peer_id, true)


## The roster's leave: forget them, and tell everybody to.
func remove_peer(peer_id: int) -> void:
	_peers.erase(peer_id)
	_gen[peer_id] = int(_gen.get(peer_id, 0)) + 1
	_read_at.erase(peer_id)
	_queue.erase(peer_id)
	if relay != null and relay.has_method(&"forget"):
		relay.call(&"forget", peer_id)
	if _loadouts.erase(peer_id):
		_send(peer_id, [], 0)


## Reads [param peer_id]'s loadout again (they changed it on the site). False when refused: not
## in the game, read less than [member refresh_min_sec] ago, or the queue is full.
func refresh(peer_id: int, joining: bool = false) -> bool:
	if not _peers.has(peer_id) or _queue.has(peer_id):
		return false
	var now := int(now_fn.call())
	if not joining and _read_at.has(peer_id) and now - int(_read_at[peer_id]) < int(refresh_min_sec * 1000.0):
		return false
	if _queue.size() >= MAX_QUEUE:
		DotLog.warn(CHANNEL, "loadout queue full; starter set", {"peer": peer_id})
		return false
	_read_at[peer_id] = now
	_queue.append(peer_id)
	_pump()
	return true


## The ids [param peer_id] may play, or null when nothing was read (the starter set).
func ids_for(peer_id: int) -> Variant:
	if not _loadouts.has(peer_id):
		return null
	var out: Array = []
	for e: Dictionary in _loadouts[peer_id]:
		out.append(e["id"])
	return out


## The entry for [param id] in [param peer_id]'s loadout, or empty.
func entry_for(peer_id: int, id: String) -> Dictionary:
	for e: Dictionary in _loadouts.get(peer_id, []):
		if e["id"] == id:
			return e
	return {}


## The backbone's `actions` (`{EMOTE: [...], POSE: [...], GESTURE: [...]}`) as wire entries:
## built-ins by known id, uploads by a well-formed `action/<id>/<version>` and a clip name,
## at most [constant MAX_PER_KIND] per kind, duplicates dropped. A kind left empty gets that
## kind's built-ins, as the site does. Null for anything that is not an object.
static func parse(actions: Variant) -> Variant:
	if not actions is Dictionary:
		return null
	if _content_re == null:
		_content_re = RegEx.create_from_string(_CONTENT_RE)
	var out: Array = []
	var seen := {}
	for kind in DotGameAvatarLoadoutMessage.KINDS.size():
		var rows: Variant = (actions as Dictionary).get(DotGameAvatarLoadoutMessage.KINDS[kind].to_upper(), [])
		var taken := 0
		for row: Variant in (rows if rows is Array else []):
			if taken >= MAX_PER_KIND:
				break
			if not row is Dictionary:
				continue
			var d: Dictionary = row
			var entry := {}
			if d.get("builtin") is String:
				var b: String = d["builtin"]
				if STARTER_KINDS.get(b, -1) == kind:
					entry = {"id": b, "kind": kind, "loop": STARTER_LOOPS.has(b), "clip": ""}
			elif d.get("contentId") is String and _content_re.search(d["contentId"]) != null \
					and d.get("clip") is String and not (d["clip"] as String).is_empty() \
					and (d["clip"] as String).length() <= DotGameAvatarLoadoutMessage.MAX_CLIP:
				entry = {"id": d["contentId"], "kind": kind, "loop": d.get("loop") == true, "clip": d["clip"]}
			if entry.is_empty() or seen.has(entry["id"]):
				continue
			seen[entry["id"]] = true
			out.append(entry)
			taken += 1
		if taken == 0:
			for b: String in STARTER_KINDS:
				if STARTER_KINDS[b] == kind and not seen.has(b):
					seen[b] = true
					out.append({"id": b, "kind": kind, "loop": STARTER_LOOPS.has(b), "clip": ""})
	return out


func _pump() -> void:
	while _in_flight < max_concurrent and not _queue.is_empty():
		var peer: int = _queue.pop_front()
		_in_flight += 1
		_read.call_deferred(peer, int(_gen.get(peer, 0)))


func _read(peer_id: int, gen: int) -> void:
	var key := _key_for(peer_id)
	var res: DotResult = DotResult.success(null)
	if key != "":
		reads += 1
		if fetch_fn.is_valid():
			res = await fetch_fn.call(key)
		else:
			res = await _fetch(key)
	_in_flight -= 1
	# Gone, or left and a new player took the peer id, while the read was out: not theirs.
	if _peers.has(peer_id) and int(_gen.get(peer_id, 0)) == gen:
		_adopt(peer_id, res)
	_pump()


func _adopt(peer_id: int, res: DotResult) -> void:
	if res == null or not res.ok:
		refused += 1
		DotLog.debug(CHANNEL, "loadout not read; starter set", {"peer": peer_id,
			"why": res.error.message if res != null and res.error != null else "no result"})
		return
	var entries: Variant = parse(res.value)
	if entries == null:
		return
	_loadouts[peer_id] = entries
	DotLog.debug(CHANNEL, "loadout read", {"peer": peer_id, "entries": (entries as Array).size()})
	_send(peer_id, entries, 0)


func _send(actor: int, entries: Array, to_peer: int) -> void:
	if net == null:
		return
	var m := DotGameAvatarLoadoutMessage.new()
	m.actor = actor
	m.entries = entries
	var targets: Array = [to_peer] if to_peer > 0 else _peers.keys()
	for p: int in targets:
		if not net.messages.peer_has(p, DotGameAvatarLoadoutMessage.NAME):
			continue
		var sent := net.send(m, p)
		if not sent.ok:
			DotLog.debug(CHANNEL, "loadout not sent", {"to": p, "why": sent.error.message})


func _key_for(peer_id: int) -> String:
	var key := ""
	if key_fn.is_valid():
		key = String(key_fn.call(peer_id))
	elif server != null and server.has_method(&"session_of"):
		var session: Object = server.call(&"session_of", peer_id)
		var identity: Object = session.get("identity") if session != null else null
		var claims: Variant = identity.get("claims") if identity != null else null
		if claims is Dictionary and (claims as Dictionary).get("scoped_key") is String:
			key = claims["scoped_key"]
	if _key_re == null:
		_key_re = RegEx.create_from_string(_KEY_RE)
	return key if _key_re.search(key) != null else ""


## `[base, token]` from the overrides or the registry's `dot_backbone_client`, as dot-platform finds it.
func _credential() -> PackedStringArray:
	if base_url != "" and token != "":
		return PackedStringArray([base_url.trim_suffix("/"), token])
	var client: Object = DotRegistry.get_service(&"dot_backbone_client")
	var cfg: Object = client.get("config") if client != null else null
	if cfg == null or not cfg.has_method("integration_endpoint"):
		return PackedStringArray()
	var t := str(cfg.get("integration_token")).strip_edges()
	if t == "":
		return PackedStringArray()
	return PackedStringArray([str(cfg.call("integration_endpoint", "")).trim_suffix("/"), t])


func _fetch(key: String) -> DotResult:
	var cred := _credential()
	if cred.is_empty():
		return DotResult.success(null)
	if _http == null:
		_http = DotHttp.new()
		_http.name = "Http"
		_http.timeout_sec = 8.0
		_http.max_retries = 1
		add_child(_http)
	var res: DotResult = await _http.get_json("%s/user/%s/avatar" % [cred[0], key.uri_encode()],
		{"Authorization": "Bearer %s" % cred[1], "Accept": "application/json"})
	if not res.ok:
		if res.error != null and res.error.http_status == 404:
			return DotResult.success(null)
		return res.wrap("reading avatar actions")
	return DotResult.success((res.value as Dictionary).get("actions") if res.value is Dictionary else null)


func describe() -> Dictionary:
	return {"players": _peers.size(), "loadouts": _loadouts.size(), "queued": _queue.size(),
		"in_flight": _in_flight, "reads": reads, "refused": refused}
