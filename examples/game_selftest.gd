extends "selftest/selftest_client.gd"

## dot-game: the sequence, the roster, the tick, and every way it has to unwind.
##
## Sections 1-9: refusal without a game, the full sequence, the roster, tick order, reverse teardown, failure unwinding, the services hooks, still-loading seats, DotGameLink and DotGameClient. Deliberate errors: three "module refused to load" lines (sections 1 and 6) and an engine `Attempt to call RPC with unknown peer ID: 3` from section 3's admission refusal, since sessions are built by hand.

## Every check this suite runs, the section guard's own included.
## A runtime error aborts a section after it announced itself, so the section counter alone misses lost checks. See docs/testing.md.
const CHECKS := 598

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
			_test_stats_feed()
			_test_stats_report()
			await _test_stats_board()
			_test_stats_keys()
			await _test_the_tick()
			_test_hibernation()
			await _test_the_teardown()

		await _run_wiring()

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


func _run_wiring() -> void:
	await _test_noblock_wired()
	await _test_a_refused_game_load_unwinds()
	await _test_a_refused_attach_unwinds()
	_test_operator_net_ceiling()
	_test_snapshot_rate_adapts_to_slots()
	await _test_operator_ceiling_reaches_the_netcode()
	await _test_server_threads_reach_the_netcode()
	_test_npc_lod_cvars()
	_test_movement_cvars()
	await _test_services_without_the_addons()
	await _test_services_hooks()
	await _test_chat_client_without_the_addons()
	await _test_chat_client_server_lines()
	await _test_map_content()
	_test_auto_update_wiring()
	await _test_profiler_placement()
	await _test_client_platform()
	await _test_look_mute()
	_test_store_entitlements_absent()
	await _test_store_panel()
	await _test_loadout_store()
	await _test_client_hooks_menu()
	await _test_client_team_menu_default()
	await _test_client_reports_cover()
	await _test_client_page_guard()
	await _test_client_user_tier()
	await _test_client_without_the_addons()
	await _test_link_survives_reload()
	_test_workbench_hosting()
	_test_workbench_key()
	_test_combat_feel_inert()
	_test_combat_feel_gap_scale()
	_test_class_immunity()
	_test_workbench_thread_cvars()
	_test_thread_defaults_off()
	_test_map_load_threads()
	_test_client_vis_mode()
	await _test_client_latency()
	await _test_client_replay_tuning()
	_test_render_quality()
	_test_sun_shadow_cvars()
	_test_relevance_cvars()
	await _test_slide_sounds()
	await _test_landing()
	await _test_avatar_actions()
	await _test_avatar_loadouts()
	await _test_avatar_loadout_client()
	await _test_avatar_content()
	await _test_site_server()
	await _test_prejoin()


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
		# `quit()`; a terminal is still read, and a suite takes no commands from either.
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


# 1. No game

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


# 2. The sequence

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


# 3. The roster

func _test_the_roster() -> void:
	_section("the roster, driven by the events a real server fires")

	var session := _fake_session(1, 41, "Joiner")

	# The roster's session lookup, substituted: this suite connects no clients, so there
	# is no real session table to find one in. Substituting it is also what makes the
	# next check mean anything -- see below.
	_sessions[session.userid] = session
	_module.roster.session_fn = func(userid: int) -> DotClientSession:
		return _sessions.get(userid)

		# [b]The regression guard.[/b] `client_spawn` carries `userid` and `name` but NOT `peer_id`;
		# reading it found session 0, and nobody joined with nothing erroring.
	var event := DotEvent.new(
		"client_spawn",
		{"userid": session.userid, "name": session.display_name}
	)

	_module._on_client_spawn(event)

	_check(_module.roster.has(session.userid), "a spawn event puts a player in")

		# [b]The guard proper.[/b] An event carrying only `peer_id` must add nobody; with the
		# lookup substituted, a handler reading `peer_id` would find session 2 and seat them.
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


# 3b. Still loading

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


# 4. The tick

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


# 4b. Hibernation

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


# 5. Teardown

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
		# [b]Read off the reference taken before the unload.[/b] `module.roster` after the free
		# aborts the section while the counter still says it ran.
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


# 6. Unwinding

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
	var slide_cvar: DotConVar = module.console.find_cvar("sv_slide_sounds") if module != null else null
	_check(
		slide_cvar != null and slide_cvar.get_string() == "1" and slide_cvar.has_flag(DotConVar.FLAG_REPLICATED),
		"every game's module binds sv_slide_sounds, on and replicated"
	)
	var surf_specs: Array = load("res://addons/dot_game/runtime/dot_game_slide_sounds.gd").surf_cvar_specs()
	var surf_cvar: DotConVar = module.console.find_cvar("sv_surf_volume") if module != null else null
	_check(
		(surf_cvar != null and surf_cvar.has_flag(DotConVar.FLAG_REPLICATED)) == (not surf_specs.is_empty()),
		"the module binds the replicated sv_surf_* cvars exactly when dot-audio is in the build"
	)
	var stub_rt := RefCounted.new()
	_check(module != null and module._noblock_runtime() == null, "no workbench on the game: no runtime for the noblock kind")
	_unload_module()
	_check(module == null or module.noblock == null, "and is gone after the unload")

	TestModule.no_noblock = true
	var opted := await _load_module()
	var opted_module: DotGameModule = _server.modules.get_module("testgame") if opted.ok else null
	_check(opted.ok and opted_module != null and opted_module.noblock == null, "use_noblock = false opts out: nothing built")
	_check(not body.pair_fn.is_valid() or not wired, "and the body's pair_fn is left alone")
	_unload_module()
	TestModule.no_noblock = false
	_game.set("body_rules", null)
	stub_rt = null

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
