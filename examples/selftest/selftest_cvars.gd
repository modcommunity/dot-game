extends "selftest_extra.gd"

## The thread, relevance, render and latency cvar sections of game_selftest.gd.

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


func _test_sun_shadow_cvars() -> void:
	_section("r_sun_shadow_size and r_sun_shadow_splits validate and cap a sun, never raising it")
	var rq := load("res://addons/dot_game/runtime/dot_game_render_quality.gd")
	var saved: Dictionary = rq.values.duplicate()
	_check(rq.set_value(&"r_sun_shadow_splits", 3).ok == false, "3 splits is refused")
	_check(rq.set_value(&"r_sun_shadow_size", 100).ok == false, "a 100 px sun map is refused")
	_check(rq.web_defaults()[&"r_sun_shadow_size"] == 2048.0 and rq.web_defaults()[&"r_sun_shadow_splits"] == 2.0, "the web defaults are 2048 and 2 splits")
	rq.values[&"r_shadow_distance"] = -1.0
	rq.set_value(&"r_sun_shadow_splits", 2)
	var sun := DirectionalLight3D.new()
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	rq.cap_sun(sun)
	_check(sun.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS, "a 4-split sun drops to 2")
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	rq.cap_sun(sun)
	_check(sun.directional_shadow_mode == DirectionalLight3D.SHADOW_ORTHOGONAL, "a 1-split sun is not raised")
	rq.set_value(&"r_sun_shadow_splits", 1)
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	rq.cap_sun(sun)
	_check(sun.directional_shadow_mode == DirectionalLight3D.SHADOW_ORTHOGONAL, "1 split forces orthogonal")
	sun.free()
	rq.values = saved
	_done()


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
	net.config = DotNetConfig.new()
	var link := LatencyLink.new()
	c.link = link
	var local := VisLocal.new()
	var con := VisConsole.new()
	con.list = [local]
	c.console = con
	c.add_latency(net)
	_check(net.config.reconcile_once_per_frame and net.config.skip_matching_replays, "the client turns on reconcile_once_per_frame and skip_matching_replays")
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


func _test_client_replay_tuning() -> void:
	_section("a client that never calls setup() still tunes its netcode's replay settings, and tune_replay off opts out")
	var c := DotGameClient.new()
	c.use_gate = false
	add_child(c)
	var early := DotNetManager.new()
	early.config = DotNetConfig.new()
	add_child(early)
	_check(early.config.reconcile_once_per_frame and early.config.skip_matching_replays, "a net registered after _ready is tuned without setup()")
	var srv := DotNetManager.new()
	srv.is_server = true
	srv.service_scope = &"replay_tune_srv"
	srv.config = DotNetConfig.new()
	add_child(srv)
	_check(not srv.config.reconcile_once_per_frame and not srv.config.skip_matching_replays, "a server's manager is left alone")
	var off := DotGameClient.new()
	off.use_gate = false
	off.tune_replay = false
	add_child(off)
	var late := DotNetManager.new()
	late.service_scope = &"replay_tune_off"
	late.config = DotNetConfig.new()
	late.config.reconcile_once_per_frame = false
	c.tune_replay = false
	add_child(late)
	_check(not late.config.reconcile_once_per_frame, "tune_replay off leaves the config as the game set it")
	early.queue_free()
	srv.queue_free()
	late.queue_free()
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


func _test_movement_cvars() -> void:
	_section("bind_movement_cvars: the game's movement targets become replicated cvars, with no per-game code")
	var console := DotConsole.new()
	add_child(console)
	var m := DotGameModule.new()
	m.console = console
	add_child(m)
	var target: Object = preload("res://examples/fixtures/test_movement_target.gd").new()

	_check(m.bind_movement_cvars().is_empty() and m.movement_cvars == null, "a game offering no targets binds nothing")

	var game := Node.new()
	game.set_script(preload("res://examples/fixtures/test_movement_game.gd"))
	game.set("target", target)
	m.game = game
	var saved := DotGameModule.fps_cvars_script
	DotGameModule.fps_cvars_script = "res://examples/fixtures/missing_binder.gd"
	_check(m.bind_movement_cvars().is_empty() and m.movement_cvars == null, "without dot-player-controller it is skipped, not an error")

	DotGameModule.fps_cvars_script = "res://examples/fixtures/test_fps_cvars.gd"
	var made := m.bind_movement_cvars()
	var cv := console.find_cvar("sv_gravity")
	_check(made.size() == 1 and cv != null and m.movement_cvars != null, "the game's movement_targets() are bound as cvars")
	_check(cv != null and (cv.flags & DotConVar.FLAG_REPLICATED) != 0, "and replicated, because a client predicts its own movement")
	var explicit := DotGameModule.new()
	explicit.console = DotConsole.new()
	add_child(explicit.console)
	add_child(explicit)
	_check(explicit.bind_movement_cvars([target]).size() == 1, "targets can also be passed explicitly")

	DotGameModule.fps_cvars_script = saved
	game.free()
	m.free()
	explicit.free()
	console.free()
	_done()
