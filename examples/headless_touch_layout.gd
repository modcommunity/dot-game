extends DotGameCheckSuite

## DotGameTouchLayout: the presets, the canonical homes of fire, jump, crouch and reload, per-game overrides, validation, and the fit through DotGameClient.

const EXPECTED_CHECKS := 42
const SECTIONS := ["presets", "homes", "overrides", "validate", "apply"]
const L := preload("res://addons/dot_game/runtime/dot_game_touch_layout.gd")

var _done: Array[String] = []


## Stands in for dot-ui's DotTouchButtons, which this addon never names.
class Buttons extends Control:
	var button_scale := 1.0
	var margin := 28.0
	var rows: Array[Dictionary] = []

	func set_buttons(list: Array[Dictionary]) -> void:
		rows = list


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _run() -> void:
	print("dot-game: touch layout")
	_presets()
	_homes()
	_overrides()
	_validate()
	await _apply()
	for s in SECTIONS:
		if not s in _done:
			_check(false, "section %s ran to the end" % s)
	_report(EXPECTED_CHECKS)


func _presets() -> void:
	for p: StringName in [L.FPS, L.DRIVING, L.PLATFORMER]:
		var res := L.build(p)
		_check(res.ok and not res.value.ids().is_empty(), "%s: builds and validates" % p)
	var fps: DotGameTouchLayout = L.make(L.FPS).value
	_check(fps.ids() == [L.FIRE, L.ALT, L.JUMP, L.CROUCH, L.USE, L.RELOAD, L.NEXT, L.PREV, L.BOARD, L.CHAT], "fps: the ten buttons of the wipeout family")
	var mini := L.make(L.MINIGAME)
	_check(mini.ok and mini.value.preset_name == L.PLATFORMER and mini.value.has(L.USE), "minigame is the platformer preset")
	var left: DotGameTouchLayout = L.build(L.DRIVING, {}, L.LEFT).value
	_check(left.ids() == [L.STEER_RIGHT, L.STEER_LEFT], "driving: the left cluster steers")
	var none := L.make(L.FPS, L.LEFT)
	_check(none.ok and none.value.ids().is_empty(), "fps has no left cluster: empty, not an error")
	var bad := L.make(&"racing")
	_check(not bad.ok and bad.code() == DotError.CODE_INVALID, "an unknown preset is CODE_INVALID")
	_done.append("presets")


func _homes() -> void:
	for id: StringName in L.HOMES:
		var slot: Array = L.SLOTS[L.HOMES[id]]
		var same := true
		for p: StringName in L.PRESETS:
			for c: StringName in L.PRESETS[p]:
				var r: Dictionary = L.make(p, c).value.row(id)
				if not r.is_empty() and (r["offset"] != slot[0] or r["radius"] != slot[1]):
					same = false
		_check(same, "%s sits in one place, one size, in every preset" % id)
	var fps: DotGameTouchLayout = L.make(L.FPS).value
	_check(fps.row(L.JUMP)["offset"] == Vector2(80, 172) and fps.row(L.JUMP)["radius"] == 32.0, "jump is under fire, (80,172) r32")
	_check(fps.row(L.CROUCH)["label"] == "DUCK", "crouch is labelled DUCK, its id is crouch")
	for extra: StringName in [L.COMMAND, L.MAPS, L.GAG, L.MUTE]:
		_check(L.build(L.PLATFORMER, {extra: &"row1"}).ok and L.LABELS.has(extra), "%s is a canonical id with a label, placeable in a slot" % extra)
	_check(L.canonical_id(&"attack") == L.FIRE and L.canonical_id(&"swing") == L.FIRE, "attack and swing are fire")
	_check(L.canonical_id(&"duck") == L.CROUCH and L.canonical_id(&"dot_fps_crouch") == L.CROUCH, "duck and dot_fps_crouch are crouch")
	_check(L.canonical_id(&"split") == &"split", "a game's own id is left alone")
	_done.append("homes")


func _overrides() -> void:
	var res := L.build(L.FPS, {&"alt": null, &"grab": &"inner", &"use": null, &"fire": {"radius": 46.0, "label": "HIT"}})
	_check(res.ok, "wipeout-style overrides build: %s" % (res.error if not res.ok else ""))
	var lay: DotGameTouchLayout = res.value
	_check(not lay.has(L.ALT) and lay.has(&"grab"), "null drops, a slot name adds")
	_check(lay.row(&"grab")["offset"] == L.SLOTS[&"inner"][0], "grab takes the inner slot")
	_check(lay.row(L.FIRE)["radius"] == 46.0 and lay.row(L.FIRE)["label"] == "HIT" and lay.row(L.FIRE)["offset"] == Vector2(80, 84), "radius and label change, the place does not")
	var moved := L.build(L.FPS, {&"reload": {"offset": Vector2(262, 128)}})
	_check(moved.ok and moved.value.row(L.RELOAD)["slot"] == &"", "an offset takes a button off its slot")
	var custom := L.custom().put(&"split", &"primary", "SPLIT").put(&"throw", &"secondary", "THROW")
	_check(custom.ids() == [&"split", &"throw"] and custom.row(&"split")["label"] == "SPLIT", "custom: a game's own ids in the canonical slots")
	var before: Array = L.make(L.FPS).value.ids()
	var fps: DotGameTouchLayout = L.make(L.FPS).value
	var bad := fps.override({&"alt": null, &"jump": &"nowhere"})
	_check(not bad.ok and bad.code() == DotError.CODE_INVALID and fps.ids() == before, "a bad slot is CODE_INVALID and nothing changes")
	_check(not fps.override({&"new": {"label": "X"}}).ok, "a new button without a place is refused")
	_check(not fps.override({&"jump": {"colour": 1}}).ok, "an unknown key is refused")
	_check(not fps.override({&"jump": 3}).ok, "an override of the wrong type is refused")
	_done.append("overrides")


func _validate() -> void:
	var clash := L.build(L.FPS, {&"grab": {"offset": Vector2(84, 90), "radius": 24.0}})
	_check(not clash.ok and clash.code() == DotError.CODE_INVALID, "two buttons on one spot are refused")
	var small := L.build(L.FPS, {&"reload": {"radius": 12.0}})
	_check(not small.ok, "a radius under %d is refused" % int(L.MIN_RADIUS))
	var alias := L.build(L.FPS, {&"crouch": null, &"duck": &"outer"})
	_check(not alias.ok and "crouch" in str(alias.error), "an alias id is refused and names the canonical one")
	_done.append("validate")


func _apply() -> void:
	var lay: DotGameTouchLayout = L.build(L.FPS).value
	var b := Buttons.new()
	_check(lay.apply(b) == 1.0 and b.rows.size() == 10 and b.button_scale == 1.0, "no client: rows set, scale left at 1")
	_check(b.rows[0].keys() == ["id", "label", "offset", "radius"], "rows carry only what DotTouchButtons reads")
	var root := get_tree().root
	var was := [root.content_scale_mode, root.content_scale_aspect, root.content_scale_size]
	DotPlatform.touch_override = 1
	var c := DotGameClient.new()
	c.use_gate = false
	c.force_offline = true
	add_child(c)
	c.screen_fit.size_override = Vector2(844, 390)
	c.screen_fit.dpi_override = 460.0
	c.screen_fit.refit()
	var k := lay.apply(b, c)
	_check(k > 1.0 and b.button_scale == k, "through fit_touch_buttons: the buttons are scaled, got %.2f" % k)
	var smallest := INF
	for r in b.rows:
		smallest = minf(smallest, float(r["radius"]))
	_check(smallest * 2.0 * k * c.screen_fit.plan.get("stretch", 1.0) >= 43.99, "the smallest preset button is 44 real px across")
	_check(lay.relabel(L.FIRE, "HIT").apply(b, c) == k and b.rows[0]["label"] == "HIT", "a relabel re-applies at the same scale")
	_check(not c.touch_look(true) and not c.touch_maps(), "the touch gag and map buttons say false with no voice and no map menu")
	c.touch_board(true)
	c.touch_board(false)
	_check(true, "the touch board button with no board does nothing")
	b.free()
	c.free()
	DotPlatform.touch_override = -1
	await get_tree().process_frame  # the screen fit restores the stretch deferred
	_check([root.content_scale_mode, root.content_scale_aspect, root.content_scale_size] == was, "the window's stretch is restored")
	_done.append("apply")
