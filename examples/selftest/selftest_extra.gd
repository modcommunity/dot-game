extends "selftest_avatar.gd"

## The chat client, look-mute and workbench sections of game_selftest.gd.

## The client's chat box with neither dot-ui nor dot-voice installed: built, quiet, and a
## bridge it is attached to is listened to rather than crashed on. The line crossing a wire is
## mg-prop-hunt's `headless_net`, which has both.
func _test_chat_client_without_the_addons() -> void:
	_section("the client's chat box, in a build with neither of its addons")

	var box := DotGameChatClient.new()
	box.name = "ChatClient"
	add_child(box)
	await get_tree().process_frame

	_check(box.window == null, "it builds no box, because there is no dot-ui")
	_check(box.voice == null, "and no microphone, because there is no dot-voice")
	_check(box.attach(null).ok, "offline is not an error")

	var bridge := FakeChatBridge.new()
	bridge.local_player_id = 7
	_check(box.attach(bridge).ok, "a bridge attaches")
	_check(box.local_player_id == 7, "and the box takes this client's id from it")

	bridge.chat_received.emit({"d": "Ada", "m": "hello", "c": "all"})
	bridge.hello_received.emit(9)
	_check(box.local_player_id == 9, "a later hello moves the id")
	_check(not box.is_typing() and not bool(box.describe().get("box", true)),
		"a line with no box to draw it in is dropped, not a crash")

	box.queue_free()
	_done()


## dot-server's own lines (a vote between games, a join, an admin's `say`) arrive on the shell's
## client link, not on the game's bridge. Eight games drew only the bridge and never showed one.
## The box finds the link in the registry itself; a stub window counts what is drawn.
func _test_chat_client_server_lines() -> void:
	_section("the client's chat box draws the server's own lines, once")

	var link := FakeClientLink.new()
	DotRegistry.register(&"dot_client_link", link)

	var box := DotGameChatClient.new()
	box.name = "ServerLinesClient"
	add_child(box)
	await get_tree().process_frame

	var window := StubChatWindow.new()
	box.window = window

	var bridge := FakeChatBridge.new()
	_check(box.attach(bridge).ok, "a bridge attaches")
	_check(box.link == link, "and the box found the client link in the registry by itself")

	link.chat_received.emit({"kind": "system", "name": "[Server]", "text": "Rocked. 1 of 1."})
	_check(
		window.lines == ["[Server] Rocked. 1 of 1."],
		"a system line on the link is drawn, prefix and all", str(window.lines)
	)

	link.chat_received.emit({"kind": "admin", "name": "[ADMIN] Ada", "text": "hi"})
	_check(window.lines.size() == 2 and window.lines[1] == "[ADMIN] Ada: hi", "an admin line is drawn with its speaker", str(window.lines))

	window.lines.clear()
	link.chat_received.emit({"kind": "state", "relay": true})
	link.chat_received.emit({"d": "Ada", "m": "hello", "c": "all"})
	link.chat_received.emit({"kind": "system", "name": "[Server]", "text": "  "})
	link.chat_received.emit({"kind": "all", "name": "Ada", "text": "hello", "userid": 3})
	_check(window.lines.is_empty(),
		"chat's state, dot-chat's shape, an empty line and a player's line on the link are not drawn",
		str(window.lines))

	bridge.chat_received.emit({"d": "Ada", "m": "hello", "c": "all"})
	_check(window.lines == ["Ada: hello"], "a routed line still comes from the bridge, once", str(window.lines))

	_check(box.attach(bridge).ok and link.get_signal_connection_list(&"chat_received").size() == 1,
		"attaching again does not connect the link twice")
	_check(bool(box.describe().get("server_lines", false)), "describe says the server's lines are read")

	# The player's own block list (`sm`): a muted speaker's routed line is not drawn. A
	# stand-in list, because this suite links no dot-chat; dot-chat's suite proves the list.
	var mutes := StubSelfMute.new()
	box.self_mute = mutes
	window.lines.clear()
	mutes.muted["Ada"] = true
	bridge.chat_received.emit({"d": "Ada", "m": "muted", "c": "all", "s": "3"})
	bridge.chat_received.emit({"d": "Bob", "m": "heard", "c": "all", "s": "4"})
	_check(window.lines == ["Bob: heard"], "a line from a player this reader muted is not drawn", str(window.lines))
	mutes.muted.clear()
	bridge.chat_received.emit({"d": "Ada", "m": "back", "c": "all", "s": "3"})
	_check(window.lines == ["Bob: heard", "Ada: back"], "and is drawn again once unmuted", str(window.lines))
	box.self_mute = null

	box.queue_free()
	await get_tree().process_frame
	_check(link.get_signal_connection_list(&"chat_received").is_empty(),
		"a freed box leaves nothing connected to the link, which outlives every game")

	var quiet := DotGameChatClient.new()
	quiet.server_lines = false
	add_child(quiet)
	await get_tree().process_frame
	_check(quiet.attach(bridge).ok and link.get_signal_connection_list(&"chat_received").is_empty(),
		"server_lines false, for a game that reads the link itself, connects nothing")
	quiet.queue_free()

	var offline := DotGameChatClient.new()
	add_child(offline)
	await get_tree().process_frame
	_check(offline.attach(null).ok and link.get_signal_connection_list(&"chat_received").is_empty(),
		"offline, with no bridge, the link is not read")
	offline.queue_free()

	DotRegistry.unregister(&"dot_client_link")
	link.free()
	_done()


class FakeClientLink:
	extends Object
	signal chat_received(payload: Dictionary)


class StubSelfMute:
	extends RefCounted
	var muted: Dictionary = {}
	func is_muted_line(wire: Dictionary) -> bool:
		return muted.has(str(wire.get("d", "")))


class StubChatWindow:
	extends Control
	var lines: Array = []
	func add_text(text: String, _colour: Color = Color.WHITE) -> void:
		lines.append(text)
	func add_said(speaker: String, text: String, _a: Color = Color.WHITE, _b: Color = Color.WHITE) -> void:
		lines.append("%s: %s" % [speaker, text])
	func is_open() -> bool:
		return false


class FakeChatBridge:
	extends RefCounted
	signal chat_received(wire: Dictionary)
	signal voice_arrived(payload: PackedByteArray)
	signal hello_received(id: int)
	var local_player_id: int = 0
	var said: Array = []
	func ask_say(channel: StringName, text: String) -> void:
		said.append([channel, text])
	func send_voice(_bytes: PackedByteArray) -> void:
		pass


func _test_look_mute() -> void:
	_section("the look-to-gag keys: default on, G and K, a conflict is found, not clobbered")

	var held := InputEventKey.new()
	held.physical_keycode = KEY_K
	InputMap.add_action(&"test_other_k")
	InputMap.action_add_event(&"test_other_k", held)
	for gone in [&"voice_gag", &"voice_mute"]:
		if InputMap.has_action(gone):
			InputMap.erase_action(gone)

	var host := Node.new()
	add_child(host)
	var client := _look_client()
	host.add_child(client)
	var chat: Node = load("res://examples/fixtures/test_voice_chat_box.gd").new()
	client.chat = chat
	var cam := Camera3D.new()
	host.add_child(cam)
	cam.make_current()
	client.look_positions_fn = func() -> Dictionary: return {7: Vector3(0, 0, -5)}
	client.look_chat_mute_fn = func(peer: int, on: bool) -> void: chat.set_meta(&"chat_muted", [peer, on])
	var done := client.setup()

	_check(done.ok and client.look_mute != null, "on by default when the chat has a voice")
	_check(InputMap.has_action(&"voice_gag") and InputMap.has_action(&"voice_mute"), "both actions exist")
	_check(client.look_mute.get(&"separate_keys") == true and client.look_mute.get(&"manager") == chat.voice,
		"on separate keys, driving the chat's voice manager")
	var mute_key := (InputMap.action_get_events(&"voice_mute")[0] as InputEventKey).physical_keycode
	_check(mute_key != KEY_K and mute_key != KEY_H and client.look_conflicts.is_empty(),
		"the mute key skipped K (held by another action) and H (help): %s" % OS.get_keycode_string(mute_key))

	client.look_mute.call(&"tap", 0, false)
	_check(chat.voice.gagged.get(7, false), "the gag key gags the player looked at, through the voice state")
	client.look_mute.call(&"tap", 0, true)
	_check(chat.voice.local_mutes.get(7, false) and chat.get_meta(&"chat_muted") == [7, true],
		"the mute key mutes voice and calls the chat hook")

	var clash := InputEventKey.new()
	clash.physical_keycode = KEY_G
	InputMap.add_action(&"test_other_g")
	InputMap.action_add_event(&"test_other_g", clash)
	var found := client.find_look_conflicts()
	_check(found.size() == 1 and found[0]["other"] == "test_other_g",
		"a key another action holds is reported, and left bound")

	var off := _look_client(false)
	off.use_look_mute = false
	off.chat = load("res://examples/fixtures/test_voice_chat_box.gd").new()
	host.add_child(off)
	var _s := off.setup()
	_check(off.look_mute == null, "use_look_mute = false builds nothing")

	var bare := _look_client()
	bare.chat = ClientChat.new()
	host.add_child(bare)
	var _b := bare.setup()
	_check(bare.look_mute == null, "a chat with no voice builds nothing")

	var late := _look_client()
	host.add_child(late)
	var _l := late.setup()
	late.look_voice = load("res://examples/fixtures/test_voice_state.gd").new()
	late.build_look_mute()
	_check(late.look_mute != null and late.look_mute.get(&"manager") == late.look_voice,
		"a client whose voice comes after setup() builds the keys with build_look_mute()")

	_look_rostered(host)

	InputMap.erase_action(&"test_other_k")
	InputMap.erase_action(&"test_other_g")
	host.queue_free()
	_done()


func _look_client(with_script := true) -> DotGameClient:
	var c := DotGameClient.new()
	c.require_camera = false
	c.use_settings = false
	c.use_console = false
	c.capture_pointer = false
	if with_script:
		c.look_mute_script = "res://examples/fixtures/test_look_mute.gd"
	return c


func _look_rostered(host: Node) -> void:
	var rostered := _look_client()
	var rchat: Node = load("res://examples/fixtures/test_voice_chat_box.gd").new()
	rchat.self_mute.roster = [
		{"id": 1, "name": "me", "key": "k1", "peer": 5, "bot": false},
		{"id": 2, "name": "ann", "key": "k2", "peer": 9, "bot": false},
		{"id": 3, "name": "bot", "key": "", "peer": 11, "bot": true}] as Array[Dictionary]
	rchat.self_mute.you = 1
	rostered.chat = rchat
	rostered.look_position_fn = func(row: Dictionary) -> Variant:
		return Vector3(0, 0, -4) if row["name"] == "ann" else Vector3(0, 0, -2)
	host.add_child(rostered)
	var _r := rostered.setup()
	_check(rostered.call(&"_look_target") == 9, "a game's position-per-roster-row finds the peer looked at, skipping you and bots")
	rostered.look_mute.call(&"tap", 0, true)
	_check(rchat.voice.local_mutes.get(9, false) and rchat.self_mute.muted == [["ann", true]],
		"a mute reaches the block list that !sm uses, by the roster row of that peer")


func _test_workbench_hosting() -> void:
	_section("the workbench is on where the player owns the process, off in production")
	_check(DotGameWorkbench.default_panel(true, false, false, false), "the editor gets the panel")
	_check(DotGameWorkbench.default_panel(false, true, false, false), "a debug build gets the panel")
	_check(DotGameWorkbench.default_panel(false, false, true, false), "a listen host gets the panel")
	_check(not DotGameWorkbench.default_panel(false, false, false, false), "a production client does not")
	_check(not DotGameWorkbench.default_panel(true, true, true, true), "a dedicated server never builds a panel")
	_check(not DotGameWorkbench.local_allowed(false, false, false), "the panel's actor is untrusted in production")
	# this project links no dot-workbench: start() says so and builds nothing
	var wb := DotGameWorkbench.new()
	add_child(wb)
	var res := wb.start()
	_check(res.ok and res.value == false and wb.overlay == null, "without the addon there is no workbench and no error")
	_check(wb.accounts and wb.account_gate == null, "accounts default on, and no gate without dot-auth or dot-workbench")
	var fake_auth := Node.new()
	_check(not DotGameWorkbenchAuth.ticket_resolver(null).is_valid() and not DotGameWorkbenchAuth.ticket_resolver(fake_auth).is_valid(), "no auth server or no ticket key gives no resolver")
	_check(DotGameWorkbenchAuth.identity_of_ticket("a.b.c", "", "srv", 0) == null, "a ticket nobody can verify is no identity")
	_check(DotGameWorkbenchAuth.attach(wb, func(_t: String) -> Variant: return null, Callable()) == null, "attach without an api builds no gate")
	fake_auth.free()
	wb.queue_free()
	_done()
