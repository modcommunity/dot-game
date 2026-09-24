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
const MODULE_PATH := "res://examples/fixtures/test_module.gd"

const PORT := 27919

## Every check this suite runs, the section guard's own included. The total the section
## counter cannot be: a runtime error inside a section aborts that function after the
## section has announced itself, so the counter is satisfied and the checks after the
## error simply never happen. See docs/testing.md.
const CHECKS := 60

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
			await _test_the_tick()
			await _test_the_teardown()

		await _test_a_refused_game_load_unwinds()
		await _test_a_refused_attach_unwinds()
		await _test_services_without_the_addons()

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

	_done()


# --- 5. Teardown -----------------------------------------------------------

func _test_the_teardown() -> void:
	_section("unloading takes it all down, in reverse")

	var bridge := _module.bridge
	var net := _module.net
	var services := _module.services
	var module := _module
	var roster := _module.roster

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

	_module = null
	_done()


# --- 6. Unwinding ----------------------------------------------------------

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


func _fake_session(peer_id: int, userid: int, who: String) -> DotClientSession:
	var session := DotClientSession.new()
	session.peer_id = peer_id
	session.userid = userid
	session.display_name = who
	return session


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
