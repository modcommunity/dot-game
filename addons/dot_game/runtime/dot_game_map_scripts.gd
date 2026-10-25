class_name DotGameMapScripts
extends RefCounted

## Handles the events a dot-map [code]DotMapScript[/code] replays: `script.set_player_speed`,
## `script.kill_players`, `script.cleanup_map`. Every operation is re-validated against dot-map's table, so
## a forged event gains nothing. Assign [method handle] as the world's `event_fn`; each operation has a hook Callable.

const CHANNEL := "game.map_scripts"
const SCRIPT_PATH := "res://addons/dot_map/io/dot_map_script.gd"
const PREFIX := "script."
## Source units to metres, as dot-player-controller's [code]sv_runspeed[/code] stores it.
const SOURCE_UNIT := 0.01905

## Per-map yml keys: each is a bool that switches one operation (or all) for that map.
const CONFIG_KEYS := {
	"map_script_enabled": {"type": "bool"},
	"map_script_set_player_speed": {"type": "bool"},
	"map_script_kill_players": {"type": "bool"},
	"map_script_cleanup_map": {"type": "bool"},
}

signal handled(op: String, data: Dictionary)
signal refused(kind: String, reason: String)

## Master switch; false drops every script event.
var enabled := true
## Per-operation switches, by operation name (absent means on).
var op_enabled := {}
## The server console whose cvars the default speed handler sets.
var console: Object = null
var run_cvar := "sv_runspeed"
var walk_cvar := "sv_walkspeed"
## Speeds in source units per second a map may ask for; a value inside dot-map's range but outside this is clamped.
var min_speed := 50.0
var max_speed := 1000.0
## `(kind: String, value: float) -> bool`, replaces the cvar write; return false to refuse. `value` is already clamped.
var speed_fn := Callable()
## `() -> int`, kills every player through the game's damage or round API and returns how many.
var kill_fn := Callable()
## `(delay: float) -> void`, removes what the round spawned (props, corpses, drops).
var cleanup_fn := Callable()

var _saved := {}


## The Callable to hand a DotMapWorld as [code]event_fn[/code]: [code](kind, data)[/code].
func event_fn() -> Callable:
	return handle


## Takes one world event. Returns true when it was a script operation this accepted and ran.
func handle(kind: String, data: Dictionary) -> bool:
	if not kind.begins_with(PREFIX):
		return false
	var op := kind.trim_prefix(PREFIX)
	if not enabled or not bool(op_enabled.get(op, true)):
		return _refuse(kind, "switched off")
	if not _valid(op, data):
		return _refuse(kind, "not a valid operation")
	match op:
		"set_player_speed":
			if not _set_speed(String(data["kind"]), float(data["value"])):
				return _refuse(kind, "the game refused the speed")
		"kill_players":
			var n := int(kill_fn.call()) if kill_fn.is_valid() else _kill_players()
			DotLog.info(CHANNEL, "map script killed players", {"count": n})
		"cleanup_map":
			if cleanup_fn.is_valid():
				cleanup_fn.call(float(data["delay"]))
			else:
				_cleanup_map(float(data["delay"]))
	handled.emit(op, data)
	return true


## Call on every map change: puts back the speeds a script changed.
func map_changed() -> void:
	restore()


## Puts back every speed a script changed. Returns how many.
func restore() -> int:
	var n := 0
	for key: String in _saved:
		if _write(key, _saved[key]):
			n += 1
	_saved.clear()
	return n


## The per-map keys for [method DotGameModule._map_config_keys] and friends.
func config_keys() -> Dictionary:
	return CONFIG_KEYS.duplicate(true)


func owns_key(key: String) -> bool:
	return CONFIG_KEYS.has(key)


## Current value of a [constant CONFIG_KEYS] key.
func config_get(key: String) -> Variant:
	if key == "map_script_enabled":
		return enabled
	return bool(op_enabled.get(key.trim_prefix("map_script_"), true))


## Sets a [constant CONFIG_KEYS] key; false for any other.
func config_set(key: String, value: Variant) -> bool:
	if not CONFIG_KEYS.has(key):
		return false
	if key == "map_script_enabled":
		enabled = bool(value)
	else:
		op_enabled[key.trim_prefix("map_script_")] = bool(value)
	return true


func describe_lines() -> PackedStringArray:
	return PackedStringArray(["DotGameMapScripts enabled=%s ops_off=%s speeds_changed=%d" % [enabled, op_enabled.keys().filter(func(k: String) -> bool: return not op_enabled[k]), _saved.size()]])


## Override: kill every player. Default logs and kills nobody.
func _kill_players() -> int:
	DotLog.info(CHANNEL, "map script asked to kill players; no kill_fn is assigned")
	return 0


## Override: clean the map up. Default logs and does nothing.
func _cleanup_map(delay: float) -> void:
	DotLog.info(CHANNEL, "map script asked to clean up the map; no cleanup_fn is assigned", {"delay": delay})


## Override to set speeds some other way than cvars.
func _set_speed(kind: String, value: float) -> bool:
	value = clampf(value, min_speed, max_speed)
	if speed_fn.is_valid():
		return bool(speed_fn.call(kind, value))
	if console == null:
		return false
	if kind == "run":
		return _write_saved(run_cvar, value)
	var run := _read(run_cvar)
	if run == null or float(run) <= 0.0:
		return false
	return _write_saved(walk_cvar, value / float(run))


func _write_saved(cvar: String, value: float) -> bool:
	var before: Variant = _read(cvar)
	if before == null:
		return false
	if not _write(cvar, value):
		return false
	if not _saved.has(cvar):
		_saved[cvar] = before
	return true


func _read(cvar: String) -> Variant:
	var cv: Object = console.call("find_cvar", cvar) if console != null else null
	return cv.call("get_string") if cv != null else null


func _write(cvar: String, value: Variant) -> bool:
	if console == null:
		return false
	var res: Variant = console.call("set_cvar", cvar, str(value))
	return res != null and bool(res.get("ok"))


func _refuse(kind: String, reason: String) -> bool:
	DotLog.info(CHANNEL, "map script event refused", {"kind": kind, "reason": reason})
	refused.emit(kind, reason)
	return false


## Re-checks against dot-map's operation table. Without dot-map nothing is valid.
func _valid(op: String, data: Dictionary) -> bool:
	if not ResourceLoader.exists(SCRIPT_PATH):
		return false
	var script: Variant = load(SCRIPT_PATH)
	if script == null:
		return false
	var d := data.duplicate()
	d["op"] = op
	return bool(script.call("valid_op", d))
