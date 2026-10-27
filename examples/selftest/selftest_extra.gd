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
	func add_var(n: StringName, _h: String, g: Callable, st: Callable) -> void:
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


class StubSlide:
	extends Node
	var enabled: bool = true
	var volume: float = 1.0
	var sliding: Array = []
	func keep(bodies: Array, sliding_of: Callable) -> void:
		sliding.clear()
		for b: Variant in bodies:
			if bool(sliding_of.call(b)):
				sliding.append(b)


class StubSlideState:
	extends RefCounted
	var on: bool = false
	func is_sliding() -> bool:
		return on


class StubController:
	extends Node
	var state := StubSlideState.new()


class StubSlideLink:
	extends Object
	signal replicated_cvar_changed(cvar_name: String, value: String)
	var cvars: Dictionary = {}
	func replicated_cvar(cvar_name: String, fallback: String) -> String:
		return String(cvars.get(cvar_name, fallback))


class StubSettings:
	extends Object
	signal changed(key: StringName, value: Variant, reason: StringName)
	var volume: float = 0.5
	func get_float(_key: StringName, _fallback: float = 0.0) -> float:
		return volume


class StubSchema:
	extends RefCounted
	var keys: Array = []
	func has(key: StringName) -> bool:
		return keys.has(key)
	func add(def: Variant) -> StubSchema:
		keys.append(def.key if def != null else &"?")
		return self


func _test_slide_sounds() -> void:
	_section("every client scrapes a slide: the server's switch, the player's volume, no per-game wiring")
	var Sounds: GDScript = load("res://addons/dot_game/runtime/dot_game_slide_sounds.gd")
	_check(Sounds.cvar_spec()["name"] == "sv_slide_sounds" and Sounds.cvar_spec()["value"] == "1", "the cvar defaults on")

	var link := StubSlideLink.new()
	link.cvars["sv_slide_sounds"] = "0"
	var settings := StubSettings.new()
	var slide := StubSlide.new()
	var node: Node = Sounds.new()
	node.slide = slide
	node.link_fn = func() -> Object: return link
	node.settings_fn = func() -> Object: return settings
	node.controller_fn = func(n: Node) -> bool: return n is StubController
	add_child(node)

	var body := Node3D.new()
	add_child(body)
	var controller := StubController.new()
	var idle := Node3D.new()
	add_child(idle)
	var idle_controller := StubController.new()
	idle.add_child(idle_controller)
	_check(node.start(), "it starts with a slide node supplied")
	body.add_child(controller)
	controller.state.on = true
	await _frames(2)
	_check(slide.sliding == [body], "a controller that enters later is followed, and only the sliding body is passed on", str(slide.sliding))
	_check(slide.enabled == false, "the server's cvar already off at connect silences it")
	_check(is_equal_approx(slide.volume, 0.5), "and the player's slide_volume is applied")
	link.replicated_cvar_changed.emit("sv_slide_sounds", "1")
	await _frames(1)
	_check(slide.enabled, "a replicated change switches it back on")
	settings.changed.emit(&"slide_volume", 0.2, &"applied")
	_check(is_equal_approx(slide.volume, 0.2), "a settings change moves the volume live")
	body.queue_free()
	await _frames(2)
	_check(node.bodies() == [idle], "a freed body is dropped", str(node.bodies()))

	var schema := StubSchema.new()
	Sounds.declare(schema)
	_check(schema.keys == [&"slide_volume"] or not ResourceLoader.exists(Sounds.DEF_SCRIPT), "declare adds slide_volume once to a schema")
	Sounds.declare(schema)
	_check(schema.keys.size() <= 1, "and never twice")
	_check(Sounds.is_controller(Node.new()) == false, "a plain node is no controller")

	node.queue_free()
	await _frames(2)
	link.free()
	settings.free()
	_done()


class StubLandingRules:
	extends RefCounted
	var volume: float = 0.6
	func volume_for(impact: float) -> float:
		return 0.0 if impact < 4.0 else volume


class StubLandingManager:
	extends Object
	var plays: Array = []
	func play_at(id: StringName, at: Vector3, scale: float) -> int:
		plays.append([id, at, scale])
		return 1


class StubLandingController:
	extends Node
	signal landed(impact: float)
	var view: Object = null


class StubKickView:
	extends Object
	var landing_strength: float = 1.0


class StubConsoleSource:
	extends Object
	var vars: Dictionary = {}
	func add_var(var_name: StringName, _help: String, get_fn: Callable, set_fn: Callable) -> void:
		vars[var_name] = [get_fn, set_fn]


func _test_landing() -> void:
	_section("every client thumps a landing and scales the camera kick: no per-game wiring")
	var Landing: GDScript = load("res://addons/dot_game/runtime/dot_game_landing.gd")
	var node: Node = Landing.new()
	var rules := StubLandingRules.new()
	var mgr := StubLandingManager.new()
	var view := StubKickView.new()
	node.rules = rules
	node.manager_fn = func() -> Object: return mgr
	node.id_fn = func(impact: float) -> StringName: return &"hard" if impact > 12.0 else &"light"
	node.controller_fn = func(n: Node) -> bool: return n is StubLandingController
	add_child(node)
	_check(node.start(), "it starts with rules supplied")
	var body := Node3D.new()
	add_child(body)
	body.global_position = Vector3(1, 2, 3)
	var controller := StubLandingController.new()
	controller.view = view
	body.add_child(controller)
	controller.landed.emit(15.0)
	_check(mgr.plays.size() == 1 and mgr.plays[0][0] == &"hard" and mgr.plays[0][1] == Vector3(1, 2, 3), "a landing plays the stock for its impact at the body", str(mgr.plays))
	_check(is_equal_approx(mgr.plays[0][2], 0.6), "scaled by the landing volume")
	controller.landed.emit(2.0)
	_check(mgr.plays.size() == 1, "a landing under the rules' minimum is silent")
	rules.volume = 0.0
	controller.landed.emit(15.0)
	_check(mgr.plays.size() == 1, "cl_landing_volume 0 mutes it")
	node.kick = 0.5
	_check(is_equal_approx(view.landing_strength, 0.5), "cl_landing_kick reaches the controller's view")
	var console := StubConsoleSource.new()
	_check(node.bind_console(console) and console.vars.has(&"cl_landing_volume") and console.vars.has(&"cl_landing_kick"), "both cvars register on a console source")
	console.vars[&"cl_landing_kick"][1].call("9")
	_check(is_equal_approx(node.kick, 2.0) and is_equal_approx(view.landing_strength, 2.0), "the kick cvar is clamped and applied live")
	_check(Landing.is_controller(Node.new()) == false, "a plain node is no controller")
	node.queue_free()
	body.queue_free()
	await _frames(2)
	mgr.free()
	view.free()
	console.free()
	_done()
