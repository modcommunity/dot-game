class_name DotGameAvatarActionSupport
extends RefCounted
## Row building and optional-addon script loading for [DotGameAvatarActionClient], kept out of its file so none of it counts as per-frame code.

static var _loaded: Dictionary = {}
static var _cache: RefCounted = null


## Groups [param entries] by action kind for the actions reader, keeping urls [param current] has.
static func input_rows(entries: Array, current: Object, url_fn: Callable, flags: Dictionary) -> Dictionary:
	var rows := {}
	for e: Dictionary in entries:
		var kind := String(DotGameAvatarLoadoutMessage.KINDS[clampi(int(e["kind"]), 0, DotGameAvatarLoadoutMessage.KINDS.size() - 1)]).to_upper()
		if not rows.has(kind):
			rows[kind] = []
		if String(e.get("clip", "")) == "":
			(rows[kind] as Array).append({"builtin": e["id"]})
			continue
		var url := ""
		if current.has_method(&"equipped"):
			for kept: Dictionary in current.call(&"equipped", StringName(kind.to_lower())):
				if kept.get("id") == e["id"]:
					url = String(kept.get("url", ""))
		if (url == "" or url == "/") and url_fn.is_valid():
			url = String(url_fn.call(String(e["id"])))
		if url == "":
			url = "/"
			flags["placeholder"] = true
		(rows[kind] as Array).append({"contentId": e["id"], "clip": e["clip"], "loop": e["loop"], "fileUrl": url})
	return rows


## The library row of each id, or what was read so far when one is missing (it is then fetched once).
static func wear_rows(ids: PackedStringArray, wearable_row_fn: Callable, tried: Dictionary, fetch: Callable) -> Array:
	var rows := []
	for id in ids:
		var row: Dictionary = wearable_row_fn.call(id) if wearable_row_fn.is_valid() else {}
		if row.is_empty():
			if not tried.has(id):
				tried[id] = true
				var _f := fetch.call({"id": id})
			return rows
		rows.append(row)
	return rows


static func new_wearer() -> RefCounted:
	var script := script("res://addons/dot_user_avatar/wearables/dot_avatar_wearables.gd")
	if script == null:
		return null
	var wearer: RefCounted = script.new()
	if _cache == null:
		_cache = script("res://addons/dot_user_avatar/actions/dot_avatar_content_cache.gd").new()
	wearer.set(&"cache", _cache)
	return wearer


## A script by path, loaded once; null when the optional addon is absent.
static func script(path: String) -> GDScript:
	if not _loaded.has(path):
		_loaded[path] = load(path) as GDScript if ResourceLoader.exists(path) else null
	return _loaded[path]
