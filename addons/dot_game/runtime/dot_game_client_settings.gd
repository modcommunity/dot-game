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
	var built: Variant = c.settings.call(&"setup")
	if built is DotResult and not (built as DotResult).ok:
		DotLog.warn(CHANNEL, "no settings; everything is at its default", {"why": (built as DotResult).error.message})
		c.settings.queue_free()
		c.settings = null
		return

	var got: Variant = c.settings.get(&"menu")
	c.menu = got if got is Object else null
	DotGameUserCfg.add_entry(c)
