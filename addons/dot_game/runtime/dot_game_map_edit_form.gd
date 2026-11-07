class_name DotGameMapEditForm
extends VBoxContainer

## A form generated from a settings schema (dot-spawn's `DotSpawnPointDef.schema()`: entries in `DotProfileSet.field` shape), and the `key=value` words that turn an edit into `spawn_set`.
##
## It names no setting: a new field in the schema is a new row, and only the types `int`, `float`, `string`, `bool`, `vec3` and `list` are editable; `dict` and keys the commands do not take are shown read-only.

signal edited

## Schema names the commands call differently.
const ARG_NAMES := {"min_player_distance": "min_dist", "max_player_distance": "max_dist"}

## Keys never sent: they identify the point or are not settable by command.
const READ_ONLY: Array[String] = ["id", "source", "meta"]

var schema: Array = []

var _values: Dictionary = {}
var _original: Dictionary = {}
var _widgets: Dictionary = {}


## Builds the rows for [param p_schema] and fills them from [param p_values] (a point's `to_dict()`).
func build(p_schema: Array, p_values: Dictionary) -> void:
	schema = p_schema
	_clear()

	for entry: Variant in schema:
		if entry is Dictionary:
			_add_row(entry as Dictionary)

	set_values(p_values)


func set_values(p_values: Dictionary) -> void:
	_original = p_values.duplicate(true)
	_values = p_values.duplicate(true)

	for key: String in _widgets:
		_show(key, _values.get(key, _default_of(key)))


## The widget for a setting, or null; for a suite or a game that styles one row.
func widget(key: String) -> Control:
	return _widgets.get(key)


## The values as the widgets hold them now.
func values() -> Dictionary:
	var out := _original.duplicate(true)

	for key: String in _widgets:
		out[key] = _read(key)

	return out


## The `key=value` words for every editable setting that differs from what the form was filled with.
func changed_args() -> PackedStringArray:
	var out := PackedStringArray()
	var now := values()

	for entry: Variant in schema:
		var field := entry as Dictionary
		var key := str(field.get("name", ""))

		if not _widgets.has(key) or key in READ_ONLY:
			continue

		var before: Variant = _original.get(key, field.get("default"))

		if _same(before, now[key], str(field.get("type", ""))):
			continue

		out.append("%s=%s" % [ARG_NAMES.get(key, key), word(now[key], str(field.get("type", "")))])

	return out


## A value as the command parser reads it back.
static func word(v: Variant, type: String) -> String:
	match type:
		"bool":
			return "1" if bool(v) else "0"
		"vec3":
			var a := _vec(v)
			return "%s,%s,%s" % [_num(a.x), _num(a.y), _num(a.z)]
		"list":
			return ",".join(_strings(v))
		"int":
			return str(int(v))
		"float":
			return _num(float(v))

	return str(v)


static func _num(f: float) -> String:
	var text := "%.4f" % f
	return text.rstrip("0").rstrip(".") if text.contains(".") else text


static func _vec(v: Variant) -> Vector3:
	if v is Vector3:
		return v

	if v is Array and (v as Array).size() == 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))

	return Vector3.ZERO


static func _strings(v: Variant) -> PackedStringArray:
	var out := PackedStringArray()

	if v is Array or v is PackedStringArray:
		for x: Variant in v:
			out.append(str(x))

	return out


static func _same(a: Variant, b: Variant, type: String) -> bool:
	match type:
		"vec3":
			return _vec(a).distance_to(_vec(b)) < 0.001
		"float":
			return absf(float(a) - float(b)) < 0.001
		"list":
			return _strings(a) == _strings(b)

	return str(a) == str(b)


func _clear() -> void:
	_widgets.clear()

	for c in get_children():
		remove_child(c)
		c.queue_free()


func _default_of(key: String) -> Variant:
	for entry: Variant in schema:
		if (entry as Dictionary).get("name") == key:
			return (entry as Dictionary).get("default")

	return null


func _add_row(field: Dictionary) -> void:
	var key := str(field.get("name", ""))
	var type := str(field.get("type", ""))
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = key.replace("_", " ")
	label.custom_minimum_size.x = 150
	row.add_child(label)
	var editable := not (key in READ_ONLY) and type in ["int", "float", "string", "bool", "vec3", "list"]
	var w: Control = _widget_for(field, type, editable)
	w.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(w)
	add_child(row)
	_widgets[key] = w
	w.set_meta("type", type)


func _widget_for(field: Dictionary, type: String, editable: bool) -> Control:
	if not editable:
		var l := Label.new()
		l.clip_text = true
		return l

	var choices: Variant = field.get("choices", field.get("enum"))

	if choices is Array and not (choices as Array).is_empty():
		var o := OptionButton.new()

		for c: Variant in choices:
			o.add_item(str(c))

		o.item_selected.connect(func(_i: int) -> void: edited.emit())
		return o

	match type:
		"bool":
			var c := CheckBox.new()
			c.toggled.connect(func(_b: bool) -> void: edited.emit())
			return c
		"int", "float":
			return _spin(field, type == "int")
		"vec3":
			var h := HBoxContainer.new()

			for i in 3:
				var s := _spin({}, false)
				s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				h.add_child(s)

			return h

	var e := LineEdit.new()
	e.text_changed.connect(func(_t: String) -> void: edited.emit())
	return e


func _spin(field: Dictionary, whole: bool) -> SpinBox:
	var s := SpinBox.new()
	s.step = 1.0 if whole else 0.0001
	s.min_value = float(field.get("min", -100000.0))
	s.max_value = float(field.get("max", 100000.0))
	s.allow_greater = not field.has("max")
	s.allow_lesser = not field.has("min")
	s.value_changed.connect(func(_v: float) -> void: edited.emit())
	return s


func _show(key: String, v: Variant) -> void:
	var w: Control = _widgets[key]
	var type := str(w.get_meta("type", ""))

	if w is Label:
		(w as Label).text = str(v) if v != null else ""
	elif w is OptionButton:
		var o := w as OptionButton

		for i in o.item_count:
			if o.get_item_text(i) == str(v):
				o.select(i)
	elif w is CheckBox:
		(w as CheckBox).button_pressed = bool(v)
	elif w is SpinBox:
		(w as SpinBox).value = float(v)
	elif w is HBoxContainer:
		var a := _vec(v)

		for i in 3:
			(w.get_child(i) as SpinBox).value = a[i]
	elif w is LineEdit:
		(w as LineEdit).text = ",".join(_strings(v)) if type == "list" else str(v)


func _read(key: String) -> Variant:
	var w: Control = _widgets[key]
	var type := str(w.get_meta("type", ""))

	if w is Label:
		return _original.get(key, _default_of(key))

	if w is OptionButton:
		var o := w as OptionButton
		return o.get_item_text(o.selected) if o.selected >= 0 else ""

	if w is CheckBox:
		return (w as CheckBox).button_pressed

	if w is SpinBox:
		return int((w as SpinBox).value) if type == "int" else (w as SpinBox).value

	if w is HBoxContainer:
		return [(w.get_child(0) as SpinBox).value, (w.get_child(1) as SpinBox).value, (w.get_child(2) as SpinBox).value]

	var text := (w as LineEdit).text

	if type == "list":
		return Array(text.split(",", false))

	return text
