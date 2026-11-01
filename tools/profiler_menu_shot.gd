extends SceneTree

## Any game's real client (project main scene, or the first user arg) with the menu opened on Advanced,
## scrolled to the Performance card, after a short recording; prints the checks and saves a PNG.
##   xvfb-run -a godot --path ~/godot/<game> --resolution 1280x720 --script ~/godot/dot-game/tools/profiler_menu_shot.gd -- out.png [scene.tscn]
## Needs a renderer (xvfb-run or a GPU box). Exit 0 only when the card exists and a recording was written.


func _initialize() -> void:
	_run.call_deferred()


func _find_menu(n: Node) -> DotMenu:
	if n is DotMenu:
		return n
	for c in n.get_children():
		var m := _find_menu(c)
		if m != null:
			return m
	return null


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "screenshots/profiler_menu.png"
	var scene_path: String = args[1] if args.size() > 1 else str(ProjectSettings.get_setting("application/run/main_scene"))
	var scene := (load(scene_path) as PackedScene).instantiate()
	root.add_child(scene)
	var menu: DotMenu = null
	var prof: Object = null
	for f in 600:
		await process_frame
		if f % 10 == 0 and f >= 30:
			menu = _find_menu(root)
			prof = DotRegistry.get_service(&"dot_profiler")
			if menu != null and prof != null:
				break
	print("profiler_menu_shot: scene=%s menu=%s profiler=%s at %d ms" % [scene_path, menu != null, prof != null, Time.get_ticks_msec()])
	if prof == null or menu == null:
		quit(1)
		return
	for f in 90:
		await process_frame
	var started: Variant = prof.call(&"start_recording", 1.0)
	var rec_seen: bool = prof.call(&"is_recording")
	var guard := 0
	while prof.call(&"is_recording") and guard < 900:
		guard += 1
		await process_frame
	var report := str(prof.call(&"describe"))
	menu.open(&"advanced")
	for f in 10:
		await process_frame
	var perf := menu.find_child("Performance", true, false) as Control
	var p: Node = perf
	while p != null and not p is ScrollContainer:
		p = p.get_parent()
	if p != null:
		(p as ScrollContainer).ensure_control_visible(perf)
	for f in 10:
		await process_frame
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var err := root.get_texture().get_image().save_png(out)
	print("profiler_menu_shot: %s (%s) card=%s recording_seen=%s start=%s | %s" % [out, error_string(err), perf != null, rec_seen, started, report])
	quit(0 if err == OK and perf != null and rec_seen else 1)
