extends RefCounted

## [DotGameClient]'s settings build: the node, its rows, its menu. No class_name: the client preloads it.

const CHANNEL := "game.client"


static func build(c: DotGameClient) -> void:
	if c.settings == null:
		c.settings = c._make_settings()
	if c.settings == null:
		return
	if c.settings.name == &"":
		c.settings.name = "Settings"
	if not c.settings.is_inside_tree():
		c.add_child(c.settings)
	if not c.settings.has_method(&"setup"):
		DotLog.warn(CHANNEL, "the settings node has no setup(); it is left alone", {"node": str(c.settings)})
		return

	DotGameClientLook.add_rows(c)
	if c.use_slide_sounds:
		preload("res://addons/dot_game/runtime/dot_game_slide_sounds.gd").declare_on(c.settings)
	var built: Variant = c.settings.call(&"setup")
	if built is DotResult and not (built as DotResult).ok:
		DotLog.warn(CHANNEL, "no settings; everything is at its default", {"why": (built as DotResult).error.message})
		c.settings.queue_free()
		c.settings = null
		return

	var got: Variant = c.settings.get(&"menu")
	c.menu = got if got is Object else null
	DotGameUserCfg.add_entry(c)


## The stock dot-menu settings node, or null when dot-menu is not in the build.
static func make(c: DotGameClient) -> Node:
	if not ResourceLoader.exists(DotGameClient.SETTINGS_SCRIPT):
		DotLog.info(CHANNEL, "dot-menu is not in this build: no settings or Escape menu")
		return null
	var script: Variant = load(DotGameClient.SETTINGS_SCRIPT)
	if not (script is GDScript):
		DotLog.warn(CHANNEL, "dot-menu's settings would not load", {"path": DotGameClient.SETTINGS_SCRIPT})
		return null
	var made: Node = (script as GDScript).new()
	made.set(&"app_namespace", c.app_namespace)
	made.set(&"avatar_actions", true)
	made.set(&"directory", c.settings_directory if c.settings_directory != "" else "user://%s_settings" % c.app_namespace)
	return made
