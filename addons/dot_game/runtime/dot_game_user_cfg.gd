class_name DotGameUserCfg
extends RefCounted

## The "Your mods" row of [DotGameClient] and the cfg editor it opens, both by path so a build without dot-menu's editor has no entry.

const CHANNEL := "game.client"
const ROW_SCRIPT := "res://addons/dot_menu/core/dot_menu_row.gd"
const EDITOR_SCRIPT := "res://addons/dot_menu/ui/dot_addon_config_editor_screen.gd"
const USER_CFG_PAGE := &"advanced"


static func add_entry(c: DotGameClient) -> void:
	if not c.user_tier_on or c.user_cfg_files.is_empty() or c.menu == null or not c.menu.has_method(&"page"):
		return
	if not ResourceLoader.exists(ROW_SCRIPT) or not ResourceLoader.exists(EDITOR_SCRIPT):
		DotLog.info(CHANNEL, "dot-menu has no cfg editor: no mods entry")
		return
	var page: Variant = c.menu.call(&"page", USER_CFG_PAGE)
	var row_script: Variant = load(ROW_SCRIPT)
	if page == null or not (row_script is GDScript):
		return
	var row: Variant = (row_script as GDScript).call(&"button", "Your mods",
			"Tune the game's own settings files for this device.", "Edit", c.open_user_cfg)
	var sec: Variant = (page as Object).call(&"section", "Mods", &"user_cfg")
	(sec as Object).call(&"add", row)


## Opens the cfg editor over the menu. False without the tier, files, menu or editor.
static func open(c: DotGameClient) -> bool:
	if not c.user_tier_on or c.user_cfg_files.is_empty() or c.menu == null:
		return false
	if not ResourceLoader.exists(EDITOR_SCRIPT):
		return false
	if c.user_cfg_overlay != null and is_instance_valid(c.user_cfg_overlay):
		c.user_cfg_overlay.open()
		return true
	# A CanvasLayer above the menu's own, or the editor draws underneath it.
	var layer := CanvasLayer.new()
	layer.layer = 200
	c.add_child(layer)
	c.user_cfg_overlay = Overlay.new()
	layer.add_child(c.user_cfg_overlay)
	var ed: Control = (load(EDITOR_SCRIPT) as GDScript).new()
	c.user_cfg_overlay.host_editor(ed)
	for f in c.user_cfg_files:
		ed.call(&"add_file", f.get("addon", ""), f.get("file", ""), f.get("schema", []), f.get("label", ""))
	var first: Dictionary = c.user_cfg_files[0]
	var _opened: Variant = ed.call(&"open", first.get("addon", ""), first.get("file", ""))
	if c.menu.has_method(&"add_overlay"):
		c.menu.call(&"add_overlay", c.user_cfg_overlay)
	c.user_cfg_overlay.open()
	if c.menu.has_method(&"overlay_opened"):
		c.menu.call(&"overlay_opened")
	return true


## The editor, full screen, with a Close button; the shape dot-menu's add_overlay wants.
class Overlay extends Control:
	signal closed()
	var _editor: Control = null

	func _init() -> void:
		set_anchors_preset(Control.PRESET_FULL_RECT)
		visible = false

	func host_editor(ed: Control) -> void:
		_editor = ed
		ed.set_anchors_preset(Control.PRESET_FULL_RECT)
		ed.offset_bottom = -48
		var back := ColorRect.new()
		back.color = Color(0.05, 0.06, 0.08, 1.0)
		back.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(back)
		add_child(ed)
		var b := Button.new()
		b.text = "Close"
		b.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		b.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		b.grow_vertical = Control.GROW_DIRECTION_BEGIN
		b.pressed.connect(close)
		add_child(b)

	func open() -> void:
		visible = true

	func close() -> void:
		if visible:
			visible = false
			closed.emit()

	func is_open() -> bool:
		return visible
