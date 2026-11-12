extends RefCounted

## [DotGameMapEdit]'s key=value parsing: every value typed, range-checked and finite before it reaches a def. No class_name: the edit preloads it.


static func parse_pairs(args: PackedStringArray) -> DotResult:
	var out := {}

	for a in args:
		var at := a.find("=")

		if at <= 0:
			return DotResult.fail(DotError.CODE_INVALID, "Write settings as key=value, not '%s'." % a.left(DotGameMapEdit.MAX_TEXT))

		out[a.left(at).to_lower()] = a.substr(at + 1)

	return DotResult.success(out)


## Parses key=value words into typed values. [param allow_id] lets `id=` through (a new point only).
static func parse_settings(args: PackedStringArray, allow_id: bool) -> DotResult:
	var pairs := parse_pairs(args)

	if not pairs.ok:
		return pairs

	var out := {}

	for key: String in pairs.value:
		var raw: String = pairs.value[key]

		if key == "id" and allow_id:
			if not token_ok(raw):
				return DotResult.fail(DotError.CODE_INVALID, "A point id is up to %d lowercase letters, digits, _ or -." % DotGameMapEdit.MAX_TEXT)

			out["id"] = raw
			continue

		if not DotGameMapEdit.KEYS.has(key):
			return DotResult.fail(DotError.CODE_INVALID, "'%s' is not a spawn setting (%s)." % [key.left(DotGameMapEdit.MAX_TEXT), ", ".join(DotGameMapEdit.KEYS.keys())])

		var parsed := parse_value(key, raw)

		if not parsed.ok:
			return parsed

		out[key] = parsed.value

	return DotResult.success(out)


static func parse_value(key: String, raw: String) -> DotResult:
	var spec: Array = DotGameMapEdit.KEYS[key]
	var type := str(spec[0])
	var bad := DotResult.fail(DotError.CODE_INVALID, "%s=%s is not a valid %s." % [key, raw.left(DotGameMapEdit.MAX_TEXT), key])

	match type:
		"b":
			if raw in ["1", "true", "on", "yes"]:
				return DotResult.success(true)
			return DotResult.success(false) if raw in ["0", "false", "off", "no"] else bad
		"f":
			if not raw.is_valid_float() or not is_finite(raw.to_float()):
				return bad
			return ranged(key, raw.to_float(), spec)
		"i":
			return ranged(key, int(raw), spec) if raw.is_valid_int() else bad
		"v":
			var parts := raw.split(",")

			if parts.size() != 3:
				return DotResult.fail(DotError.CODE_INVALID, "%s needs x,y,z." % key)

			var v := Vector3.ZERO

			for i in 3:
				if not parts[i].is_valid_float() or not is_finite(parts[i].to_float()):
					return bad
				var one := ranged(key, parts[i].to_float(), spec)
				if not one.ok:
					return one
				v[i] = float(one.value)

			return DotResult.success(v)
		"s":
			return DotResult.success(StringName(raw)) if raw == "" or token_ok(raw) else bad
		"l":
			var items: Array[StringName] = []

			for item in raw.split(",", false):
				if not token_ok(item) or items.size() >= DotGameMapEdit.MAX_TOKENS:
					return bad
				items.append(StringName(item))

			return DotResult.success(items)
		"e:kind":
			return DotResult.success(StringName(raw)) if raw in DotGameMapEdit.KINDS else bad
		"e:sight":
			return DotResult.success(StringName(raw)) if raw in DotGameMapEdit.SIGHTS else bad

	return bad


static func ranged(key: String, value: float, spec: Array) -> DotResult:
	if value < float(spec[1]) or value > float(spec[2]):
		return DotResult.fail(DotError.CODE_INVALID, "%s must be between %s and %s." % [key, str(spec[1]), str(spec[2])])

	return DotResult.success(int(value) if str(spec[0]) == "i" else value)


static func token_ok(text: String) -> bool:
	if text.is_empty() or text.length() > DotGameMapEdit.MAX_TEXT:
		return false

	for i in text.length():
		var c := text.unicode_at(i)

		if not ((c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95 or c == 45):
			return false

	return true
