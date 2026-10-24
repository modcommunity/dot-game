class_name DotGameConfigSchema
extends RefCounted

## What a [DotConfig]'s exported fields look like to a form: type, bounds, options, group and
## description, read from the property list and the doc comments.

const CHANNEL := "game.config"

## Fields of this type are not exposed (no scalar or list form).
const _TYPES := {
	TYPE_BOOL: "bool", TYPE_INT: "int", TYPE_FLOAT: "float", TYPE_STRING: "string",
	TYPE_STRING_NAME: "string", TYPE_PACKED_STRING_ARRAY: "list", TYPE_ARRAY: "list",
}


## One entry per exposed field, in declaration order. Keys: key, type, default, group,
## description, min, max, step, enum (allowed values), options ([{name, value}]).
static func of(config: DotConfig, skip: PackedStringArray = PackedStringArray()) -> Array:
	var docs := docs_of(config.get_script())
	var allowed := config.config_keys()
	var blocked := config.sensitive_keys()
	var out: Array = []
	var group := ""
	for prop: Dictionary in config.get_property_list():
		var usage: int = prop.get("usage", 0)
		if usage & PROPERTY_USAGE_GROUP:
			group = str(prop["name"])
			continue
		if usage & PROPERTY_USAGE_CATEGORY:
			group = ""
			continue
		var key := str(prop["name"])
		if not allowed.has(key) or skip.has(key) or blocked.has(key):
			continue
		var kind: String = _TYPES.get(int(prop["type"]), "")
		if kind == "":
			continue
		var entry := {"key": key, "type": kind, "group": group, "description": docs.get(key, "")}
		var def: Variant = config.get(key)
		entry["default"] = Array(def) if def is PackedStringArray else def
		_hint(entry, int(prop.get("hint", 0)), str(prop.get("hint_string", "")), kind)
		out.append(entry)
	return out


static func _hint(entry: Dictionary, hint: int, text: String, kind: String) -> void:
	if hint == PROPERTY_HINT_RANGE and (kind == "int" or kind == "float"):
		var parts := text.split(",")
		if parts.size() >= 2 and parts[0].is_valid_float() and parts[1].is_valid_float():
			entry["min"] = parts[0].to_float() if kind == "float" else parts[0].to_int()
			if not text.contains("or_greater"):
				entry["max"] = parts[1].to_float() if kind == "float" else parts[1].to_int()
			if parts.size() >= 3 and parts[2].is_valid_float():
				entry["step"] = parts[2].to_float()
		return
	if hint != PROPERTY_HINT_ENUM or (kind != "int" and kind != "string"):
		return
	var options: Array = []
	var next := 0
	for item in text.split(","):
		var name := item.strip_edges()
		var value: Variant = name
		if kind == "int":
			var colon := name.rfind(":")
			if colon >= 0:
				next = name.substr(colon + 1).to_int()
				name = name.substr(0, colon)
			value = next
			next += 1
		options.append({"name": name, "value": value})
	entry["options"] = options
	var values: Array = []
	for o in options:
		values.append(o["value"])
	entry["enum"] = values


## field name -> the first paragraph of its doc comment, read from the script source (and the
## scripts it extends). Empty where the source is not shipped; see [method DotGameConfigBinder.write_schema].
static func docs_of(script: Script) -> Dictionary:
	var out := {}
	var chain: Array[Script] = []
	var s := script
	while s != null:
		chain.push_front(s)
		s = s.get_base_script()
	var strip := RegEx.new()
	strip.compile("\\[/?(?:b|i|u|code|codeblock|br)\\]")
	var ref := RegEx.new()
	ref.compile("\\[(?:member|method|constant|param|enum|signal|class|annotation) ([^\\]]+)\\]")
	for sc in chain:
		var pending := PackedStringArray()
		for raw in sc.source_code.split("\n"):
			var line := raw.strip_edges()
			if line.begins_with("##"):
				pending.append(line.substr(2).strip_edges())
				continue
			if line.begins_with("@") and not line.contains(" var "):
				if line.begins_with("@export_group") or line.begins_with("@export_subgroup") or line.begins_with("@export_category"):
					pending.clear()
				continue
			var name := _var_name(line)
			if name != "" and not pending.is_empty():
				var text: String = " ".join(_first_paragraph(pending))
				text = strip.sub(text, "", true)
				text = ref.sub(text, "$1", true)
				out[name] = text.strip_edges()
			pending.clear()
	return out


static func _first_paragraph(lines: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for l in lines:
		if l == "":
			if not out.is_empty():
				break
			continue
		out.append(l)
	return out


static func _var_name(line: String) -> String:
	var at := line.find("var ")
	if at < 0 or not (line.begins_with("var ") or line.begins_with("@")):
		return ""
	var rest := line.substr(at + 4).strip_edges()
	var end := 0
	while end < rest.length() and (rest[end] == "_" or rest[end].to_lower() != rest[end].to_upper() or rest[end].is_valid_int()):
		end += 1
	return rest.substr(0, end)
