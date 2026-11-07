extends Node

## DotGameMapEditOverlay and DotGameMapEditForm: markers by kind, team and state, picking, the form built from a schema, and a form edit sent as commands and applied by the real DotGameMapEdit.

const CHECKS := 50

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _sent: Array[String] = []


func _schema() -> Array:
	var f := func(n: String, t: String, d: Variant, o: Dictionary = {}) -> Dictionary:
		var e := {"name": n, "type": t, "default": d}
		e.merge(o, true)
		return e
	return [
		f.call("id", "string", "point"),
		f.call("kind", "string", "both", {"choices": ["player", "npc", "both"]}),
		f.call("enabled", "bool", true),
		f.call("pos", "vec3", [0.0, 0.0, 0.0]),
		f.call("yaw", "float", 0.0),
		f.call("radius", "float", 0.0, {"min": 0.0}),
		f.call("team", "string", ""),
		f.call("classes", "list", []),
		f.call("group", "string", ""),
		f.call("weight", "float", 1.0, {"min": 0.0}),
		f.call("cooldown", "float", -1.0),
		f.call("max_alive", "int", 0, {"min": 0}),
		f.call("phases", "list", []),
		f.call("sight", "string", "any", {"choices": ["any", "hidden_from_players", "visible_to_players"]}),
		f.call("min_player_distance", "float", 0.0, {"min": 0.0}),
		f.call("max_player_distance", "float", 0.0, {"min": 0.0}),
		f.call("source", "string", "authored", {"choices": ["map", "authored", "generated"]}),
		f.call("meta", "dict", {}),
	]


func _point(id: String, kind: String, pos: Array, extra: Dictionary = {}) -> Dictionary:
	var d := {"id": id, "kind": kind, "enabled": true, "pos": pos, "yaw": 0.0, "radius": 0.0, "team": "", "classes": [],
		"group": "", "weight": 1.0, "cooldown": -1.0, "max_alive": 0, "phases": [], "sight": "any",
		"min_player_distance": 0.0, "max_player_distance": 0.0, "source": "authored", "meta": {}}
	d.merge(extra, true)
	return d


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what)


func _run() -> void:
	print("dot-game: map edit overlay")
	var ov := DotGameMapEditOverlay.new()
	ov.schema = _schema()
	ov.send_fn = func(line: String) -> void: _sent.append(line)
	add_child(ov)
	var pts := [
		_point("a", "player", [0, 0, 0]),
		_point("b", "npc", [10, 0, 0], {"radius": 4.0, "yaw": 1.0}),
		_point("c", "both", [0, 0, 10], {"enabled": false}),
		_point("d", "npc", [10, 0, 10], {"team": "red"}),
	]
	ov.set_points({"version": 1, "points": pts})
	_check(ov.marker_count() == 4, "one marker per point")
	_check(ov.color_of(pts[2]) == DotGameMapEditOverlay.DISABLED, "a disabled point is grey")
	_check(ov.color_of(pts[0]) != ov.color_of(pts[1]), "kinds differ in colour")
	_check(ov.color_of(pts[1]) != ov.color_of(pts[3]), "a team tints the colour")
	_check(ov.color_of(pts[3]) == ov.color_of(pts[3]), "a team colour is stable")
	ov.team_colors = {"red": Color.RED}
	_check(ov.color_of(pts[3]).r > ov.color_of(pts[1]).r - 0.001, "team_colors overrides the hash")
	_check(ov.marker(&"b").position == Vector3(10, 0, 0), "a marker sits at its point")
	var kids_a := ov.marker(&"a").get_child_count()
	var kids_b := ov.marker(&"b").get_child_count()
	_check(kids_b == kids_a + 1, "a radius adds a disc")
	var arrow := (ov.marker(&"a").get_child(1) as MeshInstance3D).mesh as ArrayMesh
	var verts: PackedVector3Array = arrow.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_check(verts.size() == 6 and verts[1].is_equal_approx(Vector3(0, 0.1, -1.2)), "yaw 0 faces forward (-Z)")
	var arrow_b := (ov.marker(&"b").get_child(1) as MeshInstance3D).mesh as ArrayMesh
	var vb: PackedVector3Array = arrow_b.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_check(vb.size() == 6 + DotGameMapEditOverlay.RING_SEGMENTS * 2 and vb[1].x < -0.9, "yaw turns the arrow and a radius adds a ring")

	ov.set_links({"links": {"hop": {"id": "hop", "kind": "jump", "a": [0, 0, 0], "b": [3, 1, 0]}, "bad": {"a": [1]}}})
	_check(ov.get_node("Markers").get_child_count() == 5, "a link is one line; a malformed one is skipped")
	ov.set_links([{"id": "x", "a": [0, 0, 0], "b": [1, 0, 0]}])
	_check(ov.get_node("Markers").get_child_count() == 5, "links also come as an array")
	ov.show_links = false
	ov.set_links({})
	_check(ov.get_node("Markers").get_child_count() == 4, "no links, no lines")
	ov.nav_mesh = BoxMesh.new()
	ov.show_mesh = true
	_check(ov.get_node("Markers").get_child_count() == 5, "the mesh is drawn on request")
	ov.show_mesh = false
	await get_tree().process_frame
	_check(ov.get_node("Markers").get_child_count() == 4, "and goes away again")

	ov.set_points([_point("ok", "both", [1, 2, 3]), {"id": "nopos"}, {"pos": "x"}, 5, null])
	_check(ov.marker_count() == 3 or ov.marker_count() == 2, "hostile entries do not crash")
	ov.set_points({"points": pts})
	var cam_from := Vector3(0, 0.9, 20)
	_check(ov.pick_ray(cam_from, Vector3(0, 0, -1)) == &"c", "a ray picks the nearest marker along it")
	_check(ov.pick_ray(Vector3(0, 0.9, -5), Vector3(0, 0, 1)) == &"a", "from the other side it picks the other")
	_check(ov.pick_ray(Vector3(5, 0.9, 5), Vector3(0, 1, 0)) == &"", "a miss picks nothing")
	_check(ov.pick_ray(Vector3(10, 0.9, 30), Vector3(0, 0, -1), 5.0) == &"", "beyond the distance picks nothing")
	_check(ov.pick_ray(Vector3(0.5, 0.9, 20), Vector3(0, 0, -1)) == &"c", "within the pick size counts")

	var seen := []
	ov.picked.connect(func(id: StringName) -> void: seen.append(id))
	_check(not ov.open_panel(&"ghost"), "an unknown id opens nothing")
	_check(ov.open_panel(&"b") and ov.panel.visible and seen == [&"b"], "opening shows the panel")
	var form := ov.form
	_check(form.get_child_count() == _schema().size(), "one row per schema entry")
	_check(form.widget("weight") is SpinBox and form.widget("enabled") is CheckBox and form.widget("kind") is OptionButton, "widgets follow the types")
	_check(form.widget("pos") is HBoxContainer and form.widget("classes") is LineEdit and form.widget("meta") is Label, "vec3, list and dict")
	_check(ov.apply() == "" and _sent.is_empty(), "no change sends nothing")
	_check(form.changed_args().is_empty(), "an untouched form has no arguments")
	var kind: OptionButton = form.widget("kind")
	_check(kind.get_item_text(kind.selected) == "npc", "an enum shows the point's value")
	_check((form.widget("radius") as SpinBox).value == 4.0, "a number shows the point's value")
	_check((ov.get_node("Markers").get_child_count()) == 4 and ov.selected == &"b", "the picked point is selected")
	var ring := (ov.marker(&"b").get_child(1) as MeshInstance3D).mesh as ArrayMesh
	var rv: PackedVector3Array = ring.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_check(rv.size() == 6 + DotGameMapEditOverlay.RING_SEGMENTS * 4, "the selected marker has a highlight ring")

	var extra := _schema()
	extra.append({"name": "brand_new", "type": "float", "default": 2.5})
	var f2 := DotGameMapEditForm.new()
	f2.build(extra, _point("z", "both", [0, 0, 0], {"brand_new": 3.0}))
	_check(f2.widget("brand_new") is SpinBox and (f2.widget("brand_new") as SpinBox).value == 3.0, "a new schema field is a new row with no UI change")
	(f2.widget("brand_new") as SpinBox).value = 4.0
	_check(f2.changed_args() == PackedStringArray(["brand_new=4"]), "and its edit becomes an argument")
	f2.free()

	# The round trip: edit the form, send the line, let the real command set apply it.
	var fakes: Dictionary = (load("res://examples/headless_mapedit.gd") as GDScript).get_script_constant_map()
	var host: RefCounted = fakes["Host"].new()
	var edit := DotGameMapEdit.new()
	edit.server = fakes["FakeServer"].new()
	edit.points = fakes["PointSet"].new()
	edit.def_factory = func() -> Object: return fakes["Def"].new()
	edit.pose_fn = func(_c: Object) -> Dictionary: return {"position": Vector3(1, 2, 3), "yaw": 0.5}
	edit.map_fn = func() -> Dictionary: return {"game": "tg", "id": "dm_box", "version": "3", "digest": ""}
	var _b := edit.bind(host)
	var ctx0: RefCounted = fakes["Ctx"].new()
	ctx0.args = PackedStringArray(["npc", "id=b"])
	await host.commands["spawn_add"].handler.call(ctx0)

	(form.widget("kind") as OptionButton).select(2)
	(form.widget("enabled") as CheckBox).button_pressed = false
	((form.widget("pos") as HBoxContainer).get_child(0) as SpinBox).value = 7.25
	(form.widget("weight") as SpinBox).value = 2.5
	(form.widget("max_alive") as SpinBox).value = 3
	(form.widget("classes") as LineEdit).text = "grunt,brute"
	(form.widget("team") as LineEdit).text = "blue"
	var sight: OptionButton = form.widget("sight")
	sight.select(1)
	(form.widget("min_player_distance") as SpinBox).value = 4.5
	(form.widget("max_player_distance") as SpinBox).value = 9.0
	var line := ov.apply()
	_check(line.begins_with("spawn_set b ") and _sent == [line], "apply sends one spawn_set for the point")
	_check("kind=both" in line and "enabled=0" in line and "pos=7.25,0,0" in line and "weight=2.5" in line, "changed settings are words")
	_check("min_dist=4.5" in line and "max_dist=9" in line, "long names use the command's short ones")
	_check(not ("id=" in line) and not ("source=" in line) and not ("meta=" in line) and not ("radius=" in line), "read-only and unchanged settings are left out")
	var ctx: RefCounted = fakes["Ctx"].new()
	ctx.args = PackedStringArray(line.split(" ").slice(1))
	await host.commands["spawn_set"].handler.call(ctx)
	var def: Object = edit.points.find(&"b")
	_check(ctx.last().begins_with("Updated"), "the command set accepts the form's line")
	_check(def.kind == &"both" and not def.enabled and def.position == Vector3(7.25, 0, 0), "kind, enabled and position round trip")
	_check(def.weight == 2.5 and def.max_alive == 3 and def.team == &"blue", "numbers and text round trip")
	_check(def.classes == [&"grunt", &"brute"] and def.sight == &"hidden_from_players", "a list and an enum round trip")
	_check(def.min_player_distance == 4.5 and def.max_player_distance == 9.0, "renamed distances round trip")

	_sent.clear()
	_check(ov.toggle_selected() == "spawn_toggle b" and ov.test_selected() == "spawn_test b" and ov.remove_selected() == "spawn_remove b", "the buttons send their commands")
	_check(_sent.size() == 3, "send_fn receives each")
	ov.command_prefix = "me_"
	_check(ov.toggle_selected() == "me_spawn_toggle b", "the command prefix is applied")
	ov.command_prefix = ""
	ov.close_panel()
	_check(not ov.panel.visible and ov.selected == &"" and ov.toggle_selected() == "", "closing deselects, and nothing is sent without a selection")
	ov.open_panel(&"a")
	ov.set_points({"points": [pts[1]]})
	_check(not ov.panel.visible, "a point that vanishes closes its panel")
	_check(DotGameMapEditForm.word(true, "bool") == "1" and DotGameMapEditForm.word([1, 2.5, 3], "vec3") == "1,2.5,3", "word formats bool and vec3")
	_check(DotGameMapEditForm.word([&"a", &"b"], "list") == "a,b", "word formats lists")
	ov.queue_free()
	await get_tree().process_frame

	print("map edit overlay: %d passed, %d failed (expected %d checks)" % [_passed, _failed, CHECKS])
	for f in _failures:
		print("  FAIL: ", f)
	var ok := _failed == 0 and _passed == CHECKS
	get_tree().quit(0 if ok else 1)
