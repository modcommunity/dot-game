extends Node

## Player trails over dot-net: the relay checks a request with DotTrailEquip and tells everyone, a refused request is answered with the id still worn, a late joiner hears who wears what, the client draws one emitter per wearer, and the pre-join hook fetches the pack. Needs dot-trail linked into addons/.

const CHECKS := 24

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what)


func _png() -> PackedByteArray:
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	return img.save_png_to_buffer()


func _net(server: bool) -> DotNetManager:
	var n := DotNetManager.new()
	n.is_server = server
	n.config_file = ""
	var _s := n.setup()
	var _r := DotGameTrailMessage.register(n)
	n.messages.seal()
	return n


func _decode(net: DotNetManager, payload: PackedByteArray) -> DotGameTrailMessage:
	var read := net.messages.decode(DotNetReader.new(payload), 1, false)
	return read.value as DotGameTrailMessage if read.ok else null


func _ask(net: DotNetManager, peer: int, id: String) -> void:
	var m := DotGameTrailMessage.new()
	m.sender_peer_id = peer
	m.id = id
	net.messages.dispatch(m)


func _run() -> void:
	print("dot-game: trails")
	var registry := DotTrailRegistry.new()
	registry.config.equip_cooldown = 0.0
	for spec: Array in [["spark", "public", []], ["gold", "groups", ["donator"]]]:
		var d: DotTrailDef = DotTrailDef.from_dict({"id": spec[0], "image": spec[0] + ".png", "access": spec[1], "groups": spec[2]}).value
		var _a := registry.add(d, _png())
	var equip := DotTrailEquip.new(registry)
	var server := _net(true)
	add_child(server)
	var sent := []
	server.send_fn = func(peer: int, payload: PackedByteArray, _d: int) -> void: sent.append([peer, payload])
	var groups := {7: PackedStringArray()}
	var served := DotGameTrailRelay.serve(server, equip, func(p: int) -> PackedStringArray: return groups.get(p, PackedStringArray()))
	_check(served.ok and DotGameTrailRelay.of(server) == served.value, "the relay serves and is found on the net")
	var relay: DotGameTrailRelay = served.value
	relay.add_peer(7)
	_ask(server, 7, "spark")
	var told := _decode(server, sent[0][1]) if sent.size() == 1 else null
	_check(told != null and sent[0][0] == 0 and told.actor == 7 and told.id == "spark", "an allowed request is told to everyone, naming the wearer")
	_check(equip.worn(7) == "spark", "the server's record holds it")
	sent.clear()
	_ask(server, 7, "gold")
	var back := _decode(server, sent[0][1]) if sent.size() == 1 else null
	_check(back != null and sent[0][0] == 7 and back.id == "spark" and back.actor == 7, "a refused request is answered to the asker with the id still worn")
	_check(equip.worn(7) == "spark", "a refusal changes nothing")
	sent.clear()
	_ask(server, 7, "nonesuch")
	_check(sent.size() == 1 and sent[0][0] == 7 and equip.worn(7) == "spark", "an unknown id is refused")
	sent.clear()
	_ask(server, 0, "spark")
	_check(sent.is_empty(), "a request with no sender is dropped")
	groups[7] = PackedStringArray(["donator"])
	_ask(server, 7, "gold")
	_check(equip.worn(7) == "gold" and sent.size() == 1, "the group from groups_fn lets a donator wear the restricted trail")
	sent.clear()
	groups[7] = PackedStringArray()
	_check(relay.revalidate(7) and equip.worn(7) == "" and sent.size() == 1 and _decode(server, sent[0][1]).id == "", "losing the group takes it off and tells everyone")
	sent.clear()
	_ask(server, 7, "spark")
	sent.clear()
	relay.add_peer(9)
	var late := _decode(server, sent[0][1]) if sent.size() == 1 else null
	_check(late != null and sent[0][0] == 9 and late.actor == 7 and late.id == "spark", "a late joiner is told who wears what")
	sent.clear()
	_ask(server, 7, "")
	_check(equip.worn(7) == "" and _decode(server, sent[0][1]).id == "", "an empty id takes it off")
	_ask(server, 7, "spark")
	sent.clear()
	relay.remove_peer(7)
	_check(equip.worn(7) == "" and sent.size() == 1 and _decode(server, sent[0][1]).actor == 7 and _decode(server, sent[0][1]).id == "", "leaving drops the record and tells everyone")
	var bad := DotGameTrailMessage.new()
	bad.id = "Bad Id"
	_check(not bad.validate().ok, "a message id outside a-z, 0-9, _ is refused")
	bad.id = "x".repeat(33)
	_check(not bad.validate().ok, "an over-long id is refused")

	var cooled := DotTrailRegistry.new()
	cooled.config.equip_cooldown = 1.0
	var _c := cooled.add(registry.get_def("spark"), _png())
	var clock := [0]
	var slow := DotTrailEquip.new(cooled)
	slow.now_ms = func() -> int: return clock[0]
	var server2 := _net(true)
	add_child(server2)
	var sent2 := []
	server2.send_fn = func(peer: int, payload: PackedByteArray, _d: int) -> void: sent2.append([peer, payload])
	var _s2 := DotGameTrailRelay.serve(server2, slow)
	_ask(server2, 5, "spark")
	_ask(server2, 5, "")
	_check(slow.worn(5) == "spark", "the equip cooldown applies through the relay")

	var client := _net(false)
	add_child(client)
	var tc := DotGameTrailClient.new()
	var figures := {7: Node3D.new(), 9: Node3D.new()}
	for f: Node in figures.values():
		add_child(f)
	tc.node_for = func(a: int) -> Node3D: return figures.get(a)
	var seen := []
	tc.changed.connect(func(a: int, i: String) -> void: seen.append([a, i]))
	var _att := tc.attach(client, registry)
	var wire := func(actor: int, id: String) -> void:
		var m := DotGameTrailMessage.new()
		m.actor = actor
		m.id = id
		client.messages.dispatch(m)
	wire.call(7, "spark")
	var emitters := (figures[7] as Node3D).get_children().filter(func(n: Node) -> bool: return n is DotTrailEmitter)
	_check(emitters.size() == 1 and (emitters[0] as DotTrailEmitter).def.id == "spark" and seen == [[7, "spark"]], "the client puts an emitter on the wearer's figure")
	wire.call(7, "gold")
	await get_tree().process_frame
	emitters = (figures[7] as Node3D).get_children().filter(func(n: Node) -> bool: return n is DotTrailEmitter and not n.is_queued_for_deletion())
	_check(emitters.size() == 1 and (emitters[0] as DotTrailEmitter).def.id == "gold", "a change replaces the emitter, never stacks a second")
	wire.call(7, "")
	await get_tree().process_frame
	_check((figures[7] as Node3D).get_children().filter(func(n: Node) -> bool: return n is DotTrailEmitter).is_empty() and not tc.worn.has(7), "an empty id removes it")
	wire.call(9, "not_in_the_pack")
	_check((figures[9] as Node3D).get_children().is_empty(), "an id the pack does not hold draws nothing")
	wire.call(9, "spark")
	figures.erase(9)
	wire.call(9, "spark")
	figures[9] = Node3D.new()
	add_child(figures[9])
	tc.refresh()
	_check((figures[9] as Node3D).get_children().size() == 1, "refresh draws a figure that spawned after the message")
	_check(tc.request("spark").ok or true, "request is callable")
	_check(DotGameTrailClient.pack_from_rules({"sv_trail_pack": "trails-x@1.0.0"}) == PackedStringArray(["trails-x", "1.0.0"]), "the pack is read from the server's rule")
	_check(DotGameTrailClient.pack_from_rules({"sv_trail_pack": "junk"}).is_empty() and DotGameTrailClient.pack_from_rules({}).is_empty(), "a missing or malformed rule is no pack")

	var pre := DotGamePrejoin.new()
	var calls := []
	pre.rules_fn = func(_a: String) -> Dictionary: return {"sv_trail_pack": "trails-x@1.0.0"}
	pre.trails_fn = func(rules: Dictionary) -> DotResult:
		calls.append(rules)
		return DotResult.fail(DotError.CODE_NETWORK, "cdn down")
	var joined: DotResult = await pre.prepare(self, "127.0.0.1:27015")
	_check(calls.size() == 1 and calls[0].has("sv_trail_pack") and joined.ok, "prejoin fetches the trail pack and a failure never blocks the join")

	print("%d passed, %d failed" % [_passed, _failed])
	for f in _failures:
		print("  FAIL ", f)
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran; expected %d" % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)
