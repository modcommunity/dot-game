extends RefCounted

## [DotGameClient]'s gate, stepped setup, touch buttons, pointer holds and teardown; the client keeps the state and the overridable seams. No class_name: the client preloads it.

const _Profiler := preload("res://addons/dot_game/runtime/dot_game_profiler.gd")


static func wire_gate(c: DotGameClient) -> void:
	c.gate = c._make_gate()
	if c.gate == null:
		return
	c.gate.opened.connect(c._refresh_blocked)
	c.gate.closed.connect(c._refresh_blocked)
	if c.report_loading:
		c.gate.opened.connect(c._on_gate_cover.bind(false))
		c.gate.closed.connect(c._on_gate_cover.bind(true))


static func make_gate(c: DotGameClient) -> DotLoadGate:
	var made := DotLoadGate.new()
	made.require_camera = c.require_camera
	made.warm_up_on_open = c.warm_up and DisplayServer.get_name() != "headless"
	if c.cover != null:
		made.cover = c.cover
	elif c.cover_scene != null:
		made.cover_scene = c.cover_scene
	if c.spawned_fn.is_valid():
		made.require(DotGameClient.REASON_SPAWNED, c.spawned_fn, c.spawned_text)
	# Under the host: the gate marks its parent for DotLoadGate.of. A host still readying refuses a child, so wait a frame.
	if c.host.is_node_ready():
		c.host.add_child(made)
	else:
		c.host.add_child.call_deferred(made)
	return made


static func stepped(c: DotGameClient, between: Callable) -> DotResult:
	var pieces := c._setup_pieces()
	var stepping := between.is_valid() or (DisplayServer.get_name() != "headless" and c.is_inside_tree())
	# dot-profiler is the costly piece: its script compiles on a loader thread (from _ready) while the pieces before it run.
	var profiler_loading := stepping and c.use_profiler and c.is_inside_tree() and &"profiler" in pieces and _Profiler.request_script()
	var profiler_script: Resource = null
	for i in pieces.size():
		if pieces[i] == &"profiler" and profiler_loading:
			# With between, every frame boundary is the game's (it may hold the multiplayer poll across them): never end one here.
			profiler_script = await _Profiler.await_script(c.get_tree(), between.is_valid())
			DotLog.debug(DotGameClient.CHANNEL, "profiler script loaded off the main thread", {"ok": profiler_script != null})
		c._run_setup_piece(pieces[i])
		if i == pieces.size() - 1:
			break
		if between.is_valid():
			await between.call(pieces[i])
		elif DisplayServer.get_name() != "headless" and c.is_inside_tree():
			await c.get_tree().process_frame
	return c._finish_setup()


static func run_piece(c: DotGameClient, piece: StringName) -> void:
	var started := Time.get_ticks_usec()
	match piece:
		&"chat":
			DotGameClientExtras.wire_chat(c)
			c._wire_pointer_modals()
		&"settings":
			if c.use_settings and c.menu == null:
				c._build_settings()
		&"console":
			if c.use_console:
				c.add_console()
		&"profiler":
			DotGameClientExtras.add_profiler(c)
		&"menu":
			c._wire_menu()
		&"look":
			DotGameClientLook.build(c)
		&"sounds":
			DotGameClientExtras.add_slide_sounds(c)
			DotGameClientExtras.add_landing(c)
		&"quality":
			DotGameClientExtras.add_render_quality(c)
			DotGameClientExtras.watch_latency_net(c)
	c.setup_usec[piece] = Time.get_ticks_usec() - started


static func unwire_chat(c: DotGameClient) -> void:
	if c.chat == null or not is_instance_valid(c.chat):
		return
	for signal_name: StringName in [&"typing_changed", &"opened", &"closed"]:
		if c.chat.has_signal(signal_name) and c.chat.is_connected(signal_name, c._refresh_blocked):
			c.chat.disconnect(signal_name, c._refresh_blocked)


static func chat_typing(chat: Node) -> bool:
	if chat == null or not is_instance_valid(chat):
		return false
	if chat.has_method(&"is_typing"):
		return bool(chat.call(&"is_typing"))
	if chat.has_method(&"is_open"):
		return bool(chat.call(&"is_open"))
	return false


static func touch_board(c: DotGameClient, down: bool) -> void:
	var board_node: Object = c.board
	if board_node == null or not is_instance_valid(board_node):
		return
	if not down:
		board_node.call(&"close")
	elif not c.is_menu_open() and not c._chat_typing() and not c.is_input_blocked():
		board_node.call(&"open")


static func touch_maps(c: DotGameClient) -> bool:
	var maps: Object = c.maps
	if maps == null or not is_instance_valid(maps) or c.is_input_blocked() or c.is_menu_open():
		return false
	if &"enabled" in maps and not bool(maps.get(&"enabled")):
		return false
	maps.call(&"open")
	return true


static func hold_pointer(c: DotGameClient, key: Variant) -> void:
	c._pointer_holds[key] = true
	if c.capture_pointer and c._set_up and not c.gate_only:
		c._free_pointer()
	c._refresh_blocked()


static func release_pointer(c: DotGameClient, key: Variant) -> void:
	if not c._pointer_holds.erase(key):
		return
	c._refresh_blocked()
	if c.capture_pointer and c._set_up and not c.gate_only and not DotPlatform.is_web() \
			and not c.is_menu_open() and not c._chat_typing() and not c._busy() and c._pointer_wanted():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


static func hit_flinch(sampler_fn: Callable, camera_fn: Callable, aim_fn: Callable, tunables_fn: Callable) -> DotGameHitFlinch:
	var made := DotGameHitFlinch.new()
	made.sampler_fn = sampler_fn
	made.camera_fn = camera_fn
	made.aim_fn = aim_fn
	made.tunables_fn = tunables_fn
	return made


static func exit_tree(c: DotGameClient) -> void:
	c.restore_map_config()
	DotGameClientExtras.disconnect_registry_bus(c)
	if c.user_tier_on:
		# Process-wide flag: left on, it would hand the next server's addons the player's files.
		c.user_tier_on = false
		DotAddonConfig.set_user_tier(false)
	DotGamePageGuard.clear(c, false)
	if c.screen_fit != null:
		c.screen_fit.detach(true)
