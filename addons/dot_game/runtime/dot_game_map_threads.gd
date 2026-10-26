extends RefCounted

## The `map_load_threads` cvar (workers for the pure-CPU stages of a map load, dot-map's docs/load-threads.md) and its copy into dot-map's `DotMapParallelBuild.default_workers`. dot-map is reached by path and never named; without it the cvar exists and does nothing. No class_name: the module and the client preload it.

const CHANNEL := "game.map_threads"
const CVAR := "map_load_threads"
const BUILD_SCRIPT := "res://addons/dot_map/bsp/dot_map_parallel_build.gd"
const HELP := "Worker threads for map loading: 0 inline (default), N workers, -1 automatic. Never used on the web."

## What the client console variable last held; the server reads its cvar instead.
static var client_value: int = 0


## Registers the server cvar on [param console] (once), applies it, and returns it.
static func ensure_cvar(console: DotConsole) -> DotConVar:
	var cv := console.find_cvar(CVAR)
	if cv == null:
		cv = console.cvar(CVAR, "0", HELP, DotConVar.FLAG_ARCHIVE)
		cv.with_range(-1, 64)
	apply(cv.get_int())
	return cv


## Per tick on the server: copies the cvar again when it changed, so `map_load_threads` is live.
static func follow(console: DotConsole) -> void:
	var cv := console.find_cvar(CVAR) if console != null else null
	if cv != null and cv.get_int() != current():
		apply(cv.get_int())


## Sets dot-map's default worker count; false when dot-map is not in this build.
static func apply(workers: int) -> bool:
	var script := _script()
	if script == null:
		return false
	script.set(&"default_workers", workers)
	return true


## What dot-map will use for a load now, or 0 without dot-map.
static func current() -> int:
	var script := _script()
	return int(script.get(&"default_workers")) if script != null else 0


## Adds the variable to a client console source (found by [DotGameClient]'s vis helper) and applies the value it holds.
static func add_client_var(local: Object) -> void:
	local.call(&"add_var", StringName(CVAR), HELP,
		func() -> Variant: return client_value,
		func(v: Variant) -> Variant:
			if not str(v).is_valid_int() or int(str(v)) < -1 or int(str(v)) > 64:
				return DotResult.fail(DotError.CODE_INVALID, "%s is -1 (auto), 0 (off) or a count up to 64" % CVAR)
			client_value = int(str(v))
			var _ok := apply(client_value)
			return DotResult.success(client_value))


## Applies a [code]--map_load_threads=[/code] user argument, before any map loads.
static func apply_cmdline() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % CVAR) and a.get_slice("=", 1).is_valid_int():
			client_value = clampi(int(a.get_slice("=", 1)), -1, 64)
			var _ok := apply(client_value)


static func _script() -> Script:
	return load(BUILD_SCRIPT) as Script if ResourceLoader.exists(BUILD_SCRIPT) else null
