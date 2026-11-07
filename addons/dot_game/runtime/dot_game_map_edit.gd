class_name DotGameMapEdit
extends RefCounted

## The admin map-edit command set: spawn points, spawn strategy, navigation links and the map-data file.
##
## [codeblock]
## var edit := DotGameMapEdit.new()
## edit.points = point_set            # dot-spawn's DotSpawnPointSet (duck-typed)
## edit.store = map_data_store        # dot-map's DotMapDataStore (duck-typed)
## edit.nav = nav_tools               # rebake and hand links (duck-typed)
## edit.pose_fn = func(ctx): return {"position": pos, "yaw": yaw}
## edit.map_fn = func(): return {"game": "arena", "id": "dm_box", "version": "3", "digest": ""}
## edit.bind(server.console)
## [/codeblock]
##
## [b]Duck-typed on every side, in the shape of [code]DotModToolCommands[/code].[/b] The host is anything with [code]add_command[/code] (a [code]DotModule[/code]) or [code]command[/code] (a console); the point set, the store and the navigation tools are objects this file calls by method name, so dot-game depends on none of dot-spawn, dot-map, dot-bot or dot-npc-ai. A missing collaborator turns its commands into a plain reply, never an error.
##
## [b]The contract.[/b] [member points]: [code]points[/code] (array), [code]find(id)[/code], [code]add(def)[/code], [code]to_dict()[/code], and a static [code]from_dict(d) -> DotResult[/code] on its script. A def: the [code]DotSpawnPointDef[/code] properties, [code]to_dict()[/code], [code]problem()[/code]. [member store]: [code]load(game, map_id, version)[/code] and [code]save(bundle, by)[/code], each returning a [code]DotResult[/code] and allowed to be a coroutine. [member nav]: [code]rebake()[/code], [code]add_link(dict)[/code], [code]remove_link(id)[/code], [code]links_dict()[/code] and [code]load_links(dict)[/code], each optional.
##
## [b]Server validation.[/b] Every value is parsed, range-checked and finite before it reaches a def, an unknown key is refused, an id is a short lowercase token, and the def's own [code]problem()[/code] has the last word. An edit changes the working set only; [code]mapdata_save[/code] persists it. Every edit and every save is an INFO line and an audit record with the admin's id.

const CHANNEL := "game.map_edit"
const SPAWNS := "spawns"
const NAV_LINKS := "nav_links"
const DEF_SCRIPT := "res://addons/dot_spawn/core/dot_spawn_point_def.gd"
const EXPORT_DIR := "user://map_data/export/"
const MAX_LIST := 40
const MAX_TOKENS := 32
const MAX_TEXT := 64

const KINDS: Array[String] = ["player", "npc", "both"]
const SIGHTS: Array[String] = ["any", "hidden_from_players", "visible_to_players"]
const LINK_KINDS: Array[String] = ["ladder", "door", "jump", "drop"]

## key -> [type, low, high]; type is "f", "i", "b", "v", "s" (token), "l" (token list), "e:kind", "e:sight".
const KEYS := {
	"kind": ["e:kind", 0, 0], "enabled": ["b", 0, 0], "pos": ["v", -100000.0, 100000.0],
	"yaw": ["f", -720.0, 720.0], "radius": ["f", 0.0, 1000.0], "team": ["s", 0, 0],
	"classes": ["l", 0, 0], "group": ["s", 0, 0], "weight": ["f", 0.0, 1000.0],
	"cooldown": ["f", -1.0, 86400.0], "max_alive": ["i", 0, 10000], "phases": ["l", 0, 0],
	"sight": ["e:sight", 0, 0], "min_dist": ["f", 0.0, 100000.0], "max_dist": ["f", 0.0, 100000.0],
}

## key -> the def property it writes.
const PROPS := {
	"pos": "position", "min_dist": "min_player_distance", "max_dist": "max_player_distance",
}

## role -> [name, usage, description, minimum arguments].
const COMMANDS := {
	"spawn_list": ["spawn_list", "[page]", "List the authored spawn points", 0],
	"spawn_add": ["spawn_add", "<player|npc|both> [key=value...]", "Add a spawn point at your feet, facing as you do", 1],
	"spawn_set": ["spawn_set", "<id> key=value...", "Change a spawn point's settings", 2],
	"spawn_remove": ["spawn_remove", "<id>", "Remove an authored spawn point", 1],
	"spawn_toggle": ["spawn_toggle", "<id>", "Enable or disable a spawn point", 1],
	"spawn_test": ["spawn_test", "<id>", "Spawn yourself at a spawn point", 1],
	"spawn_strategy": ["spawn_strategy", "<name>", "Choose the spawn strategy", 1],
	"nav_rebake": ["nav_rebake", "", "Rebuild the navigation mesh", 0],
	"nav_link_mark": ["nav_link_mark", "", "Mark where you stand as the start of a navigation link", 0],
	"nav_link_add": ["nav_link_add", "<ladder|door|jump|drop> [id=name]", "Add a link from the marked point to where you stand", 1],
	"nav_link_remove": ["nav_link_remove", "<id>", "Remove a hand-made navigation link", 1],
	"mapdata_save": ["mapdata_save", "[note]", "Save this map's spawns and links to the store", 0],
	"mapdata_revert": ["mapdata_revert", "", "Drop unsaved edits and reload the saved map data", 0],
	"mapdata_export": ["mapdata_export", "[name]", "Write this map's data to a file", 0],
	"mapdata_import": ["mapdata_import", "<name> [force]", "Read map data from a file written by mapdata_export", 1],
}

## The admin flag every command needs; the console refuses anybody without it.
var map_edit_flag: String = "config"

## Prepended to every command name.
var prefix: String = ""

## Roles not to register at all.
var skip: PackedStringArray = PackedStringArray()

var points: Object = null
var store: Object = null
var nav: Object = null
var server: Object = null

## `func(ctx) -> Dictionary` with `position: Vector3` and `yaw: float`, the admin's feet and facing. Without it the point-placing commands refuse.
var pose_fn: Callable = Callable()

## `func() -> Dictionary` with `game`, `id`, `version` and `digest` of the running map. Without it the data commands refuse.
var map_fn: Callable = Callable()

## `func(id: StringName) -> Object`, the def a map-declared point would have, so a map's own point can be overridden by id.
var base_fn: Callable = Callable()

## `func() -> Object`, a fresh def; the default loads dot-spawn's by path.
var def_factory: Callable = Callable()

## `func(name: String) -> DotResult`; the game applies a strategy name. Without it `spawn_strategy` refuses.
var strategy_fn: Callable = Callable()

## `func(ctx, def) -> DotResult`; the game moves the admin to a point.
var test_fn: Callable = Callable()

## `func(what: String)` after any edit the game must re-apply to its director or nav (`spawns`, `nav`).
var changed_fn: Callable = Callable()

## Names registered, for a host that must remove them again.
var registered: PackedStringArray = PackedStringArray()

## True while edits since the last save, load or revert are not stored.
var dirty: bool = false

var _marks: Dictionary = {}
var _counter: int = 0


static func install(host: Object, p_server: Object = null) -> DotGameMapEdit:
	var edit := DotGameMapEdit.new()
	edit.server = p_server
	var _res := edit.bind(host)
	return edit


func command_name(role: String) -> String:
	return prefix + str((COMMANDS[role] as Array)[0])


func bind(host: Object) -> DotResult:
	var adder := ""

	if host == null:
		return DotResult.fail(DotError.CODE_INVALID, "A host is needed.")
	if host.has_method("add_command"):
		adder = "add_command"
	elif host.has_method("command"):
		adder = "command"
	else:
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "That host has no way to register a command.")

	for role: String in COMMANDS:
		if skip.has(role):
			continue

		var entry: Array = COMMANDS[role]
		var made: Variant = host.call(adder, command_name(role), _handler_for(role), str(entry[2]), map_edit_flag)

		if made is Object:
			var command := made as Object

			if command.has_method("with_usage"):
				command.call("with_usage", str(entry[1]))
			if command.has_method("with_args") and int(entry[3]) > 0:
				command.call("with_args", int(entry[3]))

		registered.append(command_name(role))

	return DotResult.success(registered)


func _handler_for(role: String) -> Callable:
	return func(ctx: Object) -> void:
		await run(role, ctx)


## Runs one role for [param ctx]; public so a toolgun mode can drive the same editor.
func run(role: String, ctx: Object) -> void:
	var args := _args(ctx)
	var outcome: DotResult = await _dispatch(role, ctx, args)

	if not outcome.ok:
		_reply(ctx, outcome.error.message)
		return

	var said := str(outcome.value)
	_reply(ctx, said)

	if role in ["spawn_list"]:
		return

	var line := "%s %s" % [command_name(role), " ".join(args)]
	DotLog.info(CHANNEL, "map edit", {"by": _caller(ctx), "command": line.strip_edges(), "result": said})

	var audit: Variant = server.get("audit") if server != null else null

	if audit is Object and (audit as Object).has_method("record"):
		(audit as Object).call("record", command_name(role), _caller(ctx), " ".join(args), {})


func _dispatch(role: String, ctx: Object, args: PackedStringArray) -> DotResult:
	match role:
		"spawn_list": return _list(args)
		"spawn_add": return _add(ctx, args)
		"spawn_set": return _edit_set(args)
		"spawn_remove": return _remove(args)
		"spawn_toggle": return _toggle(args)
		"spawn_test": return await _test(ctx, args)
		"spawn_strategy": return await _strategy(args)
		"nav_rebake": return await _rebake()
		"nav_link_mark": return _mark(ctx)
		"nav_link_add": return await _link_add(ctx, args)
		"nav_link_remove": return await _link_remove(args)
		"mapdata_save": return await _save(ctx, args)
		"mapdata_revert": return await _revert()
		"mapdata_export": return _export(ctx, args)
		"mapdata_import": return await _import(args)

	return DotResult.fail(DotError.CODE_UNSUPPORTED, "No such map edit command.")


# --- Spawns ----------------------------------------------------------------

func _list(args: PackedStringArray) -> DotResult:
	var gone := _need_points()

	if gone != null:
		return gone

	var all: Array = points.get("points")

	if all.is_empty():
		return DotResult.success("No authored spawn points; the map's own are in use.")

	var page := maxi(1, int(args[0])) if args.size() > 0 and args[0].is_valid_int() else 1
	var pages := ceili(all.size() / float(MAX_LIST))
	var lines := PackedStringArray()

	for i in range((page - 1) * MAX_LIST, mini(all.size(), page * MAX_LIST)):
		var p: Object = all[i]
		var pos: Vector3 = p.get("position")
		lines.append("%s %s%s (%.1f, %.1f, %.1f)" % [
			str(p.get("id")), str(p.get("kind")), "" if bool(p.get("enabled")) else " off", pos.x, pos.y, pos.z,
		])

	return DotResult.success("%d point%s, page %d of %d: %s" % [
		all.size(), "" if all.size() == 1 else "s", mini(page, maxi(pages, 1)), maxi(pages, 1), ", ".join(lines),
	])


func _add(ctx: Object, args: PackedStringArray) -> DotResult:
	var gone := _need_points()

	if gone != null:
		return gone

	var pose := _pose(ctx)

	if pose.is_empty():
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "Spawn points are placed where you stand; run this in game.")

	var kind := args[0]

	if kind not in KINDS:
		return DotResult.fail(DotError.CODE_INVALID, "The kind is player, npc or both, not '%s'." % kind.left(MAX_TEXT))

	var def := _new_def()

	if def == null:
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "Spawn points need dot-spawn, which is not installed here.")

	def.set("kind", StringName(kind))
	def.set("position", pose["position"])
	def.set("yaw", float(pose["yaw"]))
	def.set("source", &"authored")

	var given := _parse_settings(args.slice(1), true)

	if not given.ok:
		return given

	var settings: Dictionary = given.value
	var id := str(settings.get("id", ""))
	settings.erase("id")

	if id == "":
		id = _free_id()

	if points.call("find", StringName(id)) != null or _base(StringName(id)) != null:
		return DotResult.fail(DotError.CODE_CONFLICT, "There is already a point called '%s'." % id)

	def.set("id", StringName(id))
	var applied := _apply(def, settings)

	if not applied.ok:
		return applied

	points.call("add", def)
	_changed(SPAWNS)
	return DotResult.success("Added %s '%s' at your feet." % [kind, id])


func _edit_set(args: PackedStringArray) -> DotResult:
	var found := _find_or_override(args[0])

	if not found.ok:
		return found

	var parsed := _parse_settings(args.slice(1), false)

	if not parsed.ok:
		return parsed

	var def: Object = found.value["def"]
	var before := _snapshot(def)
	var applied := _apply(def, parsed.value)

	if not applied.ok:
		_restore(def, before)
		return applied

	if bool(found.value["created"]):
		points.call("add", def)

	_changed(SPAWNS)
	return DotResult.success("Updated '%s'." % args[0])


func _remove(args: PackedStringArray) -> DotResult:
	var gone := _need_points()

	if gone != null:
		return gone

	var def: Object = points.call("find", StringName(args[0]))

	if def == null:
		return DotResult.fail(DotError.CODE_INVALID, "No authored point called '%s'." % args[0].left(MAX_TEXT))

	var list: Array = points.get("points")
	list.erase(def)
	_changed(SPAWNS)
	var back := " The map's own point is back." if _base(StringName(args[0])) != null else ""
	return DotResult.success("Removed '%s'.%s" % [args[0], back])


func _toggle(args: PackedStringArray) -> DotResult:
	var found := _find_or_override(args[0])

	if not found.ok:
		return found

	var def: Object = found.value["def"]
	def.set("enabled", not bool(def.get("enabled")))

	if bool(found.value["created"]):
		points.call("add", def)

	_changed(SPAWNS)
	return DotResult.success("'%s' is now %s." % [args[0], "on" if bool(def.get("enabled")) else "off"])


func _test(ctx: Object, args: PackedStringArray) -> DotResult:
	var gone := _need_points()

	if gone != null:
		return gone

	var def: Object = points.call("find", StringName(args[0]))

	if def == null:
		def = _base(StringName(args[0]))

	if def == null:
		return DotResult.fail(DotError.CODE_INVALID, "No point called '%s'." % args[0].left(MAX_TEXT))

	if not test_fn.is_valid():
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "This game cannot move you to a spawn point.")

	var moved: DotResult = await test_fn.call(ctx, def)
	return moved if not moved.ok else DotResult.success("Spawned at '%s'." % args[0])


func _strategy(args: PackedStringArray) -> DotResult:
	if not strategy_fn.is_valid():
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "This game has no spawn strategies to choose from.")

	var name := args[0].left(MAX_TEXT).to_lower()

	if not _token_ok(name):
		return DotResult.fail(DotError.CODE_INVALID, "That is not a strategy name.")

	var made: DotResult = await strategy_fn.call(name)
	return made if not made.ok else DotResult.success("Spawn strategy is now '%s'." % name)


# --- Navigation ------------------------------------------------------------

func _rebake() -> DotResult:
	if nav == null or not nav.has_method("rebake"):
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "This game has no navigation to rebuild.")

	var made: Variant = await nav.call("rebake")

	if made is DotResult and not (made as DotResult).ok:
		return (made as DotResult).wrap("the rebake failed")

	_changed("nav")
	return DotResult.success("Navigation rebuilt.")


func _mark(ctx: Object) -> DotResult:
	var pose := _pose(ctx)

	if pose.is_empty():
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "Links are marked where you stand; run this in game.")

	_marks[_caller(ctx)] = pose["position"]
	var at: Vector3 = pose["position"]
	return DotResult.success("Link start marked at (%.1f, %.1f, %.1f)." % [at.x, at.y, at.z])


func _link_add(ctx: Object, args: PackedStringArray) -> DotResult:
	if nav == null or not nav.has_method("add_link"):
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "This game has no navigation links to add.")

	var kind := args[0]

	if kind not in LINK_KINDS:
		return DotResult.fail(DotError.CODE_INVALID, "A link is a ladder, door, jump or drop, not '%s'." % kind.left(MAX_TEXT))

	var pose := _pose(ctx)
	var start: Variant = _marks.get(_caller(ctx))

	if pose.is_empty() or not (start is Vector3):
		return DotResult.fail(DotError.CODE_INVALID, "Mark the start with nav_link_mark first, then stand at the end.")

	var parsed := _parse_pairs(args.slice(1))

	if not parsed.ok:
		return parsed

	var given: Dictionary = parsed.value
	var id := str(given.get("id", ""))

	if id != "" and not _token_ok(id):
		return DotResult.fail(DotError.CODE_INVALID, "A link id is up to %d lowercase letters, digits, _ or -." % MAX_TEXT)

	if id == "":
		_counter += 1
		id = "link_%d" % _counter

	var end: Vector3 = pose["position"]
	var link := {"id": id, "kind": kind, "a": [start.x, start.y, start.z], "b": [end.x, end.y, end.z], "source": "authored"}
	var made: Variant = await nav.call("add_link", link)

	if made is DotResult and not (made as DotResult).ok:
		return (made as DotResult).wrap("the link was refused")

	_marks.erase(_caller(ctx))
	_changed("nav")
	return DotResult.success("Added %s link '%s'." % [kind, id])


func _link_remove(args: PackedStringArray) -> DotResult:
	if nav == null or not nav.has_method("remove_link"):
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "This game has no navigation links to remove.")

	var made: Variant = await nav.call("remove_link", StringName(args[0].left(MAX_TEXT)))

	if made is DotResult and not (made as DotResult).ok:
		return (made as DotResult).wrap("no link was removed")

	_changed("nav")
	return DotResult.success("Removed link '%s'." % args[0])


# --- Map data --------------------------------------------------------------

func _save(ctx: Object, args: PackedStringArray) -> DotResult:
	var map := _map()

	if map.is_empty() or store == null or not store.has_method("save"):
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "There is no map data store to save to.")

	var bundle: Variant = _bundle(_caller(ctx), map, " ".join(args).left(DotGameMapEditBundle.MAX_STRING))
	var saved: Variant = await store.call("save", bundle, _caller(ctx))

	if saved is DotResult and not (saved as DotResult).ok:
		return (saved as DotResult).wrap("the store refused the save")

	dirty = false
	return DotResult.success("Saved map data for %s." % str(map["id"]))


func _revert() -> DotResult:
	var map := _map()

	if map.is_empty() or store == null or not store.has_method("load"):
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "There is no map data store to reload from.")

	var loaded: Variant = await store.call("load", str(map["game"]), str(map["id"]), str(map["version"]))

	if loaded is DotResult and not (loaded as DotResult).ok:
		return (loaded as DotResult).wrap("nothing saved to go back to")

	var bundle: Variant = loaded.value if loaded is DotResult else loaded
	var as_dict := DotGameMapEditBundle.as_dict(bundle)

	if as_dict.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "The store returned something that is not map data.")

	var taken := await _take(as_dict.get("sections", {}))

	if not taken.ok:
		return taken

	dirty = false
	return DotResult.success("Reverted to the saved map data.")


func _export(ctx: Object, args: PackedStringArray) -> DotResult:
	var map := _map()

	if map.is_empty():
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "There is no running map to export.")

	var name := args[0].left(MAX_TEXT) if args.size() > 0 else "%s_%s" % [map["game"], map["id"]]

	if not _token_ok(name):
		return DotResult.fail(DotError.CODE_INVALID, "A file name is lowercase letters, digits, _ or -.")

	DirAccess.make_dir_recursive_absolute(EXPORT_DIR)
	var path := "%s%s.json" % [EXPORT_DIR, name]
	var file := FileAccess.open(path, FileAccess.WRITE)

	if file == null:
		return DotResult.fail(DotError.CODE_IO, "Could not write %s." % path)

	file.store_string(JSON.stringify(DotGameMapEditBundle.as_dict(_bundle(_caller(ctx), map, "")), "\t"))
	file.close()
	return DotResult.success("Exported to %s." % path)


func _import(args: PackedStringArray) -> DotResult:
	var map := _map()
	var name := args[0].left(MAX_TEXT)

	if map.is_empty():
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "There is no running map to import into.")

	if not _token_ok(name):
		return DotResult.fail(DotError.CODE_INVALID, "A file name is lowercase letters, digits, _ or -.")

	var path := "%s%s.json" % [EXPORT_DIR, name]

	if not FileAccess.file_exists(path):
		return DotResult.fail(DotError.CODE_INVALID, "No exported file called '%s'." % name)

	var checked := DotGameMapEditBundle.check(FileAccess.get_file_as_string(path), map)

	if not checked.ok:
		return checked

	var warnings: PackedStringArray = checked.value["warnings"]

	if not warnings.is_empty() and not (args.size() > 1 and args[1] == "force"):
		return DotResult.fail(DotError.CODE_CONFLICT, "Not imported: %s. Add 'force' to import anyway." % ", ".join(warnings))

	var taken := await _take((checked.value["bundle"] as Dictionary)["sections"])

	if not taken.ok:
		return taken

	dirty = true
	return DotResult.success("Imported %s; mapdata_save keeps it." % name)


func _bundle(by: String, map: Dictionary, note: String) -> Variant:
	var sections := {}

	if points != null:
		sections[SPAWNS] = points.call("to_dict")

	if nav != null and nav.has_method("links_dict"):
		sections[NAV_LINKS] = nav.call("links_dict")

	return DotGameMapEditBundle.make(str(map["game"]), map, by, sections, note)


## Replaces the working spawns and links with a bundle's sections, all or nothing for the spawns.
func _take(sections: Variant) -> DotResult:
	if not (sections is Dictionary):
		return DotResult.fail(DotError.CODE_INVALID, "The bundle has no sections.")

	var dict: Dictionary = sections

	if dict.has(SPAWNS):
		var gone := _need_points()

		if gone != null:
			return gone

		var script: Variant = points.get_script()
		var made: Variant = (script as Object).call("from_dict", dict[SPAWNS]) if script is Object else null

		if not (made is DotResult) or not (made as DotResult).ok:
			return (made as DotResult).wrap("the saved spawn points are invalid") if made is DotResult \
				else DotResult.fail(DotError.CODE_UNSUPPORTED, "Cannot rebuild a spawn point set.")

		var fresh: Array = (made as DotResult).value.get("points")
		var list: Array = points.get("points")
		list.clear()
		list.append_array(fresh)
		_changed(SPAWNS)

	if dict.has(NAV_LINKS) and nav != null and nav.has_method("load_links"):
		var linked: Variant = await nav.call("load_links", dict[NAV_LINKS])

		if linked is DotResult and not (linked as DotResult).ok:
			return (linked as DotResult).wrap("the saved links are invalid")

		_changed("nav")

	return DotResult.success("")


# --- Parsing and helpers -----------------------------------------------------

func _parse_pairs(args: PackedStringArray) -> DotResult:
	var out := {}

	for a in args:
		var at := a.find("=")

		if at <= 0:
			return DotResult.fail(DotError.CODE_INVALID, "Write settings as key=value, not '%s'." % a.left(MAX_TEXT))

		out[a.left(at).to_lower()] = a.substr(at + 1)

	return DotResult.success(out)


## Parses key=value words into typed values. [param allow_id] lets `id=` through (a new point only).
func _parse_settings(args: PackedStringArray, allow_id: bool) -> DotResult:
	var pairs := _parse_pairs(args)

	if not pairs.ok:
		return pairs

	var out := {}

	for key: String in pairs.value:
		var raw: String = pairs.value[key]

		if key == "id" and allow_id:
			if not _token_ok(raw):
				return DotResult.fail(DotError.CODE_INVALID, "A point id is up to %d lowercase letters, digits, _ or -." % MAX_TEXT)

			out["id"] = raw
			continue

		if not KEYS.has(key):
			return DotResult.fail(DotError.CODE_INVALID, "'%s' is not a spawn setting (%s)." % [key.left(MAX_TEXT), ", ".join(KEYS.keys())])

		var parsed := _parse_value(key, raw)

		if not parsed.ok:
			return parsed

		out[key] = parsed.value

	return DotResult.success(out)


func _parse_value(key: String, raw: String) -> DotResult:
	var spec: Array = KEYS[key]
	var type := str(spec[0])
	var bad := DotResult.fail(DotError.CODE_INVALID, "%s=%s is not a valid %s." % [key, raw.left(MAX_TEXT), key])

	match type:
		"b":
			if raw in ["1", "true", "on", "yes"]:
				return DotResult.success(true)
			return DotResult.success(false) if raw in ["0", "false", "off", "no"] else bad
		"f":
			if not raw.is_valid_float() or not is_finite(raw.to_float()):
				return bad
			return _ranged(key, raw.to_float(), spec)
		"i":
			return _ranged(key, int(raw), spec) if raw.is_valid_int() else bad
		"v":
			var parts := raw.split(",")

			if parts.size() != 3:
				return DotResult.fail(DotError.CODE_INVALID, "%s needs x,y,z." % key)

			var v := Vector3.ZERO

			for i in 3:
				if not parts[i].is_valid_float() or not is_finite(parts[i].to_float()):
					return bad
				var one := _ranged(key, parts[i].to_float(), spec)
				if not one.ok:
					return one
				v[i] = float(one.value)

			return DotResult.success(v)
		"s":
			return DotResult.success(StringName(raw)) if raw == "" or _token_ok(raw) else bad
		"l":
			var items: Array[StringName] = []

			for item in raw.split(",", false):
				if not _token_ok(item) or items.size() >= MAX_TOKENS:
					return bad
				items.append(StringName(item))

			return DotResult.success(items)
		"e:kind":
			return DotResult.success(StringName(raw)) if raw in KINDS else bad
		"e:sight":
			return DotResult.success(StringName(raw)) if raw in SIGHTS else bad

	return bad


func _ranged(key: String, value: float, spec: Array) -> DotResult:
	if value < float(spec[1]) or value > float(spec[2]):
		return DotResult.fail(DotError.CODE_INVALID, "%s must be between %s and %s." % [key, str(spec[1]), str(spec[2])])

	return DotResult.success(int(value) if str(spec[0]) == "i" else value)


func _apply(def: Object, settings: Dictionary) -> DotResult:
	for key: String in settings:
		def.set(str(PROPS.get(key, key)), settings[key])

	if def.has_method("problem"):
		var problem := str(def.call("problem"))

		if problem != "":
			return DotResult.fail(DotError.CODE_INVALID, "Refused: %s." % problem)

	return DotResult.success(true)


func _snapshot(def: Object) -> Dictionary:
	var out := {}

	for key: String in KEYS:
		var prop := str(PROPS.get(key, key))
		out[prop] = def.get(prop)

	return out


func _restore(def: Object, snap: Dictionary) -> void:
	for prop: String in snap:
		def.set(prop, snap[prop])


## The authored def called [param text], or a copy of the map's own point to override. `created` says it is not in the set yet.
func _find_or_override(text: String) -> DotResult:
	var gone := _need_points()

	if gone != null:
		return gone

	var id := StringName(text.left(MAX_TEXT))
	var def: Object = points.call("find", id)

	if def != null:
		return DotResult.success({"def": def, "created": false})

	var base := _base(id)

	if base == null:
		return DotResult.fail(DotError.CODE_INVALID, "No point called '%s'." % text.left(MAX_TEXT))

	return DotResult.success({"def": base, "created": true})


func _base(id: StringName) -> Object:
	if not base_fn.is_valid():
		return null

	var made: Variant = base_fn.call(id)
	return made as Object if made is Object else null


func _new_def() -> Object:
	if def_factory.is_valid():
		return def_factory.call() as Object

	if not ResourceLoader.exists(DEF_SCRIPT):
		return null

	var script: Variant = load(DEF_SCRIPT)
	return (script as GDScript).new() if script is GDScript else null


func _free_id() -> String:
	while true:
		_counter += 1
		var id := "authored_%d" % _counter

		if points.call("find", StringName(id)) == null and _base(StringName(id)) == null:
			return id

	return ""


func _need_points() -> DotResult:
	if points == null:
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "This game has no editable spawn points.")

	return null


func _pose(ctx: Object) -> Dictionary:
	if not pose_fn.is_valid():
		return {}

	var pose: Variant = pose_fn.call(ctx)

	if pose is Dictionary and (pose as Dictionary).get("position") is Vector3:
		var pos: Vector3 = (pose as Dictionary)["position"]

		if pos.is_finite():
			return {"position": pos, "yaw": float((pose as Dictionary).get("yaw", 0.0))}

	return {}


func _map() -> Dictionary:
	if not map_fn.is_valid():
		return {}

	var map: Variant = map_fn.call()

	if map is Dictionary and str((map as Dictionary).get("id", "")) != "":
		return map

	return {}


func _changed(what: String) -> void:
	dirty = true

	if changed_fn.is_valid():
		changed_fn.call(what)


static func _token_ok(text: String) -> bool:
	if text.is_empty() or text.length() > MAX_TEXT:
		return false

	for i in text.length():
		var c := text.unicode_at(i)

		if not ((c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95 or c == 45):
			return false

	return true


func _caller(ctx: Object) -> String:
	return str(ctx.call("caller_label")) if ctx.has_method("caller_label") else "console"


func _args(ctx: Object) -> PackedStringArray:
	var args: Variant = ctx.get("args")
	return args as PackedStringArray if args is PackedStringArray else PackedStringArray()


func _reply(ctx: Object, text: String) -> void:
	ctx.call("reply", text)
