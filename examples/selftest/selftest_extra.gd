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


func _test_store_entitlements_absent() -> void:
	_section("store entitlements: a project without dot-loadout, or a non-manager, is left alone")
	var plain := Node.new()
	_check(not DotGameStoreEntitlements.attach(plain), "a node without entitlement_source is not wrapped")
	_check(not DotGameStoreEntitlements.attach(null), "null is not wrapped")
	_check(DotGameStoreEntitlements.attach_tree(plain) == 0, "an empty tree attaches nothing")
	plain.free()
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


func _test_thread_defaults_off() -> void:
	_section("threads are off by default and turn on only through their own switch")
	var sc := DotServerConfig.new()
	_check(not sc.threads_net and not sc.threads_npc, "both opt-ins default off")
	_check(sc.net_snapshot_workers() == 0 and sc.npc_workers() == 0, "no workers asked for while off")
	sc.threads_net = true
	sc.worker_threads = 3
	_check(sc.net_snapshot_workers() == 3 and sc.npc_workers() == 0, "one switch enables only its own subsystem")
	_check(DotParallel.resolve_workers(0) == 0, "0 workers is the main thread")
	_check(DotParallel.resolve_workers(3) == (3 if DotParallel.available() else 0), "workers only where DotParallel.available() (never web)")
	sc.worker_threads = 0
	_check(sc.net_snapshot_workers() == 0, "sv_worker_threads 0 rules every subsystem out")
	_done()


class _FakeVarSource extends RefCounted:
	var vars := {}

	func add_var(name: StringName, _help: String, getter: Callable, setter: Callable) -> void:
		vars[name] = [getter, setter]


func _test_map_load_threads() -> void:
	_section("map_load_threads reaches dot-map's default worker count, on the server and the client")
	var threads := load("res://addons/dot_game/runtime/dot_game_map_threads.gd")
	var have_map := ResourceLoader.exists(threads.BUILD_SCRIPT)
	var console := DotConsole.new()
	add_child(console)
	DotGameNetcode.follow_map_threads(console)
	var cv := console.find_cvar("map_load_threads")
	_check(cv != null, "the server cvar is registered")
	_check(cv != null and cv.get_int() == 0, "and defaults to 0 (inline)")
	_check(threads.current() == 0, "so dot-map starts with no workers (dot-map: %s)" % str(have_map))
	var _r := console.set_cvar("map_load_threads", "3")
	DotGameNetcode.follow_map_threads(console)
	_check(threads.current() == (3 if have_map else 0), "setting it reaches DotMapParallelBuild.default_workers")
	_r = console.set_cvar("map_load_threads", "-1")
	DotGameNetcode.follow_map_threads(console)
	_check(DotParallel.resolve_workers(threads.current()) == (DotParallel.resolve_workers(-1) if have_map else 0), "-1 resolves through DotParallel (automatic)")
	_check(DotParallel.available() or DotParallel.resolve_workers(threads.current()) == 0, "where DotParallel.available() is false (web, no threads) the count stays 0 whatever the cvar says")
	var src := _FakeVarSource.new()
	threads.add_client_var(src)
	var setter: Callable = src.vars[&"map_load_threads"][1]
	var good: DotResult = setter.call("2")
	var bad: DotResult = setter.call("99")
	_check(good.ok and (not bad.ok and bad.error.code == DotError.CODE_INVALID) and threads.current() == (2 if have_map else 0), "the client variable sets it and refuses a count over 64")
	_r = console.set_cvar("map_load_threads", "0")
	DotGameNetcode.follow_map_threads(console)
	threads.client_value = 0
	_check(threads.current() == 0, "back to 0 puts dot-map back inline")
	console.queue_free()
	_done()


func _test_workbench_thread_cvars() -> void:
	_section("the workbench edits and saves the server's thread cvars")
	var console := DotConsole.new()
	add_child(console)
	console.cvar("sv_worker_threads", "0", "Workers.", DotConVar.FLAG_ARCHIVE).with_range(-1, 64)
	console.cvar("sv_threads_net", "0", "Net threads.", DotConVar.FLAG_ARCHIVE)
	var types := DotGameWorkbench.THREAD_CVARS.duplicate()
	types["sv_no_such_cvar"] = "int"
	var set := DotGameWorkbench.cvar_set(console, types, "threads", "dot_server")
	var root := "user://wb_thread_cvars_%d" % OS.get_process_id()
	set.roots = PackedStringArray([root])
	var names: Array = set.schema.map(func(f: Dictionary) -> String: return f["name"])
	_check(names == ["sv_worker_threads", "sv_threads_net"], "only cvars that exist become fields", str(names))
	_check(set.schema[0].get("max") == 64.0, "a cvar's range is the field's")
	var runtime := DotProfileRuntime.new()
	runtime.save_root = root
	runtime.permit = func(_a: Variant, _f: String) -> bool: return true
	runtime.add_set(set)
	_check(DotGameWorkbench.bind_cvar_set(set, runtime, console) == 0, "no saved file applies nothing")
	console.set_cvar("sv_threads_net", "1")
	var r := runtime.handle_request("t", DotProfileRuntime.make_request("set", "threads", "server", "sv_worker_threads", 4))
	_check(r.ok and console.get_int("sv_worker_threads") == 4, "an edit sets the cvar", str(r.error.message if not r.ok else ""))
	_check(console.get_bool("sv_threads_net"), "a cvar changed at the console is not reverted by an edit of another")
	var saved := runtime.handle_request("t", DotProfileRuntime.make_request("save", "threads", "server"))
	_check(saved.ok and str(saved.value.get("saved", "")).ends_with("server/addon/dot_server/threads/server.yml"), "save writes the server tier", str(saved.value if saved.ok else saved.error.message))
	var fresh := DotConsole.new()
	add_child(fresh)
	fresh.cvar("sv_worker_threads", "0", "Workers.", DotConVar.FLAG_ARCHIVE).with_range(-1, 64)
	fresh.cvar("sv_threads_net", "0", "Net threads.", DotConVar.FLAG_ARCHIVE)
	var again := DotGameWorkbench.cvar_set(fresh, DotGameWorkbench.THREAD_CVARS, "threads", "dot_server")
	again.roots = PackedStringArray([root])
	_check(DotGameWorkbench.bind_cvar_set(again, null, fresh) == 1 and fresh.get_int("sv_worker_threads") == 4, "the saved file is applied at the next start")
	var file := root.path_join("server/addon/dot_server/threads/server.yml")
	DirAccess.remove_absolute(file)
	console.queue_free()
	fresh.queue_free()
	_done()


func _test_relevance_cvars() -> void:
	_section("the relevance settings are server cvars that drive the default interest strategy")
	var Rel: GDScript = load("res://addons/dot_game/net/dot_game_relevance.gd")
	var console := DotConsole.new()
	add_child(console)
	var net := DotNetManager.new()
	var distance := DotNetInterestDistance.new()
	distance.radius = 100.0
	distance.far_every = 2
	distance.far_distance = 30.0
	net.interest = distance
	_check(Rel.bind(console, net, {"interest_radius": 80.0}), "binds to the default strategy")
	_check(console.find_cvar("net_far_every") != null and console.find_cvar("net_far_distance") != null, "the far pair are cvars")
	_check(is_equal_approx(distance.radius, 80.0) and distance.far_every == 2, "the operator file seeds the radius as a ceiling; 0 keeps the game's far values")
	console.set_cvar("net_far_every", "4")
	console.set_cvar("net_far_distance", "50")
	_check(distance.far_every == 4 and is_equal_approx(distance.far_distance, 50.0), "the far pair replaces the game's, live")
	console.set_cvar("net_interest_radius", "150")
	_check(is_equal_approx(distance.radius, 100.0), "the radius never raises the game's own")
	console.set_cvar("net_far_every", "0")
	_check(distance.far_every == 2, "0 gives the game's value back")
	var listeners := console.find_cvar("net_far_every").changed.get_connections().size()
	Rel.bind(console, net, {"interest_radius": 80.0})
	_check(console.find_cvar("net_far_every").changed.get_connections().size() == listeners, "binding again adds no second listener")
	var early := DotConsole.new()
	add_child(early)
	Rel.ensure_cvars(early)
	var set := DotGameWorkbench.cvar_set(early, Rel.TYPES, "relevance", "dot_server")
	_check(set != null and set.schema.size() == 3, "the workbench set exists even when it starts before the netcode")
	var late := DotNetInterestDistance.new()
	var late_net := DotNetManager.new()
	late_net.interest = late
	Rel.bind(early, late_net, {"interest_radius": 60.0})
	_check(is_equal_approx(late.radius, 60.0), "a cvar made early still takes the operator's ceiling")
	early.queue_free()
	late_net.free()
	var other := DotNetManager.new()
	other.interest = DotNetInterestGrid.new()
	_check(not Rel.bind(console, other), "a game's own strategy is left alone")
	console.queue_free()
	net.free()
	other.free()
	_done()


class VisLocal extends RefCounted:
	var vars := {}
	var taken: Array = []
	var adds: Array = []
	func add_var(n: StringName, _h: String, g: Callable, st: Callable) -> void:
		adds.append(n)
		vars[n] = [g, st]
	func claims(n: String) -> bool:
		return taken.has(n)


class VisConsole extends Node:
	var list: Array = []
	func sources() -> Array:
		return list


class RenderStore:
	extends RefCounted
	signal changed(key: StringName, value: Variant, why: StringName)
	var vals := {}
	func get_int(key: StringName, d: int) -> int:
		return int(vals.get(key, d))
	func get_float(key: StringName, d: float) -> float:
		return float(vals.get(key, d))


func _test_render_quality() -> void:
	_section("every client applies render quality (dot-fx) from the menu's keys, no per-game wiring")
	var c := DotGameClient.new()
	c.use_gate = false
	c.use_settings = false
	c.use_console = false
	c.use_slide_sounds = false
	c.capture_pointer = false
	add_child(c)
	var has_fx := ResourceLoader.exists("res://addons/dot_fx/runtime/dot_fx_render_quality.gd")
	_check(c.setup().ok, "setup succeeds")
	if not has_fx:
		_check(c.render_quality == null, "without dot-fx it is a no-op")
	else:
		_check(c.render_quality != null and c.get_node_or_null("RenderQuality") == c.render_quality, "the node is added")
		var vp := c.get_viewport()
		_check(vp.anisotropic_filtering_level == Viewport.ANISOTROPY_16X, "desktop default is 16x anisotropic")
		var store := RenderStore.new()
		c.render_quality.follow(store)
		store.vals[&"aniso"] = 8
		store.vals[&"mip_bias"] = -0.5
		store.changed.emit(&"aniso", 8, &"set")
		_check(vp.anisotropic_filtering_level == Viewport.ANISOTROPY_8X, "the menu's aniso reaches the viewport")
		_check(is_equal_approx(vp.texture_mipmap_bias, -0.5), "and mip_bias")
	c.use_render_quality = false
	var off := DotGameClient.new()
	off.use_render_quality = false
	off.use_gate = false
	off.use_settings = false
	off.use_console = false
	off.use_slide_sounds = false
	off.capture_pointer = false
	add_child(off)
	off.setup()
	_check(off.render_quality == null, "use_render_quality = false adds nothing")
	off.queue_free()
	c.queue_free()
	_done()


class LatencyLink extends RefCounted:
	signal replicated_cvar_changed(cvar_name: String, value: String)
	var held := {}

	func replicated_cvar(cvar_name: String, fallback: String = "") -> String:
		return String(held.get(cvar_name, fallback))


func _test_client_latency() -> void:
	_section("cl_latency_baseline on the client and sv_allow_client_latency on the server, switch reaching the client")
	var loaded: DotResult = await _load_module()
	if _check(loaded.ok, "the module loads", str(loaded.error)):
		var module := loaded.value as DotGameModule
		var sv := module.console.find_cvar("sv_allow_client_latency")
		_check(sv != null and sv.get_string() == "1" and sv.has_flag(DotConVar.FLAG_REPLICATED), "the server cvar exists, defaults to 1 and replicates")
		_check(module.net != null and module.net.latency.allowed, "and the server's latency allows it")
		if sv != null:
			var _r := module.console.set_cvar("sv_allow_client_latency", "0")
			_check(not module.net.latency.allowed, "setting it to 0 reaches the server's latency")
		_unload_module()
	var c := DotGameClient.new()
	c.use_gate = false
	add_child(c)
	var net := DotNetManager.new()
	var link := LatencyLink.new()
	c.link = link
	var local := VisLocal.new()
	var con := VisConsole.new()
	con.list = [local]
	c.console = con
	c.add_latency(net)
	_check(local.vars.has(&"cl_latency_baseline"), "the client console gets cl_latency_baseline")
	var res: Variant = (local.vars[&"cl_latency_baseline"][1] as Callable).call("0.2")
	_check(res is DotResult and (res as DotResult).ok and is_equal_approx(net.latency.requested, 0.2) and is_equal_approx(net.latency.effective(), 0.2), "typing seconds sets the baseline")
	res = (local.vars[&"cl_latency_baseline"][1] as Callable).call("fast")
	_check(res is DotResult and not (res as DotResult).ok, "a non-number is refused")
	link.replicated_cvar_changed.emit("sv_allow_client_latency", "0")
	_check(not net.latency.allowed and net.latency.effective() == 0.0 and is_equal_approx(net.latency.requested, 0.2), "the server's switch at 0 forces the client to 0 and keeps the request")
	link.replicated_cvar_changed.emit("sv_allow_client_latency", "1")
	_check(is_equal_approx(net.latency.effective(), 0.2), "and back to 1 restores it")
	c.add_latency(net)
	_check(local.adds.count(&"cl_latency_baseline") == 1, "add_latency twice binds once")
	c.console = null
	con.free()
	net.free()
	c.queue_free()
	var auto := DotGameClient.new()
	auto.use_gate = false
	add_child(auto)
	var local2 := VisLocal.new()
	var con2 := VisConsole.new()
	con2.list = [local2]
	auto.console = con2
	auto.link = LatencyLink.new()
	auto.setup()
	var net2 := DotNetManager.new()
	add_child(net2)
	_check(local2.vars.has(&"cl_latency_baseline"), "setup finds the client's registered net by itself")
	net2.queue_free()
	var srv := DotNetManager.new()
	srv.is_server = true
	srv.service_scope = &"latency_test_srv"
	add_child(srv)
	_check(auto._latency_net != srv, "a server's manager is not taken")
	srv.queue_free()
	auto.console = null
	con2.free()
	auto.queue_free()
	_done()


func _test_client_vis_mode() -> void:
	_section("map culling is opt-in, and the console's vis_mode drives it")
	var c := DotGameClient.new()
	c.use_gate = false
	add_child(c)
	_check(c.vis_mode == "off", "off by default")
	var drawn := Node3D.new()
	add_child(drawn)
	var mesh := DotMapBspMesh.new()
	_check(c.attach_visibility(mesh, drawn) == null and drawn.get_child_count() == 0, "off builds nothing")
	_check(not c.set_vis_mode("bogus") and c.vis_mode == "off", "an unknown mode is refused")
	_check(c.set_vis_mode(" PVS ") and c.vis_mode == "pvs" and c.visibility == null, "a map with no visibility data stays drawn whole")
	var local := VisLocal.new()
	var con := VisConsole.new()
	con.list = [local]
	c.console = con
	_check(DotGameClient._Vis.add_console_var(c) and local.vars.has(&"vis_mode"), "the client console gets vis_mode")
	var r: Variant = (local.vars[&"vis_mode"][1] as Callable).call("both")
	_check(r is DotResult and (r as DotResult).ok and c.vis_mode == "both", "setting it at the console sets the mode")
	local.taken = ["vis_mode"]
	_check(not DotGameClient._Vis.add_console_var(c), "a game's own vis_mode is left alone")
	c.detach_visibility()
	c.console = null
	con.free()
	drawn.queue_free()
	c.queue_free()
	_done()


## Escape frees the client's captured pointer, once.
func _test_escape_and_hold(host: Node) -> void:
	# Release-then-open pointer.
	var esc := InputEventKey.new()
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	var esc_menu := EscMenu.new()
	host.add_child(esc_menu)
	var ptr := FakePointerClient.new()
	ptr.use_gate = false
	ptr.use_settings = false
	ptr.use_console = false
	ptr.capture_pointer = false
	ptr.escape_releases_pointer = true
	ptr.menu = esc_menu
	host.add_child(ptr)
	var _p := ptr.setup()
	ptr.capture_pointer = true
	ptr.captured = true
	var vp := get_viewport()
	vp.push_input(esc)
	_check(not ptr.captured and not esc_menu.open_now,
		"the first real Escape press frees a captured pointer and the menu stays shut")
	vp.push_input(esc)
	_check(esc_menu.open_now and ptr.is_menu_open(), "the second opens the menu")
	esc_menu.open_now = false
	ptr.captured = true
	var typing := [true]
	ptr.busy_fn = func() -> bool: return typing[0]
	vp.push_input(esc)
	_check(ptr.captured and esc_menu.open_now,
		"nothing is freed while the game's own keyboard owner has Escape; the menu gets it")
	esc_menu.open_now = false
	typing[0] = false
	var other := InputEventKey.new()
	other.physical_keycode = KEY_E
	other.pressed = true
	vp.push_input(other)
	_check(ptr.captured, "only Escape does it")
	ptr.escape_releases_pointer = false
	vp.push_input(esc)
	_check(ptr.captured and esc_menu.open_now, "off by default: Escape is not touched, the menu opens")

	await _test_pointer_hold(host, esc_menu, vp)


## A game's own modal and a dot_pointer_modal node hold the pointer.
func _test_pointer_hold(host: Node, esc_menu: Node, vp: Viewport) -> void:
	# A game's own modal holds the pointer: a click, a menu closing and a focus event do not recapture.
	esc_menu.open_now = false
	var hold := DotGameClient.new()
	hold.use_gate = false
	hold.use_settings = false
	hold.use_console = false
	hold.menu = esc_menu
	host.add_child(hold)
	var _h := hold.setup()
	hold.hold_pointer(&"shop")
	hold.hold_pointer(&"loadout")
	_check(hold.is_input_blocked(), "a held pointer blocks input")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	vp.push_input(click)
	hold._on_menu_state(false)
	hold.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	await get_tree().process_frame
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE,
		"with a modal held, a click, another menu closing and a focus event leave the pointer visible")
	hold.release_pointer(&"shop")
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE and hold.is_input_blocked(),
		"two holds: releasing one keeps the pointer free")
	hold.release_pointer(&"shop")
	hold.release_pointer(&"loadout")
	_check(not hold.is_input_blocked(), "released holds unblock input, and a spare release does not underflow")

	# A node in the pointer-modal group (dot-ui's ballot) holds it through its own signal.
	var modal := FakePointerModal.new()
	modal.add_to_group(&"dot_pointer_modal")
	host.add_child(modal)
	hold._wire_pointer_modals()
	modal.set_pointer(true)
	_check(hold.is_input_blocked(), "a pointer-modal node freeing the mouse holds the pointer")
	hold._on_menu_state(false)
	await get_tree().process_frame
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE and hold.is_input_blocked(), "and another menu closing does not recapture it")
	modal.set_pointer(false)
	_check(not hold.is_input_blocked(), "its signal going off releases the hold")
	modal.set_pointer(true)
	modal.free()
	_check(not hold.is_input_blocked(), "and the node leaving the tree releases it too")
	hold.queue_free()


class FakePointerModal extends Node:
	signal pointer_mode_changed(on: bool)
	var on := false

	func set_pointer(p_on: bool) -> void:
		on = p_on
		pointer_mode_changed.emit(p_on)

	func is_pointer_mode() -> bool:
		return on


## A client whose pointer is a flag, because a headless display server keeps no captured mode.
class FakePointerClient extends DotGameClient:
	var captured: bool = false
	func _pointer_captured() -> bool:
		return captured
	func _free_pointer() -> void:
		captured = false


## A menu that opens on a real Escape press, as dot-menu's does in _unhandled_input.
class EscMenu extends Node:
	signal overlays_changed(open: bool)
	var busy: Callable = Callable()
	var open_now: bool = false
	func is_open() -> bool:
		return open_now
	func _unhandled_input(event: InputEvent) -> void:
		var key := event as InputEventKey
		if key != null and key.pressed and key.physical_keycode == KEY_ESCAPE:
			open_now = true
			overlays_changed.emit(true)
