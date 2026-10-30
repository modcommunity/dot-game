extends SceneTree

## Renders DotGameStorePanel with owned items to screenshots/store_panel.png.
##   xvfb-run -a godot --path . --resolution 800x450 --script tools/store_panel_shot.gd

func _initialize() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.11, 0.14)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)
	var panel := DotGameStorePanel.new()
	panel.store_url = "https://games.tmcdev.net/dashboard/store"
	panel.position = Vector2(40, 40)
	root.add_child(panel)
	panel.set_owned([{"key": "arena_gold_skin", "name": "Gold skin", "kind": "AVATAR"}, {"key": "launcher", "name": "Rocket launcher", "kind": "ITEM"}])
	for i in 4:
		await process_frame
	DirAccess.make_dir_recursive_absolute("screenshots")
	root.get_texture().get_image().save_png("screenshots/store_panel.png")
	quit()
