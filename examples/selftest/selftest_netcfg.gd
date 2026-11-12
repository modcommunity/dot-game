extends "selftest_hooks.gd"

## The net-ceiling, snapshot-rate, npc-lod, services and map-content sections of game_selftest.gd.

func _caps(game_values: Dictionary, ceiling: Dictionary, tick := 64) -> DotNetConfig:
	var c := DotNetConfig.new()
	c.tick_rate = tick
	for key in game_values:
		c.set(key, game_values[key])
	DotGameNetcode.cap(c, ceiling)
	return c


func _test_cpu_usec() -> void:
	_section("DotGameCheckSuite.cpu_usec counts CPU time, not wall time")
	var a := DotGameCheckSuite.cpu_usec()
	var w0 := Time.get_ticks_usec()
	var x := 0
	while Time.get_ticks_usec() - w0 < 30000:
		x += 1
	var burned := DotGameCheckSuite.cpu_usec() - a
	_check(burned >= 15000 and burned < 200000, "a 30 ms spin reads as about 30 ms", "%d us" % burned)
	var b := DotGameCheckSuite.cpu_usec()
	OS.delay_msec(60)
	var slept := DotGameCheckSuite.cpu_usec() - b
	_check(slept < 30000 or not DotGameCheckSuite.cpu_is_real(), "a 60 ms sleep costs no CPU (wall fallback excused)", "%d us" % slept)
	_done()


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

	c = _caps({"interest_radius": 300.0}, {"interest_radius": 150.0})
	_check(is_equal_approx(c.interest_radius, 150.0), "the relevance radius is clamped to the operator's metres")
	c = _caps({"interest_radius": 100.0}, {"interest_radius": 150.0})
	_check(is_equal_approx(c.interest_radius, 100.0), "a game radius under the cap is kept")
	c = _caps({"interest_radius": 300.0}, {"interest_radius": 0.0})
	_check(is_equal_approx(c.interest_radius, 300.0), "an operator radius of 0 leaves the game's")
	c = _caps({"far_every": 1, "far_distance": 0.0}, {"far_every": 4, "far_distance": 60.0})
	_check(c.far_every == 4 and is_equal_approx(c.far_distance, 60.0), "far_every and far_distance are the operator's to set")

	c = _caps({}, {"stagger_snapshots": 1})
	_check(c.stagger_snapshots, "stagger_snapshots is the operator's to turn on")
	c = _caps({}, {})
	_check(not c.stagger_snapshots, "and stays off without it")

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


func _test_snapshot_rate_adapts_to_slots() -> void:
	_section("the snapshot rate follows the server's size: kept to 32 slots, lower past it, never raised")
	var c := DotNetConfig.new()
	c.tick_rate = 64
	c.snapshot_rate = 30
	_check(DotGameNetcode.adapt_snapshot_rate(c, 32) == "" and c.snapshot_rate == 30, "32 slots keep the game's rate")
	_check(DotGameNetcode.adapt_snapshot_rate(c, 64) != "" and c.snapshot_rate == 16, "64 slots: 20 lands on the divisor 16")
	_check(c.stagger_snapshots, "and the peers are staggered over the ticks between snapshots")
	c.snapshot_rate = 30
	_check(DotGameNetcode.adapt_snapshot_rate(c, 100) != "" and c.snapshot_rate == 16, "100 slots: 16")
	_check(DotGameNetcode.adapt_snapshot_rate(c, 100) == "", "and a second call changes nothing")
	c.snapshot_rate = 8
	_check(DotGameNetcode.adapt_snapshot_rate(c, 100) == "" and c.snapshot_rate == 8, "a lower game rate is never raised")
	c.tick_rate = 60
	c.snapshot_rate = 30
	var _l := DotGameNetcode.adapt_snapshot_rate(c, 200)
	_check(c.snapshot_rate == 10, "200 slots on tick 60: 10")
	_check(DotGameNetcode.adapt_snapshot_rate(null, 100) == "", "no config is a no-op")
	_done()


class FakeNpcLimits:
	extends RefCounted
	var sense_quiet_mult := 1


class FakeNpcSpawner:
	extends Node
	var sense_workers := 0
	var limits := FakeNpcLimits.new()


func _test_npc_lod_cvars() -> void:
	_section("DotGameNpcLod: the cvars exist, default off, and reach the spawner")

	var console := DotConsole.new()
	add_child(console)
	DotGameNpcLod.ensure_cvars(console)
	DotGameNpcLod.ensure_cvars(console)
	var all := true
	for name: String in DotGameNpcLod.CVARS:
		all = all and console.find_cvar(name) != null
	_check(all, "every cvar is registered, twice over without harm")
	_check(console.get_int("npc_lod") == 0 and console.get_int("npc_sense_quiet") == 1, "and each defaults to off")

	var spawner := FakeNpcSpawner.new()
	add_child(spawner)
	var sc := DotServerConfig.new()
	sc.threads_npc = true
	sc.worker_threads = 3
	var lod := DotGameNpcLod.attach(self, console, spawner, sc)
	_check(lod != null and spawner.sense_workers == sc.npc_workers(), "attach hands the sense workers sv_threads_npc gives (%d)" % spawner.sense_workers)
	_check(spawner.limits.sense_quiet_mult == 1 and lod.scheduler == null, "with the cvars at rest nothing changes and no scheduler is built")

	console.set_cvar("npc_sense_quiet", "3")
	lod.follow(0.016)
	_check(spawner.limits.sense_quiet_mult == 3, "npc_sense_quiet is followed live")

	console.set_cvar("npc_lod", "1")
	lod.follow(0.016)
	var have_ai := ResourceLoader.exists(DotGameNpcLod.SCHEDULER_SCRIPT)
	_check((lod.scheduler != null) == have_ai, "npc_lod builds the scheduler when dot-npc-ai is present (%s)" % str(have_ai))
	_check(not have_ai or lod.scheduler.config.enabled, "and enables it")
	lod.release()
	spawner.queue_free()
	console.queue_free()
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


## [DotGameServices] in a project that has none of the three addons it drives.
##
## Skipping must be quiet and complete: setup succeeds, admission passes, the fan-out is a no-op, and a line is refused in a way a caller can act on. Chat routing proper is asserted in a game that has the addons.
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


## The profiler placement is optional: with dot-profiler absent it places nothing and parses.
func _test_profiler_placement() -> void:
	_section("profiler placement")
	var prof := preload("res://addons/dot_game/runtime/dot_game_profiler.gd")
	var host := Node.new()
	add_child(host)
	var placed: Node = prof.add(host)
	if ResourceLoader.exists(prof.SCRIPT):
		_check(placed != null and DotRegistry.get_service(&"dot_profiler") == placed, "placed and registered as dot_profiler")
		_check(prof.add(host) == null, "placing twice adds nothing")
	else:
		_check(placed == null and host.get_child_count() == 0, "a build without dot-profiler places nothing")
	prof.install_server(null)
	host.queue_free()
	await _late_console_after_free()
	_done()


## The registry outlives a client: a late console registration for a freed client must find nothing, not a freed capture.
func _late_console_after_free() -> void:
	var c := DotGameClient.new()
	var id := c.get_instance_id()
	c.free()
	DotGameClientExtras._bind_if_alive(id)
	_check(instance_from_id(id) == null, "a profiler hook for a freed client resolves to nothing and raises no error")
	var live := DotGameClient.new()
	add_child(live)
	_check(not DotGameClientExtras.bind_profiler_console(live), "a live client with no profiler binds nothing")
	live.queue_free()


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



