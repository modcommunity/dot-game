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
	_check(
		box.voice == null or ResourceLoader.exists(DotGameChatClient.VOICE_SCRIPT),
		"and no microphone unless dot-voice is linked"
	)
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


func _test_store_entitlements_absent() -> void:
	_section("store entitlements: a project without dot-loadout, or a non-manager, is left alone")
	var plain := Node.new()
	_check(not DotGameStoreEntitlements.attach(plain), "a node without entitlement_source is not wrapped")
	_check(not DotGameStoreEntitlements.attach(null), "null is not wrapped")
	_check(DotGameStoreEntitlements.attach_tree(plain) == 0, "an empty tree attaches nothing")
	plain.free()
	_done()


class StoreClient:
	extends RefCounted
	func get_integration(_path: String, query: Dictionary) -> DotResult:
		return DotResult.success({"ok": true, "player": query.get("player"), "items": [
			{"key": "arena_gold_skin", "name": "Gold skin", "kind": "AVATAR"},
			{"key": "arena_gold_skin", "name": "dup"},
			{"key": "launcher_pack", "name": "Launcher", "kind": "ITEM"}, 5, {"name": "no key"}]})


func _test_store_panel() -> void:
	_section("store panel: owned items by key, deduplicated, a store button that reports its address")
	var panel := DotGameStorePanel.new()
	add_child(panel)
	_check(not panel.is_owned("x") and panel.owned().is_empty(), "empty before a read")
	var res: DotResult = await panel.refresh(StoreClient.new(), "p1")
	_check(res.ok and res.value == 2, "refresh returns the distinct owned count", str(res.value))
	_check(panel.is_owned("arena_gold_skin") and panel.is_owned("launcher_pack") and not panel.is_owned("dup"), "owned by key")
	_check((panel.owned()[0] as Dictionary)["name"] == "Gold skin", "the first entry for a key wins")
	_check(not (await panel.refresh(null, "p1")).ok, "no client fails, list kept")
	_check(panel.owned().size() == 2, "a failed read leaves the list as it was")
	panel.store_url = "https://example.test/dashboard/store"
	var got: Array = []
	panel.store_requested.connect(func(url: String) -> void: got.append(url))
	panel.open_store()
	_check(got == ["https://example.test/dashboard/store"], "the button reports the store address")
	_check(DotGameStorePanel.owned_from({"items": "bad"}).is_empty(), "a malformed body owns nothing")
	panel.queue_free()
	_check(DotGameStorePanel.add_to_menu(null, Callable()) == null, "no menu: no store page")
	_check(DotGameStorePanel.add_to_menu(Node.new(), Callable()) == null, "a non-menu is left alone")
	_done()


class FakeManager:
	extends RefCounted
	var store_url: String = "https://example.test/store"
	var asked: Array = []
	func request_store(item_id: StringName) -> String:
		asked.append(item_id)
		return store_url


class FakeCommand:
	extends RefCounted
	var manager := FakeManager.new()
	func offer(key: String, include_locked: bool = false) -> Dictionary:
		return {"key": key, "locked": include_locked}


class FakeLoadoutMenu:
	extends RefCounted
	var offer_fn := Callable()
	var store_fn := Callable()
	var include_locked := true


func _test_loadout_store() -> void:
	_section("loadout menu: locked store items solo (offer asks for locked, store button reaches the manager)")
	_check(not DotGameStoreEntitlements.wire_menu(null, Callable(), Callable()), "no menu: nothing wired")
	_check(not DotGameStoreEntitlements.wire_menu(Node.new(), Callable(), Callable()), "a non-loadout menu is left alone")
	var menu := FakeLoadoutMenu.new()
	var holder: Array = [null]
	_check(DotGameStoreEntitlements.wire_menu(menu, func() -> Object: return holder[0], func() -> String: return "p1"), "wired")
	var early: Variant = await menu.offer_fn.call()
	_check(early is DotResult and not early.ok, "before the match exists the offer fails, not crashes")
	var command := FakeCommand.new()
	holder[0] = command
	var offer: Dictionary = await menu.offer_fn.call()
	_check(offer.get("key") == "p1" and offer.get("locked") == true, "the solo offer includes locked items", str(offer))
	menu.include_locked = false
	var plain: Dictionary = await menu.offer_fn.call()
	_check(plain.get("locked") == false, "include_locked off is honoured")
	var url: String = menu.store_fn.call(&"sniper")
	_check(url == "https://example.test/store" and command.manager.asked == [&"sniper"], "store_fn is the manager's request_store")
	_done()


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


func _test_workbench_key() -> void:
	_section("the workbench key: the semicolon by default, ignored while typing, a toggle otherwise")
	if InputMap.has_action(DotGameWorkbench.TOGGLE_ACTION):
		InputMap.erase_action(DotGameWorkbench.TOGGLE_ACTION)
	DotGameWorkbench.ensure_action()
	var ev := InputMap.action_get_events(DotGameWorkbench.TOGGLE_ACTION)
	_check(ev.size() == 1 and (ev[0] as InputEventKey).physical_keycode == KEY_SEMICOLON, "the default binding is the semicolon")
	var wb := DotGameWorkbench.new()
	var stub := GDScript.new()
	stub.source_code = "extends Control\nfunc open() -> void:\n\tvisible = true\nfunc close() -> void:\n\tvisible = false\n"
	var _r := stub.reload()
	var panel: Control = stub.new()
	panel.visible = false
	wb.overlay = panel
	add_child(wb)
	add_child(panel)
	var key := InputEventKey.new()
	key.physical_keycode = KEY_SEMICOLON
	key.pressed = true
	var line := LineEdit.new()
	add_child(line)
	line.grab_focus()
	_check(DotGameWorkbench.text_has_focus(get_viewport().gui_get_focus_owner()), "a focused LineEdit counts as typing")
	_check(not wb.handle_key(key, get_viewport().gui_get_focus_owner()) and not wb.is_open(), "the key is ignored with a LineEdit focused")
	var edit := TextEdit.new()
	_check(DotGameWorkbench.text_has_focus(edit) and DotGameWorkbench.text_has_focus(CodeEdit.new()), "TextEdit and CodeEdit count too")
	line.release_focus()
	var chatting := [true]
	wb.typing_fn = func() -> bool: return chatting[0]
	_check(not wb.handle_key(key, null) and not wb.is_open(), "the key is ignored while the chat or console is open")
	chatting[0] = false
	_check(wb.handle_key(key, null) and wb.is_open(), "otherwise the key opens it")
	_check(wb.handle_key(key, get_viewport().gui_get_focus_owner()) and not wb.is_open(), "and closes it again")
	var other := InputEventKey.new()
	other.physical_keycode = KEY_BACKSLASH
	other.pressed = true
	_check(not wb.handle_key(other, null), "another key does nothing")
	InputMap.action_erase_events(DotGameWorkbench.TOGGLE_ACTION)
	var moved := InputEventKey.new()
	moved.physical_keycode = KEY_BACKSLASH
	InputMap.action_add_event(DotGameWorkbench.TOGGLE_ACTION, moved)
	_check(wb.handle_key(other, null) and not wb.handle_key(key, null), "a rebound action follows the new key and not the semicolon")
	line.queue_free()
	edit.free()
	panel.queue_free()
	wb.overlay = null
	wb.queue_free()
	InputMap.erase_action(DotGameWorkbench.TOGGLE_ACTION)
	_done()


func _test_class_immunity() -> void:
	_section("class immunity: a class that lists fall takes none and breaks no legs; respawn clears it")
	var combat_path := "res://addons/dot_combat/dot_combat_manager.gd"
	if not ResourceLoader.exists(combat_path) or not ResourceLoader.exists(DotGameClassImmunity.APPLY_SCRIPT):
		_check(DotGameClassImmunity.apply(null, null, 1) == 0, "without dot-combat it is a no-op")
		_done()
		return
	var manager: Node = load(combat_path).new()
	manager.set(&"register_service", false)
	manager.set(&"trace", load("res://addons/dot_combat/trace/dot_trace_flat.gd").call(&"with_floor", 0.0))
	manager.set(&"rules", load("res://addons/dot_combat/resolve/dot_damage_rules.gd").new())
	manager.set(&"config", load("res://addons/dot_combat/dot_combat_config.gd").new())
	add_child(manager)
	# Immunity matches DotDamageType.id; an unregistered kind resolves as the default type, so games register "fall".
	manager.call(&"register_damage_type", load("res://addons/dot_combat/core/dot_damage_type.gd").call(&"make", &"fall", "Fall"))
	var health := _immune_health()
	manager.call(&"register_health", 7, health)
	manager.call(&"register_health", 8, _immune_health())
	var rules: Object = load("res://addons/dot_combat/core/dot_fall_damage_rules.gd").new()
	rules.set(&"enabled", true)
	rules.set(&"threshold", 10.0)
	rules.set(&"scale", 2.0)
	rules.set(&"legs_seconds", 2.0)
	var ctl := ImmuneController.new()
	add_child(ctl)
	var fall: Node = load("res://addons/dot_combat/core/dot_fall_damage.gd").new()
	fall.set(&"rules", rules)
	fall.set(&"victim", 7)
	var cref: DotNodeRef = DotNodeRef.of_path(ctl.get_path())
	cref.mode = DotNodeRef.Mode.ABSOLUTE
	var mref: DotNodeRef = DotNodeRef.of_path(manager.get_path())
	mref.mode = DotNodeRef.Mode.ABSOLUTE
	fall.set(&"controller", cref)
	fall.set(&"combat", mref)
	add_child(fall)
	var legs: Array[int] = []
	fall.connect(&"legs_broken", func(_s: float, _k: float) -> void: legs.append(1))
	var immune_def := ImmuneDef.new([&"fall"])
	var plain_def := ImmuneDef.new([])

	_check(DotGameClassImmunity.ensure(manager, false) == null, "nothing is created until a class is applied")
	ctl.landed.emit(15.0)
	_check(is_equal_approx(health.get(&"health"), 90.0) and legs.size() == 1, "no class applied: unchanged (10 damage, legs break)")
	health.set(&"health", 100.0)

	_check(DotGameClassImmunity.apply(manager, immune_def, 7) == 1, "a class with immune [fall] writes one kind")
	ctl.landed.emit(15.0)
	_check(is_equal_approx(health.get(&"health"), 100.0), "immune to fall: no damage")
	_check(legs.size() == 1, "immune to fall: legs_broken is not emitted")

	_check(DotGameClassImmunity.apply(manager, plain_def, 8) == 0, "a class without immune writes none")
	_check(not DotGameClassImmunity.ensure(manager).call(&"is_immune", 7, &"bullet"), "other kinds still hurt")

	_check(DotGameClassImmunity.apply(manager, plain_def, 7) == 0, "respawn as another class")
	ctl.landed.emit(15.0)
	_check(is_equal_approx(health.get(&"health"), 90.0) and legs.size() == 2, "the old immunity is gone")
	_check(DotGameClassImmunity.apply(manager, immune_def, 7) == 1 and DotGameClassImmunity.apply(manager, null, 7) == 0, "a null class clears")
	var old := GDScript.new()
	old.source_code = "static func other() -> int:\n\treturn 1\n"
	old.reload()
	_check(DotGameClassImmunity.call_apply(old, immune_def, RefCounted.new(), 7) == 0, "an older dot-player-class without to_immunity is skipped, not a script error")
	_check(not DotGameClassImmunity.ensure(manager).call(&"is_immune", 7, &"fall"), "cleared")
	manager.queue_free()
	ctl.queue_free()
	fall.queue_free()
	_done()


func _immune_health() -> Node:
	var h: Node = load("res://addons/dot_combat/core/dot_health.gd").new()
	h.set(&"max_health", 100.0)
	h.set(&"health", 100.0)
	add_child(h)
	return h


class ImmuneController extends Node:
	signal landed(impact: float)
	var state: Object = null
	var surfaces: Object = null


class ImmuneDef extends RefCounted:
	var immune_to: Array = []

	func _init(kinds: Array) -> void:
		immune_to = kinds


func _test_combat_feel_inert() -> void:
	_section("combat feel is an inert no-op without dot-weapon, dot-ui and dot-player-controller")
	var feel := DotGameCombatFeel.new(true)
	_check(feel.spread == null and feel.recoil == null and feel.sprint == null, "no addon, no rules")
	var names: Array[String] = []
	feel.bind_cvars(func(n: String, _d: String, _h: String, _f: int) -> Object:
		names.append(n)
		return null)
	_check(names.is_empty(), "no cvars register")
	var arsenal := Node.new()
	feel.attach(arsenal)
	feel.attach(null)
	feel.track_tunables(arsenal)
	feel.sprint_defaults(arsenal)
	feel.follow_cvars(null)
	_check(not feel.bind_console(null) and not feel.bind_console(arsenal), "no console binding")
	feel.drive(null, arsenal)
	_check(true, "attach, track, follow and drive on nothing do not error")
	arsenal.free()
	_done()


class FakeSpread:
	extends RefCounted
	var enabled := true


class FakeArsenal:
	extends Node
	var scale := 1.0
	func spread_now() -> float:
		return 1.0
	func crosshair_scale() -> float:
		return scale


class FakeCrosshair:
	extends Control
	var gap_scale := 1.0
	var fov_degrees := 75.0
	func set_spread(_d: float) -> void:
		pass


func _test_combat_feel_gap_scale() -> void:
	_section("drive carries the weapon's crosshair_scale to the crosshair: a sniper wider, an automatic tighter")
	var feel := DotGameCombatFeel.new(true)
	feel.spread = FakeSpread.new()
	var arsenal := FakeArsenal.new()
	var cross := FakeCrosshair.new()
	arsenal.scale = 1.6
	feel.drive(cross, arsenal)
	_check(is_equal_approx(cross.gap_scale, 1.6), "a sniper's scale widens the gap")
	arsenal.scale = 0.7
	feel.drive(cross, arsenal)
	_check(is_equal_approx(cross.gap_scale, 0.7), "an automatic's scale tightens it")
	arsenal.free()
	cross.free()
	_done()
