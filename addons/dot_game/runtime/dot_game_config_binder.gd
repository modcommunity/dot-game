class_name DotGameConfigBinder
extends RefCounted

## Makes a game's [DotConfig] (its tunables) operator-reachable: one layered load with the
## layer each value came from, a cvar per field, a profile kind `config` the workbench edits,
## and the yml diff against the code defaults.
##
## [codeblock]
## var binder := DotGameConfigBinder.create(config, "mygame", "mg", "user://cfg/mygame.json")
## var res := binder.load_layers()             # strict on a dedicated server: failure = exit
## if not res.ok: DotGameConfigBinder.fail_boot(get_tree(), res)
## binder.bind_cvars(add_cvar)                 # in the module, after the console exists
## binder.attach(profile_runtime)              # optional: live edits from dot-workbench
## [/codeblock]
##
## Layers, weakest first: code defaults, [member json_path], the `config` profile
## (`cfg/game/<game>/config/game.yml`, then `cfg/server/game/<game>/config/game.yml`, then
## `PROFILE_CONFIG_GAME_<KEY>` / `--profile.config/game.<key>=`), the config's own env and argv,
## then cvars and the workbench at runtime. Docs: dot-game `docs/config-binder.md`.

const CHANNEL := "game.config"
const PROFILE_KIND := "config"
const DEFAULT_ID := "game"

## Emitted when a field changes after load: [param source] is `cvar` or `workbench`.
signal field_changed(key: String, value: Variant, source: String)

var config: DotConfig
var game_id := ""
## cvars are `<cvar_prefix>_<field>`.
var cvar_prefix := ""
## JSON layer (the game's old `user://cfg/<game>.json`); empty skips it.
var json_path := ""
## Unknown keys, a bad JSON/profile file or a failed validate make [method load_layers] fail.
var strict := default_strict()
var profile_id := DEFAULT_ID
## The workbench kind (and cfg subdirectory) of the profile set; a second binder in one game needs its own.
var profile_kind := PROFILE_KIND
## Fields never exposed (on top of the config's sensitive keys).
var skip_keys := PackedStringArray()
## Fields whose cvar is REPLICATED (a client predicts with them), by name or by `@export_group`.
var replicate_keys := PackedStringArray()
var replicate_groups := PackedStringArray()
## Config roots for the profile files; empty is the family's default.
var roots := PackedStringArray()

var _schema: Array = []
var _set: DotProfileSet = null
var _defaults := {}
var _base := {}
var _sources := {}
var _layer_log: Array = []
var _cvars := {}
var _skipped := {}
var _syncing := false
var _rt_keys := PackedStringArray()
var _runtime: DotProfileRuntime = null


## [param p_prefix] is the cvar prefix without the underscore (`hs`).
static func create(p_config: DotConfig, p_game: String, p_prefix: String, p_json := "") -> DotGameConfigBinder:
	var b := DotGameConfigBinder.new()
	b.config = p_config
	b.game_id = p_game
	b.cvar_prefix = p_prefix
	b.json_path = p_json
	b._defaults = p_config.to_dictionary()
	return b


## On for a dedicated/headless server outside the editor; `--config-strict` / `--no-config-strict` decide otherwise.
static func default_strict() -> bool:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	if args.has("--no-config-strict"):
		return false
	if args.has("--config-strict"):
		return true
	if Engine.is_editor_hint():
		return false
	return OS.has_feature("dedicated_server") or DisplayServer.get_name() == "headless"


## Logs [param res] as an ERROR and quits with a non-zero code. The one exit a strict boot takes.
static func fail_boot(tree: SceneTree, res: DotResult, code := 2) -> void:
	DotLog.error(CHANNEL, "configuration refused, not starting", {"why": res.error.message})
	if tree != null:
		tree.quit(code)


## [param requested] against [param known] map ids: failure when strict and unknown (and non-empty).
func check_map(requested: String, known: Array) -> DotResult:
	if requested == "" or known.has(requested):
		return DotResult.success(requested)
	var msg := "unknown map '%s' (known: %s)" % [requested, ", ".join(PackedStringArray(known))]
	if strict:
		return DotResult.fail(DotError.CODE_INVALID, msg)
	DotLog.warn(CHANNEL, msg)
	return DotResult.success("")


## The exposed fields: see [method DotGameConfigSchema.of].
func schema() -> Array:
	if _schema.is_empty():
		_schema = DotGameConfigSchema.of(config, skip_keys)
		for e: Dictionary in _schema:
			if e["description"] == "":
				e["description"] = _shipped_docs().get(e["key"], "")
	return _schema


## The `config` profile set over [method schema] (id [member profile_id], never needs a file).
func profile_set() -> DotProfileSet:
	if _set != null:
		return _set
	var fields: Array = []
	for e: Dictionary in schema():
		var opts := {}
		for k in ["min", "max", "enum", "group", "description", "options", "step"]:
			if e.has(k) and (k != "description" or e[k] != ""):
				opts[k] = e[k]
		fields.append(DotProfileSet.field(e["key"], e["type"], e["default"], opts))
	_set = DotProfileSet.create("", game_id, profile_kind, fields)
	_set.implicit_ids = PackedStringArray([profile_id])
	_set.strict = strict
	if not roots.is_empty():
		_set.roots = roots
	return _set


## Runs every layer and validates. Value: self. See the class doc for the order.
func load_layers() -> DotResult:
	var problems := PackedStringArray()
	_sources.clear()
	_layer_log.clear()
	config.unknown_keys = PackedStringArray()
	if json_path != "" and FileAccess.file_exists(json_path):
		var res := config.apply_json_file(json_path)
		if res.ok:
			_note("json", res.value, json_path)
		else:
			problems.append(res.error.message)
	var set := profile_set()
	if _file_present(set):
		var p := set.load_profile(profile_id)
		if p.ok:
			_apply_profile(p.value as DotProfile, problems)
		else:
			problems.append(p.error.message)
	_note("env", config.apply_env(), "")
	_note("argv", config.apply_cli(), "")
	for k in config.unknown_keys:
		problems.append("unknown config key '%s'" % k)
	var valid := config.validate()
	if not valid.ok:
		problems.append(valid.error.message)
	_base = config.to_dictionary()
	_dump()
	if problems.is_empty():
		return DotResult.success(self)
	for p in problems:
		DotLog.error(CHANNEL, p, {"game": game_id, "strict": strict})
	if strict:
		return DotResult.fail(DotError.CODE_INVALID, "; ".join(problems))
	return DotResult.success(self)


func _file_present(set: DotProfileSet) -> bool:
	return not set._files_for(profile_id).is_empty() or _has_override()


func _has_override() -> bool:
	for a in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if a.begins_with("--profile.%s/%s." % [profile_kind, profile_id]):
			return true
	return false


func _apply_profile(p: DotProfile, problems: PackedStringArray) -> void:
	var names := {}
	for e: Dictionary in schema():
		names[e["key"]] = true
	var file := {}
	for path in p.file_keys:
		var top := String(path).split(".")[0]
		if top == DotProfileSet.EXTRA_KEY:
			continue
		if names.has(top):
			file[top] = true
		else:
			problems.append("unknown key '%s' in %s" % [top, p.sources[p.sources.size() - 1] if not p.sources.is_empty() else "profile"])
	var over := {}
	for o in p.overrides:
		over[String(o).split(" <- ")[0]] = String(o).split(" <- ")[1]
	var d := {}
	for k in file:
		d[k] = p.values[k]
	var from := p.sources[p.sources.size() - 1] if not p.sources.is_empty() else "yml"
	_note("yml", config.apply_dictionary(d, "yml"), from)
	d.clear()
	for k in over:
		d[k] = p.values[k]
	if not d.is_empty():
		_note("profile-override", config.apply_dictionary(d, "profile-override"), ", ".join(PackedStringArray(over.values())))


func _note(layer: String, keys: PackedStringArray, from: String) -> void:
	for k in keys:
		_sources[k] = layer if from == "" else "%s (%s)" % [layer, from]
	_layer_log.append({"layer": layer, "from": from, "keys": keys})


func _dump() -> void:
	for l in _layer_log:
		if not (l["keys"] as PackedStringArray).is_empty():
			DotLog.info(CHANNEL, "layer applied", {"game": game_id, "layer": l["layer"], "from": l["from"], "keys": ", ".join(l["keys"])})
	for line in report_lines():
		DotLog.debug(CHANNEL, line)


## Every exposed field with its effective value and the layer it came from (`default` when none).
func report_lines() -> PackedStringArray:
	var out := PackedStringArray()
	for e: Dictionary in schema():
		var k: String = e["key"]
		out.append("%-32s %-24s %s" % [k, str(config.get(k)), _sources.get(k, "default")])
	return out


## The layer that last set [param key]: `default`, `json`, `yml`, `profile-override`, `env`, `argv`, `cvar`, `workbench`.
func source_of(key: String) -> String:
	return String(_sources.get(key, "default")).split(" ")[0]


# --- cvars -----------------------------------------------------------------

## Registers `<prefix>_<field>` for every exposed field not already a cvar. [param add_cvar] is
## the module's (name, default, description, flags) -> DotConVar; [param exists] (name) -> bool
## skips a name the game already binds by hand. Returns the made cvars.
func bind_cvars(add_cvar: Callable, flags := DotConVar.FLAG_ARCHIVE, exists := Callable()) -> Array:
	var made: Array = []
	for e: Dictionary in schema():
		var key: String = e["key"]
		var name := "%s_%s" % [cvar_prefix, key]
		if exists.is_valid() and exists.call(name):
			_skipped[key] = "already a cvar"
			continue
		var f := flags
		if replicate_keys.has(key) or replicate_groups.has(e["group"]):
			f |= DotConVar.FLAG_REPLICATED
		var desc: String = e["description"]
		if desc.length() > 200:
			desc = desc.substr(0, 197) + "..."
		var c: DotConVar = add_cvar.call(name, _to_text(config.get(key)), desc, f)
		if c == null:
			continue
		if e.has("min") and e.has("max"):
			c.with_range(float(e["min"]), float(e["max"]))
		elif e.has("min"):
			c.with_min(float(e["min"]))
		if e.has("enum"):
			c.with_validator(_enum_check.bind(name, e["enum"]))
		c.changed.connect(_on_cvar.bind(key))
		_cvars[key] = c
		made.append(c)
	DotLog.info(CHANNEL, "config cvars bound", {"game": game_id, "cvars": made.size(), "skipped": _skipped.size()})
	return made


func cvar_for(key: String) -> DotConVar:
	return _cvars.get(key)


static func _enum_check(text: String, name: String, allowed: Array) -> DotResult:
	var v: Variant = int(text) if text.is_valid_int() else text
	if allowed.has(v):
		return DotResult.success(text)
	return DotResult.fail(DotError.CODE_INVALID, "%s must be one of %s" % [name, str(allowed)])


static func _to_text(v: Variant) -> String:
	if v is bool:
		return "1" if v else "0"
	if v is PackedStringArray or v is Array:
		return ",".join(PackedStringArray(v))
	return str(v)


func _from_text(key: String, text: String) -> Variant:
	var cur: Variant = config.get(key)
	if cur is PackedStringArray:
		return PackedStringArray(text.split(",", false))
	if cur is Array:
		return Array(text.split(",", false))
	return text


func _on_cvar(_old: String, text: String, key: String) -> void:
	if _syncing:
		return
	var applied := config.apply_dictionary({key: _from_text(key, text)}, "cvar")
	if applied.is_empty():
		return
	_base[key] = config.get(key)
	_sources[key] = "cvar"
	field_changed.emit(key, config.get(key), "cvar")


# --- the workbench ---------------------------------------------------------

## Adds the `config` kind to [param runtime]; an edit there writes the field and its cvar.
func attach(runtime: DotProfileRuntime) -> void:
	_runtime = runtime
	runtime.add_set(profile_set())
	runtime.profile_changed.connect(_on_profile)


func _on_profile(kind: String, id: String, _rev: int) -> void:
	if kind != profile_kind or id != profile_id:
		return
	var set := profile_set()
	var paths := set.runtime_paths(profile_id)
	var now := PackedStringArray()
	for p in paths:
		now.append(String(p).split(".")[0])
	var loaded := set.load_profile(profile_id)
	if not loaded.ok:
		return
	var p: DotProfile = loaded.value
	for k in _rt_keys:
		if not now.has(k):
			_assign(k, _base.get(k), "workbench")
	for k in now:
		if p.values.has(k):
			_assign(k, p.values[k], "workbench")
	_rt_keys = now


func _assign(key: String, v: Variant, source: String) -> void:
	if str(config.get(key)) == str(v):
		return
	config.apply_dictionary({key: v}, source)
	_sources[key] = source
	var c: DotConVar = _cvars.get(key)
	if c != null:
		_syncing = true
		c.force_set(_to_text(config.get(key)))
		_syncing = false
	field_changed.emit(key, config.get(key), source)


# --- the diff --------------------------------------------------------------

## field -> effective value, for every exposed field that differs from the code defaults.
func diff() -> Dictionary:
	var out := {}
	for e: Dictionary in schema():
		var k: String = e["key"]
		var now: Variant = config.get(k)
		var was: Variant = _defaults.get(k)
		if now is PackedStringArray:
			now = Array(now)
		if not _same(now, was):
			out[k] = now
	return out


static func _same(a: Variant, b: Variant) -> bool:
	if (a is float or b is float) and (a is float or a is int) and (b is float or b is int):
		return is_equal_approx(float(a), float(b))
	return a == b


## [method diff] as the yml of a `config` profile: save it as `cfg/game/<game>/config/game.yml`
## and the values become the shipped defaults.
func diff_yaml() -> String:
	var d := diff()
	var text := "# %s: values that differ from the code defaults, as of the running config.\n" % game_id
	var keys := d.keys()
	keys.sort()
	for k in keys:
		text += "%s: %s\n" % [k, _yaml(d[k])]
	return text


static func _yaml(v: Variant) -> String:
	if v is Array:
		var parts := PackedStringArray()
		for e in v:
			parts.append(_yaml(e))
		return "[" + ", ".join(parts) + "]"
	if v is bool or v is int:
		return str(v)
	if v is float:
		var s := str(v)
		return s if s.contains(".") or s.contains("e") else s + ".0"
	return "\"" + String(v).replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") + "\""


func write_diff(path: String) -> DotResult:
	var dir := DotPaths.ensure_parent_dir(path)
	if not dir.ok:
		return dir
	return DotPaths.write_text(path, diff_yaml())


## Registers `<prefix>_config_diff [save]` and `<prefix>_config_dump` through the module's
## add_command. `save` writes [method diff_path]; no command takes a path from the caller.
func bind_commands(add_command: Callable, permission := "root") -> void:
	add_command.call("%s_config_diff" % cvar_prefix, _cmd_diff,
		"Print the config values that differ from the code defaults as yml; 'save' writes them to a file", permission)
	add_command.call("%s_config_dump" % cvar_prefix, _cmd_dump,
		"Print every config field with its value and the layer it came from", permission)


## Where the `save` argument of the diff command writes.
func diff_path() -> String:
	return "user://config_diff_%s.yml" % game_id


func _cmd_diff(ctx: DotCmdContext) -> void:
	if ctx.argc() > 0 and ctx.args[0] == "save":
		var res := write_diff(diff_path())
		ctx.reply("wrote %s" % ProjectSettings.globalize_path(diff_path()) if res.ok else res.error.message)
		return
	ctx.reply_lines(diff_yaml().split("\n"))


func _cmd_dump(ctx: DotCmdContext) -> void:
	ctx.reply_lines(report_lines())


# --- shipped docs ----------------------------------------------------------

## Writes name -> description JSON beside the game, for a build whose scripts carry no source.
func write_schema(path: String) -> DotResult:
	var d := {}
	for e: Dictionary in schema():
		d[e["key"]] = e["description"]
	return DotPaths.write_json(path, d)


func _shipped_docs() -> Dictionary:
	var path := "res://cfg/game/%s/config/schema.json" % game_id
	if not FileAccess.file_exists(path):
		return {}
	var res := DotPaths.read_json(path)
	return res.value if res.ok and res.value is Dictionary else {}
