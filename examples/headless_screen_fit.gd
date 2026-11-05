extends Node

## DotGameScreenFit: the touch canvas plan, buttons sized in millimetres and capped to the screen, the root window fitted and restored, and DotGameClient's switch.

const EXPECTED_CHECKS := 28
const SECTIONS := ["plan", "buttons", "window", "client"]
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
	fit.detach()
	_check([root.content_scale_mode, root.content_scale_aspect, root.content_scale_size] == was, "detach restores the window")
	b.free()
	_done.append("window")


func _client() -> void:
	var root := get_tree().root
	var was := [root.content_scale_mode, root.content_scale_aspect, root.content_scale_size]
	var on := _make_client(true, 1)
	_check(on.screen_fit != null and on.screen_fit.window == root, "touch: the client attaches a fit")
	_check(on.describe().has("screen_fit"), "describe reports the fit")
	on.screen_fit.detach()
	on.free()
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
	remove_child(c)
	return c


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what)
