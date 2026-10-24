extends Node

## dot-game: the sequence, the roster, the tick, and every way it has to unwind.
##
## [b]What this suite is really for.[/b] The skeleton it exercises was extracted from
## five games that each wrote it by hand, and the reason to extract it is that two of
## them wrote it slightly wrong: one read a field off an event that the event does not
## carry, so nobody ever joined its dedicated servers, silently, for the life of the
## module. A base class only helps if the base class is the one that is right, which
## means the base class is the one that has to be tested.
##
## Sections:
##
##   1. It refuses to load without a game object, and says which one it wanted.
##   2. The whole sequence, in order, with a real [DotServer] and a real module host.
##   3. The roster: a spawn event, an admission refusal, a disconnect.
##   4. The tick reaches the bridge before the game.
##   5. Unload tears down in the reverse order, and nothing is left ticking.
##   6. Every failure path unwinds what it had already built.
##   7. The services layer's hooks: no server, the backlog held, the ear.
##   3b. Still loading: a joined seat is loading until its client reports, the timeout
##      releases one that never does (with a warning), a map change re-marks, bots never are.
##   9. DotGameLink: a link under the server node survives two reloads as exactly one, and a
##      whole server tree torn down logs no engine ERROR.
##   8. DotGameClient: the cover first, then the settings, menu, console, Tab, M, the chat's
##      keyboard and the input block, driven through stand-ins; and the same client in a build
##      with neither dot-menu nor dot-console.
##
## [b]Errors this suite prints on purpose.[/b] Three "module refused to load" lines,
## which are sections 1 and 6 doing their job -- and, from section 3, an engine-level
## [code]Attempt to call RPC with unknown peer ID: 3[/code]. That last one is the
## admission refusal reaching [method DotServer.kick], which sends a disconnect RPC to a
## peer that does not exist because this suite's sessions are built by hand rather than
## connected. It is the fixture's shape, not a failure; a suite whose deliberate errors
## are not written down is a suite whose real ones get scrolled past.
##
## Run:
## [codeblock]
## godot --headless --path . res://examples/game_selftest.tscn
## [/codeblock]

const TestGame := preload("fixtures/test_game.gd")
const TestModule := preload("fixtures/test_module.gd")
const TestHookServices := preload("fixtures/test_hook_services.gd")
const TestLink := preload("fixtures/test_link.gd")
const MODULE_PATH := "res://examples/fixtures/test_module.gd"

const PORT := 27919

## Every check this suite runs, the section guard's own included. The total the section
## counter cannot be: a runtime error inside a section aborts that function after the
## section has announced itself, so the counter is satisfied and the checks after the
## error simply never happen. See docs/testing.md.
const CHECKS := 358

var _entered := 0
var _completed := 0
var _passed := 0
var _failed := 0
var _failures: Array[String] = []

var _server: DotServer = null
var _game: Node = null
var _module: DotGameModule = null

## userid -> session, for the roster's substituted lookup.
var _sessions: Dictionary = {}


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("dot-game: the module skeleton, end to end")

	if await _boot():
		await _test_it_refuses_without_a_game()
		_make_game()

		if await _test_the_sequence():
			await _test_the_roster()
			_test_still_loading()
			await _test_the_tick()
			_test_hibernation()
			await _test_the_teardown()

		await _test_noblock_wired()
		await _test_a_refused_game_load_unwinds()
		await _test_a_refused_attach_unwinds()
		_test_operator_net_ceiling()
		await _test_operator_ceiling_reaches_the_netcode()
		await _test_server_threads_reach_the_netcode()
		await _test_services_without_the_addons()
		await _test_services_hooks()
		await _test_chat_client_without_the_addons()
		await _test_chat_client_server_lines()
		await _test_map_content()
		_test_auto_update_wiring()
		await _test_client_platform()
		await _test_look_mute()
		await _test_client_hooks_menu()
		await _test_client_reports_cover()
		await _test_client_page_guard()
		await _test_client_user_tier()
		await _test_client_without_the_addons()
		await _test_link_survives_reload()
		_test_workbench_hosting()
		await _test_avatar_actions()
		await _test_avatar_loadouts()
		await _test_avatar_loadout_client()
		await _test_avatar_content()
		await _test_site_server()
		await _test_prejoin()

	_teardown()

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _boot() -> bool:
	_section("a server boots")

	var config := DotServerConfig.new()
	config.hostname = "dot-game selftest"
	config.port = PORT
	config.max_players = 4
	config.a2s_enabled = false
	config.query_enabled = false
	config.hibernate_when_empty = false
	# The addon ships a server.cfg the search path would find, and this suite would
	# then be asserting against whatever that file contains.
	config.startup_config = ""
	config.autoexec_config = ""
	# A thread blocked in a read the engine cannot cancel keeps the process alive after
	# `quit()`, which turns a half-second suite into one that has to be killed.
	# Kept after dot-server 5f46687, which no longer reads a pipe unless `stdin_console_pipes`
	# is on: a terminal is still read, and a suite takes no commands from either.
	config.stdin_console_enabled = false

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	add_child(_server)

	var booted := await _server.boot()

	if not _check(booted.ok, "it boots", str(booted.error)):
		_done()
		return false

	_check(_server.modules != null, "and has a module host")
	_done()
	return true


# --- 1. No game ------------------------------------------------------------

func _test_it_refuses_without_a_game() -> void:
	_section("it refuses to load without a game object")

	var loaded: DotResult = await _load_module()

	if not _check(not loaded.ok, "the module refuses"):
		_unload_module()
		_done()
		return

	_check(
		loaded.error.code == DotError.CODE_STATE,
		"with CODE_STATE rather than something a retry would fix",
		"got %s" % loaded.error.code
	)
	_check(
		loaded.error.message.contains(String(TestGame.SERVICE)),
		"naming the registry service it looked for",
		"a module that says 'no game' and not WHICH game is a grep through five files"
	)
	# A module that refused must leave nothing behind. `load_module` cleans up
	# registrations, and the skeleton has to have built nothing worth cleaning.
	_check(
		not _server.modules.has_module("testgame"),
		"and is not left half-attached"
	)

	_done()


# --- 2. The sequence -------------------------------------------------------

func _test_the_sequence() -> bool:
	_section("the whole sequence, in order")

	var loaded: DotResult = await _load_module()

	if not _check(loaded.ok, "the module loads", str(loaded.error)):
		_done()
		return false

	_module = loaded.value as DotGameModule

	_check(_module.game == _game, "it found the game")
	_check(_module.net != null, "it built the netcode")
	_check(
		_module.net != null and _module.net.messages.is_sealed(),
		"and sealed the message schema",
		"wire ids come from a sort of the registered names, so a type registered "
		+ "after the seal renumbers every id above it"
	)
	_check(
		_module.net != null and not _module.net.auto_tick,
		"with auto_tick off, so the game is not simulated twice"
	)
	_check(
		_module.net != null and _module.net.config_file == "",
		"and no config file, so a stale user:// JSON cannot set the tick rate"
	)

	_check(_module.bridge != null, "it built the bridge")
	_check(
		_module.bridge != null and _module.bridge.attached,
		"and attached it to the netcode"
	)
	_check(
		_module.bridge != null and _module.bridge.link_opened,
		"and opened its link under the server node"
	)

	_check(_module.identity != null, "it built the identity layer")
	_check(
		_module.identity != null and _module.identity.setup_calls == 1,
		"and awaited its setup exactly once",
		"an un-awaited coroutine returns at its first suspension, so a caller that "
		+ "forgets is testing a property of a Signal"
	)

	_check(_module.services != null, "it built the services layer")
	_check(
		_module.services != null and _module.services.link == _module.bridge,
		"and handed it the bridge's link",
		"a services layer with no link relays voice into nothing"
	)
	_check(
		_module.services != null and _module.services.backbone == _module.identity,
		"and the identity layer's backbone, BEFORE its setup ran",
		"a backbone assigned afterwards is one the relay has already decided it "
		+ "does not have"
	)
	_check(
		_module.bridge != null and _module.bridge.voice_relay_fn.is_valid(),
		"and wired voice back onto the bridge"
	)

	_check(_module.roster != null, "it built the roster")
	_check(_module.game_loaded == 1, "and ran the game's own load last")
	_check(
		_server.console != null
			and _server.console.find_command("testgame_status") != null,
		"so a command the game registered is there"
	)

	# What a listing prints as the map is the game's to say, and a game on these bases
	# says it in one call rather than reaching into the server's game manager.
	_check(
		_module.report_map("dm_selftest") and _server.games.current_map() == "dm_selftest",
		"a map the game reports is the server's map",
		_server.games.current_map()
	)
	_module.report_map("")
	_check(_server.games.current_map() == "", "and \"\" clears it")

	_done()
	return true


# --- 3. The roster ---------------------------------------------------------

func _test_the_roster() -> void:
	_section("the roster, driven by the events a real server fires")

	var session := _fake_session(1, 41, "Joiner")

	# The roster's session lookup, substituted: this suite connects no clients, so there
	# is no real session table to find one in. Substituting it is also what makes the
	# next check mean anything -- see below.
	_sessions[session.userid] = session
	_module.roster.session_fn = func(userid: int) -> DotClientSession:
		return _sessions.get(userid)

	# [b]The regression guard this addon exists for.[/b] `client_spawn` carries `userid`
	# and `name` and does NOT carry `peer_id`. Two games in this family read `peer_id`
	# here, looked up session 0, found null and returned -- so nobody ever joined, and
	# nothing errored, because a null session is a legitimate thing to find.
	var event := DotEvent.new(
		"client_spawn",
		{"userid": session.userid, "name": session.display_name}
	)

	_module._on_client_spawn(event)

	_check(_module.roster.has(session.userid), "a spawn event puts a player in")

	# [b]The guard proper.[/b] An event carrying only `peer_id` -- which is what the two
	# broken games were reading -- must add nobody, because `peer_id` is not a userid and
	# is not even on this event. With the lookup substituted, "found nothing" and "read
	# the wrong field" are finally distinguishable: a handler reading `peer_id` would find
	# session 2 here and seat them.
	_sessions[2] = _fake_session(2, 2, "Wrong")
	var peer_only := DotEvent.new("client_spawn", {"peer_id": 2, "name": "Wrong"})
	_module._on_client_spawn(peer_only)
	_check(
		not _module.roster.has(2),
		"an event carrying only peer_id seats nobody",
		"client_spawn has no peer_id; a handler that reads one looks up userid 0 and "
		+ "silently seats nobody -- or, worse, seats whoever userid 2 happens to be"
	)
	_sessions.erase(2)
	_check(
		_module.bridge.added.has(session.userid),
		"through the bridge, so they are replicated and not only simulated"
	)
	_check(
		_module.services.peers_added.has(session.peer_id),
		"and chat is told, keyed on the PEER rather than the userid"
	)

	# Twice is once.
	_module._on_client_spawn(event)
	_check(
		_module.bridge.added.size() == 1,
		"a second spawn event for the same player changes nothing"
	)

	# Admission.
	_module.services.refuse_admission = true
	var banned := _fake_session(3, 42, "Banned")
	_sessions[banned.userid] = banned
	var banned_event := DotEvent.new(
		"client_spawn",
		{"userid": banned.userid, "name": banned.display_name}
	)

	_module._on_client_spawn(banned_event)

	_check(
		not _module.roster.has(banned.userid),
		"a player the services layer refuses is not added",
		"dot-server's own mute dies with the connection; dot-moderation's records "
		+ "are the durable second gate and they are checked here"
	)
	_module.services.refuse_admission = false

	# Leaving.
	_module.roster.on_client_disconnected(session, "quit")

	_check(not _module.roster.has(session.userid), "a disconnect takes them out")
	_check(
		_module.bridge.removed.has(session.peer_id),
		"through the bridge, which releases their entities and input buffer"
	)
	_check(
		_module.services.peers_removed.has(session.peer_id),
		"and chat is told they went"
	)

	var counts := _module.roster.describe()
	_check(
		int(counts.get("joins", 0)) == 1 and int(counts.get("leaves", 0)) == 1,
		"and describe() can be dumped into a bug report (%s)" % counts
	)

	_done()


# --- 3b. Still loading ------------------------------------------------------

var _warnings: Array[Dictionary] = []


func _capture_warning(record: Dictionary) -> void:
	if int(record.get("level", 0)) >= DotLog.Level.WARN:
		_warnings.append(record)


## A seat is loading from the spawn until its client says its cover lifted; nothing a client
## sends makes a loaded seat loading again; a map change does, briefly for a client that does
## not re-cover; the timeout releases a silent one and says so; a bot never is.
func _test_still_loading() -> void:
	_section("still loading: from the join until the client's cover lifts, bounded")

	var roster := _module.roster
	var clock := [100000]
	roster.now_fn = func() -> int: return clock[0]
	var heard: Array = []
	var on_changed := func(seat: int, loading: bool) -> void: heard.append([seat, loading])
	_module.loading_changed.connect(on_changed)
	var env := _server.envelope

	var ada := _fake_session(5, 51, "Ada")
	var bea := _fake_session(6, 52, "Bea")
	var bot := _fake_session(0, 53, "Bot")
	bot.local = true
	for one: DotClientSession in [ada, bea, bot]:
		_sessions[one.userid] = one
		_module._on_client_spawn(DotEvent.new("client_spawn", {"userid": one.userid, "name": one.display_name}))

	_check(_module.is_loading(51) and _module.is_peer_loading(5) and not _module.can_be_harmed(51)
			and not _module.can_peer_be_harmed(5),
		"a seat that just joined is loading, and cannot be harmed")
	_check(heard.has([51, true]) and heard.has([52, true]), "loading_changed says so", str(heard))
	_check(not _module.is_loading(53) and _module.can_be_harmed(53) and not heard.has([53, true]),
		"a bot is never loading")
	_check(not _module.is_peer_loading(99) and _module.can_peer_be_harmed(99),
		"and nobody the game does not know is")
	_check(_game.peer_loading_fn.is_valid() and bool(_game.peer_loading_fn.call(5)),
		"a game that declares peer_loading_fn is handed the question")
	var described: Dictionary = _module.describe()
	_check(described.get("loading", []) == [51, 52], "describe() names the loading seats", str(described.get("loading")))

	_check(env.knows(DotGameRoster.COVER_KIND), "the server advertises the cover kind")
	_check(env.dispatch(5, DotGameRoster.COVER_KIND, {"covered": "no"}) and _module.is_loading(51),
		"a malformed report changes nothing")
	_check(env.dispatch(5, DotGameRoster.COVER_KIND, {"covered": false})
			and not _module.is_loading(51) and _module.can_be_harmed(51) and heard.has([51, false]),
		"the client saying its cover lifted ends it, through the envelope")
	env.dispatch(5, DotGameRoster.COVER_KIND, {"covered": true})
	_check(not _module.is_loading(51),
		"a cover going up never makes a loaded seat loading: only the server starts one")

	# A map change: everybody loading again. Ada re-covers (her report came just before the
	# server's change, which is allowed), Bea's client never says anything.
	_module.report_map("first")
	_check(not _module.is_loading(51), "the first map reported is not a map change")
	_module.report_map("second")
	_check(_module.is_loading(51) and _module.is_loading(52) and not _module.is_loading(53),
		"a new map re-marks every client's seat, not the bot's")
	_module.report_map("second")
	clock[0] += int(_module.reload_grace_sec * 1000.0) + 10
	_module.roster.poll_loading()
	_check(_module.is_loading(51), "a client that covered for the change waits out the grace")

	clock[0] += int(_module.load_timeout_sec * 1000.0)
	_warnings.clear()
	DotLog.set_channel_level(DotGameRoster.CHANNEL, DotLog.Level.WARN)
	DotLog.add_sink(_capture_warning)
	var before := roster.load_timeouts
	_module._physics_process(1.0 / 60.0)
	DotLog.remove_sink(_capture_warning)
	DotLog.clear_channel_level(DotGameRoster.CHANNEL)
	_check(not _module.is_loading(51) and not _module.is_loading(52) and roster.load_timeouts > before,
		"the timeout releases a client that never says, from the module's own tick")
	_check(_warnings.size() >= 1 and str(_warnings[0].get("message", "")).contains("never said"),
		"with a warning", str(_warnings))

	# Bea's client did not re-cover for a map change: the grace releases her, not the timeout.
	_module.report_map("third")
	_module.roster.report_cover(5, true)
	clock[0] += int(_module.reload_grace_sec * 1000.0) + 10
	_module.roster.poll_loading()
	_check(not _module.is_loading(52) and _module.is_loading(51),
		"a client that does not re-cover is released by the grace; one that did is not")
	_module.mark_reloading()
	_check(_module.is_loading(52), "mark_reloading is the same for a change report_map does not see")

	heard.clear()
	_module.roster.on_client_disconnected(ada, "quit")
	_check(not _module.is_loading(51) and heard.has([51, false]), "leaving while loading ends it")
	for one: DotClientSession in [bea, bot]:
		_module.roster.on_client_disconnected(one, "quit")
		_sessions.erase(one.userid)
	_sessions.erase(ada.userid)
	_check(_module.loading_seats().is_empty(), "and nobody is left loading")

	_module.loading_changed.disconnect(on_changed)
	roster.now_fn = Callable()
	_done()


# --- 4. The tick -----------------------------------------------------------

func _test_the_tick() -> void:
	_section("the tick reaches the bridge, and the game after it")

	var before: int = _module.bridge.ticks.size()

	await get_tree().physics_frame
	await get_tree().physics_frame

	var after: int = _module.bridge.ticks.size()

	if not _check(after > before, "the bridge is ticked (%d ticks)" % after):
		_done()
		return

	_check(
		_module.bridge.ticks[after - 1] == _module.tick,
		"with the module's own counter, not the frame count"
	)
	_check(
		_module.game_ticks.size() == after,
		"and the game's tick runs once per bridge tick",
		"a game ticking itself as well moves every player twice"
	)
	_check(
		_module.game_ticks[-1] == _module.bridge.ticks[-1],
		"on the same tick number, in that order"
	)

	# `_can_tick`: a module whose world went away underneath it says no, and a frame it
	# refused is not a tick — neither the counter, the bridge nor the game moves.
	var held_at: int = _module.tick
	var held_bridge: int = _module.bridge.ticks.size()
	TestModule.hold_ticks = true
	await get_tree().physics_frame
	await get_tree().physics_frame
	var held_ok: bool = _module.tick == held_at and _module.bridge.ticks.size() == held_bridge
	TestModule.hold_ticks = false
	_check(held_ok, "a module that answers _can_tick false is not ticked, and its counter does not move")
	await get_tree().physics_frame
	_check(_module.tick > held_at, "and ticks again once it says yes")

	_done()


# --- 4b. Hibernation -------------------------------------------------------

func _test_hibernation() -> void:
	_section("the server's hibernation reaches every clock under the module, and the game")

	var clock: Node = _module.clock
	_check(
		clock != null and clock.followed == 1,
		"a clock two levels down was handed the server once, after the game's load"
	)

	# The signal itself, rather than the cvar: what is under test is the module's wiring,
	# and dot-server's own suite owns when the server decides to sleep.
	_server.hibernation_changed.emit(true)
	_server.hibernation_changed.emit(false)

	_check(
		clock != null and str(clock.heard) == str([true, false]),
		"the clock heard the server sleep and wake (%s)" % (str(clock.heard) if clock != null else "-")
	)
	_check(
		str(_module.hibernation_heard) == str([true, false]),
		"and so did the game's own _game_hibernation (%s)" % str(_module.hibernation_heard)
	)
	_done()


# --- 5. Teardown -----------------------------------------------------------

func _test_the_teardown() -> void:
	_section("unloading takes it all down, in reverse")

	var bridge := _module.bridge
	var net := _module.net
	var services := _module.services
	var module := _module
	var roster := _module.roster
	var on_hibernation := Callable(_module, "_on_hibernation_changed")
	var was_following := _server.hibernation_changed.is_connected(on_hibernation)

	# The Tab board: the game's columns reach dot-server's roster through the module.
	var fields: Callable = _server.scoreboard_fields
	var row: Dictionary = fields.call(DotClientSession.new(42)) if fields.is_valid() else {}
	_check(int(row.get("kills", 0)) == 3 and int(row.get("who", 0)) == 42,
		"the game's own board columns are the server's, per session", str(row))
	var snap := _server.scoreboard_snapshot()
	_check((snap.get("teams", []) as Array).size() == 1, "and its teams ride on the roster")

	var unloaded := _server.modules.unload_module("testgame")

	if not _check(unloaded.ok, "the module unloads", str(unloaded.error)):
		_done()
		return

	_check(module.game_unloaded == 1, "the game's own unload ran")

	# A frame for the queue_free()s to land.
	await get_tree().process_frame
	await get_tree().process_frame

	_check(not is_instance_valid(net), "the netcode is gone")
	_check(not is_instance_valid(bridge), "the bridge is gone")
	_check(not is_instance_valid(services), "the services layer is gone")
	_check(
		_server.console.find_command("testgame_status") == null,
		"and the command it registered went with it",
		"a command whose handler points at a freed module crashes the server when "
		+ "somebody types it"
	)
	# [b]Read off the reference taken before the unload.[/b] `module.roster` after the
	# module has been freed is an access on a previously freed object, which aborts the
	# section -- and a section that aborts takes the rest of its checks with it while the
	# section counter goes on saying it ran.
	_check(
		not _server.client_disconnected.is_connected(
			Callable(roster, "on_client_disconnected")
		),
		"and nothing is still connected to the server's signals"
	)
	_check(
		was_following and not _server.hibernation_changed.is_connected(on_hibernation),
		"including its hibernation"
	)
	_check(not _server.scoreboard_fields.is_valid() and not _server.scoreboard_extra.is_valid(),
		"and the board's columns: the server outlives the game, and the next is not asked about it")

	_module = null
	_done()


# --- 6. Unwinding ----------------------------------------------------------

class NoblockBody:
	extends RefCounted
	var pair_fn: Callable = Callable()


func _test_noblock_wired() -> void:
	_section("a game with body_rules gets the block rules from the module")

	var body := NoblockBody.new()
	_game.set("body_rules", body)
	var loaded: DotResult = await _load_module()
	_check(loaded.ok, "the module loads")
	var module: DotGameModule = _server.modules.get_module("testgame") if loaded.ok else null
	var wired := DotGameNoblock.available()
	_check(
		module != null and (module.noblock != null) == wired,
		"noblock is built exactly when dot-team is in the build"
	)
	_check(body.pair_fn.is_valid() == wired, "and feeds the body's pair_fn")
	_unload_module()
	_game.set("body_rules", null)
	_check(module == null or module.noblock == null, "and is gone after the unload")

	_done()


func _test_a_refused_game_load_unwinds() -> void:
	_section("a game that refuses to load leaves nothing running")

	TestModule.refuse_game_load = true
	var loaded: DotResult = await _load_module()
	TestModule.refuse_game_load = false

	_check(not loaded.ok, "the module refuses")
	_check(
		not _server.modules.has_module("testgame"),
		"and is not registered"
	)

	await get_tree().process_frame
	await get_tree().process_frame

	# The netcode is the one that matters: a manager left parented under a module the
	# host has freed goes on ticking, and an open link goes on answering.
	var strays := 0
	for child in _server.get_children():
		if child is DotNetManager:
			strays += 1

	_check(strays == 0, "and left no netcode ticking behind it")

	_done()


func _test_a_refused_attach_unwinds() -> void:
	_section("a bridge that will not attach unwinds the netcode")

	TestModule.refuse_attach = true
	var loaded: DotResult = await _load_module()
	TestModule.refuse_attach = false

	_check(not loaded.ok, "the module refuses")
	_check(
		loaded.error != null and str(loaded.error).contains("netcode"),
		"and says the netcode is what failed (%s)"
			% (loaded.error.message if loaded.error != null else "")
	)

	await get_tree().process_frame
	_check(
		not _server.modules.has_module("testgame"),
		"and nothing is left loaded"
	)

	_done()


# --- Harness ---------------------------------------------------------------

func _make_game() -> void:
	_game = TestGame.new()
	_game.name = "TestGame"
	add_child(_game)


func _caps(game_values: Dictionary, ceiling: Dictionary, tick := 64) -> DotNetConfig:
	var c := DotNetConfig.new()
	c.tick_rate = tick
	for key in game_values:
		c.set(key, game_values[key])
	DotGameNetcode.cap(c, ceiling)
	return c


func _test_operator_net_ceiling() -> void:
	_section("an operator's net limits are a ceiling on the game's own")

	var c := _caps({"per_client_budget": 500000}, {"per_client_budget": 1000000})
	_check(c.per_client_budget == 500000, "a game value under the cap is kept")
	c = _caps({"per_client_budget": 2000000}, {"per_client_budget": 1000000})
	_check(c.per_client_budget == 1000000, "a game value over the cap is clamped")
	c = _caps({"per_client_budget": 0}, {"per_client_budget": 1000000})
	_check(c.per_client_budget == 1000000, "a game that is unlimited takes the operator's cap")
	c = _caps({"per_client_budget": 2000000}, {"per_client_budget": 0})
	_check(c.per_client_budget == 2000000, "an operator 0 leaves the game's value alone")
	c = _caps({"per_client_budget": 0}, {"per_client_budget": 0})
	_check(c.per_client_budget == 0, "0 on both sides stays unlimited")
	c = _caps({"per_client_packet_rate": 60}, {"per_client_packet_rate": 30})
	_check(c.per_client_packet_rate == 30, "the packet rate is clamped the same way")
	c = _caps({"max_entities_per_snapshot": 256}, {"max_entities_per_snapshot": 64})
	_check(c.max_entities_per_snapshot == 64, "so is the entity cap")
	c = _caps({"mtu": 1200}, {"mtu": 1000})
	_check(c.mtu == 1000, "and the mtu")
	c = _caps({"interpolation_buffer": 2.0}, {"interpolation_buffer": 3.0})
	_check(is_equal_approx(c.interpolation_buffer, 3.0), "the interpolation buffer is overridden, not capped")

	c = _caps({"snapshot_rate": 32}, {"snapshot_rate": 66})
	_check(c.snapshot_rate == 32, "a snapshot cap above the game's rate changes nothing")
	c = _caps({"snapshot_rate": 32}, {"snapshot_rate": 20})
	_check(c.snapshot_rate == 16, "a snapshot cap of 20 on tick 64 lands on the divisor 16")
	c = _caps({"snapshot_rate": 30}, {"snapshot_rate": 66}, 30)
	_check(c.snapshot_rate == 30, "and never above the tick rate")
	c = _caps({"snapshot_rate": 32}, {"snapshot_rate": 0})
	_check(c.snapshot_rate == 32, "a snapshot cap of 0 uses the game's rate")
	c = _caps({"snapshot_rate": 32}, {})
	_check(c.snapshot_rate == 32 and DotGameNetcode.cap(c, {}).is_empty(), "no ceiling changes nothing, and logs nothing")
	_done()


func _test_avatar_actions() -> void:
	_section("avatar actions: checked on the server, then told to everybody")
	var loaded: DotResult = await _load_module()
	if _check(loaded.ok, "the module loads", str(loaded.error)):
		var module := loaded.value as DotGameModule
		var relay := module.net.get_meta(DotGameAvatarActionRelay.NET_META, null) as DotGameAvatarActionRelay
		if _check(relay != null, "the netcode serves the relay"):
			var clock := [10000]
			relay.now_fn = func() -> int: return clock[0]
			var sent := []
			module.net.send_fn = func(peer: int, payload: PackedByteArray, _d: int) -> void: sent.append([peer, payload])
			var ask := func(peer: int, id: String) -> void:
				var m := DotGameAvatarActionMessage.new()
				m.sender_peer_id = peer
				m.id = id
				m.loop = true
				module.net.messages.dispatch(m)
			ask.call(7, "wave")
			_check(sent.size() == 1 and sent[0][0] == 0, "a starter action is sent to everyone")
			var back := DotGameAvatarActionMessage.new()
			var read := module.net.messages.decode(DotNetReader.new(sent[0][1]), 1, false) if not sent.is_empty() else null
			_check(read != null and read.ok and read.value is DotGameAvatarActionMessage and read.value.actor == 7 and read.value.id == "wave",
				"naming who and what")
			_check(read != null and read.ok and read.value.loop == false, "a built-in's loop is its own, not the client's (asked true)")
			clock[0] += 1000
			var asked_loop := func(peer: int, id: String, loop: bool) -> void:
				var m := DotGameAvatarActionMessage.new()
				m.sender_peer_id = peer
				m.id = id
				m.loop = loop
				module.net.messages.dispatch(m)
			asked_loop.call(7, "dance", false)
			var dance := module.net.messages.decode(DotNetReader.new(sent[1][1]), 1, false) if sent.size() == 2 else null
			_check(dance != null and dance.ok and dance.value.loop == true, "a looping built-in loops though the client asked not to")
			sent.resize(1)
			clock[0] += 1000
			TestModule.avatar_veto = ["bow"]
			ask.call(7, "bow")
			TestModule.avatar_veto = []
			_check(sent.size() == 1, "the module's own _avatar_action_veto override stops it")
			var game_hook := Node.new()
			game_hook.set_script(_veto_game_script())
			var kept_game: Object = module.game
			module.game = game_hook
			ask.call(7, "bow")
			module.game = kept_game
			game_hook.free()
			_check(sent.size() == 1, "and so does the game object's, when the module does not override it")
			ask.call(7, "bow")
			_check(sent.size() == 2, "with neither, it plays")
			sent.resize(1)
			ask.call(7, "dance")
			_check(sent.size() == 1, "a second one inside the interval is dropped")
			clock[0] += 1000
			ask.call(7, "not_an_action")
			_check(sent.size() == 1, "an id that is not equipped is dropped")
			relay.equipped_fn = func(_p: int) -> Variant: return ["custom_clip"]
			ask.call(7, "custom_clip")
			_check(sent.size() == 2, "an equipped uploaded id passes")
			clock[0] += 1000
			relay.veto_fn = func(_p: int, _i: String) -> bool: return true
			ask.call(7, "custom_clip")
			_check(sent.size() == 2, "the game's veto stops it")
			relay.veto_fn = Callable()
			ask.call(0, "custom_clip")
			_check(sent.size() == 2, "a request with no peer is dropped")
			_check(DotGameAvatarActionRelay.STARTER_IDS.size() == 13, "thirteen starter ids")
			_unload_module()
	_done()


func _veto_game_script() -> GDScript:
	var g := GDScript.new()
	g.source_code = "extends Node\nfunc _avatar_action_veto(_p: int, id: String) -> bool:\n\treturn id == \"bow\"\n"
	var _r := g.reload()
	return g


class FakeActionInput extends Node:
	signal action_requested(entry: Dictionary)
	var enabled := true
	var actions: Object = RefCounted.new()


class FakeSkeletonFigure extends RefCounted:
	var bones := Skeleton3D.new()

	func skeleton() -> Skeleton3D:
		return bones


class FakeActionFigure extends RefCounted:
	var clips := {}
	var played: Array = []
	var added: Array = []

	func play_action(id: StringName, loop: bool = false, elapsed: float = 0.0) -> bool:
		if String(id).contains("/") and not clips.has(id):
			return false
		played.append([String(id), loop, elapsed])
		return true

	func add_action_scene(id: StringName, scene: Node, clip: String, loop: bool) -> DotResult:
		added.append([String(id), scene, clip, loop])
		clips[id] = true
		return DotResult.success(true)


func _loadout_sent(module: DotGameModule, sent: Array) -> Array:
	var out := []
	for s: Array in sent:
		var read := module.net.messages.decode(DotNetReader.new(s[1]), 1, false)
		if read.ok and read.value is DotGameAvatarLoadoutMessage:
			out.append([s[0], read.value])
	return out


func _test_avatar_loadouts() -> void:
	_section("avatar loadouts: read by the server, checked, bounded, told to everybody and to a late joiner")
	var upload := {"contentId": "action/9/1", "clip": "Hop", "loop": false, "fileUrl": "https://cdn.test/a.glb"}
	var parsed: Variant = DotGameAvatarLoadouts.parse({"EMOTE": [upload, upload, {"builtin": "wave"}, {"builtin": "nope"}],
		"POSE": [{"contentId": "avatar/3/1", "clip": "X"}, {"contentId": "action/4/1", "clip": ""}],
		"GESTURE": [{"builtin": "wave"}]})
	var ids := []
	for e: Dictionary in (parsed if parsed is Array else []):
		ids.append(e["id"])
	_check(ids == ["action/9/1", "sit", "salute", "arms_crossed", "hands_on_hips", "wave"], "parse keeps an upload once, a built-in only of its own kind, and gives an empty kind the starters", str(ids))
	var many := []
	for i in 30:
		many.append({"contentId": "action/%d/1" % (i + 1), "clip": "c"})
	var capped: Variant = DotGameAvatarLoadouts.parse({"EMOTE": many})
	_check(capped is Array and (capped as Array).size() == DotGameAvatarLoadouts.MAX_PER_KIND + 9, "at most eight per kind", str((capped as Array).size() if capped is Array else capped))
	_check(DotGameAvatarLoadouts.parse("junk") == null and DotGameAvatarLoadouts.parse(null) == null, "anything but an object is no loadout")
	var big := DotGameAvatarLoadoutMessage.new()
	big.actor = 3
	for i in DotGameAvatarLoadoutMessage.MAX_ENTRIES + 1:
		big.entries.append({"id": "wave", "kind": 2, "loop": false, "clip": ""})
	_check(not big.validate().ok, "a loadout message over the cap is refused")

	var loaded: DotResult = await _load_module()
	if not _check(loaded.ok, "the module loads", str(loaded.error)):
		_done()
		return
	var module := loaded.value as DotGameModule
	var relay := module.net.get_meta(DotGameAvatarActionRelay.NET_META, null) as DotGameAvatarActionRelay
	var lo: DotGameAvatarLoadouts = relay.loadouts if relay != null else null
	if not _check(lo != null and module.roster.followers.has(lo) and lo.server == module.server, "the relay's loadouts follow the roster"):
		_unload_module()
		_done()
		return
	var clock := [100000]
	relay.now_fn = func() -> int: return clock[0]
	lo.now_fn = func() -> int: return clock[0]
	var sent := []
	module.net.send_fn = func(peer: int, payload: PackedByteArray, _d: int) -> void: sent.append([peer, payload])
	var asked := []
	lo.key_fn = func(peer: int) -> String: return "key-of-peer-%d" % peer if peer != 6 else ""
	lo.fetch_fn = func(key: String) -> DotResult:
		asked.append(key)
		await get_tree().process_frame
		return DotResult.success({"EMOTE": [upload], "GESTURE": [{"builtin": "wave"}]})
	var ask := func(peer: int, id: String) -> int:
		var before := sent.size()
		var m := DotGameAvatarActionMessage.new()
		m.sender_peer_id = peer
		m.id = id
		m.loop = true
		module.net.messages.dispatch(m)
		clock[0] += 1000
		return sent.size() - before

	lo.add_peer(6)
	lo.add_peer(5)
	for i in 4:
		await get_tree().process_frame
	_check(asked == ["key-of-peer-5"], "only a peer with a key is read from the backbone", str(asked))
	var told := _loadout_sent(module, sent)
	_check(told.size() == 2 and told[0][1].actor == 5 and told[0][1].ids().has("action/9/1"), "the read loadout is told to every player in", str(told.size()))
	sent.clear()
	_check(ask.call(5, "action/9/1") == 1, "an equipped upload passes")
	var start := module.net.messages.decode(DotNetReader.new(sent[0][1]), 1, false) if not sent.is_empty() else null
	_check(start != null and start.ok and start.value.loop == false, "with the loop the loadout says, not the client's")
	_check(ask.call(5, "dance") == 0, "a starter emote they replaced is refused")
	_check(ask.call(5, "action/8/1") == 0, "an upload they have not equipped is refused")
	_check(ask.call(6, "dance") == 1 and ask.call(6, "action/9/1") == 0, "a player with no key plays the starter set, and nothing else")

	sent.clear()
	lo.add_peer(8)
	for i in 4:
		await get_tree().process_frame
	told = _loadout_sent(module, sent)
	var late := told.filter(func(t: Array) -> bool: return t[0] == 8 and t[1].actor == 5)
	_check(late.size() == 1, "a late joiner is told the loadouts already read", str(told.size()))

	# A client that wired its handler after that message asks, and is told again.
	var ask_from := func(peer: int) -> int:
		var before := sent.size()
		var q := DotGameAvatarLoadoutAsk.new()
		q.sender_peer_id = peer
		module.net.messages.dispatch(q)
		return _loadout_sent(module, sent.slice(before)).filter(func(t: Array) -> bool: return t[0] == peer and t[1].actor == 5).size()
	sent.clear()
	_check(ask_from.call(8) == 1, "a client's ask is answered with the loadouts already read")
	_check(ask_from.call(8) == 0, "a second ask inside the interval is not")
	clock[0] += 2500
	_check(ask_from.call(8) == 1 and ask_from.call(77) == 0, "again after it, and never to a peer not in the game")

	_check(not lo.refresh(5), "a second read inside the interval is refused")
	clock[0] += 31000
	_check(lo.refresh(5), "and allowed after it")
	for i in 4:
		await get_tree().process_frame

	# A re-equip on the site reaches the game by itself, and only a change is told.
	var current := {"EMOTE": [{"builtin": "dance"}]}
	lo.fetch_fn = func(_key: String) -> DotResult:
		await get_tree().process_frame
		return DotResult.success(current)
	lo.auto_refresh_sec = 60.0
	clock[0] += 31000
	sent.clear()
	lo._process(30.0)
	for i in 4:
		await get_tree().process_frame
	_check(lo.reads > 0 and sent.is_empty() and lo.ids_for(5).has("action/9/1"), "the periodic read waits for its interval", str(lo.ids_for(5)))
	lo._process(31.0)
	for i in 4:
		await get_tree().process_frame
	_check(lo.ids_for(5).has("dance") and not lo.ids_for(5).has("action/9/1") and not _loadout_sent(module, sent).is_empty(), "a player who re-equips is read again and told", str(lo.ids_for(5)))
	clock[0] += 31000
	sent.clear()
	lo._process(61.0)
	for i in 4:
		await get_tree().process_frame
	_check(_loadout_sent(module, sent).is_empty(), "a re-read that changed nothing tells nobody")
	lo.auto_refresh_sec = 0.0

	sent.clear()
	lo.remove_peer(5)
	told = _loadout_sent(module, sent)
	_check(lo.ids_for(5) == null and told.size() == 2 and told[0][1].actor == 5 and told[0][1].entries.is_empty(), "a leaver is forgotten, and everybody told")

	lo.add_peer(9)
	lo.remove_peer(9)
	lo.add_peer(9)
	lo.fetch_fn = func(_key: String) -> DotResult:
		await get_tree().process_frame
		return DotResult.success({"EMOTE": [upload]})
	for i in 6:
		await get_tree().process_frame
	_check(lo.ids_for(9) != null, "a peer id that rejoins is read again")
	lo.add_peer(10)
	lo.remove_peer(10)
	for i in 6:
		await get_tree().process_frame
	_check(lo.ids_for(10) == null, "a read that lands after its player left is dropped")

	var forged := DotGameAvatarLoadoutMessage.new()
	forged.actor = 6
	forged.entries = [{"id": "action/77/1", "kind": 0, "loop": false, "clip": "c"}]
	var w := DotNetWriter.new()
	var _enc := module.net.messages.encode(forged, w)
	var from_client := module.net.messages.decode(DotNetReader.new(w.to_bytes()), 6, true)
	_check(not from_client.ok and lo.ids_for(6) == null, "a client cannot send a loadout")
	_check(lo.describe().has("reads"), "describe() reports it")
	_unload_module()
	_done()


func _test_avatar_loadout_client() -> void:
	_section("avatar loadouts on a client: an uploaded clip is fetched once and handed to the figure")
	var server_net := DotNetManager.new()
	server_net.is_server = true
	server_net.config_file = ""
	var _sp := server_net.setup()
	var _r := DotGameAvatarActionMessage.register(server_net)
	server_net.messages.seal()
	var net := DotNetManager.new()
	net.local_peer_id = 4
	net.config_file = ""
	var _cp := net.setup()
	var reg := DotGameAvatarActionMessage.register(net)
	net.messages.seal()
	_check(reg.ok and net.messages.type_names().has(String(DotGameAvatarLoadoutMessage.NAME)), "registering the action message registers the loadout too")
	add_child(net)
	var input := FakeActionInput.new()
	add_child(input)
	var figures := {7: FakeActionFigure.new()}
	var client := DotGameAvatarActionClient.new()
	add_child(client)
	var asks := []
	net.send_fn = func(_peer: int, payload: PackedByteArray, _d: int) -> void:
		var r := server_net.messages.decode(DotNetReader.new(payload), 4, true)
		if r.ok and r.value is DotGameAvatarLoadoutAsk:
			asks.append(true)
	var fetched := []
	client.content_fn = func(entry: Dictionary) -> DotResult:
		fetched.append(entry["id"])
		await get_tree().process_frame
		return DotResult.success(Node3D.new())
	client.attach(net, input, func(peer: int) -> Object: return figures.get(peer))
	var deliver := func(m: DotNetMessage) -> void:
		var w := DotNetWriter.new()
		var _e := server_net.messages.encode(m, w)
		var read := net.messages.decode(DotNetReader.new(w.to_bytes()), 1, false)
		if read.ok:
			net.messages.dispatch(read.value)
	var lm := DotGameAvatarLoadoutMessage.new()
	lm.actor = 7
	lm.entries = [{"id": "action/9/1", "kind": 0, "loop": true, "clip": "Hop"}, {"id": "wave", "kind": 2, "loop": false, "clip": ""}]
	_check(asks.size() == 1, "attaching asks the server for the loadouts it may have missed", str(asks.size()))
	client._process(1.1)
	_check(asks.size() == 2, "and asks again while none has come")
	deliver.call(lm)
	deliver.call(lm)
	client._process(10.0)
	_check(asks.size() == 2, "and stops once one arrives")
	for i in 3:
		await get_tree().process_frame
	_check(fetched == ["action/9/1"], "the upload is fetched once, the built-in not at all", str(fetched))
	var start := DotGameAvatarActionMessage.new()
	start.actor = 7
	start.id = "action/9/1"
	start.loop = true
	start.start_tick = 0
	deliver.call(start)
	var fig: FakeActionFigure = figures[7]
	_check(fig.added.size() == 1 and fig.added[0][2] == "Hop" and fig.played.size() == 1 and fig.played[0][0] == "action/9/1", "another player's upload plays on their figure", str(fig.added))
	lm.entries = []
	deliver.call(lm)
	_check(not client.loadouts.has(7), "an empty loadout forgets them")
	var seen_rows := []
	client.actions_fn = func(rows: Dictionary) -> DotResult:
		seen_rows.append(rows)
		return DotResult.success("actions")
	var own := DotGameAvatarLoadoutMessage.new()
	own.actor = 4
	own.entries = [{"id": "action/9/1", "kind": 0, "loop": true, "clip": "Hop"}, {"id": "wave", "kind": 2, "loop": false, "clip": ""}]
	deliver.call(own)
	_check(seen_rows.size() == 1 and seen_rows[0]["EMOTE"][0]["contentId"] == "action/9/1" and seen_rows[0]["GESTURE"][0]["builtin"] == "wave", "the local player's keys are rebuilt from their own relayed loadout", str(seen_rows))
	_check(seen_rows[0]["EMOTE"][0]["fileUrl"] == "/", "with no library read yet the row keeps the valid placeholder")
	client.url_fn = func(id: String) -> String:
		return "https://cdn.test/hop.glb" if id == "action/9/1" else ""
	var _ap := client.apply_to_input(own.entries)
	_check(seen_rows.size() == 2 and seen_rows[1]["EMOTE"][0]["fileUrl"] == "https://cdn.test/hop.glb", "once the library names it, the keys get the real file url", str(seen_rows[-1]))
	lm.actor = 7
	lm.entries = [{"id": "wave", "kind": 2, "loop": false, "clip": ""}]
	deliver.call(lm)
	_check(seen_rows.size() == 2, "another player's loadout leaves the local keys alone")
	var wm := DotGameAvatarLoadoutMessage.new()
	wm.actor = 9
	wm.wearables = PackedStringArray(["wearable/3/1", "wearable/4/2"])
	var ww := DotNetWriter.new()
	var _we := server_net.messages.encode(wm, ww)
	var wr := net.messages.decode(DotNetReader.new(ww.to_bytes()), 1, false)
	_check(wr.ok and wr.value is DotGameAvatarLoadoutMessage and wr.value.wearables == wm.wearables, "the wearable ids ride the loadout message", str(wr.error.message if not wr.ok else ""))
	wm.wearables = PackedStringArray(["a", "b", "c", "d", "e", "f", "g", "h"])
	_check(not wm.validate().ok, "a loadout message with too many wearables is refused")
	var parsed := DotGameAvatarLoadouts.parse_wearables({"WEARABLES": [
		{"contentId": "wearable/3/1", "slot": "head"}, {"contentId": "wearable/4/2", "slot": "head"},
		{"contentId": "wearable/../1", "slot": "back"}, {"contentId": "wearable/5/1", "slot": "back"}, 7]})
	_check(parsed == PackedStringArray(["wearable/3/1", "wearable/5/1"]), "the read's wearables: well-formed ids, one per slot", str(parsed))
	_check(DotGameAvatarLoadouts.parse_wearables("junk").is_empty() and DotGameAvatarLoadouts.parse_wearables({}).is_empty(), "no wearables in the read is none")
	var skel_fig := FakeSkeletonFigure.new()
	figures[9] = skel_fig
	var looked := []
	client.wearable_row_fn = func(id: String) -> Dictionary:
		looked.append(id)
		return {}
	var wl := DotGameAvatarLoadoutMessage.new()
	wl.actor = 9
	wl.wearables = PackedStringArray(["wearable/3/1"])
	deliver.call(wl)
	_check(not client.wear(9) and looked.has("wearable/3/1") and client.worn[9] == wl.wearables, "wearables wait for the library row, and are asked for once", str(looked))
	wl.wearables = PackedStringArray()
	deliver.call(wl)
	_check(not client.worn.has(9) and client.wear(9), "a loadout with no wearables takes them off")
	skel_fig.bones.free()
	client.queue_free()
	input.queue_free()
	net.queue_free()
	server_net.free()
	_done()


func _test_server_threads_reach_the_netcode() -> void:
	_section("sv_threads_net reaches DotNetConfig.snapshot_workers, and the game's own value wins")

	var sc := DotServerConfig.new()
	var c := DotNetConfig.new()
	_check(not DotGameNetcode.follow_server_threads(c, null), "no server config changes nothing")
	_check(DotGameNetcode.follow_server_threads(c, sc) and c.snapshot_workers == 0,
		"the default stays 0 with the switch off")
	sc.threads_net = true
	sc.worker_threads = 3
	_check(DotGameNetcode.follow_server_threads(c, sc) and c.snapshot_workers == 3,
		"switched on, the server's worker count is copied")
	sc.worker_threads = -1
	DotGameNetcode.follow_server_threads(c, sc)
	_check(c.snapshot_workers == -1, "a later cvar change is followed")
	sc.threads_net = false
	DotGameNetcode.follow_server_threads(c, sc)
	_check(c.snapshot_workers == 0, "switched off again, back to 0")

	var own := DotNetConfig.new()
	own.snapshot_workers = 2
	sc.threads_net = true
	sc.worker_threads = 5
	_check(not DotGameNetcode.follow_server_threads(own, sc) and own.snapshot_workers == 2,
		"a value the game set is kept")

	# Through the module: the config the game returns, as the server's switch has it.
	_server.config.threads_net = true
	_server.config.worker_threads = 2
	var loaded: DotResult = await _load_module()
	if _check(loaded.ok, "the module loads", str(loaded.error)):
		var module := loaded.value as DotGameModule
		_check(module.net != null and module.net.config.snapshot_workers == 2,
			"the module wired it into the live netcode")
		_unload_module()
	_server.config.threads_net = false
	_server.config.worker_threads = -1
	_done()


func _test_operator_ceiling_reaches_the_netcode() -> void:
	_section("the module applies the server's ceiling before the netcode starts")

	_server.set_meta(DotGameNetcode.CEILING_META, {"snapshot_rate": 12, "max_entities_per_snapshot": 8})
	var loaded: DotResult = await _load_module()
	_server.remove_meta(DotGameNetcode.CEILING_META)

	if not _check(loaded.ok, "the module loads", str(loaded.error)):
		_done()
		return

	var module := loaded.value as DotGameModule
	_check(module.net != null and module.net.config.snapshot_rate == 12, "the snapshot rate is the operator's (12 divides tick 60)")
	_check(module.net != null and module.net.config.max_entities_per_snapshot == 8, "and the entity cap")
	_unload_module()
	_done()


func _test_prejoin() -> void:
	_section("prejoin: avatar files come down before the shell connects, and never block it")
	var host := Node.new()
	add_child(host)
	var progress := []
	var pj := DotGamePrejoin.new()
	pj.progress_fn = func(f: float, t: String) -> void: progress.append([f, t])
	pj.rules_fn = func(_a: String) -> Dictionary: return {}
	var none: DotResult = await pj.prepare(host, "127.0.0.1:1")
	_check(none.ok and none.value == 0, "a server advertising nothing needs nothing")

	var calls := []
	pj.rules_fn = func(_a: String) -> Dictionary: return {"sv_avatar_content": "avatar/5/1"}
	pj.fetch_fn = func(ids: Array, gate: DotLoadGate) -> DotResult:
		calls.append(ids)
		gate.hold(&"avatar_content", "Downloading avatars")
		gate.set_progress(0.5, "Downloading avatar/5/1 (1 of 1)")
		await get_tree().process_frame
		gate.release(&"avatar_content")
		return DotResult.success(1)
	var got: DotResult = await pj.prepare(host, "127.0.0.1:1")
	_check(got.ok and got.value == 1 and calls == [["avatar/5/1"]], "the advertised ids are fetched before the join")
	_check(not progress.is_empty() and progress.back()[0] == 0.5, "progress reaches the loading screen's callback")

	pj.fetch_fn = func(_ids: Array, _gate: DotLoadGate) -> DotResult:
		return DotResult.fail(DotError.CODE_NETWORK, "cdn down")
	var failed: DotResult = await pj.prepare(host, "127.0.0.1:1")
	_check(not failed.ok and failed.error.code == DotError.CODE_NETWORK, "a failed download is reported so the caller can log it and join anyway")

	pj.timeout_sec = 0.3
	pj.fetch_fn = func(_ids: Array, _gate: DotLoadGate) -> DotResult:
		await get_tree().create_timer(5.0).timeout
		return DotResult.success(1)
	var t0 := Time.get_ticks_msec()
	var slow: DotResult = await pj.prepare(host, "127.0.0.1:1")
	_check(not slow.ok and slow.error.code == DotError.CODE_TIMEOUT and Time.get_ticks_msec() - t0 < 2000, "a hung CDN times out and does not hold the join")
	host.queue_free()
	_done()


class FakeAuthServer extends RefCounted:
	var audience := ""
	func join_audience() -> String:
		return audience


class FakeAuthConfig extends RefCounted:
	var backbone_url := "https://site.test/"


class FakeAuthClient extends RefCounted:
	var config := FakeAuthConfig.new()


class FakeLink extends RefCounted:
	var replicated_cvars := {}


func _test_site_server() -> void:
	_section("the server's site id: advertised as a replicated rule, read by prejoin and the client")
	_check(DotGameAvatarContent.server_id_from_audience("server:42") == 42 and DotGameAvatarContent.server_id_from_audience("app:42") == 0
		and DotGameAvatarContent.server_id_from_audience("server:x") == 0, "only a server: audience is a site server id")
	_check(DotGameAvatarContent.server_id_from_rules({"sv_site_server": "17"}) == 17 and DotGameAvatarContent.server_id_from_rules({"sv_site_server": "-3"}) == 0
		and DotGameAvatarContent.server_id_from_rules({}) == 0, "the rule parses, and nonsense is no id")
	var auth := FakeAuthServer.new()
	DotRegistry.register(&"dot_auth_server", auth)
	TestModule.site_server = -1
	var loaded: DotResult = await _load_module()
	if _check(loaded.ok, "the module loads", str(loaded.error)):
		var module := loaded.value as DotGameModule
		var cv := module.console.find_cvar(DotGameAvatarContent.SERVER_CVAR)
		_check(cv != null and cv.get_string() == "0" and cv.has_flag(DotConVar.FLAG_NOTIFY) and cv.has_flag(DotConVar.FLAG_REPLICATED),
			"advertised as a notify, replicated cvar, 0 while dot-auth has not read it")
		var timer := module.get_node_or_null("SiteServerRetry") as Timer
		auth.audience = "server:42"
		if _check(timer != null, "and looked for again"):
			timer.timeout.emit()
		_check(cv != null and cv.get_string() == "42", "it takes the audience dot-auth read", cv.get_string() if cv != null else "")
		_unload_module()
	DotRegistry.unregister_instance(&"dot_auth_server", auth)

	var pj := DotGamePrejoin.new()
	pj.rules_fn = func(_a: String) -> Dictionary: return {"sv_avatar_content": "avatar/5/1", "sv_site_server": "42"}
	pj.fetch_fn = func(_ids: Array, _g: Object) -> DotResult: return DotResult.success(1)
	var _p: DotResult = await pj.prepare(self, "127.0.0.1:1")
	_check(pj.server_id == 42, "prejoin reads the server id from the rules", str(pj.server_id))

	var ac := FakeAuthClient.new()
	DotRegistry.register(&"dot_auth_client", ac)
	_check(DotGameAvatarContent.default_site_url() == "https://site.test", "the site defaults to the one the client signs in against")
	var platform := DotGameClient.new()
	var link := FakeLink.new()
	link.replicated_cvars = {"sv_site_server": "42"}
	platform.link = link
	_check(platform.avatar_site() == "https://site.test" and platform.avatar_server() == 42, "the client finds both by itself")
	platform.avatar_site_url = "https://other.test"
	platform.avatar_server_id = 9
	_check(platform.avatar_site() == "https://other.test" and platform.avatar_server() == 9, "and a game's own values win")
	platform.free()
	DotRegistry.unregister_instance(&"dot_auth_client", ac)
	_done()


func _test_avatar_content() -> void:
	_section("avatar content: advertised as a rule, refused cleanly when it cannot be fetched")
	_check(DotGameAvatarContent.parse(" avatar/5/1, action/7/2 ,,") == ["avatar/5/1", "action/7/2"], "the advertisement parses")
	_check(DotGameAvatarContent.ids_from_rules({}) == [], "no rule is no ids")
	_check(DotGameAvatarContent.ids_from_rules({"sv_avatar_content": "avatar/5/1"}) == ["avatar/5/1"], "ids come from a query rule")
	var plain: DotResult = await _load_module()
	var plain_module := _server.modules.get_module("testgame") if plain.ok else null
	_check(plain_module != null and plain_module.console.find_cvar(DotGameAvatarContent.CVAR) == null, "a game requiring nothing publishes no cvar")
	_unload_module()
	TestModule.avatar_content = ["avatar/5/1", "action/7/1"]
	var loaded: DotResult = await _load_module()
	TestModule.avatar_content = []
	var module := _server.modules.get_module("testgame") if loaded.ok else null
	var cv: DotConVar = module.console.find_cvar(DotGameAvatarContent.CVAR) if module != null else null
	_check(cv != null and cv.get_string() == "avatar/5/1,action/7/1" and cv.has_flag(DotConVar.FLAG_NOTIFY), "the module advertises it as a notify cvar")
	_unload_module()
	var host := Node.new()
	add_child(host)
	var empty: DotResult = await DotGameAvatarContent.prepare(host, [], "https://site.test", 3, null, null)
	_check(empty.ok, "nothing required is ready at once")
	if not DotGameAvatarContent.available():
		var missing: DotResult = await DotGameAvatarContent.prepare(host, ["avatar/5/1"], "https://site.test", 3, null, null)
		_check(not missing.ok and missing.error.code == DotError.CODE_UNSUPPORTED, "required files without dot-user-avatar refuse the connect")
	else:
		_check(true, "dot-user-avatar is present (its own suite covers the fetch)")
	host.free()
	_check(DotGameAvatarContent.format(["a/1/1", "b/2/1"]) == "a/1/1,b/2/1", "ids format back")
	_done()


func _load_module() -> DotResult:
	return await _server.modules.load_module(MODULE_PATH)


func _unload_module() -> void:
	if _server != null and _server.modules != null:
		if _server.modules.has_module("testgame"):
			_server.modules.unload_module("testgame")


## A session the server did not make, because this suite connects no clients.
##
## The roster only reads `userid`, `peer_id` and `display_name`, and building one here
## keeps every roster check deterministic -- a real connection would make the section
## about the transport instead.
## [DotGameServices] in a project that has none of the three addons it drives.
##
## [b]This is the path most deployments are NOT on, and it is the only one this addon can
## test.[/b] dot-chat, dot-voice and dot-moderation are deliberately not dependencies here
## — a game with no chat is a legitimate game, and naming an absent class fails to parse —
## so the base loads each layer by path and skips what is missing. What has to be true is
## that skipping is *quiet and complete*: setup succeeds, admission passes, the peer
## fan-out is a no-op rather than a crash, and asking it to carry a line is refused in a
## way a caller can act on.
##
## The other half — chat actually routing, a gag actually silencing somebody — is asserted
## in a game that has the addons: `game-buses-from-hell/examples/headless_net.tscn`.
func _test_services_without_the_addons() -> void:
	_section("the services layer, in a build with none of its addons")

	var services := DotGameServices.new()
	services.name = "Services"
	add_child(services)

	var ready_now: DotResult = await services.setup(_server, _game, null)

	_check(ready_now.ok, "it sets up", str(ready_now.error) if not ready_now.ok else "")
	_check(services.chat == null, "and builds no chat, because there is none to build")
	_check(services.voice == null, "no voice")
	_check(services.moderation == null, "and no moderation")

	_check(
		services.check_admission(_fake_session(9, 9, "Ada")).ok,
		"admission passes when there is no moderation to ask"
	)

	# The fan-out a module calls on every join and leave. With no layers at all these are
	# the calls that would crash a server that installed nothing.
	services.add_peer(9)
	services.remove_peer(9)
	services.relay_voice(9, PackedByteArray([1, 2, 3]))
	_check(true, "the peer fan-out and a voice frame are no-ops rather than crashes")

	var said := services.say(9, &"all", "hello")
	_check(
		not said.ok and said.error.code == DotError.CODE_UNSUPPORTED,
		"and a line is refused as unsupported rather than silently dropped",
		str(said.error.code)
	)

	var lines := services.describe_lines()
	var mentions_relay := false

	for line in lines:
		if line.findn("relay") >= 0:
			mentions_relay = true

	_check(mentions_relay, "describe_lines says whether the website relay is on")

	services.queue_free()
	_done()


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


## The hooks the first hand-written game converted needed, each of which it had worked
## round in a subclass.
func _test_services_hooks() -> void:
	_section("the services layer's hooks: no server, the backlog, the ear")

	# No server: offline play. This was refused, and it was the only line that needed one.
	var offline := TestHookServices.new()
	offline.name = "OfflineServices"
	add_child(offline)
	var ready_offline: DotResult = await offline.setup(null, _game, null)
	_check(
		ready_offline.ok, "it sets up with no server, for a game played offline",
		str(ready_offline.error) if not ready_offline.ok else ""
	)
	_check(
		offline.check_admission(_fake_session(9, 9, "Ada")).ok and offline.say(9, &"all", "hi").error != null,
		"and every seam past it answers \"no server\" rather than crashing"
	)
	offline.queue_free()

	# The backlog: at seating by default, and held for a game whose clients cannot receive
	# yet, which then sends it itself.
	var services := TestHookServices.new()
	services.name = "HookServices"
	add_child(services)
	var _r: DotResult = await services.setup(_server, _game, null)
	var link := TestHookServices.FakeLink.new()
	var chat := TestHookServices.FakeChat.new()
	add_child(link)
	add_child(chat)
	services.link = link
	services.chat = chat

	services.add_peer(9)
	_check(link.sent.size() == 2, "by default a seated peer is handed the backlog at once (%d lines)" % link.sent.size())

	link.sent.clear()
	services.receive = false
	services.add_peer(10)
	_check(link.sent.is_empty(), "a game whose peer cannot receive yet holds it (%d lines)" % link.sent.size())
	if services.has_method("send_backlog"):
		services.call("send_backlog", 10)
	_check(
		link.sent.size() == 2 and int(link.sent[0][0]) == 10,
		"and sends it itself when the peer is ready, to that peer"
	)

	# The ear. Wired into both routers when they exist; here, the default's answer.
	_check(
		services.has_method("_can_hear") and bool(services.call("_can_hear", 1, 2, Vector3.ZERO, Vector3(999, 0, 0))),
		"and _can_hear defaults to the radius being the whole answer"
	)

	services.chat = null
	services.link = null
	chat.queue_free()
	link.queue_free()
	services.queue_free()
	_done()


func _fake_session(peer_id: int, userid: int, who: String) -> DotClientSession:
	var session := DotClientSession.new()
	session.peer_id = peer_id
	session.userid = userid
	session.display_name = who
	return session


class _FakeGames extends RefCounted:
	var maps := PackedStringArray()
	var server_deps := PackedStringArray()
	func current_maps() -> PackedStringArray: return maps
	func current_server_dependencies() -> PackedStringArray: return server_deps


class _FakeServer extends RefCounted:
	var games: Object = null


class _FakeManager extends RefCounted:
	var games: Array = []


## What dot-cloud's auto-update is told to watch, and that a build without dot-cloud gets none.
func _test_auto_update_wiring() -> void:
	_section("server auto-update wiring")
	var delivered := DotGameDescriptor.new()
	delivered.game_id = "arena"
	delivered.content_id = "me/arena"
	delivered.version = "0.1.0"
	delivered.scene = "scenes/main.tscn"
	delivered.dependencies = PackedStringArray(["me/lib@1.0.0"])
	delivered.maps = PackedStringArray(["me/dm_one@2"])
	var built_in := DotGameDescriptor.new()
	built_in.game_id = "local"
	built_in.scene = "res://examples/fixtures/none.tscn"
	var manager := _FakeManager.new()
	manager.games = [delivered, built_in]
	var fake := _FakeServer.new()
	fake.games = manager
	var watched := DotGameModule.watched_packs(fake)
	_check(watched == [
		{"id": "me/arena", "version": "0.1.0"},
		{"id": "me/lib", "version": "1.0.0"},
		{"id": "me/dm_one", "version": "2"},
	], "a delivered game's own pack, dependencies and maps; a built-in game adds nothing", str(watched))
	_check(DotGameModule.watched_packs(null).is_empty(), "no server watches nothing")
	_check(DotGameModule.start_auto_update(_server) == null, "a build without dot-cloud starts no updater")
	_done()


## DotGameContent, against a stand-in manager: the keys a server names, where each mounts,
## and the directories a game is handed. No content client here, so a pack that is not on
## the disk is a warning and is left out, which is the path a build without dot-cloud takes.
func _test_map_content() -> void:
	_section("the map packs a server names (DotGameContent)")

	var games := _FakeGames.new()
	games.maps = PackedStringArray(["me/course_a@1.0.0", "me/shared@2"])
	games.server_deps = PackedStringArray(["me/shared@2", "me/old_maps@0.1.0"])
	var fake := _FakeServer.new()
	fake.games = games

	_check(DotGameContent.map_keys(fake) == PackedStringArray(["me/course_a@1.0.0", "me/shared@2", "me/old_maps@0.1.0"]),
		"the maps first, then the server-only packs, each once", str(DotGameContent.map_keys(fake)))
	_check(DotGameContent.map_keys(fake, false) == games.maps, "and without the server-only packs when asked")
	_check(DotGameContent.map_keys(null).is_empty() and DotGameContent.map_keys(_FakeServer.new()).is_empty(),
		"no server, or one without a manager, names nothing")
	_check(DotGameContent.mount_of("me/course_a@1.0.0") == "res://dot_cloud/me/course_a/1.0.0",
		"a key mounts where dot-cloud mounts it")

	# One pack "already mounted" on the disk; the others are not and there is no client.
	var root := "res://dot_cloud/me/course_a/1.0.0/courses"
	DirAccess.make_dir_recursive_absolute(root)
	var dirs: PackedStringArray = await DotGameContent.map_dirs(fake, "courses")
	_check(dirs == PackedStringArray([root]), "a mounted pack's subdirectory is handed over, the rest left out", str(dirs))
	var missing: DotResult = await DotGameContent.ensure_one("me/shared@2")
	_check(not missing.ok and missing.error.code == DotError.CODE_STATE,
		"and with no content client a fetch fails with the reason, not a crash")
	for d in ["res://dot_cloud/me/course_a/1.0.0/courses", "res://dot_cloud/me/course_a/1.0.0",
			"res://dot_cloud/me/course_a", "res://dot_cloud/me", "res://dot_cloud"]:
		DirAccess.remove_absolute(d)
	_done()


const ClientSettings := preload("fixtures/test_client_settings.gd")
const ClientChat := preload("fixtures/test_chat_box.gd")
const CONSOLE_KIT_FIXTURE := "res://examples/fixtures/test_console_kit.gd"


func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame


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


## A client whose pointer is a flag, because a headless display server keeps no captured mode.
class FakePointerClient extends DotGameClient:
	var captured: bool = false
	func _pointer_captured() -> bool:
		return captured
	func _free_pointer() -> void:
		captured = false


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


class GuardLink extends RefCounted:
	var up: bool = false
	func is_connected_to_server() -> bool:
		return up


## The player's cfg tier: on solo and for a listen host, off for a dedicated server, a guest, or an opt-out.
func _test_client_user_tier() -> void:
	_section("the user cfg tier: solo and listen host only")
	var host := Node.new()
	add_child(host)
	var solo := DotGameClient.new()
	solo.use_gate = false
	solo.force_offline = true
	host.add_child(solo)
	_check(solo.user_tier_on and DotAddonConfig.user_tier_enabled, "solo turns the tier on")
	_check(solo.describe()["user_tier"], "describe reports it")

	var guest := DotGameClient.new()
	guest.use_gate = false
	guest.link = GuardLink.new()
	host.add_child(guest)
	_check(not guest.offline and not guest.user_tier_on and not DotAddonConfig.user_tier_enabled,
		"joined to someone else's server turns it off")

	var listen := DotGameClient.new()
	listen.use_gate = false
	listen.link = GuardLink.new()
	listen.listen_host_fn = func() -> bool: return true
	host.add_child(listen)
	_check(listen.user_tier_on and DotAddonConfig.user_tier_enabled, "a listen host turns it on")

	var out := DotGameClient.new()
	out.use_gate = false
	out.force_offline = true
	out.user_cfg = false
	host.add_child(out)
	_check(not out.user_tier_on and not DotAddonConfig.user_tier_enabled, "user_cfg = false opts out")

	_check(not DotGameClient.user_tier_allowed(true, true, true, true), "a dedicated server never has it")
	_check(DotGameClient.user_tier_allowed(true, false, true, false)
			and not DotGameClient.user_tier_allowed(true, false, false, false)
			and not DotGameClient.user_tier_allowed(false, true, false, false), "the rule table")
	_check(not out.open_user_cfg(), "and refuses without the tier")
	var solo2 := DotGameClient.new()
	solo2.use_gate = false
	solo2.force_offline = true
	host.add_child(solo2)
	_check(DotAddonConfig.user_tier_enabled, "a second solo client has the tier on")
	host.remove_child(solo2)
	_check(not DotAddonConfig.user_tier_enabled and not DotProfileSet.user_tier_enabled, "leaving the tree clears the process-wide tier")
	solo2.free()
	DotAddonConfig.set_user_tier(false)
	host.queue_free()
	_done()


## The browser guard: the leave-site prompt follows the live game, the keyboard lock listener is
## installed once, and a desktop or headless client does nothing at all.
func _test_client_page_guard() -> void:
	_section("the page guard: leave-site prompt follows the live game, installed once, silent off the web")

	var host := Node.new()
	add_child(host)
	var plain := DotGameClient.new()
	plain.use_gate = false
	plain.link = GuardLink.new()
	host.add_child(plain)
	plain._process(0.0)
	_check(not plain.describe()["leave_guard_installed"] and not plain.describe()["leave_guard"],
		"off the web nothing is installed or armed")

	var sent: Array = []
	var link := GuardLink.new()
	var client := DotGameClient.new()
	client.use_gate = false
	client.link = link
	client.web_eval_fn = func(code: String) -> void: sent.append(code)
	host.add_child(client)
	_check(sent.size() == 1 and "fullscreenchange" in sent[0] and "beforeunload" in sent[0]
			and "if (!window.__dotTabGuard)" in sent[0],
		"the listeners are installed once, behind a page flag")
	client._process(0.0)
	_check(sent.size() == 1 and not client.describe()["leave_guard"], "a disconnected link does not arm it")
	link.up = true
	client._process(0.0)
	_check(sent.size() == 2 and "armed = true" in sent[1] and client.describe()["leave_guard"],
		"a connected link arms the prompt")
	client._process(0.0)
	_check(sent.size() == 2, "and a steady state sends nothing")
	client.clear_leave_guard()
	_check(sent.size() == 3 and "armed = false" in sent[2] and not client.describe()["leave_guard"],
		"a deliberate navigation can clear it")
	client._process(0.0)
	link.up = false
	client._process(0.0)
	client._process(0.0)
	_check(not client.describe()["leave_guard"] and sent.size() == 5, "a dropped link disarms it")
	link.up = true
	client._process(0.0)
	client.queue_free()
	await get_tree().process_frame
	_check("armed = false" in sent[sent.size() - 1], "leaving the tree disarms it")

	var offline := DotGameClient.new()
	offline.use_gate = false
	offline.link = GuardLink.new()
	offline.link.up = true
	offline.force_offline = true
	var off_sent: Array = []
	offline.web_eval_fn = func(code: String) -> void: off_sent.append(code)
	host.add_child(offline)
	offline._process(0.0)
	_check(off_sent.size() == 2 and "armed = true" in off_sent[1] and not offline.is_in_live_game(),
		"a solo game (offline) arms the prompt too")
	host.queue_free()
	await get_tree().process_frame
	_done()


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

# --- 9. DotGameLink --------------------------------------------------------

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
	await get_tree().process_frame
	await get_tree().process_frame
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
	await get_tree().process_frame
	await get_tree().process_frame
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
	await get_tree().process_frame
	await get_tree().process_frame
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


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(ok: bool, label: String, detail: String = "") -> bool:
	if ok:
		_passed += 1
		print("  ok    %s" % label)
	else:
		_failed += 1
		print("  FAIL  %s%s" % [label, "" if detail == "" else "  -- " + detail])
		_failures.append(label)
	return ok


func _teardown() -> void:
	_unload_module()
	if _server != null:
		_server.shutdown("test over")


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
	var client := DotGameClient.new()
	client.require_camera = false
	client.capture_pointer = false
	client.use_console = false
	client.use_settings = false
	client.look_mute_script = "res://examples/fixtures/test_look_mute.gd"
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

	var off := DotGameClient.new()
	off.use_look_mute = false
	off.require_camera = false
	off.use_settings = false
	off.use_console = false
	off.capture_pointer = false
	off.chat = load("res://examples/fixtures/test_voice_chat_box.gd").new()
	host.add_child(off)
	var _s := off.setup()
	_check(off.look_mute == null, "use_look_mute = false builds nothing")

	var bare := DotGameClient.new()
	bare.require_camera = false
	bare.use_settings = false
	bare.use_console = false
	bare.capture_pointer = false
	bare.look_mute_script = "res://examples/fixtures/test_look_mute.gd"
	bare.chat = ClientChat.new()
	host.add_child(bare)
	var _b := bare.setup()
	_check(bare.look_mute == null, "a chat with no voice builds nothing")

	var late := DotGameClient.new()
	late.require_camera = false
	late.use_settings = false
	late.use_console = false
	late.capture_pointer = false
	late.look_mute_script = "res://examples/fixtures/test_look_mute.gd"
	host.add_child(late)
	var _l := late.setup()
	late.look_voice = load("res://examples/fixtures/test_voice_state.gd").new()
	late.build_look_mute()
	_check(late.look_mute != null and late.look_mute.get(&"manager") == late.look_voice,
		"a client whose voice comes after setup() builds the keys with build_look_mute()")

	var rostered := DotGameClient.new()
	rostered.require_camera = false
	rostered.use_settings = false
	rostered.use_console = false
	rostered.capture_pointer = false
	rostered.look_mute_script = "res://examples/fixtures/test_look_mute.gd"
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

	InputMap.erase_action(&"test_other_k")
	InputMap.erase_action(&"test_other_g")
	host.queue_free()
	_done()


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
