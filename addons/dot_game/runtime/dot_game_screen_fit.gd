class_name DotGameScreenFit
extends RefCounted

## Fits a touch screen: aspect expand (no pillarbox), a canvas whose short side is the HUD design's, and touch buttons sized from the real window and the display's DPI.
## Only the real-pixel floor is guaranteed: on the web and headless the DPI is a guess, so the millimetre target is only as true as it.
##
## [DotGameClient] attaches one to the root window when [member DotGameClient.use_screen_fit] is on and [method DotPlatform.has_touch] says a finger can reach the screen. A game tunes it by assigning [member DotGameClient.screen_fit] before the client is added, or opts out with [code]use_screen_fit = false[/code].

const CHANNEL := "game.screen_fit"
const MM_PER_INCH := 25.4
## Window meta holding the stretch the first fit found and how many fits hold it, so a second fit never saves fitted values as the original.
const META := &"dot_game_screen_fit"

## Canvas units the short side gets: dot-ui's HUD design height, so its 1280x720 pieces fit unscaled on a landscape phone.
var short_side: float = 720.0
## Smallest button diameter wanted, in millimetres at the reported DPI, and the real-pixel floor, which is all a guessed DPI can promise.
var button_mm: float = 9.0
var button_min_px: float = 44.0
## Shares of the canvas the button block may cover: nearly the whole height, under half the width so the stick keeps its side.
var button_max_height: float = 0.92
var button_max_width: float = 0.45
## Replaces the DPI the display reports; zero asks the display. A suite or a game with a better source sets it.
var dpi_override: float = 0.0
## Replaces the window's real size; zero reads the window. A suite has no phone.
var size_override: Vector2 = Vector2.ZERO
## Replaces the display's safe area, in the window's real pixels; an empty rect asks the display. A suite has no notch.
var safe_area_override: Rect2i = Rect2i()

var window: Window = null
## The last [method plan_for] applied: aspect, size (canvas units), stretch (real pixels per unit).
var plan: Dictionary = {}

var _base: Vector2 = Vector2.ZERO
var _saved: Dictionary = {}
var _buttons: Array[Dictionary] = []
## Content scale factor and DPI the buttons were last sized for.
var _inputs: Vector2 = Vector2.ZERO
var _safe_seen: Dictionary = {}


## The canvas for a window [param window_px] real pixels on a project laid out at [param base]: the short side is [param short] units (never more than the base's), the long side follows the window, so nothing is pillarboxed.
static func plan_for(window_px: Vector2, base: Vector2, short: float = 720.0) -> Dictionary:
	if window_px.x <= 0.0 or window_px.y <= 0.0:
		return {}
	var base_short := minf(base.x, base.y) if base.x > 0.0 and base.y > 0.0 else short
	var units := minf(short, base_short)
	var stretch := minf(window_px.x, window_px.y) / units
	var canvas := Vector2i((window_px / stretch).round())
	return {"aspect": Window.CONTENT_SCALE_ASPECT_EXPAND, "size": canvas, "stretch": stretch}


## The [code]button_scale[/code] that makes the smallest button in [param layout] (dot-ui's DotTouchButtons dictionaries: offset from the bottom-right corner towards the middle, radius) at least [param target_px] real pixels across at [param stretch], capped so the block fits [param limit] canvas units less [param margin], and never below 1.
## The block's reach from the corner is offset + radius per axis, which holds for a negative offset too (that button just reaches less far).
static func button_scale_for(layout: Array, stretch: float, target_px: float, limit: Vector2, margin: float = 28.0) -> float:
	if layout.is_empty() or stretch <= 0.0:
		return 1.0
	var smallest := INF
	var extent := Vector2.ZERO
	for b in layout:
		var r := float(b.get("radius", 0.0))
		var off: Vector2 = b.get("offset", Vector2.ZERO)
		if r > 0.0:
			smallest = minf(smallest, r)
		extent = extent.max(off + Vector2(r, r))
	if smallest == INF:
		return 1.0
	var k := target_px / (2.0 * smallest * stretch)
	var room := limit - Vector2(margin, margin)
	if room.x > 0.0 and room.y > 0.0:
		if extent.x > 0.0:
			k = minf(k, room.x / extent.x)
		if extent.y > 0.0:
			k = minf(k, room.y / extent.y)
	return maxf(1.0, k)


## Real pixels a [param mm] millimetre target is at [param dpi], never under [param floor_px].
static func target_px_for(dpi: float, mm: float = 9.0, floor_px: float = 44.0) -> float:
	return maxf(floor_px, mm / MM_PER_INCH * clampf(dpi, 72.0, 640.0))


## Attaches [param fit] (or a default one) to [param win] when [param wanted] is 1, or -1 and a finger can reach the screen. Null when not wanted, leaving the project's stretch alone.
static func install(win: Window, wanted: int = -1, fit: DotGameScreenFit = null) -> DotGameScreenFit:
	if win == null or wanted == 0 or (wanted < 0 and not DotPlatform.has_touch()):
		return null
	var made := fit if fit != null else DotGameScreenFit.new()
	made.attach(win)
	return made


## Saves the window's stretch (or takes the one an earlier fit saved), applies the fit and follows resizes (a phone turning over). Attaching to the same window again does nothing.
func attach(win: Window) -> void:
	if win == null or win == window:
		return
	if window != null:
		detach()
	window = win
	var held: Dictionary = win.get_meta(META, {})
	if held.is_empty():
		held = {"saved": {"mode": win.content_scale_mode, "aspect": win.content_scale_aspect, "size": win.content_scale_size}, "holders": 0}
	held["holders"] = int(held["holders"]) + 1
	win.set_meta(META, held)
	_saved = held["saved"]
	_base = Vector2(_saved["size"])
	if _base == Vector2.ZERO:
		_base = Vector2(ProjectSettings.get_setting("display/window/size/viewport_width", 1152), ProjectSettings.get_setting("display/window/size/viewport_height", 648))
	if not win.size_changed.is_connected(refit):
		win.size_changed.connect(refit)
	refit()
	DotLog.info(CHANNEL, "touch screen fit: %s canvas %s at %.2f px per unit" % [win.size, plan.get("size", Vector2i.ZERO), float(plan.get("stretch", 1.0))])


## Stops following the window and forgets the buttons; the last fit to let go puts the window's stretch back.
func detach() -> void:
	_buttons.clear()
	if window == null:
		return
	if is_instance_valid(window):
		if window.size_changed.is_connected(refit):
			window.size_changed.disconnect(refit)
		var held: Dictionary = window.get_meta(META, {})
		var left := int(held.get("holders", 1)) - 1
		if left > 0:
			held["holders"] = left
		else:
			window.remove_meta(META)
			window.content_scale_mode = _saved["mode"]
			window.content_scale_aspect = _saved["aspect"]
			window.content_scale_size = _saved["size"]
	window = null
	plan = {}


## Re-applies for the window's size (or [member size_override]). True when the plan changed.
func refit() -> bool:
	if window == null or not is_instance_valid(window):
		return false
	var px := size_override if size_override != Vector2.ZERO else Vector2(window.size)
	var next := plan_for(px, _base, short_side)
	if next.is_empty():
		return false
	var changed: bool = next != plan
	plan = next
	if window.content_scale_mode == Window.CONTENT_SCALE_MODE_DISABLED:
		window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	if window.content_scale_aspect != plan["aspect"]:
		window.content_scale_aspect = plan["aspect"]
	if window.content_scale_size != plan["size"]:
		window.content_scale_size = plan["size"]
	if changed or _scale_inputs() != _inputs or safe_insets() != _safe_seen:
		_refit_buttons()
	return changed


## The display's DPI, or [member dpi_override].
func dpi() -> float:
	if dpi_override > 0.0:
		return dpi_override
	return float(DisplayServer.screen_get_dpi(window.current_screen if window != null and is_instance_valid(window) else -1))


## Sizes [param buttons] (anything with [code]button_scale[/code] and [code]margin[/code], dot-ui's DotTouchButtons) for [param layout] now and on every refit. Returns the scale set.
func fit_buttons(buttons: Control, layout: Array) -> float:
	# The margin a game set, before any safe-area shift, so refits never stack shifts.
	var base := float(buttons.get("margin")) if "margin" in buttons else 28.0
	for e in _buttons:
		if e["ref"].get_ref() == buttons:
			base = e["margin"]
	_buttons = _buttons.filter(func(e: Dictionary) -> bool: return e["ref"].get_ref() != null and e["ref"].get_ref() != buttons)
	_buttons.append({"ref": weakref(buttons), "layout": layout, "margin": base})
	return _scale_one(buttons, layout, base)


## The display's unsafe borders (notch, rounded corners, gesture bar) in canvas units: left, top, right, bottom, all zero when the safe area is the whole screen. Only a window that fills its screen has any.
func safe_insets() -> Dictionary:
	var none := {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	if plan.is_empty() or window == null or not is_instance_valid(window):
		return none
	var px := size_override if size_override != Vector2.ZERO else Vector2(window.size)
	var safe := safe_area_override
	if safe.size == Vector2i.ZERO:
		if size_override != Vector2.ZERO or DisplayServer.screen_get_size(window.current_screen) != window.size:
			return none
		safe = DisplayServer.get_display_safe_area()
	if safe.size == Vector2i.ZERO:
		return none
	var factor := window.content_scale_factor if window.content_scale_factor > 0.0 else 1.0
	var per_unit := float(plan["stretch"]) * factor
	return {"left": maxf(0.0, safe.position.x) / per_unit, "top": maxf(0.0, safe.position.y) / per_unit,
		"right": maxf(0.0, px.x - safe.end.x) / per_unit, "bottom": maxf(0.0, px.y - safe.end.y) / per_unit}


func _scale_inputs() -> Vector2:
	return Vector2(window.content_scale_factor if window != null and is_instance_valid(window) else 1.0, dpi())


func _refit_buttons() -> void:
	_inputs = _scale_inputs()
	_safe_seen = safe_insets()
	for e in _buttons:
		var b: Control = e["ref"].get_ref()
		if b != null:
			_scale_one(b, e["layout"], e["margin"])


func _scale_one(buttons: Control, layout: Array, base_margin: float) -> float:
	if plan.is_empty() or not "button_scale" in buttons:
		return 1.0
	_inputs = _scale_inputs()
	# content_scale_factor (a player's UI size) multiplies the stretch and shrinks the visible canvas by as much.
	var factor := window.content_scale_factor if window != null and is_instance_valid(window) and window.content_scale_factor > 0.0 else 1.0
	var canvas := Vector2(plan["size"]) / factor
	var limit := Vector2(canvas.x * button_max_width, canvas.y * button_max_height)
	var margin := base_margin
	var k := button_scale_for(layout, float(plan["stretch"]) * factor, target_px_for(dpi(), button_mm, button_min_px), limit, margin)
	buttons.set("button_scale", k)
	_safe_seen = safe_insets()
	if "margin" in buttons:
		buttons.set("margin", margin + _safe_shift(layout, k, margin, canvas, _safe_seen))
	if buttons.has_method(&"queue_redraw"):
		buttons.queue_redraw()
	return k


## How much more margin (the buttons anchor to the bottom-right and use one margin on both axes) keeps every button inside the safe rect, without pushing the block's far edge out of it.
static func _safe_shift(layout: Array, k: float, margin: float, canvas: Vector2, insets: Dictionary) -> float:
	var near := Vector2(INF, INF)
	var far := Vector2.ZERO
	for b in layout:
		var r := float(b.get("radius", 0.0))
		var off: Vector2 = b.get("offset", Vector2.ZERO)
		near = near.min(off - Vector2(r, r))
		far = far.max(off + Vector2(r, r))
	if near.x == INF:
		return 0.0
	var need := maxf(float(insets["right"]) - (margin + near.x * k), float(insets["bottom"]) - (margin + near.y * k))
	var room := minf(canvas.x - float(insets["left"]) - (margin + far.x * k), canvas.y - float(insets["top"]) - (margin + far.y * k))
	return clampf(need, 0.0, maxf(0.0, room))


func describe() -> Dictionary:
	return {"attached": window != null, "plan": plan, "dpi": dpi() if window != null else 0.0, "buttons": _buttons.size(), "safe_insets": safe_insets(),
		"short_side": short_side, "button_mm": button_mm}
