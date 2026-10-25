extends Node

## DotGameConfigBinder: schema, layered load with provenance, cvar round trip, strict failure, diff, workbench edits.

const TestConfig := preload("fixtures/test_config.gd")
const ROOT := "res://examples/fixtures/config/"
const CHECKS := 52

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _make(roots_dir: String, strict := true, json := "") -> DotGameConfigBinder:
	var b := DotGameConfigBinder.create(TestConfig.new(), "tg", "tg", json)
	b.roots = PackedStringArray([ROOT + roots_dir])
	b.strict = strict
	return b


func _run() -> void:
	print("dot-game: config binder")
	_schema()
	_defaults()
	_layers()
	_cvars()
	_strict()
	_diff()
	_workbench()
	if _passed + _failed != CHECKS:
		_failed += 1
		_failures.append("ran %d checks, expected %d" % [_passed + _failed - 1, CHECKS])
	for f in _failures:
		print("FAIL: ", f)
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what)


func _entry(b: DotGameConfigBinder, key: String) -> Dictionary:
	for e: Dictionary in b.schema():
		if e["key"] == key:
			return e
	return {}


func _schema() -> void:
	var b := _make("none")
	var keys: Array = []
	for e: Dictionary in b.schema():
		keys.append(e["key"])
	_check(keys == ["speed", "count", "tie", "friendly_fire", "label", "tags"], "schema lists exported fields in order, not plain vars: %s" % str(keys))
	var s := _entry(b, "speed")
	_check(s["type"] == "float" and s["min"] == 0.0 and s["max"] == 20.0 and s["step"] == 0.5, "range hint becomes min/max/step")
	_check(s["group"] == "Movement" and _entry(b, "tie")["group"] == "Rules", "export_group is the group")
	_check(s["description"] == "Metres per second on foot. Second sentence is kept.", "doc comment: first paragraph only: '%s'" % s["description"])
	_check(_entry(b, "tie")["enum"] == [0, 1, 5], "enum values follow name:value")
	_check(_entry(b, "tags")["type"] == "list" and _entry(b, "tags")["default"] == ["x"], "PackedStringArray is a list")
	_check(_entry(b, "count")["type"] == "int" and _entry(b, "count")["max"] == 100, "int field")


func _defaults() -> void:
	var b := _make("none")
	var res := b.load_layers()
	_check(res.ok, "load with no files succeeds")
	_check(b.source_of("speed") == "default" and b.config.speed == 2.0, "no layer: default")
	_check(b.diff().is_empty(), "no layer: empty diff")


func _layers() -> void:
	DirAccess.make_dir_recursive_absolute("user://cfgtest")
	var f := FileAccess.open("user://cfgtest/tg.json", FileAccess.WRITE)
	f.store_string('{"speed": 1.5, "count": 7, "label": "json"}')
	f.close()
	var b := _make("cfg", true, "user://cfgtest/tg.json")
	var res := b.load_layers()
	_check(res.ok, "layered load succeeds: %s" % (res.error.message if not res.ok else ""))
	_check(b.config.speed == 4.5 and b.source_of("speed") == "yml", "server tier beats game tier beats json")
	_check(b.config.count == 12, "server tier count")
	_check(b.config.label == "from game tier", "game tier beats json")
	_check(b.config.tags == PackedStringArray(["a", "b"]), "list from yml")
	OS.set_environment("TGTEST_SPEED", "7")
	var e := _make("cfg", true, "user://cfgtest/tg.json")
	e.load_layers()
	OS.unset_environment("TGTEST_SPEED")
	_check(e.config.speed == 7.0 and e.source_of("speed") == "env", "env beats yml and records its layer")
	var lines := "\n".join(e.report_lines())
	_check(lines.contains("speed") and lines.contains("env") and lines.contains("default"), "report names the layer of each value")
	var json_only := _make("none", true, "user://cfgtest/tg.json")
	json_only.load_layers()
	_check(json_only.config.speed == 1.5 and json_only.source_of("speed") == "json", "json layer alone")


func _cvars() -> void:
	var console := DotConsole.new()
	add_child(console)
	var b := _make("cfg")
	b.replicate_groups = PackedStringArray(["Movement"])
	b.load_layers()
	var made := b.bind_cvars(console.cvar, DotConVar.FLAG_ARCHIVE)
	_check(made.size() == 6, "one cvar per field")
	_check(console.get_float("tg_speed") == 4.5 and console.get_string("tg_label") == "from game tier", "cvar starts at the effective value")
	_check(console.get_string("tg_tags") == "a,b" and console.get_string("tg_friendly_fire") == "0", "list and bool text")
	_check(b.cvar_for("speed").has_flag(DotConVar.FLAG_REPLICATED) and not b.cvar_for("tie").has_flag(DotConVar.FLAG_REPLICATED), "replicated by group")
	_check(console.find_cvar("tg_speed").description.begins_with("Metres per second"), "cvar carries the doc comment")
	console.set_cvar("tg_speed", "9")
	_check(b.config.speed == 9.0 and b.source_of("speed") == "cvar", "cvar -> field")
	console.set_cvar("tg_speed", "99")
	_check(b.config.speed == 20.0, "cvar range clamps the field")
	console.set_cvar("tg_friendly_fire", "1")
	_check(b.config.friendly_fire, "bool cvar")
	console.set_cvar("tg_tags", "p,q,r")
	_check(b.config.tags == PackedStringArray(["p", "q", "r"]), "list cvar")
	var bad := console.set_cvar("tg_tie", "3")
	_check(not bad.ok and b.config.tie == 1, "enum cvar refuses a value outside the options")
	console.set_cvar("tg_tie", "5")
	_check(b.config.tie == 5, "enum cvar accepts an option")
	var again := b.bind_cvars(console.cvar, 0, console.has_name)
	_check(again.is_empty(), "names already registered are skipped")
	b.config.speed = 3.0
	b._assign("speed", 6.0, "workbench")
	_check(console.get_float("tg_speed") == 6.0, "field -> cvar through the workbench path")
	console.queue_free()


func _strict() -> void:
	var b := _make("bad")
	var res := b.load_layers()
	_check(not res.ok and res.error.message.contains("spede"), "strict: an unknown yml key fails and names it")
	var lax := _make("bad", false)
	_check(lax.load_layers().ok, "not strict: an unknown yml key is logged, boot continues")
	_check(not _make("badtype").load_layers().ok, "strict: a value above the range fails")
	var f := FileAccess.open("user://cfgtest/broken.json", FileAccess.WRITE)
	f.store_string("{not json")
	f.close()
	var j := _make("none", true, "user://cfgtest/broken.json")
	_check(not j.load_layers().ok, "strict: bad JSON fails")
	f = FileAccess.open("user://cfgtest/unknown.json", FileAccess.WRITE)
	f.store_string('{"speeed": 1}')
	f.close()
	_check(not _make("none", true, "user://cfgtest/unknown.json").load_layers().ok, "strict: unknown JSON key fails")
	f = FileAccess.open("user://cfgtest/invalid.json", FileAccess.WRITE)
	f.store_string('{"count": 13}')
	f.close()
	_check(not _make("none", true, "user://cfgtest/invalid.json").load_layers().ok, "strict: validate() failure fails")
	var m := _make("none")
	_check(not m.check_map("nope", ["a", "b"]).ok, "strict: unknown map fails")
	_check(m.check_map("a", ["a", "b"]).ok and m.check_map("", ["a"]).ok, "known or empty map passes")
	m.strict = false
	_check(m.check_map("nope", ["a"]).ok and m.check_map("nope", ["a"]).value == "", "not strict: unknown map falls back to the default")


func _diff() -> void:
	var b := _make("cfg")
	b.load_layers()
	var d := b.diff()
	_check(d.keys().size() == 4 and d["speed"] == 4.5 and d["count"] == 12 and d["tags"] == ["a", "b"], "diff holds only changed fields: %s" % str(d.keys()))
	_check(not d.has("tie") and not d.has("friendly_fire"), "unchanged fields are not in the diff")
	var text := b.diff_yaml()
	var parsed := DotYaml.parse(text)
	_check(parsed.ok and parsed.value["speed"] == 4.5 and parsed.value["tags"] == ["a", "b"] and parsed.value["label"] == "from game tier", "diff yml parses back")
	var wrote := b.write_diff("user://cfgtest/out/game.yml")
	_check(wrote.ok and FileAccess.file_exists("user://cfgtest/out/game.yml"), "diff written to a path")
	var console := DotConsole.new()
	add_child(console)
	b.bind_commands(console.command, "")
	_check(console.has_name("tg_config_diff") and console.has_name("tg_config_dump"), "diff and dump commands register")
	_check(console.execute("tg_config_diff save").ok and FileAccess.file_exists(b.diff_path()), "the diff command saves to its fixed path")
	console.queue_free()
	# The exported file, used as a game-tier default, reproduces the values.
	DirAccess.make_dir_recursive_absolute("user://cfgtest/round/game/tg/config")
	DirAccess.copy_absolute("user://cfgtest/out/game.yml", "user://cfgtest/round/game/tg/config/game.yml")
	var r := DotGameConfigBinder.create(TestConfig.new(), "tg", "tg")
	r.roots = PackedStringArray(["user://cfgtest/round"])
	r.load_layers()
	_check(r.config.speed == 4.5 and r.config.count == 12 and r.config.label == "from game tier" and r.diff() == d, "exported diff round-trips as a default")


func _workbench() -> void:
	var console := DotConsole.new()
	add_child(console)
	var b := _make("cfg")
	b.load_layers()
	b.bind_cvars(console.cvar)
	var rt := DotProfileRuntime.new()
	rt.permit = func(_actor: Variant, _flag: String) -> bool: return true
	b.attach(rt)
	_check(b.profile_set().list_ids() == PackedStringArray(["game"]), "the config profile is listed with no file for its id")
	var res := rt.handle_request("tester", DotProfileRuntime.make_request("set", "config", "game", "speed", 8.0))
	_check(res.ok and b.config.speed == 8.0 and console.get_float("tg_speed") == 8.0, "workbench set -> field and cvar")
	_check(b.source_of("speed") == "workbench", "source is the workbench")
	var bad := rt.handle_request("tester", DotProfileRuntime.make_request("set", "config", "game", "speed", 99.0))
	_check(not bad.ok and b.config.speed == 8.0, "workbench refuses a value out of range")
	rt.handle_request("tester", DotProfileRuntime.make_request("reset_key", "config", "game", "speed"))
	_check(b.config.speed == 4.5 and console.get_float("tg_speed") == 4.5, "reset returns the lower layer's value")
	console.queue_free()
