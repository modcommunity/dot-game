extends Node

## DotGameScreenFit: the touch canvas plan, buttons sized in millimetres and capped to the screen, the root window fitted and restored, and DotGameClient's switch.

const EXPECTED_CHECKS := 56
const SECTIONS := ["plan", "buttons", "window", "safe", "client"]
const BASE := Vector2(1600, 900)
## The smallest radius here is 24, its block 164x276: a two-column phone layout.
const LAYOUT: Array[Dictionary] = [
	{"id": &"jump", "offset": Vector2(56, 56), "radius": 44.0},
	{"id": &"chat", "offset": Vector2(56, 200), "radius": 24.0},
	{"id": &"tab", "offset": Vector2(56, 252), "radius": 24.0},
	{"id": &"duck", "offset": Vector2(134, 46), "radius": 30.0},
]

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _done: Array[String] = []


## Stands in for dot-ui's DotTouchButtons, which this addon never names.
class Buttons extends Control:
	var button_scale := 1.0
	var margin := 28.0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _run() -> void:
	print("dot-game: screen fit")
	_plan()
	_buttons()
	_window()
	_safe()
	_client()
	for s in SECTIONS:
		if not s in _done:
			_check(false, "section %s ran to the end" % s)
	var total := _passed + _failed
	if total != EXPECTED_CHECKS:
		_failed += 1
		_failures.append("ran %d checks, expected %d" % [total, EXPECTED_CHECKS])
	for f in _failures:
		print("FAIL: ", f)
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _plan() -> void:
	var p := DotGameScreenFit.plan_for(Vector2(844, 390), BASE)
	_check(p["aspect"] == Window.CONTENT_SCALE_ASPECT_EXPAND, "phone: aspect expand")
	_check(p["size"] == Vector2i(1558, 720), "phone: canvas 1558x720, got %s" % p["size"])
	_check(is_equal_approx(float(p["stretch"]), 390.0 / 720.0), "phone: stretch is short side over 720")
	_check(absf(float(p["size"].x) / p["size"].y - 844.0 / 390.0) < 0.01, "phone: canvas keeps the window's aspect, no pillarbox")
	var tall := DotGameScreenFit.plan_for(Vector2(390, 844), BASE)
	_check(tall["size"] == Vector2i(720, 1558), "portrait: short side is the width")
	var dense := DotGameScreenFit.plan_for(Vector2(2532, 1170), BASE)
	_check(dense["size"] == Vector2i(1558, 720) and is_equal_approx(float(dense["stretch"]), 1170.0 / 720.0), "dense phone: same canvas, 1.625 px per unit")
	var pixel := DotGameScreenFit.plan_for(Vector2(844, 390), Vector2(640, 360))
	_check(pixel["size"].y == 360, "a 640x360 project keeps its 360")
	_check(DotGameScreenFit.plan_for(Vector2.ZERO, BASE).is_empty(), "no window: no plan")
	_done.append("plan")


func _buttons() -> void:
	var stretch := 390.0 / 720.0
	var target := DotGameScreenFit.target_px_for(96.0)
	_check(is_equal_approx(target, 44.0), "96 dpi: 9 mm is under the 44 px floor")
	_check(absf(DotGameScreenFit.target_px_for(460.0) - 163.0) < 0.5, "460 dpi: 9 mm is 163 px")
	var k := DotGameScreenFit.button_scale_for(LAYOUT, stretch, target, Vector2(1558 * 0.45, 720 * 0.92))
	_check(24.0 * 2.0 * k * stretch >= 43.99, "phone: smallest button is 44 real px across, got %.1f" % (48.0 * k * stretch))
	_check(276.0 * k + 28.0 <= 720.0 * 0.92, "phone: the block fits the height")
	var dense := 1170.0 / 720.0
	var kd := DotGameScreenFit.button_scale_for(LAYOUT, dense, DotGameScreenFit.target_px_for(460.0), Vector2(1558 * 0.45, 720 * 0.92))
	_check(48.0 * kd * dense >= 162.5, "dense phone: smallest button is 9 mm across")
	var capped := DotGameScreenFit.button_scale_for(LAYOUT, stretch, 400.0, Vector2(700, 662))
	_check(is_equal_approx(capped, (662.0 - 28.0) / 276.0), "a target too big is capped to the room")
	_check(DotGameScreenFit.button_scale_for(LAYOUT, 3.0, 44.0, Vector2(2000, 2000)) == 1.0, "never shrinks a layout below its design")
	_check(DotGameScreenFit.button_scale_for([], stretch, 44.0, Vector2(700, 662)) == 1.0, "no layout: 1")
	_check(DotGameScreenFit.button_scale_for(LAYOUT, stretch, 400.0, Vector2(120, 120)) == 1.0, "a layout already over the room stays at its design, never shrunk")
	var odd: Array[Dictionary] = [{"offset": Vector2(-20, -20), "radius": 30.0}, {"offset": Vector2(100, 200), "radius": 24.0}]
	var ko := DotGameScreenFit.button_scale_for(odd, stretch, 400.0, Vector2(700, 400))
	_check(is_equal_approx(ko, (400.0 - 28.0) / 224.0), "a negative offset: the reach is the far button's offset + radius")
	_done.append("buttons")


func _window() -> void:
	var root := get_tree().root
	var was := [root.content_scale_mode, root.content_scale_aspect, root.content_scale_size]
	_check(DotGameScreenFit.install(root, 0) == null and root.content_scale_aspect == was[1], "not wanted: null, the window untouched")
	var fit := DotGameScreenFit.new()
	fit.dpi_override = 96.0
	fit.size_override = Vector2(844, 390)
	fit.attach(root)
	_check(root.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_EXPAND, "attached: root aspect is expand")
	_check(root.content_scale_mode != Window.CONTENT_SCALE_MODE_DISABLED, "attached: the canvas is stretched")
	_check(root.content_scale_size.y == 720, "attached: the root canvas is 720 tall")
	_check(not fit.refit(), "the same size again changes nothing")
	var b := Buttons.new()
	add_child(b)
	var k := fit.fit_buttons(b, LAYOUT)
	_check(k > 1.0 and is_equal_approx(b.button_scale, k), "fit_buttons sets button_scale")
	fit.dpi_override = 460.0
	fit.size_override = Vector2(2532, 1170)
	fit.refit()
	_check(b.button_scale > k, "a refit resizes the buttons it was given")
	var one := b.button_scale
	root.content_scale_factor = 2.0
	fit.fit_buttons(b, LAYOUT)
	_check(absf(b.button_scale - one / 2.0) < 0.01, "content_scale_factor 2 halves the scale, got %.3f of %.3f" % [b.button_scale, one])
	root.content_scale_factor = 2.0
	fit.fit_buttons(b, LAYOUT)
	var at_two := b.button_scale
	root.content_scale_factor = 1.0
	fit.refit()
	_check(b.button_scale > at_two, "a changed content_scale_factor alone resizes the buttons on refit")
	var at_dpi := b.button_scale
	fit.dpi_override = 160.0
	fit.refit()
	_check(b.button_scale != at_dpi, "a changed DPI alone resizes the buttons on refit")
	fit.attach(root)
	_check(root.get_meta(DotGameScreenFit.META)["holders"] == 1, "attaching to the same window again does nothing")
	var second := DotGameScreenFit.new()
	second.size_override = Vector2(844, 390)
	second.attach(root)
	_check(second._saved["aspect"] == was[1] and second._saved["size"] == was[2], "a second fit keeps the original stretch, not the fitted one")
	second.detach()
	_check(root.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_EXPAND, "the first fit still holds after the second lets go")
	fit.detach()
	_check([root.content_scale_mode, root.content_scale_aspect, root.content_scale_size] == was, "detach restores the window")
	_check(fit._buttons.is_empty() and not root.has_meta(DotGameScreenFit.META), "detach forgets the buttons and the meta")
	b.free()
	_done.append("window")


func _safe() -> void:
	var root := get_tree().root
	var fit := DotGameScreenFit.new()
	fit.dpi_override = 96.0
	fit.size_override = Vector2(844, 390)
	fit.attach(root)
	var b := Buttons.new()
	var plain := fit.fit_buttons(b, LAYOUT)
	_check(fit.safe_insets()["right"] == 0.0 and fit.safe_insets()["bottom"] == 0.0 and b.margin == 28.0, "no notch: no insets, the margin untouched")
	fit.safe_area_override = Rect2i(0, 0, 844, 390)
	fit.refit()
	_check(fit.safe_insets()["left"] == 0.0 and b.margin == 28.0, "a safe area equal to the screen is a no-op")
	var per_unit := 390.0 / 720.0
	fit.safe_area_override = Rect2i(47, 0, 750, 356)
	fit.refit()
	var ins := fit.safe_insets()
	_check(absf(ins["left"] - 47.0 / per_unit) < 0.01 and absf(ins["right"] - 47.0 / per_unit) < 0.01 and absf(ins["bottom"] - 34.0 / per_unit) < 0.01 and ins["top"] == 0.0, "notch: insets are the cutout in canvas units")
	_check(b.margin > 28.0 and b.button_scale == plain, "notch: the block shifts in, the size is unchanged")
	var canvas := Vector2(fit.plan["size"])
	var inside := true
	for e in LAYOUT:
		var c: Vector2 = canvas - Vector2(b.margin, b.margin) - e["offset"] * b.button_scale
		var r: float = e["radius"] * b.button_scale
		inside = inside and c.x + r <= canvas.x - ins["right"] + 0.01 and c.y + r <= canvas.y - ins["bottom"] + 0.01 and c.x - r >= ins["left"] and c.y - r >= ins["top"]
	_check(inside, "notch: every button sits inside the safe rect")
	_check(b.button_scale * 48.0 * per_unit >= 43.99, "notch: the smallest button keeps the 44 px floor")
	var shifted := b.margin
	fit.refit()
	fit.fit_buttons(b, LAYOUT)
	_check(b.margin == shifted, "refitting and re-registering never stacks the shift")
	fit.safe_area_override = Rect2i(0, 0, 844, 390)
	fit.refit()
	_check(b.margin == 28.0, "the cutout going away gives the margin back")
	fit.size_override = Vector2(2532, 1170)
	fit.dpi_override = 460.0
	fit.safe_area_override = Rect2i(132, 0, 2268, 1100)
	fit.refit()
	var cut := fit.safe_insets()
	_check(absf(cut["left"] - 132.0 / (1170.0 / 720.0)) < 0.01 and cut["top"] == 0.0, "landscape cutout: left inset in canvas units at a dense phone")
	var limit_ok: bool = b.margin >= 28.0 and b.margin + (56.0 + 44.0) * b.button_scale < float(fit.plan["size"].x) - cut["left"]
	_check(b.margin > 28.0 and limit_ok, "landscape cutout: the margin grows for the bottom bar and the block stays clear of the cutout")
	_check(fit.describe().has("safe_insets"), "describe reports the safe insets")
	fit.safe_area_override = Rect2i(0, 0, 0, 0)
	_check(DotGameScreenFit.new().safe_insets()["left"] == 0.0, "an unattached fit has no insets")
	fit.detach()
	_done.append("safe")


func _client() -> void:
	var root := get_tree().root
	var was := [root.content_scale_mode, root.content_scale_aspect, root.content_scale_size]
	var on := _make_client(true, 1)
	_check(on.screen_fit != null and on.screen_fit.window == root, "touch: the client attaches a fit")
	_check(on.describe().has("screen_fit"), "describe reports the fit")
	var held := Buttons.new()
	on.fit_touch_buttons(held, LAYOUT)
	var fit := on.screen_fit
	on.free()
	_check([root.content_scale_mode, root.content_scale_aspect, root.content_scale_size] == was, "freeing the client restores the window's stretch")
	_check(fit.window == null and fit._buttons.is_empty(), "freeing the client drops the fit's window and buttons")
	held.free()
	var again := _make_client(true, 1)
	var moved := Buttons.new()
	again.fit_touch_buttons(moved, LAYOUT)
	var sized := moved.button_scale
	remove_child(again)
	_check(again.screen_fit.window == null, "leaving the tree detaches the fit")
	add_child(again)
	_check(again.screen_fit.window == root and root.get_meta(DotGameScreenFit.META)["holders"] == 1, "re-entering the tree reattaches once")
	_check(moved.button_scale == sized and sized > 1.0, "re-entering the tree sizes the remembered buttons again")
	moved.free()
	again.free()
	var late := _make_client(false, 1)
	var wait_b := Buttons.new()
	_check(late.fit_touch_buttons(wait_b, LAYOUT) == 1.0 and wait_b.button_scale == 1.0, "no fit yet: 1, buttons untouched")
	late.use_screen_fit = true
	late._attach_screen_fit()
	_check(wait_b.button_scale > 1.0, "a request made before the fit attached is applied when it does")
	wait_b.free()
	late.free()
	var off := _make_client(false, 1)
	var b := Buttons.new()
	_check(off.screen_fit == null and off.fit_touch_buttons(b, LAYOUT) == 1.0 and b.button_scale == 1.0, "use_screen_fit off: no fit, buttons left alone")
	b.free()
	off.free()
	var desk := _make_client(true, 0)
	_check(desk.screen_fit == null and root.content_scale_aspect == was[1], "no touch: no fit")
	desk.free()
	DotPlatform.touch_override = -1
	_done.append("client")


func _make_client(use_fit: bool, touch: int) -> DotGameClient:
	DotPlatform.touch_override = touch
	var c := DotGameClient.new()
	c.use_gate = false
	c.force_offline = true
	c.use_screen_fit = use_fit
	add_child(c)
	return c


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what)
