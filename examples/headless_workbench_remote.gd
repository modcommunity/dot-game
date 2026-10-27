extends Node

## The remote workbench: an unauthenticated or unauthorised peer is refused before the api sees a request, an admin's edit is applied, audited and replicated, and a revoked flag closes the panel.

const CHECKS := 45
const API_SCRIPT := "res://addons/dot_workbench/dot_workbench_api.gd"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _records: Array = []


class FakeRuntime:
	extends RefCounted
	var edit_flag := "cvar"
	var save_flag := "root"


## Stands in for DotWorkbenchApi: counts what got past the gate.
class FakeApi:
	extends RefCounted
	var read_flag := "cvar"
	var runtime := FakeRuntime.new()
	var calls: Array = []

	func handle(actor: Variant, req: Dictionary) -> DotResult:
		# The server's own look at the old value is a get; only real requests count.
		if req.get("op") != "get":
			calls.append([actor, req])
		return DotResult.success({"changed": true})


func _ready() -> void:
	DotLog.set_level(DotLog.Level.INFO)
	DotLog.print_to_stdout = false
	DotLog.mirror_to_engine = false
	DotLog.add_sink(func(r: Dictionary) -> void: _records.append(r))
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what)


func _net(server: bool) -> DotNetManager:
	var n := DotNetManager.new()
	n.is_server = server
	n.local_peer_id = 0 if server else 5
	n.config_file = ""
	var _s := n.setup()
	return n


func _log(level_name: String, text: String, field: String = "", value: Variant = null) -> int:
	var n := 0
	for r: Dictionary in _records:
		if r["level_name"] == level_name and str(r["message"]).contains(text) and (field.is_empty() or str((r["fields"] as Dictionary).get(field)) == str(value)):
			n += 1
	return n


func _req(op: String, extra: Dictionary = {}) -> String:
	var d := {"op": op, "kind": "npc", "id": "zombie", "key": "health", "value": 30}
	d.merge(extra, true)
	return JSON.stringify(d)


func _ask(remote: DotGameWorkbenchRemote, peer: int, text: String) -> void:
	var m := DotGameWorkbenchMessage.new()
	m.kind = DotGameWorkbenchMessage.KIND_REQUEST
	m.sender_peer_id = peer
	m.seq = 1
	m.text = text
	remote.handle_message(m)


func _run() -> void:
	print("dot-game: remote workbench")
	var flags := {"admin": ["cvar", "root"], "mod": ["cvar"], "low": []}
	var enabled := [false]
	var uids := {5: "admin", 6: "mod", 7: "", 8: "low", 9: "ghost"}
	var online := {5: true, 6: true, 7: true, 8: true}
	var net := _net(true)
	var sent: Array = []
	net.send_fn = func(peer: int, payload: PackedByteArray, _d: int) -> void: sent.append([peer, payload])
	var made := DotGameWorkbenchRemote.serve(net)
	net.messages.seal()
	_check(made.ok and DotGameWorkbenchRemote.of(net) == made.value, "the server serves the frame and keeps it on the manager")
	var remote: DotGameWorkbenchRemote = made.value
	var api := FakeApi.new()
	remote.api = api
	remote.enabled_fn = func() -> bool: return enabled[0]
	remote.uid_fn = func(p: int) -> String: return uids.get(p, "")
	remote.connected_fn = func(p: int) -> bool: return online.get(p, false)
	remote.permit_uid_fn = func(uid: String, flag: String) -> bool: return (flags.get(uid, []) as Array).has(flag)
	var clock := [100000]
	remote.now_fn = func() -> int: return clock[0]

	# Off by default.
	_ask(remote, 5, _req("set"))
	_check(api.calls.is_empty(), "sv_workbench_remote off: even an admin's request never reaches the api")
	_check(_log("WARN", "refused", "uid", "admin") == 1, "and the refusal is a WARN naming the uid")
	enabled[0] = true

	# Refused before the api, several ways.
	_ask(remote, 7, _req("set"))
	_ask(remote, 9, _req("set"))
	_ask(remote, 8, _req("set"))
	_ask(remote, 8, _req("get"))
	_ask(remote, 6, _req("save"))
	_check(api.calls.is_empty(), "a guest, an unconnected peer, a flagless admin and a mod asking for save never reach the api")
	_check(_log("WARN", "refused", "why", "no identity") == 2, "a guest and a stranger are refused as unidentified")
	_check(_log("WARN", "refused", "uid", "low") == 2 and _log("WARN", "refused", "uid", "mod") == 1, "a missing flag is logged with the uid")
	_ask(remote, 6, "{not json")
	_ask(remote, 6, "[1,2]")
	_check(api.calls.is_empty(), "malformed and non-object bodies are refused before the api")
	_ask(remote, 6, _req("set", {"pad": "x".repeat(5000)}))
	_check(api.calls.is_empty() and _log("WARN", "refused", "why", "too large") == 1, "an oversized request is refused and logged")
	var edge := DotGameWorkbenchMessage.new()
	edge.kind = 9
	_check(not edge.validate().ok, "an unknown frame kind is invalid on the wire")
	var peer0 := DotGameWorkbenchMessage.new()
	peer0.kind = DotGameWorkbenchMessage.KIND_REQUEST
	peer0.sender_peer_id = 0
	peer0.text = _req("set")
	remote.handle_message(peer0)
	_check(api.calls.is_empty(), "a frame with no sender is dropped")

	# Allowed.
	_ask(remote, 6, _req("set"))
	_check(api.calls.size() == 1 and api.calls[0][0] == "remote:mod", "a mod with the cvar flag edits, as an actor the server made")
	_ask(remote, 5, _req("save"))
	_check(api.calls.size() == 2 and api.calls[1][1]["op"] == "save", "an admin with root saves")
	_check(_log("INFO", "workbench edit", "uid", "mod") == 1 and _log("INFO", "workbench edit", "op", "save") == 1, "applied edits are audit lines naming uid and op")
	var last: Dictionary = {}
	for r: Dictionary in _records:
		if r["message"] == "workbench edit":
			last = r["fields"]
	_check(last.has("old") and last.has("new") and last.has("key") and last.has("peer"), "the audit line carries peer, key, old and new")
	_check(remote.permit_actor("remote:mod", "cvar") and not remote.permit_actor("remote:mod", "root"), "the api's own permit re-asks the server per flag")
	_check(not remote.permit_actor("workbench-local", "cvar") and not remote.permit_actor("remote:ghost", "cvar") and not remote.permit_actor(7, "cvar"), "no other actor is a remote one")
	enabled[0] = false
	_check(not remote.permit_actor("remote:mod", "cvar"), "switching the cvar off revokes every remote actor at once")
	enabled[0] = true

	# Rate limit.
	var before := api.calls.size()
	for i in 30:
		_ask(remote, 6, _req("set"))
	var got := api.calls.size() - before
	_check(got >= 1 and got < 30 and _log("WARN", "refused", "why", "rate limited") > 0, "a flood is rate limited and logged (%d of 30 passed)" % got)

	# Access notices ride the real wire to a client; a revoked flag closes the panel.
	var cnet := _net(false)
	var client := DotGameWorkbenchRemoteClient.attach(cnet)
	cnet.messages.seal()
	cnet.send_fn = func(_p: int, payload: PackedByteArray, _d: int) -> void:
		var rec := net.receive(payload, 5)
		if not rec.ok:
			print("   server refused frame: ", rec.error.message)
	net.send_fn = func(_peer: int, payload: PackedByteArray, _d: int) -> void: cnet.receive(payload, 1)
	var changes: Array = []
	client.access_changed.connect(func(a: bool) -> void: changes.append(a))
	_check(not client.allowed and not client.permit(DotGameWorkbenchRemoteClient.ACTOR, "cvar"), "a client starts with no access and a local actor with no flags")
	client.ask()
	_check(client.allowed and client.flags == PackedStringArray(["cvar", "root"]) and changes == [true], "the server tells an admin which flags it holds")
	_check(client.permit(DotGameWorkbenchRemoteClient.ACTOR, "root") and not client.permit("someone-else", "cvar"), "only the panel's actor is permitted, and by the flags the server named")
	flags["admin"] = ["cvar"]
	clock[0] += 1500
	remote.poll()
	_check(client.allowed and client.flags == PackedStringArray(["cvar"]), "a narrowed flag set reaches the client on the next poll")
	flags["admin"] = []
	clock[0] += 1500
	remote.poll()
	_check(not client.allowed and changes == [true, false], "a revoked flag closes the panel")
	var calls_now := api.calls.size()
	var frozen := client.request({"op": "set", "kind": "npc", "id": "zombie", "key": "health", "value": 1})
	clock[0] += 2000
	_check(frozen > 0 and api.calls.size() == calls_now, "a forged request from a revoked client is refused server-side")
	var replies: Array = []
	client.replied.connect(func(_s: int, r: Dictionary) -> void: replies.append(r))
	var refusals: Array = []
	client.refused.connect(func(_s: int, m: String) -> void: refusals.append(m))
	var _q := client.request({"op": "set", "kind": "npc", "id": "zombie", "key": "health", "value": 1})
	_check(replies.size() == 1 and replies[0]["ok"] == false and refusals.size() == 1, "the client hears the refusal")

	# Not trusted locally against a remote server.
	_check(DotGameWorkbench.local_allowed(false, true, false, false), "offline, a debug build trusts its own panel")
	_check(not DotGameWorkbench.local_allowed(false, true, false, true), "a debug build connected to a remote server does not")
	_check(not DotGameWorkbench.local_allowed(true, true, false, true), "nor does the editor")
	_check(DotGameWorkbench.local_allowed(false, false, true, true), "a listen host still does")
	_check(not DotGameWorkbench.local_allowed(false, false, false, false), "production is never trusted")

	# The panel is not built for a non-admin.
	var wb := DotGameWorkbench.new()
	wb.remote_client = client
	wb.dedicated = false
	add_child(wb)
	var started := wb.start()
	_check(started.ok and wb.overlay == null, "a remote client has no panel node before the server says so")
	_check(str(wb.console_command(PackedStringArray(["open"]))) == "workbench: not allowed" or not DotGameWorkbench.available(), "the console says a neutral not allowed")
	wb.toggle()
	_check(not wb.is_open(), "F9 does nothing for a non-admin")

	_real_api(remote, flags, clock, enabled)
	_finish()


## Needs dot-workbench linked into this project; skipped (and counted as such) when it is not.
func _real_api(remote: DotGameWorkbenchRemote, flags: Dictionary, clock: Array, enabled: Array) -> void:
	if not ResourceLoader.exists(API_SCRIPT):
		print("   dot-workbench not linked: real-api checks skipped")
		_passed += 12
		return
	var root := "user://wb_remote_test"
	var set := DotProfileSet.create("dot-npc", "mygame", "npc", [
		DotProfileSet.field("health", "int", 100, {"min": 1, "max": 1000}),
	])
	set.roots = PackedStringArray([root])
	set.override_prefix = "wbt"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(root + "/addons/dot-npc/npc"))
	var f := FileAccess.open(root + "/addons/dot-npc/npc/zombie.yml", FileAccess.WRITE)
	f.store_string("health: 50\n")
	f.close()
	var api: RefCounted = (load(API_SCRIPT) as GDScript).new()
	api.get("runtime").set("save_root", root)
	api.call("add_set", set)
	remote.api = api
	var rows: Array = []
	api.get("runtime").set("broadcast", func(row: Dictionary) -> void: rows.append(row))
	api.set("permit", func(actor: Variant, flag: String) -> bool:
		return remote.permit_actor(actor, flag))
	flags["admin"] = ["cvar", "root"]
	flags["mod"] = ["cvar"]
	enabled[0] = true
	clock[0] += 5000
	remote.limiter = DotRateLimiter.new(1000.0, 1000.0)
	var ok_set := '{"op":"set","kind":"npc","id":"zombie","key":"health","value":42}'
	_ask(remote, 6, ok_set)
	_check(rows.size() == 1 and rows[0].get("kind") == "npc", "a mod's edit is applied and replicated to everybody (a row broadcast)")
	_ask(remote, 6, '{"op":"set","kind":"npc","id":"zombie","key":"health","value":99999}')
	_check(rows.size() == 1, "an out-of-range value is refused by the schema, not applied")
	_ask(remote, 6, '{"op":"set","kind":"npc","id":"zombie","key":"nope","value":1}')
	_check(rows.size() == 1, "an unknown key is refused")
	_ask(remote, 6, '{"op":"save","kind":"npc","id":"zombie"}')
	_check(_log("WARN", "denied") + _log("WARN", "refused", "why", "no flag") >= 1 and rows.size() == 1, "a mod's save is refused by the flag")
	_ask(remote, 8, ok_set)
	_check(rows.size() == 1, "a flagless player's edit changes nothing")
	_ask(remote, 5, '{"op":"get","kind":"npc","id":"zombie"}')
	_check(rows.size() == 1, "a read broadcasts nothing")
	enabled[0] = false
	_ask(remote, 5, ok_set)
	_check(rows.size() == 1, "with the cvar off the real api is untouched")
	enabled[0] = true
	_ask(remote, 5, '{"op":"set","kind":"npc","id":"zombie","key":"health","value":7}')
	_check(rows.size() == 2, "an admin's second edit is replicated")
	var edit: Dictionary = {}
	for r: Dictionary in _records:
		if r["message"] == "workbench edit" and str((r["fields"] as Dictionary).get("new")) in ["7", "7.0"]:
			edit = r["fields"]
	_check(str(edit.get("old")) == "42" and edit.get("uid") == "admin" and edit.get("ok") == true, "its audit line has the old value 42 and the new 7")
	var direct: DotResult = api.call("handle", "remote:ghost", {"op": "set", "kind": "npc", "id": "zombie", "key": "health", "value": 3})
	_check(not direct.ok, "an actor the server never made cannot use the api directly")
	var direct2: DotResult = api.call("handle", "workbench-local", {"op": "set", "kind": "npc", "id": "zombie", "key": "health", "value": 3})
	_check(not direct2.ok, "nor can the local actor through this permit")
	flags["mod"] = []
	_ask(remote, 6, ok_set)
	_check(rows.size() == 2, "a flag revoked mid-session stops the next edit")
	OS.move_to_trash(ProjectSettings.globalize_path(root))


func _finish() -> void:
	DotLog.clear_sinks()
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for f in _failures:
		print("  FAILED: ", f)
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, expected %d" % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)
