extends SceneTree

## Rewrites every game's shipped `cfg/game/<game>/config_*/game.yml` from its config's fields: godot --headless --path . --script addons/dot_game/qa/dot_game_cfg_templates.gd


func _init() -> void:
	var failed := false
	for script: Script in DotGameConfigSchemas.config_scripts():
		if not script.has_method("make_binder"):
			continue
		var files: Dictionary = script.call("make_binder", script.new()).template_files()
		for path: String in files:
			var res := DotPaths.write_text("res://" + path, files[path])
			print("%s %s" % ["wrote" if res.ok else "FAILED", path])
			failed = failed or not res.ok
	quit(1 if failed else 0)
