extends "selftest_netcfg.gd"

## The DotGameClient and DotGameLink sections of game_selftest.gd.

## A cover of the game's own, in the shape DotLoadGate drives.
class ClientCover extends Control:
	func show_cover() -> void: pass
	func hide_cover() -> void: pass
	func set_status(_text: String) -> void: pass
	func set_progress(_fraction: float) -> void: pass


## The client's platform, with dot-menu and dot-console stood in by fixtures in their shape.
func _test_client_platform() -> void:
	_section("the client's platform: the cover first, then the menu, the console and the keys")

	var host := Node.new()
	host.name = "ClientRoot"
	add_child(host)
	var spawned := [false]
	var blocked_seen: Array = []
	var client := DotGameClient.new()
	client.require_camera = false
	client.spawned_fn = func() -> bool: return spawned[0]
	client.input_blocked_changed.connect(func(on: bool) -> void: blocked_seen.append(on))
	host.add_child(client)

	_check(client.gate != null and client.gate.get_parent() == host,
		"the load gate is up the moment the client is added, under the client root")
	_check(DotLoadGate.of(host) == client.gate, "and DotLoadGate.of finds it from the root")
	_check(client.offline and client.link == null, "no link in the registry is offline")
	_check(client.is_input_blocked() and not client.is_shown(), "covered is input off")

	var settings := ClientSettings.new()
	var chat := ClientChat.new()
	var hud := Control.new()
	host.add_child(hud)
	var snapshot := func() -> Dictionary: return {"players": []}
	client.settings = settings
	client.chat = chat
	client.hud = hud
	client.board_snapshot_fn = snapshot
	client.maps_rows_fn = func() -> Array: return []
	client.maps_change_fn = func(_id: StringName) -> DotResult: return DotResult.success(null)
	client.maps_title = "Change arena"
	client.maps_noun = "arenas"
	client.console_kit_path = CONSOLE_KIT_FIXTURE
	client.capture_pointer = false
	var set_up := client.setup()
	_check(set_up.ok and settings.setups == 1 and settings.is_inside_tree() and chat.is_inside_tree(),
		"setup builds the game's settings once, and takes the chat box in")

	var menu: Object = client.menu
	_check(menu != null and (menu.get(&"followed") as Array).size() == 1 \
			and (menu.get(&"followed") as Array)[0][0] == hud,
		"the HUD follows the menu's theme")
	_check(menu != null and menu.get(&"scoreboard_action") == DotGameClient.SCOREBOARD_ACTION \
			and InputMap.has_action(DotGameClient.SCOREBOARD_ACTION)
			and InputMap.action_get_events(DotGameClient.SCOREBOARD_ACTION).any(func(e: InputEvent) -> bool:
				return e is InputEventKey and (e as InputEventKey).physical_keycode == KEY_TAB),
		"Tab is the board's key, made when the game's table has none")
	_check(client.board != null and client.board.get(&"source") == snapshot,
		"offline the board is drawn from the game's own snapshot")
	_check(client.maps != null and client.maps.get(&"title") == "Change arena" \
			and client.maps.get(&"link_service") == &"",
		"M is the game's map list, and offline asks no server")
	_check(client.console != null and client.console.get_parent() == client \
			and client.console.get_meta(&"menu") == menu,
		"the console is built by the kit, over the settings and the menu")

	spawned[0] = true
	var opened := [false]
	client.gate.opened.connect(func() -> void: opened[0] = true)
	for i in range(240):
		if opened[0]:
			break
		await get_tree().process_frame
	await _frames(2)
	_check(opened[0] and client.is_shown() and not client.is_input_blocked(),
		"the cover lifts once the player exists, and input comes on")

	chat.set_typing(true)
	_check(client.is_input_blocked() and bool((menu.get(&"busy") as Callable).call()),
		"typing is input off, and keeps Escape off the menu")
	chat.set_typing(false)
	var relayed: Array = []
	client.menu_state_changed.connect(func(on: bool) -> void: relayed.append(on))
	settings.set_open(true)
	_check(client.is_input_blocked() and relayed == [true], "an open menu is input off, and is relayed")
	settings.set_open(false)
	var busy := [true]
	client.busy_fn = func() -> bool: return busy[0]
	await _frames(2)
	_check(client.is_input_blocked() and bool((menu.get(&"busy") as Callable).call()),
		"the game's own busy_fn (a command line) counts too")
	busy[0] = false
	await _frames(2)
	_check(not client.is_input_blocked() and blocked_seen.size() >= 3 and blocked_seen.back() == false,
		"and every change was signalled, ending live", str(blocked_seen))

	var again := client.setup()
	_check(not again.ok and again.error.code == DotError.CODE_STATE, "a second setup is refused")
	_check(client.describe().get("console", false) == true and client.describe_lines().size() >= 4,
		"describe says what was built")

	# Hooks for what a game builds later, or wants its own way (API level 11).
	var late_hud := Control.new()
	host.add_child(late_hud)
	client.set_hud(late_hud)
	_check((menu.get(&"followed") as Array).size() == 2 and (menu.get(&"followed") as Array)[1][0] == late_hud
			and (menu.get(&"unfollowed") as Array) == [hud],
		"set_hud after setup follows the new HUD and lets the old one go")
	var late_chat := ClientChat.new()
	client.set_chat(late_chat)
	_check(late_chat.is_inside_tree(), "set_chat after setup takes the new box in")
	late_chat.set_typing(true)
	_check(client.is_input_blocked(), "and typing in it blocks input")
	late_chat.set_typing(false)
	_check(not chat.is_connected(&"typing_changed", client._refresh_blocked), "the old box is let go")
	var before := blocked_seen.size()
	busy[0] = true
	client.refresh_blocked()
	_check(blocked_seen.size() == before + 1 and blocked_seen.back() == true,
		"refresh_blocked signals a change in the frame it is called")
	busy[0] = false
	client.refresh_blocked()
	var rule := [false]
	client.pointer_fn = func() -> bool: return rule[0]
	_check(not client._pointer_wanted(), "pointer_fn false keeps the pointer free")
	rule[0] = true
	_check(client._pointer_wanted(), "and true takes it")
	client.pointer_fn = Callable()
	_check(client._pointer_wanted(), "unset keeps the old behaviour")
	var custom_cover := ClientCover.new()
	var cover_host := Node.new()
	add_child(cover_host)
	var covered := DotGameClient.new()
	covered.require_camera = false
	covered.cover = custom_cover
	cover_host.add_child(covered)
	_check(covered.gate != null and covered.gate.cover == custom_cover,
		"a cover assigned to the client is the gate's cover")
	custom_cover.free()
	cover_host.queue_free()

	# A settings file that will not load costs the menu, not the game.
	var refused_host := Node.new()
	add_child(refused_host)
	var refused := DotGameClient.new()
	refused.use_gate = false
	refused.use_console = false
	refused.capture_pointer = false
	refused_host.add_child(refused)
	var bad := ClientSettings.new()
	bad.refuse = true
	refused.settings = bad
	var refused_set_up := refused.setup()
	_check(refused_set_up.ok and refused.settings == null and refused.menu == null and refused.gate == null,
		"refused settings are dropped with a line, and the rest still sets up")

	# A client inside a scene readying its children: the gate waits a frame for the root.
	var scene := Node.new()
	var nested := DotGameClient.new()
	nested.require_camera = false
	scene.add_child(nested)
	add_child(scene)
	await get_tree().process_frame
	_check(nested.gate != null and nested.gate.get_parent() == scene,
		"a client that is part of a scene still puts the gate under its root")

	host.queue_free()
	refused_host.queue_free()
	scene.queue_free()
	await get_tree().process_frame
	_done()


## A menu the game built itself, in dot-menu's DotMenu shape (overlays_changed, is_open).
class OwnMenu extends RefCounted:
	signal overlays_changed(open: bool)
	var busy: Callable = Callable()
	var scoreboard_action: StringName = &""
	var scoreboard: RefCounted = RefCounted.new()
	var followed: Array = []
	var maps_made: int = 0
	var open_now: bool = false
	func is_open() -> bool:
		return open_now
	func follow_hud(root: Control, accent: Theme = null) -> void:
		followed.append([root, accent])
	func set_open(on: bool) -> void:
		open_now = on
		overlays_changed.emit(on)
	func use_maps(_rows: Callable, _change: Callable) -> RefCounted:
		maps_made += 1
		return RefCounted.new()


class TeamsStub extends RefCounted:
	var default_when_unwired: bool = true


class TeamsMenu extends OwnMenu:
	var teams: RefCounted = null
	var used: int = 0
	func use_teams(_offer: Callable = Callable(), _choose: Callable = Callable()) -> RefCounted:
		used += 1
		teams = TeamsStub.new()
		return teams


func _team_menu_client(host: Node, menu: TeamsMenu, unwired: bool) -> DotGameClient:
	var c := DotGameClient.new()
	c.use_gate = false
	c.use_console = false
	c.capture_pointer = false
	c.menu = menu
	c.team_menu_default_when_unwired = unwired
	c.board_snapshot_fn = func() -> Dictionary: return {}
	c.maps_rows_fn = func() -> Array: return []
	c.maps_change_fn = func(_id: StringName) -> DotResult: return DotResult.success(null)
	c.hud = Control.new()
	host.add_child(c)
	var _r := c.setup()
	return c


func _test_client_team_menu_default() -> void:
	_section("team_menu_default_when_unwired: on by default, and the unwired team menu honours it")
	var host := Node.new()
	add_child(host)
	var fresh := DotGameClient.new()
	_check(fresh.team_menu_default_when_unwired, "the Play and Spectate offer is on by default")
	fresh.free()
	var on_menu := TeamsMenu.new()
	var _a := _team_menu_client(host, on_menu, true)
	_check(on_menu.used == 1 and on_menu.teams.default_when_unwired, "default: the unwired team menu keeps its offer")
	var off_menu := TeamsMenu.new()
	var _b := _team_menu_client(host, off_menu, false)
	_check(off_menu.used == 1 and not off_menu.teams.default_when_unwired, "false: the unwired team menu is told to say there are no teams")
	var own_menu := TeamsMenu.new()
	own_menu.teams = TeamsStub.new()
	var _c := _team_menu_client(host, own_menu, false)
	_check(own_menu.used == 0 and own_menu.teams.default_when_unwired, "a game's own team menu is left alone")
	var no_teams := TeamsMenu.new()
	var off := DotGameClient.new()
	off.use_team_menu = false
	off.use_gate = false
	off.use_console = false
	off.capture_pointer = false
	off.menu = no_teams
	off.hud = Control.new()
	off.board_snapshot_fn = func() -> Dictionary: return {}
	off.maps_rows_fn = func() -> Array: return []
	off.maps_change_fn = func(_id: StringName) -> DotResult: return DotResult.success(null)
	host.add_child(off)
	var _d := off.setup()
	_check(no_teams.used == 0, "use_team_menu off wires nothing")
	host.queue_free()
	_completed += 1


## The hooks for a game with its own menu, a board of its own, a console built later, no
## settings at all, and Escape that frees the pointer before it opens anything (API level 12).
func _test_client_hooks_menu() -> void:
	_section("the client's hooks: an adopted menu, board prepare, late console, gate-only, release-then-open")

	var host := Node.new()
	add_child(host)
	var own := OwnMenu.new()
	var own_board := RefCounted.new()
	var prepared: Array = []
	var client := DotGameClient.new()
	client.use_gate = false
	client.use_console = false
	client.capture_pointer = false
	client.menu = own
	client.board = own_board
	client.board_prepare_fn = func(b: Object) -> void: prepared.append(b)
	client.board_snapshot_fn = func() -> Dictionary: return {}
	client.maps_rows_fn = func() -> Array: return []
	client.maps_change_fn = func(_id: StringName) -> DotResult: return DotResult.success(null)
	var hud := Control.new()
	client.hud = hud
	host.add_child(client)
	var relayed: Array = []
	client.menu_state_changed.connect(func(on: bool) -> void: relayed.append(on))
	var made := client.setup()
	_check(made.ok and client.settings == null and client.menu == own,
		"a menu assigned before setup is kept, and no settings are built over it")
	_check(client.board == own_board and prepared == [own_board],
		"an assigned board is kept instead of the menu's, and prepared first")
	_check(own.followed.size() == 1 and own.scoreboard_action == DotGameClient.SCOREBOARD_ACTION,
		"the HUD theme and Tab reach the adopted menu")
	_check(own.maps_made == 1 and client.maps != null, "M is made on the menu when there are no settings")
	own.set_open(true)
	_check(client.is_menu_open() and client.is_input_blocked() and relayed == [true],
		"a menu without settings still blocks input and emits menu_state_changed")
	own.set_open(false)
	_check(not client.is_menu_open() and relayed == [true, false], "and closing it is relayed")

	# Adopted after setup, with a console built later around it.
	var late := DotGameClient.new()
	late.use_gate = false
	late.use_settings = false
	late.use_console = false
	late.capture_pointer = false
	late.console_kit_path = CONSOLE_KIT_FIXTURE
	host.add_child(late)
	var _s := late.setup()
	_check(late.menu == null and late.console == null, "with settings and console off nothing is built")
	var second := OwnMenu.new()
	late.adopt_menu(second)
	second.set_open(true)
	_check(late.is_menu_open() and late.is_input_blocked(), "adopt_menu after setup wires it at once")
	second.set_open(false)
	var console := late.add_console(RefCounted.new())
	_check(console != null and console.get_meta(&"menu") == second and late.console == console,
		"add_console builds the console later, around the adopted menu")
	_check(late.add_console() == console, "and a second call keeps the first")

	# Gate-only: setup builds nothing, the block still works.
	var bare := DotGameClient.new()
	bare.gate_only = true
	bare.require_camera = false
	bare.console_kit_path = CONSOLE_KIT_FIXTURE
	var bare_settings := ClientSettings.new()
	bare.settings = bare_settings
	host.add_child(bare)
	var bare_up := bare.setup()
	_check(bare_up.ok and bare.gate != null and bare_settings.setups == 0 and bare.menu == null \
			and bare.console == null and not bare_settings.is_inside_tree(),
		"gate_only keeps the gate and builds no settings, menu or console")
	_check(bare.is_input_blocked(), "and the cover still blocks input")
	# The cover hides busy_fn, so wait for it to lift: only then does busy_fn alone decide.
	for i in range(240):
		if bare.is_shown():
			break
		await get_tree().process_frame
	var busy_flag := [false]
	bare.busy_fn = func() -> bool: return busy_flag[0]
	bare.refresh_blocked()
	_check(bare.is_shown() and not bare.is_input_blocked(), "once the cover lifts nothing blocks", str(bare.is_shown()))
	busy_flag[0] = true
	bare.refresh_blocked()
	_check(bare.is_input_blocked(), "busy_fn still counts (it alone blocks, the cover being up no longer)")
	busy_flag[0] = false

	# gate_only with the default capture_pointer (true): nothing is captured or released.
	var gp := FakePointerClient.new()
	gp.gate_only = true
	gp.require_camera = false
	gp.escape_releases_pointer = true
	_check(gp.capture_pointer, "capture_pointer defaults to true")
	host.add_child(gp)
	var gp_up := gp.setup()
	gp.captured = true
	var gesc := InputEventKey.new()
	gesc.physical_keycode = KEY_ESCAPE
	gesc.pressed = true
	_check(gp_up.ok and not gp._release_pointer_on_escape(gesc) and gp.captured,
		"gate_only with capture_pointer on neither captures nor frees the pointer on Escape")
	gp._on_menu_state(true)
	_check(gp.captured, "and a menu state change does not touch the pointer")
	gp._on_menu_state(false)

	await _test_escape_and_hold(host)

	_test_client_hooks_rewire(host)

	host.queue_free()
	await get_tree().process_frame
	_done()


class _CoverLink extends RefCounted:
	var sent: Array = []
	func send_kind(kind: StringName, payload: Dictionary = {}, _lane: int = 0) -> bool:
		sent.append([kind, payload])
		return true


## The client's half: the gate opening and closing again is told to the server, with no line
## of the game's.
func _test_client_reports_cover() -> void:
	_section("the client tells the server when its cover lifts and comes back")
	var host := Node.new()
	add_child(host)
	var link := _CoverLink.new()
	var client := DotGameClient.new()
	client.require_camera = false
	client.capture_pointer = false
	client.link = link
	host.add_child(client)
	_check(not client.offline and link.sent.is_empty(), "connected, and nothing is said while covered")
	for i in range(240):
		if client.is_shown():
			break
		await get_tree().process_frame
	_check(link.sent == [[DotGameRoster.COVER_KIND, {"covered": false}]],
		"the cover lifting is sent once", str(link.sent))
	client.gate.hold(&"map", "Loading the map")
	_check(link.sent.size() == 2 and link.sent[1] == [DotGameRoster.COVER_KIND, {"covered": true}],
		"a map change's cover going up is sent too", str(link.sent))
	_check(DotGameClient.report_cover(link, false) and not DotGameClient.report_cover(null, false),
		"report_cover is the same send for a client not on DotGameClient")
	host.queue_free()
	await get_tree().process_frame
	_done()


## adopt_menu twice, adopt_menu beside settings, and a board prepared once.
func _test_client_hooks_rewire(host: Node) -> void:
	var a := OwnMenu.new()
	var b := OwnMenu.new()
	var hud := Control.new()
	var prepared: Array = []
	var c := DotGameClient.new()
	c.use_gate = false
	c.use_settings = false
	c.use_console = false
	c.capture_pointer = false
	c.hud = hud
	c.board_prepare_fn = func(x: Object) -> void: prepared.append(x)
	c.adopt_menu(a)
	host.add_child(c)
	var _s := c.setup()
	_check(c.board == a.scoreboard and prepared == [a.scoreboard], "adopt_menu before setup: its board, prepared once")
	c.adopt_menu(b)
	_check(c.menu == b and c.board == b.scoreboard and prepared == [a.scoreboard, b.scoreboard],
		"adopt_menu twice: the second menu's own board is fed and prepared")
	a.set_open(true)
	_check(not c.is_menu_open() and not a.busy.is_valid(), "the first menu is unwired: no state, no busy callable")
	_check(a.followed.size() == 1 and b.followed.size() == 1, "and the HUD follows the second")
	b.set_open(true)
	_check(c.is_menu_open() and c.is_input_blocked(), "the second blocks input")
	b.set_open(false)
	var mine := RefCounted.new()
	var d := OwnMenu.new()
	c.board = mine
	c.adopt_menu(d)
	_check(c.board == mine, "an assigned board survives adopt_menu without one")
	c.adopt_menu(OwnMenu.new(), d.scoreboard)
	_check(c.board == d.scoreboard, "and an explicit board argument replaces it")

	# A board assigned before setup, then adopt_menu: prepared once.
	var once: Array = []
	var pre := OwnMenu.new()
	var c2 := DotGameClient.new()
	c2.use_gate = false
	c2.use_settings = false
	c2.use_console = false
	c2.capture_pointer = false
	c2.menu = pre
	c2.board = pre.scoreboard
	c2.board_prepare_fn = func(x: Object) -> void: once.append(x)
	host.add_child(c2)
	var _s2 := c2.setup()
	c2.adopt_menu(pre)
	_check(once.size() == 1, "an assigned board adopted again is prepared once", str(once.size()))

	# Adopted after setup with settings present: it blocks input and relays, beside the settings.
	var settings := ClientSettings.new()
	var c3 := DotGameClient.new()
	c3.use_gate = false
	c3.use_console = false
	c3.capture_pointer = false
	c3.settings = settings
	host.add_child(c3)
	var _s3 := c3.setup()
	var relayed: Array = []
	c3.menu_state_changed.connect(func(on: bool) -> void: relayed.append(on))
	var adopted := OwnMenu.new()
	c3.adopt_menu(adopted)
	adopted.set_open(true)
	_check(c3.is_menu_open() and c3.is_input_blocked() and relayed == [true],
		"adopt_menu with settings present: the adopted menu blocks input and relays")
	adopted.set_open(false)
	settings.open_now = true
	_check(c3.is_menu_open(), "and the settings still count")
	settings.open_now = false
	_check(not c3.is_menu_open() and relayed == [true, false], "both closed: open is false")


## This suite's project has neither dot-menu nor dot-console, which is a real build.
func _test_client_without_the_addons() -> void:
	_section("the client's platform, in a build with neither dot-menu nor dot-console")
	var host := Node.new()
	add_child(host)
	var client := DotGameClient.new()
	client.require_camera = false
	client.capture_pointer = false
	host.add_child(client)
	var set_up := client.setup()
	_check(set_up.ok and client.settings == null and client.menu == null and client.console == null,
		"it sets up with no settings, menu or console, and says so instead of failing")
	_check(client.gate != null and client.chat == null and client.board == null,
		"the cover is still there; nothing else was invented")
	host.queue_free()
	await get_tree().process_frame
	_done()


## setup_stepped: the same pieces as setup, with the caller's step between each.
func _test_client_stepped_setup() -> void:
	_section("the client's platform, set up one piece a frame")
	var host := Node.new()
	add_child(host)
	var client := DotGameClient.new()
	client.require_camera = false
	client.capture_pointer = false
	client.console_kit_path = CONSOLE_KIT_FIXTURE
	var settings := ClientSettings.new()
	client.settings = settings
	host.add_child(client)
	var seen: Array[StringName] = []
	var frame0 := Engine.get_process_frames()
	var between := func(piece: StringName) -> void:
		seen.append(piece)
		await get_tree().process_frame
	var stepped: DotResult = await client.setup_stepped(between)
	var expected := DotGameClient.SETUP_PIECES.slice(0, DotGameClient.SETUP_PIECES.size() - 1)
	_check(stepped.ok and seen == expected,
		"the caller's step runs after every piece but the last, in order", str(seen))
	_check(Engine.get_process_frames() - frame0 >= expected.size(),
		"and a frame passes at each step")
	_check(Engine.get_process_frames() - frame0 == expected.size(),
		"and only there: the profiler's script load ends no frame of its own", str(Engine.get_process_frames() - frame0))
	_check(settings.setups == 1 and client.menu != null and client.console != null \
			and client.console.get_meta(&"menu") == client.menu,
		"it builds what setup builds: the settings once, the menu, the console over it")
	_check(client.setup_usec.keys() == Array(DotGameClient.SETUP_PIECES),
		"and times every piece", str(client.setup_usec))
	var again: DotResult = await client.setup_stepped(between)
	_check(not again.ok and again.error.code == DotError.CODE_STATE and not client.setup().ok,
		"a second setup, either way, is refused")

	var bare := DotGameClient.new()
	bare.gate_only = true
	bare.require_camera = false
	host.add_child(bare)
	seen.clear()
	var bare_up: DotResult = await bare.setup_stepped(between)
	_check(bare_up.ok and seen.is_empty() and bare.setup_usec.keys() == [&"chat"] and bare.menu == null,
		"gate_only steps only the chat, with nothing between")
	host.queue_free()
	await get_tree().process_frame
	_done()

# 9. DotGameLink

## Catches every engine-level error while attached. A deliberate error elsewhere in this suite
## cannot reach it: it is attached only for this section.
class ErrorCatcher extends Logger:
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String,
			rationale: String, _editor_notify: bool, error_type: int,
			_script_backtraces: Array) -> void:
		errors.append("%s %s %s" % [code, rationale, function])


func _links_named(parent: Node, wanted: StringName) -> Array[Node]:
	var found: Array[Node] = []
	for child in parent.get_children():
		# A retired link stays in the tree for a grace period (in-flight RPCs from clients that
		# have not heard of the new game yet); only a live one counts.
		if child.get_script() == TestLink and not String(child.name).begins_with(DotGameLink.RETIRED):
			found.append(child)
	return found


## What a game's bridge does in open_link, and what the module does to it on unload.
func _open_bridge(host: Node, parent: Node) -> Node:
	var bridge := Node.new()
	host.add_child(bridge)
	DotGameLink.attach(TestLink.new(), parent, bridge, TestLink.NODE_NAME)
	return bridge


func _drop_bridge(host: Node, bridge: Node) -> void:
	# Exactly DotGameModule._drop.
	host.remove_child(bridge)
	bridge.queue_free()


func _test_link_survives_reload() -> void:
	_section("DotGameLink: one live link after a reload, and a clean teardown")
	var catcher := ErrorCatcher.new()
	OS.add_logger(catcher)

	var server := Node.new()
	server.name = "Server"
	add_child(server)
	var module := Node.new()
	server.add_child(module)

	var bridge := _open_bridge(module, server)
	_check(_links_named(server, TestLink.NODE_NAME).size() == 1, "a link is under the server node")

	# Reload twice. The second reload comes before the frame that would free the first: the
	# name has to be free that instant, not a frame later.
	_drop_bridge(module, bridge)
	bridge = _open_bridge(module, server)
	_drop_bridge(module, bridge)
	await get_tree().process_frame
	bridge = _open_bridge(module, server)
	await _frames(2)
	var links := _links_named(server, TestLink.NODE_NAME)
	_check(links.size() == 1, "after two reloads exactly one link remains", str(links.size()))
	_check(links.size() == 1 and links[0].name == TestLink.NODE_NAME,
		"and it has the name the clients route to",
		str(links[0].name) if links.size() == 1 else "")
	var retired_count := 0
	for child in server.get_children():
		if String(child.name).begins_with(DotGameLink.RETIRED):
			retired_count += 1
	_check(server.get_child_count() - retired_count == 2, "and nothing else live was left under the server",
		str(server.get_children()))
	_check(retired_count == 0, "a same-name reload frees the retired links within a frame or two (a client's cache id must not land on one)",
		str(retired_count))

	# A link nobody re-attaches under (a switch to another game) keeps its grace period.
	var holder := Node.new()
	server.add_child(holder)
	var game_a := TestLink.new()
	var owner_a := Node.new()
	holder.add_child(owner_a)
	DotGameLink.attach(game_a, holder, owner_a, &"GameA")
	owner_a.free()
	await get_tree().process_frame
	var game_b := TestLink.new()
	var owner_b := Node.new()
	holder.add_child(owner_b)
	DotGameLink.attach(game_b, holder, owner_b, &"GameB")
	await _frames(2)
	_check(is_instance_valid(game_a) and game_a.is_inside_tree() and not game_a.is_queued_for_deletion()
		and String(game_a.name).begins_with(DotGameLink.RETIRED + "GameA_"),
		"a link retired by an attach under a different name survives for the grace period")
	_check(is_instance_valid(game_b) and game_b.name == &"GameB", "and the new link has its own name")
	holder.queue_free()

	# A link left by an unclean unload is retired by the next attach.
	var orphan := TestLink.new()
	orphan.name = TestLink.NODE_NAME
	var other := Node.new()
	other.name = "Other"
	server.add_child(other)
	_drop_bridge(module, bridge)
	await get_tree().process_frame
	server.add_child(orphan)
	bridge = _open_bridge(module, server)
	await get_tree().process_frame
	links = _links_named(server, TestLink.NODE_NAME)
	_check(links.size() == 1 and links[0] != orphan and links[0].name == TestLink.NODE_NAME,
		"a same-named link already there is retired, and the new one gets the name")

	# A stale link something else already queue_freed still holds its name this frame; the
	# next attach must take the name anyway, not be renamed by add_child.
	var freed := TestLink.new()
	freed.name = TestLink.NODE_NAME
	_drop_bridge(module, bridge)
	await get_tree().process_frame
	server.add_child(freed)
	freed.queue_free()
	bridge = _open_bridge(module, server)
	var live: Node = server.get_node_or_null(NodePath(String(TestLink.NODE_NAME)))
	_check(live != null and live != freed,
		"a same-named link already queued for deletion still gives up the name at once",
		str(live.name) if live != null else "none")
	await get_tree().process_frame

	# The whole server tree goes at once, as it does when the process stops.
	var errors_before := catcher.errors.size()
	server.queue_free()
	await _frames(2)
	_check(not is_instance_valid(server), "the whole server tree frees")
	_check(catcher.errors.size() == errors_before,
		"and tearing it down logs no engine ERROR", str(catcher.errors))

	# The same teardown with the module unloading first, then the tree: the order of a stop.
	var server2 := Node.new()
	server2.name = "Server"
	add_child(server2)
	var module2 := Node.new()
	server2.add_child(module2)
	_open_bridge(module2, server2)
	server2.remove_child(module2)
	module2.free()
	await get_tree().process_frame
	server2.free()
	_check(catcher.errors.size() == errors_before, "and freeing the module before the tree logs none")
	# The retire timers of the links freed early above fire now, on nodes that are gone.
	await get_tree().create_timer(DotGameLink.RETIRED_SECONDS + 1.0).timeout
	_check(catcher.errors.is_empty(), "no engine ERROR in the whole section, nor when the retire timers fire", str(catcher.errors))

	OS.remove_logger(catcher)
	_done()
