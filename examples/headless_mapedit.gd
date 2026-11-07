extends Node

## DotGameMapEdit against a fake console, point set, store and navigation: every command, the flag gate, validation, save, revert, export and import.

const CHECKS := 66

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


class Def:
	extends RefCounted
	var id: StringName = &"point"
	var kind: StringName = &"both"
	var enabled: bool = true
	var position: Vector3 = Vector3.ZERO
	var yaw: float = 0.0
	var radius: float = 0.0
	var team: StringName = &""
	var classes: Array[StringName] = []
	var group: StringName = &""
	var weight: float = 1.0
	var cooldown: float = -1.0
	var max_alive: int = 0
	var phases: Array[StringName] = []
	var sight: StringName = &"any"
	var min_player_distance: float = 0.0
	var max_player_distance: float = 0.0
	var source: StringName = &"authored"

	func problem() -> String:
		return "radius with no weight" if radius > 0.0 and weight == 0.0 else ""

	func to_dict() -> Dictionary:
		return {"id": str(id), "kind": str(kind), "enabled": enabled, "pos": [position.x, position.y, position.z],
			"yaw": yaw, "radius": radius, "weight": weight, "team": str(team)}


class PointSet:
	extends RefCounted
	var points: Array[Def] = []

	func add(p: Def) -> void:
		points.append(p)

	func find(id: StringName) -> Def:
		for p in points:
			if p.id == id:
				return p
		return null

	func to_dict() -> Dictionary:
		var list: Array = []
		for p in points:
			list.append(p.to_dict())
		return {"version": 1, "points": list}

	static func from_dict(d: Dictionary) -> DotResult:
		var made := PointSet.new()
		for e: Dictionary in d.get("points", []):
			var p := Def.new()
			p.id = StringName(str(e["id"]))
			p.kind = StringName(str(e["kind"]))
			p.enabled = bool(e["enabled"])
			p.position = Vector3(e["pos"][0], e["pos"][1], e["pos"][2])
			made.add(p)
		return DotResult.success(made)


class Store:
	extends RefCounted
	var saved: Dictionary = {}
	var saves: Array = []

	func save(bundle: Dictionary, by: String) -> DotResult:
		await Engine.get_main_loop().process_frame
		saved = bundle.duplicate(true)
		saves.append(by)
		return DotResult.success(true)

	func load(_game: String, _id: String, _version: String) -> DotResult:
		if saved.is_empty():
			return DotResult.fail(DotError.CODE_INVALID, "nothing saved")
		return DotResult.success(saved.duplicate(true))


class Nav:
	extends RefCounted
	var rebakes := 0
	var links: Dictionary = {}

	func rebake() -> DotResult:
		rebakes += 1
		return DotResult.success(true)

	func add_link(link: Dictionary) -> DotResult:
		if links.has(link["id"]):
			return DotResult.fail(DotError.CODE_CONFLICT, "duplicate link")
		links[link["id"]] = link
		return DotResult.success(true)

	func remove_link(id: StringName) -> DotResult:
		if not links.has(str(id)):
			return DotResult.fail(DotError.CODE_INVALID, "no such link")
		links.erase(str(id))
		return DotResult.success(true)

	func links_dict() -> Dictionary:
		return {"links": links.duplicate(true)}

	func load_links(d: Dictionary) -> DotResult:
		links = (d.get("links", {}) as Dictionary).duplicate(true)
		return DotResult.success(true)


class Cmd:
	extends RefCounted
	var handler: Callable
	var permission: String = ""

	func with_usage(_u: String) -> Cmd:
		return self

	func with_args(_a: int) -> Cmd:
		return self


class Host:
	extends RefCounted
	var commands: Dictionary = {}

	func add_command(name: String, handler: Callable, _desc: String = "", permission: String = "") -> Cmd:
		var c := Cmd.new()
		c.handler = handler
		c.permission = permission
		commands[name] = c
		return c


class Ctx:
	extends RefCounted
	var args: PackedStringArray = PackedStringArray()
	var replies: Array[String] = []

	func reply(text: String) -> void:
		replies.append(text)

	func caller_label() -> String:
		return "admin#7"

	func last() -> String:
		return replies.back() if not replies.is_empty() else ""


class Audit:
	extends RefCounted
	var lines: Array = []

	func record(command: String, by: String, target: String, _extra: Dictionary) -> void:
		lines.append([command, by, target])


class FakeServer:
	extends RefCounted
	var audit := Audit.new()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what)


func _say(host: Host, name: String, args: Array) -> Ctx:
	var ctx := Ctx.new()
	ctx.args = PackedStringArray(args)
	await (host.commands[name] as Cmd).handler.call(ctx)
	return ctx


func _run() -> void:
	print("dot-game: map edit commands")
	var host := Host.new()
	var server := FakeServer.new()
	var store := Store.new()
	var nav := Nav.new()
	var edit := DotGameMapEdit.new()
	var tests: Dictionary = {"strategies": [], "moved": [], "changed": []}
	var base := Def.new()
	base.id = &"map_a"
	base.position = Vector3(1, 0, 1)
	edit.server = server
	edit.points = PointSet.new()
	edit.store = store
	edit.nav = nav
	edit.def_factory = func() -> Object: return Def.new()
	edit.base_fn = func(id: StringName) -> Object:
		if id != &"map_a":
			return null
		var copy := Def.new()
		copy.id = id
		copy.source = &"map"
		copy.position = base.position
		return copy
	edit.pose_fn = func(_c: Object) -> Dictionary: return {"position": Vector3(5, 1, 6), "yaw": 1.5}
	edit.map_fn = func() -> Dictionary: return {"game": "tg", "id": "dm_box", "version": "3", "digest": "abc"}
	edit.strategy_fn = func(n: String) -> DotResult:
		if n == "bogus":
			return DotResult.fail(DotError.CODE_INVALID, "No such strategy.")
		tests["strategies"].append(n)
		return DotResult.success(true)
	edit.test_fn = func(_c: Object, d: Object) -> DotResult:
		tests["moved"].append(str(d.get("id")))
		return DotResult.success(true)
	edit.changed_fn = func(what: String) -> void: tests["changed"].append(what)

	var bound := edit.bind(host)
	_check(bound.ok and host.commands.size() == DotGameMapEdit.COMMANDS.size(), "every role registers")
	var gated := true
	for name: String in host.commands:
		gated = gated and (host.commands[name] as Cmd).permission == "config"
	_check(gated, "every command carries the map_edit_flag")
	_check(host.commands.has("spawn_add") and host.commands.has("mapdata_import"), "names match the plan")

	var c := await _say(host, "spawn_list", [])
	_check(c.last().begins_with("No authored"), "an empty set says the map's own are in use")

	c = await _say(host, "spawn_add", ["npc", "id=door_a", "radius=3", "team=red", "classes=zombie,runner"])
	_check(c.last().begins_with("Added npc 'door_a'"), "spawn_add places a point")
	var d: Def = edit.points.find(&"door_a")
	_check(d != null and d.position == Vector3(5, 1, 6) and is_equal_approx(d.yaw, 1.5), "at the admin's feet and facing")
	_check(d.radius == 3.0 and d.team == &"red" and d.classes.size() == 2, "settings parsed to typed values")
	_check(d.source == &"authored" and tests["changed"].has("spawns"), "authored, and the game is told")
	_check(edit.dirty, "an edit marks the set dirty")

	c = await _say(host, "spawn_add", ["player"])
	_check(c.last().begins_with("Added player 'authored_"), "an id is made when none is given")
	c = await _say(host, "spawn_add", ["player", "id=door_a"])
	_check(c.last().contains("already"), "a duplicate id is refused")
	c = await _say(host, "spawn_add", ["player", "id=map_a"])
	_check(c.last().contains("already"), "a map point's id is refused too")
	c = await _say(host, "spawn_add", ["tank"])
	_check(c.last().contains("player, npc or both"), "a bad kind is refused")
	var before: int = edit.points.points.size()
	for bad in [["weight=-1"], ["radius=nan"], ["pos=1,2"], ["pos=1e9,0,0"], ["bogus=1"], ["classes=A B"], ["sight=up"], ["max_alive=x"], ["enabled=maybe"], ["noequals"]]:
		c = await _say(host, "spawn_add", ["both"] + bad)
		_check(edit.points.points.size() == before, "refused: %s" % bad[0])
	c = await _say(host, "spawn_add", ["both", "id=Bad Id"])
	_check(edit.points.points.size() == before, "an id is a lowercase token")
	c = await _say(host, "spawn_add", ["both", "radius=2", "weight=0"])
	_check(edit.points.points.size() == before and c.last().contains("Refused"), "the def's own problem() has the last word")

	c = await _say(host, "spawn_set", ["door_a", "weight=2.5", "pos=9,9,9", "enabled=off"])
	_check(d.weight == 2.5 and d.position == Vector3(9, 9, 9) and not d.enabled, "spawn_set changes settings")
	c = await _say(host, "spawn_set", ["door_a", "weight=7", "radius=2", "weight=0"])
	_check(d.weight == 2.5 and d.radius == 3.0, "a refused set leaves the point as it was")
	c = await _say(host, "spawn_set", ["ghost", "weight=1"])
	_check(c.last().contains("No point"), "an unknown id is refused")
	c = await _say(host, "spawn_toggle", ["door_a"])
	_check(d.enabled and c.last().contains("on"), "spawn_toggle flips")

	c = await _say(host, "spawn_set", ["map_a", "weight=4"])
	var over: Def = edit.points.find(&"map_a")
	_check(over != null and over.weight == 4.0, "a map point is overridden by id into the set")
	c = await _say(host, "spawn_toggle", ["map_a"])
	_check(not over.enabled, "an override toggles")
	c = await _say(host, "spawn_remove", ["map_a"])
	_check(edit.points.find(&"map_a") == null and c.last().contains("back"), "removing an override gives the map's point back")
	c = await _say(host, "spawn_remove", ["nope"])
	_check(c.last().contains("No authored"), "removing an unknown point is refused")

	c = await _say(host, "spawn_list", [])
	_check(c.last().contains("door_a") and c.last().contains("2 points"), "spawn_list shows the set")
	c = await _say(host, "spawn_test", ["door_a"])
	_check(tests["moved"] == ["door_a"], "spawn_test hands the point to the game")
	c = await _say(host, "spawn_test", ["map_a"])
	_check(tests["moved"].size() == 2, "spawn_test reaches a map point")
	c = await _say(host, "spawn_strategy", ["scatter"])
	_check(tests["strategies"] == ["scatter"] and c.last().contains("scatter"), "spawn_strategy applies a name")
	c = await _say(host, "spawn_strategy", ["bogus"])
	_check(c.last().contains("No such"), "the game's refusal is the reply")
	c = await _say(host, "spawn_strategy", ["Bad Name!"])
	_check(c.last().contains("not a strategy"), "a strategy name is validated first")

	c = await _say(host, "nav_rebake", [])
	_check(nav.rebakes == 1 and tests["changed"].has("nav"), "nav_rebake calls the nav tools")
	c = await _say(host, "nav_link_add", ["jump"])
	_check(c.last().contains("Mark"), "a link needs its start marked")
	c = await _say(host, "nav_link_mark", [])
	c = await _say(host, "nav_link_add", ["jump", "id=hop"])
	_check(nav.links.has("hop") and nav.links["hop"]["kind"] == "jump" and nav.links["hop"]["a"] == [5.0, 1.0, 6.0], "nav_link_add from the mark")
	c = await _say(host, "nav_link_add", ["jump", "id=hop"])
	_check(c.last().contains("Mark"), "the mark is used once")
	c = await _say(host, "nav_link_add", ["teleporter"])
	_check(c.last().contains("ladder, door, jump or drop"), "a link kind is checked")
	c = await _say(host, "nav_link_remove", ["hop"])
	_check(nav.links.is_empty(), "nav_link_remove removes")
	c = await _say(host, "nav_link_remove", ["hop"])
	_check(c.last().contains("no link was removed"), "a missing link is the nav tools' refusal")

	await _say(host, "nav_link_mark", [])
	await _say(host, "nav_link_add", ["ladder", "id=lad"])
	c = await _say(host, "mapdata_save", ["first pass"])
	_check(c.last().contains("Saved") and not edit.dirty, "mapdata_save stores and clears dirty")
	var secs: Dictionary = store.saved["sections"]
	_check(store.saved["format"] == "dot-map-data" and store.saved["map"]["id"] == "dm_box", "the bundle has the plan's shape")
	_check(secs["spawns"]["points"].size() == 2 and secs["nav_links"]["links"].has("lad"), "spawns and links are in it")
	_check(store.saved["meta"]["author"] == "admin#7" and store.saved["meta"]["note"] == "first pass", "author and note recorded")

	await _say(host, "spawn_remove", ["door_a"])
	await _say(host, "nav_link_remove", ["lad"])
	c = await _say(host, "mapdata_revert", [])
	_check(edit.points.find(&"door_a") != null and nav.links.has("lad") and not edit.dirty, "mapdata_revert restores the saved set and links")

	c = await _say(host, "mapdata_export", ["box_test"])
	_check(c.last().contains("Exported") and FileAccess.file_exists("user://map_data/export/box_test.json"), "mapdata_export writes a file")
	await _say(host, "spawn_remove", ["door_a"])
	c = await _say(host, "mapdata_import", ["box_test"])
	_check(edit.points.find(&"door_a") != null and edit.dirty, "mapdata_import loads it and leaves it unsaved")
	c = await _say(host, "mapdata_import", ["../etc/passwd"])
	_check(c.last().contains("file name"), "a path is not a file name")
	c = await _say(host, "mapdata_import", ["missing"])
	_check(c.last().contains("No exported"), "a missing file is refused")

	var other: Dictionary = store.saved.duplicate(true)
	other["map"]["id"] = "dm_other"
	_write("alien", other)
	c = await _say(host, "mapdata_import", ["alien"])
	_check(c.last().contains("different map"), "a different map id is refused")
	other = store.saved.duplicate(true)
	other["map"]["version"] = "2"
	other["sections"]["spawns"] = {"points": [{"id": "from_v2", "kind": "both", "enabled": true, "pos": [0, 0, 0]}]}
	other["sections"]["scripts"] = {"load": "res://evil.gd"}
	_write("older", other)
	c = await _say(host, "mapdata_import", ["older"])
	_check(c.last().contains("force") and edit.points.find(&"from_v2") == null, "a version difference needs force")
	c = await _say(host, "mapdata_import", ["older", "force"])
	_check(edit.points.find(&"from_v2") != null, "force imports it")
	other["sections"]["spawns"] = {"points": [{"id": "x" , "kind": "both", "enabled": true, "pos": [0, 0, 0]}], "deep": "y".repeat(500)}
	_write("fat", other)
	c = await _say(host, "mapdata_import", ["fat", "force"])
	_check(c.last().contains("over a limit") and edit.points.find(&"x") == null, "an over-long string is refused")
	_write_text("junk", "not json")
	c = await _say(host, "mapdata_import", ["junk"])
	_check(c.last().contains("not a map data bundle"), "junk is refused")

	_check(server.audit.lines.size() > 20 and server.audit.lines[0][1] == "admin#7", "edits reach the audit with the admin's id")
	_check(server.audit.lines.all(func(l: Array) -> bool: return l[0] != "spawn_list"), "reads are not audited")

	var bare := DotGameMapEdit.new()
	var bare_host := Host.new()
	bare.bind(bare_host)
	c = await _say(bare_host, "spawn_add", ["npc"])
	_check(c.last().contains("no editable"), "no point set: a plain reply")
	c = await _say(bare_host, "nav_rebake", [])
	_check(c.last().contains("no navigation"), "no nav tools: a plain reply")
	c = await _say(bare_host, "mapdata_save", [])
	_check(c.last().contains("no map data store"), "no store: a plain reply")
	_check(not DotGameMapEdit.new().bind(Object.new()).ok, "a host with no way to register is refused")

	_check(_passed + _failed == CHECKS, "the check count is %d, ran %d" % [CHECKS, _passed + _failed])
	print("dot-game map edit: %d passed, %d failed" % [_passed, _failed])
	for f in _failures:
		print("  FAIL: ", f)
	get_tree().quit(1 if _failed > 0 else 0)


func _write(name: String, data: Dictionary) -> void:
	_write_text(name, JSON.stringify(data))


func _write_text(name: String, text: String) -> void:
	var f := FileAccess.open("user://map_data/export/%s.json" % name, FileAccess.WRITE)
	f.store_string(text)
	f.close()
