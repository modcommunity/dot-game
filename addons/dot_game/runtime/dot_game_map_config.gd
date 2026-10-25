class_name DotGameMapConfig
extends RefCounted

## A game's per-map settings: the whitelist and defaults a game declares, applied through dot-map's
## [code]DotMapConfig[/code] (looked up by path; absent applies nothing) on every map change and put back on the next.
## [method for_console] builds one for a game not on [DotGameModule]; then call [method apply] and [method restore].

const CHANNEL := "game.map_config"
const SCRIPT_PATH := "res://addons/dot_map/config/dot_map_config.gd"

## The game whose `cfg/game/<game>/dot_map/` tiers are read.
var game_id: String = ""
## Allowed keys: key -> `{type: "float"|"int"|"bool"|"string", min, max}`. Empty allows nothing.
var keys: Dictionary = {}
## The weakest layer: key -> value a map without a file still gets (the converter's defaults).
var defaults: Dictionary = {}
## `(key: String) -> Variant`, the key's current value.
var get_fn: Callable = Callable()
## `(key: String, value: Variant) -> bool`; false means the game refused it.
var set_fn: Callable = Callable()
## Extra config root, as [code]DotMapConfig.config_dir[/code].
var config_dir: String = ""

var _cfg: Object = null
var _warned := false


## One over a [DotConsole]-shaped object (`find_cvar`, `set_cvar`), which is what a server's cvars are.
static func for_console(p_game: String, console: Object, p_keys: Dictionary, p_defaults: Dictionary = {}) -> DotGameMapConfig:
	var out := DotGameMapConfig.new()
	out.game_id = p_game
	out.keys = p_keys
	out.defaults = p_defaults
	out.get_fn = func(key: String) -> Variant:
		var cv: Object = console.call("find_cvar", key)
		return cv.call("get_string") if cv != null else null
	out.set_fn = func(key: String, value: Variant) -> bool:
		var res: Variant = console.call("set_cvar", key, str(value))
		return res != null and bool(res.get("ok"))
	return out


## Applies [param map_id]'s settings after putting the last map's back. Returns the keys applied; empty when nothing is declared or dot-map is absent.
func apply(map_id: String) -> PackedStringArray:
	if keys.is_empty() and defaults.is_empty():
		return PackedStringArray()
	var cfg := _config()
	if cfg == null:
		return PackedStringArray()
	var res: DotResult = cfg.call("apply", map_id)
	return res.value if res.ok else PackedStringArray()


## Puts back what the last [method apply] changed.
func restore() -> int:
	return int(_cfg.call("restore")) if _cfg != null else 0


## What is applied now: key -> value.
func applied() -> Dictionary:
	return _cfg.call("applied") if _cfg != null else {}


func describe_lines() -> PackedStringArray:
	if _cfg == null:
		return PackedStringArray(["DotGameMapConfig game=%s (not built)" % game_id])
	return _cfg.call("describe_lines")


## The [code]DotMapConfig[/code] under this, built on first use; null without dot-map.
func _config() -> Object:
	if _cfg != null:
		return _cfg
	if not ResourceLoader.exists(SCRIPT_PATH):
		if not _warned:
			_warned = true
			DotLog.info(CHANNEL, "dot-map is not in this build: maps change no settings", {"game": game_id})
		return null
	var script: Variant = load(SCRIPT_PATH)
	if script == null or not script.has_method("new"):
		return null
	_cfg = script.new()
	_cfg.set("game", game_id)
	_cfg.set("config_dir", config_dir)
	_cfg.set("defaults", defaults)
	_cfg.set("get_fn", get_fn)
	_cfg.set("set_fn", set_fn)
	for key: String in keys:
		_cfg.call("allow", key, keys[key])
	return _cfg
