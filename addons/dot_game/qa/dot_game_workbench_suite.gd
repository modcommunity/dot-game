class_name DotGameWorkbenchSuite
extends DotGameCheckSuite

## Base for a game's `examples/headless_workbench.gd`: opens the workbench over the game's binder, edits one field per profile set
## (one per bound group when the binder is grouped) and proves the live config changed, the export holds it, and the cfg file loads back.
## A game overrides [method _make_config] and [method _make_binder] and calls [method _run_suite].

const _PERMIT_ID := "mod"
## Sections [method _run_suite] counts: open, edit, export, reload, permit.
const _SECTIONS := 5

var _wb_entered := 0
var _wb_finished := 0


## A fresh config of the game's `DotConfig` subclass.
func _make_config() -> DotConfig:
	return null


## The game's binder over [param config], as its server builds it.
func _make_binder(_config: DotConfig) -> DotGameConfigBinder:
	return null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run_suite.call_deferred()


## Fixed checks (5 before the sets, 2 after) plus 3 per set.
func _run_suite() -> void:
	_wb_entered += 1
	var probe := _make_config()
	var count := _make_binder(probe).profile_sets().size()
	print("workbench: %d profile set(s)" % count)
	var config := _make_config()
	var binder := _make_binder(config)
	_check(binder.load_layers().ok, "defaults load")
	var wb := DotGameWorkbench.new()
	wb.panel_mode = 2
	wb.config = {"enabled": false}
	for set: DotProfileSet in binder.profile_sets():
		wb.add_set(set, set.rel_path)
	add_child(wb)
	var started := wb.start()
	_check(started.ok and started.value == true, "the workbench starts with a panel")
	binder.attach(wb.api.runtime)
	_check(wb.overlay != null and not wb.is_open(), "the window is built and closed")
	wb.open()
	_check(wb.is_open(), "F9 or the command opens it")
	_check(wb.console_command(PackedStringArray(["close"])) == "workbench closed", "the console command closes it")
	_wb_finished += 1
	_wb_entered += 1
	var edits := {}
	for set: DotProfileSet in binder.profile_sets():
		var entry := _pick(binder, set)
		if entry.is_empty():
			_check(false, "%s: a field to edit" % set.rel_path)
			continue
		var key: String = entry["key"]
		var value: Variant = _changed(entry)
		var res: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "set", "kind": set.rel_path, "id": binder.profile_id, "key": key, "value": value})
		_check(res.ok and str(config.get(key)) == str(value), "%s: an edit of %s reaches the live config" % [set.rel_path, key], "" if res.ok else res.error.message)
		edits[set.rel_path] = {"key": key, "value": value}
	_wb_finished += 1
	_wb_entered += 1
	var files: Dictionary = wb.exporter.call("collect")
	var root := "user://cfgtest_%s_export" % binder.game_id
	var written := PackedStringArray()
	for set: DotProfileSet in binder.profile_sets():
		var edit: Dictionary = edits.get(set.rel_path, {})
		if edit.is_empty():
			continue
		var path := "cfg/game/%s/%s/%s.yml" % [binder.game_id, set.rel_path, binder.profile_id]
		var text: String = files.get(path, "")
		_check(text.contains("%s: " % edit["key"]), "%s: the export holds %s in the cfg layout" % [set.rel_path, edit["key"]], path)
		var dir := root.path_join(path.trim_prefix("cfg/").get_base_dir())
		DirAccess.make_dir_recursive_absolute(dir)
		var out := FileAccess.open(dir.path_join("%s.yml" % binder.profile_id), FileAccess.WRITE)
		out.store_string(text)
		out.close()
		written.append(dir.path_join("%s.yml" % binder.profile_id))
	_wb_finished += 1
	_wb_entered += 1
	var again := _make_config()
	var reload := _make_binder(again)
	reload.roots = PackedStringArray([root])
	reload.strict = true
	var loaded := reload.load_layers()
	for set: DotProfileSet in binder.profile_sets():
		var edit: Dictionary = edits.get(set.rel_path, {})
		if edit.is_empty():
			continue
		_check(loaded.ok and str(again.get(edit["key"])) == str(edit["value"]), "%s: the cfg file loads back as the default of %s" % [set.rel_path, edit["key"]], "" if loaded.ok else loaded.error.message)
	for f in written:
		DirAccess.remove_absolute(f)
	_wb_finished += 1
	_wb_entered += 1
	var first: Dictionary = edits.values()[0] if not edits.is_empty() else {}
	var kind: String = edits.keys()[0] if not edits.is_empty() else ""
	if first.is_empty():
		_check(false, "another actor is refused without a permit")
		_check(false, "a permitted actor edits")
	else:
		var other: Variant = wb.api.handle("somebody", {"op": "set", "kind": kind, "id": binder.profile_id, "key": first["key"], "value": first["value"]})
		_check(not other.ok, "another actor is refused without a permit")
		wb.permit_fn = func(actor: Variant, _flag: String) -> bool: return actor == _PERMIT_ID
		_check(wb.api.handle(_PERMIT_ID, {"op": "set", "kind": kind, "id": binder.profile_id, "key": first["key"], "value": first["value"]}).ok, "a permitted actor edits")
	wb.free()
	_wb_finished += 1
	_report_sections(_wb_entered, _wb_finished, _SECTIONS, 7 + 3 * count)


## The first field of [param set] a test can change: numbers, then bool, then enum or string.
func _pick(binder: DotGameConfigBinder, set: DotProfileSet) -> Dictionary:
	var names := {}
	for f: Dictionary in set.schema:
		names[f["name"]] = true
	var best := {}
	var best_rank := 99
	for e: Dictionary in binder.schema():
		if not names.has(e["key"]):
			continue
		var rank := {"int": 0, "float": 0, "bool": 1, "string": 2}.get(e["type"], 99) as int
		if e.has("enum") and (e["enum"] as Array).size() < 2:
			rank = 99
		if rank < best_rank:
			best = e
			best_rank = rank
	return best


## A value other than the field's current one that stays inside its bounds.
func _changed(e: Dictionary) -> Variant:
	var def: Variant = e["default"]
	if e.has("enum"):
		for v: Variant in e["enum"]:
			if str(v) != str(def):
				return v
	match e["type"]:
		"bool":
			return not def
		"int":
			return def + 1 if not e.has("max") or def + 1 <= e["max"] else def - 1
		"float":
			var step: float = maxf(float(e.get("step", 0.0)), 0.25)
			return def + step if not e.has("max") or def + step <= float(e["max"]) else def - step
	return str(def) + "x"
