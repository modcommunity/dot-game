class_name DotGameMapEditBundle
extends RefCounted

## The map-data bundle as a plain dictionary: build one, and check an untrusted one.
##
## Stands in for dot-map's `DotMapDataBundle` until that lands; the shape is the plan's (dot-spawn `docs/map-data-tools.md`), so swapping the class changes no command.

const FORMAT := "dot-map-data"
const SCHEMA := 1
const SECTIONS: Array[String] = ["spawns", "nav_settings", "nav_links", "nav_annotations", "cull"]
const MAX_BYTES := 1048576
const MAX_STRING := 256
const MAX_ITEMS := 4096
const MAX_DEPTH := 8


static func make(game: String, map: Dictionary, by: String, sections: Dictionary, note: String = "") -> Dictionary:
	return {
		"format": FORMAT,
		"schema": SCHEMA,
		"game": game,
		"map": {
			"id": str(map.get("id", "")),
			"version": str(map.get("version", "")),
			"digest": str(map.get("digest", "")),
		},
		"meta": {"author": by, "created": int(Time.get_unix_time_from_system()), "note": note},
		"sections": sections.duplicate(true),
	}


## Parses and checks an imported file's text. On success `value` is `{bundle, warnings}`; a different map id is refused, a different version or digest is a warning the caller turns into a need for `force`.
static func check(text: String, map: Dictionary) -> DotResult:
	if text.length() > MAX_BYTES:
		return DotResult.fail(DotError.CODE_INVALID, "That file is too large for map data.")

	var json := JSON.new()
	var parsed: Variant = json.data if json.parse(text) == OK else null

	if not (parsed is Dictionary):
		return DotResult.fail(DotError.CODE_INVALID, "That file is not a map data bundle.")

	var raw: Dictionary = parsed

	if str(raw.get("format", "")) != FORMAT:
		return DotResult.fail(DotError.CODE_INVALID, "That file is not a map data bundle.", "format")

	var schema: Variant = raw.get("schema")

	if not (schema is float or schema is int) or int(schema) > SCHEMA or int(schema) < 1:
		return DotResult.fail(DotError.CODE_VERSION, "That bundle's schema is not one this server reads.")

	var theirs: Variant = raw.get("map")

	if not (theirs is Dictionary) or str((theirs as Dictionary).get("id", "")) != str(map.get("id", "")):
		return DotResult.fail(DotError.CODE_CONFLICT, "That bundle is for a different map.")

	var sections_raw: Variant = raw.get("sections", {})

	if not (sections_raw is Dictionary):
		return DotResult.fail(DotError.CODE_INVALID, "The bundle's sections are malformed.")

	var kept := {}
	var dropped := PackedStringArray()

	for key: Variant in (sections_raw as Dictionary):
		if not (str(key) in SECTIONS):
			dropped.append(str(key))
			continue

		var section: Variant = (sections_raw as Dictionary)[key]

		if not (section is Dictionary) or not _bounded(section, 0):
			return DotResult.fail(DotError.CODE_INVALID, "Section '%s' is malformed or over a limit." % str(key))

		kept[str(key)] = section

	var warnings := PackedStringArray()

	if str((theirs as Dictionary).get("version", "")) != str(map.get("version", "")):
		warnings.append("map version differs")

	var digest := str((theirs as Dictionary).get("digest", ""))

	if digest != "" and str(map.get("digest", "")) != "" and digest != str(map.get("digest", "")):
		warnings.append("geometry digest differs")

	if not dropped.is_empty():
		DotLog.warn("game.map_edit", "unknown bundle sections ignored", {"sections": ", ".join(dropped)})

	var meta: Variant = raw.get("meta", {})
	var meta_out := {}

	if meta is Dictionary:
		for k: String in ["author", "note"]:
			meta_out[k] = str((meta as Dictionary).get(k, "")).left(MAX_STRING)

	return DotResult.success({
		"bundle": {
			"format": FORMAT, "schema": SCHEMA, "game": str(raw.get("game", "")).left(MAX_STRING),
			"map": (theirs as Dictionary).duplicate(), "meta": meta_out, "sections": kept,
		},
		"warnings": warnings,
	})


## Every string and container within the caps, and nothing that is not plain data. A path or script is just text here and is never loaded.
static func _bounded(v: Variant, depth: int) -> bool:
	if depth > MAX_DEPTH:
		return false

	if v is String:
		return (v as String).length() <= MAX_STRING

	if v is float:
		return is_finite(v)

	if v is int or v is bool or v == null:
		return true

	if v is Array:
		if (v as Array).size() > MAX_ITEMS:
			return false

		for e: Variant in v:
			if not _bounded(e, depth + 1):
				return false

		return true

	if v is Dictionary:
		if (v as Dictionary).size() > MAX_ITEMS:
			return false

		for k: Variant in v:
			if not (k is String) or (k as String).length() > MAX_STRING or not _bounded((v as Dictionary)[k], depth + 1):
				return false

		return true

	return false
