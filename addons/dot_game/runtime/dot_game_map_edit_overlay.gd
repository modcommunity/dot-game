class_name DotGameMapEditOverlay
extends Node3D

## The admin's view of a map's spawn points and navigation links, and a form to edit a point by looking at it.
##
## Markers are coloured by kind and team, with a disc for the radius, an arrow for the facing and grey when disabled. A point picked by looking opens a form built from the point definition's own schema; its buttons send the [DotGameMapEdit] commands through [member send_fn], so the server validates and logs every edit and the overlay holds no rules.
##
## Data comes in as dictionaries (`DotSpawnPointSet.to_dict()` and `links_dict()`), so a client can feed it from a replicated copy and dot-game names no addon. The game places it in the world, supplies [member schema] and [member send_fn], and keeps the mouse free while the panel is open.

signal picked(id: StringName)
signal command_sent(line: String)

const KIND_COLORS := {"player": Color(0.25, 0.55, 1.0), "npc": Color(1.0, 0.35, 0.3), "both": Color(0.75, 0.4, 1.0)}
const DISABLED := Color(0.5, 0.5, 0.5)
const POLE := 1.8
const PICK_RADIUS := 0.7
const RING_SEGMENTS := 48

## `DotSpawnPointDef.schema()`: the form is built from it.
var schema: Array = []

## `func(line: String)`: sends a command line (without any prefix) to the server.
var send_fn: Callable = Callable()

## Prepended to every command sent, matching [member DotGameMapEdit.prefix].
var command_prefix: String = ""

## `team` -> Color; a team not listed gets a hue from its name.
var team_colors: Dictionary = {}

## Drawn translucent when set and [member show_mesh] is on.
var nav_mesh: Mesh = null

var show_links: bool = true
var show_mesh: bool = false: set = _set_show_mesh

var selected: StringName = &""
var panel: PanelContainer = null
var form: DotGameMapEditForm = null

var _points: Array = []
var _links: Array = []
var _markers: Dictionary = {}
var _root: Node3D = null
var _mesh_node: MeshInstance3D = null
var _layer: CanvasLayer = null


func _ready() -> void:
	_root = Node3D.new()
	_root.name = "Markers"
	add_child(_root)
	_rebuild()


## Replaces the markers from a point set's `to_dict()` (`{"points": [...]}`) or a plain array of point dictionaries.
func set_points(data: Variant) -> void:
	var list: Variant = (data as Dictionary).get("points", []) if data is Dictionary else data
	_points = []

	if list is Array:
		for p: Variant in list:
			if p is Dictionary:
				_points.append(p)

	if selected != &"" and find_point(selected).is_empty():
		close_panel()

	_rebuild()


## Replaces the link lines from `links_dict()` (`{"links": {id: link}}`) or an array of links with `a` and `b` ends.
func set_links(data: Variant) -> void:
	var list: Variant = (data as Dictionary).get("links", []) if data is Dictionary else data
	_links = []

	for l: Variant in (list as Dictionary).values() if list is Dictionary else (list as Array if list is Array else []):
		if l is Dictionary:
			_links.append(l)

	_rebuild()


func find_point(id: StringName) -> Dictionary:
	for p: Dictionary in _points:
		if StringName(str(p.get("id", ""))) == id:
			return p

	return {}


func marker_count() -> int:
	return _markers.size()


## The marker node for a point, or null.
func marker(id: StringName) -> Node3D:
	return _markers.get(id)


## The color a point is drawn in.
func color_of(p: Dictionary) -> Color:
	if not bool(p.get("enabled", true)):
		return DISABLED

	var c: Color = KIND_COLORS.get(str(p.get("kind", "both")), KIND_COLORS["both"])
	var team := str(p.get("team", ""))

	if team != "":
		c = c.lerp(_team_color(team), 0.5)

	return c


## The point whose marker is nearest to the ray, within the marker's pick size, or an empty id.
func pick_ray(origin: Vector3, dir: Vector3, max_distance: float = 300.0) -> StringName:
	var best := &""
	var best_t := INF
	var d := dir.normalized()

	for p: Dictionary in _points:
		var at := _centre(p)
		var t := clampf((at - origin).dot(d), 0.0, max_distance)
		var miss := (origin + d * t).distance_to(at)

		if miss <= PICK_RADIUS and t < best_t:
			best_t = t
			best = StringName(str(p.get("id", "")))

	return best


## Picks along the current camera's view and opens the panel on the hit.
func pick_from_camera() -> StringName:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null

	if cam == null:
		return &""

	var id := pick_ray(cam.global_position, -cam.global_basis.z)

	if id != &"":
		open_panel(id)

	return id


func open_panel(id: StringName) -> bool:
	var p := find_point(id)

	if p.is_empty():
		return false

	selected = id
	_ensure_panel()
	(panel.get_node("Box/Title") as Label).text = "Spawn point %s" % id
	form.build(schema, p)
	panel.visible = true
	_rebuild()
	picked.emit(id)
	return true


func close_panel() -> void:
	selected = &""

	if panel != null:
		panel.visible = false

	if is_inside_tree():
		_rebuild()


## Sends `spawn_set` with what the form changed. Returns the line, or "" when nothing changed.
func apply() -> String:
	if selected == &"" or form == null:
		return ""

	var args := form.changed_args()

	if args.is_empty():
		return ""

	return _send("spawn_set %s %s" % [selected, " ".join(args)])


func toggle_selected() -> String:
	return _send("spawn_toggle %s" % selected) if selected != &"" else ""


func remove_selected() -> String:
	return _send("spawn_remove %s" % selected) if selected != &"" else ""


func test_selected() -> String:
	return _send("spawn_test %s" % selected) if selected != &"" else ""


func describe() -> String:
	return "DotGameMapEditOverlay(points=%d, links=%d, selected=%s)" % [_points.size(), _links.size(), selected]


func _send(line: String) -> String:
	var full := command_prefix + line

	if send_fn.is_valid():
		send_fn.call(full)

	command_sent.emit(full)
	return full


func _team_color(team: String) -> Color:
	if team_colors.has(team):
		return team_colors[team]

	return Color.from_hsv(float(team.hash() % 360) / 360.0, 0.7, 1.0)


func _centre(p: Dictionary) -> Vector3:
	return _pos(p) + Vector3.UP * POLE * 0.5


func _pos(p: Dictionary) -> Vector3:
	var a: Variant = p.get("pos")
	return Vector3(float(a[0]), float(a[1]), float(a[2])) if a is Array and (a as Array).size() == 3 else Vector3.ZERO


func _rebuild() -> void:
	if _root == null:
		return

	for c in _root.get_children():
		_root.remove_child(c)
		c.queue_free()

	_markers.clear()

	for p: Dictionary in _points:
		var id := StringName(str(p.get("id", "")))
		var m := _build_marker(p, id == selected)
		_root.add_child(m)
		m.position = _pos(p)
		_markers[id] = m

	if show_links:
		for l: Dictionary in _links:
			var line := _link_line(l)

			if line != null:
				_root.add_child(line)

	_set_show_mesh(show_mesh)


func _build_marker(p: Dictionary, chosen: bool) -> Node3D:
	var m := Node3D.new()
	m.name = "P_%s" % str(p.get("id", ""))
	var col := color_of(p)
	var pole := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.05
	cyl.bottom_radius = 0.18
	cyl.height = POLE
	pole.mesh = cyl
	pole.position.y = POLE * 0.5
	pole.material_override = _mat(Color(col, 0.9 if bool(p.get("enabled", true)) else 0.4))
	m.add_child(pole)
	var lines := PackedVector3Array()
	var yaw := float(p.get("yaw", 0.0))
	var fwd := Basis(Vector3.UP, yaw) * Vector3.FORWARD
	var side := fwd.cross(Vector3.UP)
	var tip := fwd * 1.2 + Vector3.UP * 0.1
	lines.append_array([Vector3.UP * 0.1, tip, tip, tip - fwd * 0.35 + side * 0.2, tip, tip - fwd * 0.35 - side * 0.2])
	var radius := float(p.get("radius", 0.0))

	if radius > 0.0:
		_ring(lines, radius, 0.05)

	if chosen:
		_ring(lines, 0.6, POLE + 0.1)

	var drawn := MeshInstance3D.new()
	drawn.mesh = _line_mesh(lines)
	drawn.material_override = _mat(Color.WHITE if chosen else col, true)
	m.add_child(drawn)

	if radius > 0.0:
		var disc := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = radius
		cm.bottom_radius = radius
		cm.height = 0.02
		cm.radial_segments = RING_SEGMENTS
		disc.mesh = cm
		disc.position.y = 0.04
		disc.material_override = _mat(Color(col, 0.18))
		m.add_child(disc)

	return m


func _link_line(l: Dictionary) -> MeshInstance3D:
	var a: Variant = l.get("a")
	var b: Variant = l.get("b")

	if not (a is Array and b is Array and (a as Array).size() == 3 and (b as Array).size() == 3):
		return null

	var pa := Vector3(float(a[0]), float(a[1]), float(a[2]))
	var pb := Vector3(float(b[0]), float(b[1]), float(b[2]))
	var mi := MeshInstance3D.new()
	mi.name = "L_%s" % str(l.get("id", ""))
	mi.mesh = _line_mesh(PackedVector3Array([pa, pb]))
	mi.material_override = _mat(Color(1.0, 0.85, 0.2), true)
	return mi


func _ring(lines: PackedVector3Array, r: float, y: float) -> void:
	for i in RING_SEGMENTS:
		var a0 := TAU * float(i) / RING_SEGMENTS
		var a1 := TAU * float(i + 1) / RING_SEGMENTS
		lines.append(Vector3(cos(a0) * r, y, sin(a0) * r))
		lines.append(Vector3(cos(a1) * r, y, sin(a1) * r))


func _line_mesh(verts: PackedVector3Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh


func _mat(c: Color, line: bool = false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.no_depth_test = true
	m.render_priority = 10
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if c.a < 1.0 and not line else BaseMaterial3D.TRANSPARENCY_DISABLED
	return m


func _set_show_mesh(on: bool) -> void:
	show_mesh = on

	if _root == null:
		return

	if _mesh_node != null and is_instance_valid(_mesh_node):
		_mesh_node.queue_free()

	_mesh_node = null

	if on and nav_mesh != null:
		_mesh_node = MeshInstance3D.new()
		_mesh_node.mesh = nav_mesh
		var m := _mat(Color(0.2, 0.9, 0.5, 0.25))
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mesh_node.material_override = m
		_root.add_child(_mesh_node)


func _ensure_panel() -> void:
	if panel != null:
		return

	_layer = CanvasLayer.new()
	_layer.layer = 90
	add_child(_layer)
	panel = PanelContainer.new()
	panel.name = "Panel"
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.offset_left = -430.0
	panel.offset_right = -10.0
	panel.offset_top = 10.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	var back := StyleBoxFlat.new()
	back.bg_color = Color(0.09, 0.1, 0.13, 0.96)
	back.set_content_margin_all(10.0)
	back.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", back)
	_layer.add_child(panel)
	var box := VBoxContainer.new()
	box.name = "Box"
	panel.add_child(box)
	var title := Label.new()
	title.name = "Title"
	box.add_child(title)
	form = DotGameMapEditForm.new()
	form.name = "Form"
	box.add_child(form)
	var buttons := HBoxContainer.new()
	box.add_child(buttons)

	for spec: Array in [["Apply", apply], ["Enable / disable", toggle_selected], ["Test here", test_selected],
			["Remove", remove_selected], ["Close", close_panel]]:
		var b := Button.new()
		b.text = spec[0]
		var fn: Callable = spec[1]
		b.pressed.connect(func() -> void: fn.call())
		buttons.add_child(b)
