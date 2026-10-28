extends "selftest_extra.gd"

## The slide-sound and landing sections of game_selftest.gd.

class StubSlide:
	extends Node
	var enabled: bool = true
	var volume: float = 1.0
	var sliding: Array = []
	func keep(bodies: Array, sliding_of: Callable) -> void:
		sliding.clear()
		for b: Variant in bodies:
			if bool(sliding_of.call(b)):
				sliding.append(b)


class StubSlideState:
	extends RefCounted
	var on: bool = false
	func is_sliding() -> bool:
		return on


class StubController:
	extends Node
	var state := StubSlideState.new()


class StubSlideLink:
	extends Object
	signal replicated_cvar_changed(cvar_name: String, value: String)
	var cvars: Dictionary = {}
	func replicated_cvar(cvar_name: String, fallback: String) -> String:
		return String(cvars.get(cvar_name, fallback))


class StubSettings:
	extends Object
	signal changed(key: StringName, value: Variant, reason: StringName)
	var volume: float = 0.5
	func get_float(_key: StringName, _fallback: float = 0.0) -> float:
		return volume


class StubSchema:
	extends RefCounted
	var keys: Array = []
	func has(key: StringName) -> bool:
		return keys.has(key)
	func add(def: Variant) -> StubSchema:
		keys.append(def.key if def != null else &"?")
		return self


func _test_slide_sounds() -> void:
	_section("every client scrapes a slide: the server's switch, the player's volume, no per-game wiring")
	var Sounds: GDScript = load("res://addons/dot_game/runtime/dot_game_slide_sounds.gd")
	_check(Sounds.cvar_spec()["name"] == "sv_slide_sounds" and Sounds.cvar_spec()["value"] == "1", "the cvar defaults on")

	var link := StubSlideLink.new()
	link.cvars["sv_slide_sounds"] = "0"
	var settings := StubSettings.new()
	var slide := StubSlide.new()
	var node: Node = Sounds.new()
	node.slide = slide
	node.link_fn = func() -> Object: return link
	node.settings_fn = func() -> Object: return settings
	node.controller_fn = func(n: Node) -> bool: return n is StubController
	add_child(node)

	var body := Node3D.new()
	add_child(body)
	var controller := StubController.new()
	var idle := Node3D.new()
	add_child(idle)
	var idle_controller := StubController.new()
	idle.add_child(idle_controller)
	_check(node.start(), "it starts with a slide node supplied")
	body.add_child(controller)
	controller.state.on = true
	await _frames(2)
	_check(slide.sliding == [body], "a controller that enters later is followed, and only the sliding body is passed on", str(slide.sliding))
	_check(slide.enabled == false, "the server's cvar already off at connect silences it")
	_check(is_equal_approx(slide.volume, 0.5), "and the player's slide_volume is applied")
	link.replicated_cvar_changed.emit("sv_slide_sounds", "1")
	await _frames(1)
	_check(slide.enabled, "a replicated change switches it back on")
	settings.changed.emit(&"slide_volume", 0.2, &"applied")
	_check(is_equal_approx(slide.volume, 0.2), "a settings change moves the volume live")
	body.queue_free()
	await _frames(2)
	_check(node.bodies() == [idle], "a freed body is dropped", str(node.bodies()))

	var schema := StubSchema.new()
	Sounds.declare(schema)
	_check(schema.keys == [&"slide_volume"] or not ResourceLoader.exists(Sounds.DEF_SCRIPT), "declare adds slide_volume once to a schema")
	Sounds.declare(schema)
	_check(schema.keys.size() <= 1, "and never twice")
	_check(Sounds.is_controller(Node.new()) == false, "a plain node is no controller")

	node.queue_free()
	await _frames(2)
	link.free()
	settings.free()
	_done()


class StubLandingRules:
	extends RefCounted
	var volume: float = 0.6
	func volume_for(impact: float) -> float:
		return 0.0 if impact < 4.0 else volume


class StubLandingManager:
	extends Object
	var plays: Array = []
	func play_at(id: StringName, at: Vector3, scale: float) -> int:
		plays.append([id, at, scale])
		return 1


class StubLandingController:
	extends Node
	signal landed(impact: float)
	var view: Object = null


class StubKickView:
	extends Object
	var landing_strength: float = 1.0


class StubConsoleSource:
	extends Object
	var vars: Dictionary = {}
	func add_var(var_name: StringName, _help: String, get_fn: Callable, set_fn: Callable) -> void:
		vars[var_name] = [get_fn, set_fn]


func _test_landing() -> void:
	_section("every client thumps a landing and scales the camera kick: no per-game wiring")
	var Landing: GDScript = load("res://addons/dot_game/runtime/dot_game_landing.gd")
	var node: Node = Landing.new()
	var rules := StubLandingRules.new()
	var mgr := StubLandingManager.new()
	var view := StubKickView.new()
	node.rules = rules
	node.manager_fn = func() -> Object: return mgr
	node.id_fn = func(impact: float) -> StringName: return &"hard" if impact > 12.0 else &"light"
	node.controller_fn = func(n: Node) -> bool: return n is StubLandingController
	add_child(node)
	_check(node.start(), "it starts with rules supplied")
	var body := Node3D.new()
	add_child(body)
	body.global_position = Vector3(1, 2, 3)
	var controller := StubLandingController.new()
	controller.view = view
	body.add_child(controller)
	controller.landed.emit(15.0)
	_check(mgr.plays.size() == 1 and mgr.plays[0][0] == &"hard" and mgr.plays[0][1] == Vector3(1, 2, 3), "a landing plays the stock for its impact at the body", str(mgr.plays))
	_check(is_equal_approx(mgr.plays[0][2], 0.6), "scaled by the landing volume")
	controller.landed.emit(2.0)
	_check(mgr.plays.size() == 1, "a landing under the rules' minimum is silent")
	rules.volume = 0.0
	controller.landed.emit(15.0)
	_check(mgr.plays.size() == 1, "cl_landing_volume 0 mutes it")
	node.kick = 0.5
	_check(is_equal_approx(view.landing_strength, 0.5), "cl_landing_kick reaches the controller's view")
	var console := StubConsoleSource.new()
	_check(node.bind_console(console) and console.vars.has(&"cl_landing_volume") and console.vars.has(&"cl_landing_kick"), "both cvars register on a console source")
	console.vars[&"cl_landing_kick"][1].call("9")
	_check(is_equal_approx(node.kick, 2.0) and is_equal_approx(view.landing_strength, 2.0), "the kick cvar is clamped and applied live")
	_check(Landing.is_controller(Node.new()) == false, "a plain node is no controller")
	node.queue_free()
	body.queue_free()
	await _frames(2)
	mgr.free()
	view.free()
	console.free()
	_done()
