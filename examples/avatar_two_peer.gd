extends Node

## Avatar loadouts over a real ENet link, one process per role (run tools/avatar_two_peer.sh): the
## server reads loadouts from a fake backbone; client `a` joins first, `b` later with an upload.
## `b` must hear `a`'s loadout and `a` must see `b`'s upload play and nothing unequipped.

const CHECKS_A := 6
const CHECKS_B := 4
const TOKEN := "two-peer-token"

var _role := ""
var _port := 0
var _backbone := ""
var _peer: Object = null
var _net: DotNetManager = null
var _client: DotGameAvatarActionClient = null
var _input: FakeInput = null
var _plays: Array = []
var _added: Array = []
var _joined: Array[int] = []
var _seen: Dictionary = {}
var _passed := 0
var _failed := 0


class FakeInput:
	extends Node
	signal action_requested(entry: Dictionary)
	var enabled := true


class FakeFigure:
	extends RefCounted
	var peer := 0
	var owner_node: Node = null
	var clips := {}

	func play_action(id: StringName, loop: bool, _elapsed: float) -> bool:
		var known := DotGameAvatarActionRelay.STARTER_IDS.has(String(id)) or clips.has(id)
		if known:
			owner_node.call(&"_note_play", peer, String(id), loop)
		return known

	func add_action_scene(id: StringName, _scene: Node, clip: String, _loop: bool) -> DotResult:
		clips[id] = true
		owner_node.call(&"_note_added", peer, String(id), clip)
		return DotResult.success(true)


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="):
			_role = arg.get_slice("=", 1)
		elif arg.begins_with("--port="):
			_port = int(arg.get_slice("=", 1))
		elif arg.begins_with("--backbone="):
			_backbone = arg.substr("--backbone=".length())
	if not ClassDB.class_exists("ENetMultiplayerPeer") or _port <= 0 or _role not in ["server", "a", "b"]:
		print("two-peer: usage --role=server|a|b --port=N [--backbone=URL]")
		get_tree().quit(2)
		return
	_net = DotNetManager.new()
	_net.name = "Net"
	_net.config_file = ""
	_net.is_server = _role == "server"
	add_child(_net)
	var _set := _net.setup()
	# The server's serve() registers both types; a client registers them itself, as a game's bridge does.
	if not _net.is_server:
		var reg := DotGameAvatarActionMessage.register(_net)
		if not reg.ok:
			print("two-peer: register failed: ", reg.error.message)
			get_tree().quit(1)
			return
	_peer = ClassDB.instantiate("ENetMultiplayerPeer")
	_net.send_fn = _send
	if _net.is_server:
		_serve()
	else:
		_join()


func _serve() -> void:
	var err: int = _peer.call(&"create_server", _port, 4)
	if err != OK:
		print("two-peer server: listen failed: ", error_string(err))
		get_tree().quit(1)
		return
	var served := DotGameAvatarActionRelay.serve(_net)
	var relay: DotGameAvatarActionRelay = served.value
	relay.loadouts.base_url = _backbone
	relay.loadouts.token = TOKEN
	# There is no identity layer here, so the key is the join order; the read itself is the real HTTP one.
	relay.loadouts.key_fn = func(peer: int) -> String:
		return ["keyA0000", "keyB0000"][_joined.find(peer)] if _joined.find(peer) in [0, 1] else ""
	_peer.connect(&"peer_connected", func(id: int) -> void:
		_joined.append(id)
		_net.add_peer(id)
		relay.loadouts.add_peer(id))
	_peer.connect(&"peer_disconnected", func(id: int) -> void:
		relay.loadouts.remove_peer(id)
		var _r := _net.remove_peer(id))
	var _s := _net.start()
	print("two-peer server: listening on %d" % _port)
	get_tree().create_timer(22.0).timeout.connect(func() -> void:
		print("two-peer server: ", relay.loadouts.describe())
		get_tree().quit(0))


func _join() -> void:
	var err: int = _peer.call(&"create_client", "127.0.0.1", _port)
	if err != OK:
		print("two-peer %s: connect failed: %s" % [_role, error_string(err)])
		get_tree().quit(1)
		return
	_input = FakeInput.new()
	add_child(_input)
	_client = DotGameAvatarActionClient.new()
	add_child(_client)
	_client.content_fn = func(_entry: Dictionary) -> DotResult:
		return DotResult.success(Node3D.new())
	if _role == "a":
		_attach_client()
	_peer.connect(&"peer_connected", func(id: int) -> void:
		if id != 1:
			return
		_net.local_peer_id = int(_peer.call(&"get_unique_id"))
		var _s := _net.start()
		var _a := _net.announce_schema(1)
		print("two-peer %s: connected as %d" % [_role, _net.local_peer_id])
		if _role == "b":
			_play_b())
	get_tree().create_timer(11.0 if _role == "a" else 14.0).timeout.connect(_finish)


func _attach_client() -> void:
	var figures := {}
	_client.attach(_net, _input, func(peer: int) -> Object:
		if not figures.has(peer):
			var f := FakeFigure.new()
			f.peer = peer
			f.owner_node = self
			figures[peer] = f
		return figures[peer])


func _play_b() -> void:
	await get_tree().create_timer(2.0).timeout
	_attach_client()
	await get_tree().create_timer(1.5).timeout
	_input.action_requested.emit({"id": "action/12/3", "loop": false})
	await get_tree().create_timer(1.0).timeout
	_input.action_requested.emit({"id": "wave", "loop": false})
	await get_tree().create_timer(1.0).timeout
	_input.action_requested.emit({"id": "action/99/1", "loop": false})
	await get_tree().create_timer(1.0).timeout
	_input.action_requested.emit({"id": "point", "loop": false})
	_seen = _client.loadouts.duplicate(true)


func _note_play(peer: int, id: String, loop: bool) -> void:
	if _net != null and peer != _net.local_peer_id:
		_plays.append([peer, id, loop])


func _note_added(peer: int, id: String, clip: String) -> void:
	_added.append([peer, id, clip])


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
	print("two-peer %s: %s %s" % [_role, "ok  " if ok else "FAIL", what])


func _finish() -> void:
	var others: Array = _client.loadouts.keys().filter(func(p: int) -> bool: return p != _net.local_peer_id)
	if _role == "a":
		var b: int = others[0] if others.size() == 1 else 0
		var ids: Array = _client.loadouts.get(b, []).map(func(e: Dictionary) -> String: return e["id"])
		_check(b > 0 and ids.has("action/12/3") and ids.has("point") and not ids.has("wave"),
			"b's loadout arrived as the backbone has it, read by the server (%s)" % [ids])
		var played: Array = _plays.filter(func(p: Array) -> bool: return p[0] == b).map(func(p: Array) -> String: return p[1])
		_check(played.has("action/12/3"), "b's upload played here (%s)" % [played])
		_check(_added.any(func(a: Array) -> bool: return a[1] == "action/12/3" and a[2] == "Wave_Big"),
			"its fetched clip was handed to the figure by its clip name")
		_check(_plays.any(func(p: Array) -> bool: return p[1] == "action/12/3" and p[2] == true),
			"loop came from the server's entry, not b's request")
		_check(not played.has("wave") and not played.has("action/99/1"),
			"a starter b replaced, and an upload b never equipped, were refused")
		_check(played.has("point"), "an equipped built-in played")
	else:
		var seen_others: Array = _seen.keys().filter(func(p: int) -> bool: return p != _net.local_peer_id)
		var a: int = seen_others[0] if seen_others.size() == 1 else 0
		var ids: Array = _seen.get(a, []).map(func(e: Dictionary) -> String: return e["id"])
		_check(a > 0 and ids.has("dance") and not ids.has("cheer") and ids.size() == 10,
			"the late joiner heard a's loadout, read before it joined (%s)" % [ids])
		_check(_seen.has(_net.local_peer_id), "and its own, as the server read it")
		_check(a > 0 and not _client.loadouts.has(a), "a's loadout was forgotten once a left")
		_check(_added.all(func(x: Array) -> bool: return x[0] == _net.local_peer_id),
			"a clip was added only for its own upload, none for a player with only built-ins")
	var want := CHECKS_A if _role == "a" else CHECKS_B
	print("two-peer %s: %d passed, %d failed of %d" % [_role, _passed, _failed, want])
	get_tree().quit(0 if _failed == 0 and _passed == want else 1)


func _process(_delta: float) -> void:
	if _peer == null:
		return
	_peer.call(&"poll")
	while int(_peer.call(&"get_available_packet_count")) > 0:
		var from: int = _peer.call(&"get_packet_peer")
		var pkt: PackedByteArray = _peer.call(&"get_packet")
		var got := _net.receive(pkt, from)
		if not got.ok:
			print("two-peer ", _role, ": refused a packet from ", from, ": ", got.error.message)


func _send(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
	_peer.set(&"transfer_mode", MultiplayerPeer.TRANSFER_MODE_RELIABLE if delivery == DotNetMessage.Delivery.RELIABLE
		else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
	_peer.call(&"set_target_peer", peer_id)
	var _e: int = _peer.call(&"put_packet", payload)
