class_name DotGameWorkbenchRemote
extends RefCounted

## The server half of the remote workbench: an admin's client edits profiles on a running server.
##
## Every request is checked on the server, in this order: switched on (`sv_workbench_remote`), a known identity (a guest is never an admin), size, rate, then the flag the op needs, held now (so a revoked admin is refused on the next edit). Only then does [member api] see it, as the actor `remote:<uid>`, and the api's own permit asks [method permit_actor] again. A refusal is a WARN with the uid; an applied edit is an INFO audit line with old and new.

const CHANNEL := "game.workbench"
const NET_META := &"dot_workbench_remote"
const CVAR := "sv_workbench_remote"
const ACTOR_PREFIX := "remote:"
const READ_OPS := ["list", "get"]

## The [DotWorkbenchApi] (duck-typed: `handle`, `read_flag`, and its runtime's `edit_flag` / `save_flag`).
var api: RefCounted = null
## func() -> bool: remote editing is switched on. Unset means off.
var enabled_fn: Callable = Callable()
## func(peer_id: int) -> String: the player's account uid, "" for a guest.
var uid_fn: Callable = Callable()
## func(uid: String, flag: String) -> bool: whether that account holds the flag now.
var permit_uid_fn: Callable = Callable()
## func(peer_id: int) -> bool: the peer is still connected; revoked on leave.
var connected_fn: Callable = Callable()
## Largest request text accepted, in bytes.
var max_bytes: int = 4096
var limiter := DotRateLimiter.new(4.0, 8.0)
## Milliseconds; replaced by a suite.
var now_fn: Callable = Callable(Time, &"get_ticks_msec")

var _net: DotNetManager = null
## peer -> last access notice sent (flags string), for peers that asked.
var _known: Dictionary = {}
var _last_sweep := 0


## Registers the message on [param net], answers it, and stores the result as [constant NET_META]. Call before the schema seals.
static func serve(net: DotNetManager, wb_api: RefCounted = null) -> DotResult:
	var made := DotGameWorkbenchMessage.register(net)
	if not made.ok:
		return made
	var remote := DotGameWorkbenchRemote.new()
	remote._net = net
	remote.api = wb_api
	var _on := net.messages.on(DotGameWorkbenchMessage.NAME, remote._on_message)
	net.set_meta(NET_META, remote)
	return DotResult.success(remote)


## Reads the admin manager and sessions of [param server] (a DotServer) and the `sv_workbench_remote` cvar.
func bind_server(server: Object) -> void:
	if server == null:
		return
	var console: Variant = server.get("console")
	if console is DotConsole:
		ensure_cvar(console)
		var cv := (console as DotConsole).find_cvar(CVAR)
		enabled_fn = func() -> bool: return cv != null and cv.get_bool()
	uid_fn = func(peer: int) -> String:
		var session: Object = server.call(&"session_of", peer)
		return str(session.call(&"uid")) if session != null else ""
	connected_fn = func(peer: int) -> bool: return server.call(&"session_of", peer) != null
	permit_uid_fn = func(uid: String, flag: String) -> bool:
		var admins: Object = server.get("admins")
		return admins != null and bool(admins.call(&"uid_has_permission", uid, flag))


static func ensure_cvar(console: DotConsole) -> void:
	if console.find_cvar(CVAR) == null:
		var _cv := console.cvar(CVAR, "0", "Let flagged admins edit profiles from a connected client (0 off, 1 on)", DotConVar.FLAG_ARCHIVE).with_range(0, 1)


static func of(net: DotNetManager) -> DotGameWorkbenchRemote:
	var found: Variant = net.get_meta(NET_META, null) if net != null else null
	return found as DotGameWorkbenchRemote


## Whether the actor [param actor] (made here) holds [param flag] right now.
func permit_actor(actor: Variant, flag: String) -> bool:
	if not (actor is String) or not (actor as String).begins_with(ACTOR_PREFIX):
		return false
	return _held(String(actor).substr(ACTOR_PREFIX.length()), flag)


## The flags [param uid] holds among those the workbench uses, comma separated; "" for none or when remote editing is off.
func flags_of(uid: String) -> String:
	if not _on() or uid.is_empty():
		return ""
	var held := PackedStringArray()
	for f in _flag_names():
		if _held(uid, f) and not held.has(f):
			held.append(f)
	return ",".join(held)


func forget(peer_id: int) -> void:
	_known.erase(peer_id)


## Re-checks every peer that asked and tells those whose access changed: a revoked flag closes the panel. Call about once a second.
func poll() -> void:
	var now := int(now_fn.call())
	if now - _last_sweep < 1000:
		return
	_last_sweep = now
	for peer: int in _known.keys():
		if connected_fn.is_valid() and not bool(connected_fn.call(peer)):
			_known.erase(peer)
		elif flags_text(peer) != _known[peer]:
			_tell_access(peer)


func flags_text(peer: int) -> String:
	return flags_of(_uid(peer))


## Handles one decoded frame; also the entry point of a suite.
func handle_message(m: DotGameWorkbenchMessage) -> void:
	var peer := m.sender_peer_id
	if peer <= 0:
		return
	match m.kind:
		DotGameWorkbenchMessage.KIND_ASK:
			_tell_access(peer)
		DotGameWorkbenchMessage.KIND_REQUEST:
			_reply(peer, m.seq, _serve_request(peer, m.text))


func _on_message(message: DotNetMessage) -> void:
	var m := message as DotGameWorkbenchMessage
	if m != null:
		handle_message(m)


func _serve_request(peer: int, text: String) -> DotResult:
	var uid := _uid(peer)
	if not _on():
		return _refuse(peer, uid, "remote editing is off", "off")
	if uid.is_empty() or (connected_fn.is_valid() and not bool(connected_fn.call(peer))):
		return _refuse(peer, uid, "not an identified player", "no identity")
	if text.to_utf8_buffer().size() > max_bytes:
		return _refuse(peer, uid, "request too large", "too large")
	if not limiter.allow(peer):
		return _refuse(peer, uid, "too many requests", "rate limited")
	var json := JSON.new()
	var parsed: Variant = json.data if json.parse(text) == OK else null
	if not (parsed is Dictionary):
		return DotResult.fail(DotError.CODE_INVALID, "request must be a JSON object")
	var req: Dictionary = parsed
	var op := str(req.get("op", ""))
	var flag := _flag_for(op)
	if not _held(uid, flag):
		return _refuse(peer, uid, "needs '%s'" % flag, "no flag", {"op": op, "flag": flag, "kind": str(req.get("kind", "")), "id": str(req.get("id", ""))})
	if api == null:
		return DotResult.fail(DotError.CODE_STATE, "no workbench api")
	var before: Variant = _peek(uid, req)
	var res: DotResult = api.call(&"handle", ACTOR_PREFIX + uid, req)
	if not READ_OPS.has(op):
		DotLog.info(CHANNEL, "workbench edit", {"uid": uid, "peer": peer, "op": op, "kind": str(req.get("kind", "")), "id": str(req.get("id", "")),
			"key": str(req.get("key", "")), "old": str(before), "new": str(req.get("value")), "ok": res.ok, "error": "" if res.ok else res.error.message})
	return res


func _refuse(peer: int, uid: String, why: String, tag: String, extra: Dictionary = {}) -> DotResult:
	var fields := {"uid": uid, "peer": peer, "why": tag}
	fields.merge(extra)
	DotLog.warn(CHANNEL, "workbench request refused", fields)
	return DotResult.fail(DotError.CODE_FORBIDDEN, why)


func _flag_for(op: String) -> String:
	if READ_OPS.has(op):
		return str(api.get("read_flag")) if api != null else "cvar"
	var runtime: Object = api.get("runtime") if api != null else null
	var saves: bool = op == "save"
	if runtime != null:
		return str(runtime.get("save_flag" if saves else "edit_flag"))
	return "root" if saves else "cvar"


func _flag_names() -> PackedStringArray:
	return PackedStringArray([_flag_for("get"), _flag_for("set"), _flag_for("save")])


func _on() -> bool:
	return enabled_fn.is_valid() and bool(enabled_fn.call())


func _uid(peer: int) -> String:
	return str(uid_fn.call(peer)) if uid_fn.is_valid() else ""


func _held(uid: String, flag: String) -> bool:
	return _on() and not uid.is_empty() and permit_uid_fn.is_valid() and bool(permit_uid_fn.call(uid, flag))


## The value a `set` is about to overwrite (the profile as it reads now); null when it cannot say.
func _peek(uid: String, req: Dictionary) -> Variant:
	if str(req.get("op", "")) != "set" or api == null:
		return null
	var got: DotResult = api.call(&"handle", ACTOR_PREFIX + uid, {"op": "get", "kind": req.get("kind", ""), "id": req.get("id", "")})
	if got == null or not got.ok or not (got.value is Dictionary):
		return null
	var node: Variant = (got.value as Dictionary).get("values", {}).duplicate()
	node["extra"] = (got.value as Dictionary).get("extra", {})
	for part in str(req.get("key", "")).split("."):
		if not (node is Dictionary) or not (node as Dictionary).has(part):
			return null
		node = node[part]
	return node


func _tell_access(peer: int) -> void:
	var flags := flags_text(peer)
	_known[peer] = flags
	var out := DotGameWorkbenchMessage.new()
	out.kind = DotGameWorkbenchMessage.KIND_ACCESS
	out.allowed = not flags.is_empty()
	out.flags = flags
	_send(out, peer)


func _reply(peer: int, seq: int, res: DotResult) -> void:
	var out := DotGameWorkbenchMessage.new()
	out.kind = DotGameWorkbenchMessage.KIND_REPLY
	out.seq = seq
	out.text = JSON.stringify(_wire(res))
	_send(out, peer)


static func _wire(res: DotResult) -> Dictionary:
	if res.ok:
		return {"ok": true, "value": res.value}
	return {"ok": false, "error": {"code": res.error.code, "message": res.error.message}}


func _send(out: DotGameWorkbenchMessage, peer: int) -> void:
	if _net == null:
		return
	var sent := _net.send(out, peer)
	if not sent.ok:
		DotLog.warn(CHANNEL, "workbench frame not sent", {"peer": peer, "why": sent.error.message})
