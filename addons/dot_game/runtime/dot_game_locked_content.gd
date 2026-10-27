class_name DotGameLockedContent
extends RefCounted
## Mounts what a game's `content.lock.json` pins, through dot-cloud's `ensure_locked`, behind the load gate. A game with no lock does nothing.

const CHANNEL := "game.locked_content"
const REASON := &"locked_content"
const LOCK_FILE := "content.lock.json"
const META_REPORT := &"locked_content_report"

## Test seam: where the lock is looked for when non-empty (the first existing path).
static var lock_override: String = ""


## `--locked_content=0` (or off/false/no) switches it off; `--locked_content=PATH` names the lock file.
static func cmdline_value() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--locked_content="):
			return a.get_slice("=", 1).strip_edges()
	return ""


static func disabled_by_cmdline() -> bool:
	return cmdline_value().to_lower() in ["0", "off", "false", "no", "none"]


## The lock file this game ships: `--locked_content=PATH`, else `res://content.lock.json`, else the one beside a linked `res://maps` (a map repository's lock). Empty when there is none.
static func find_lock() -> String:
	var forced := lock_override if lock_override != "" else cmdline_value()
	if forced != "" and not disabled_by_cmdline():
		return forced if FileAccess.file_exists(forced) else ""
	var here := "res://" + LOCK_FILE
	if FileAccess.file_exists(here):
		return here
	var maps := ProjectSettings.globalize_path("res://maps").rstrip("/")
	if DirAccess.dir_exists_absolute(maps):
		var real := maps
		var parent := DirAccess.open(maps.get_base_dir())
		if parent != null and parent.is_link(maps.get_file()):
			real = parent.read_link(maps.get_file())
			if real.is_relative_path():
				real = maps.get_base_dir().path_join(real)
		var beside := real.simplify_path().get_base_dir().path_join(LOCK_FILE)
		if FileAccess.file_exists(beside):
			return beside
	return ""


## Ensures the lock's packs with [param cloud] (a DotCloudClient) and holds [param gate] meanwhile. The value is ensure_locked's report, or null when there was nothing to do. Never blocks the game on failure: the gate is released and the failure logged.
static func run(cloud: Object, gate: DotLoadGate = null, opts: Dictionary = {}) -> DotResult:
	if disabled_by_cmdline():
		DotLog.info(CHANNEL, "locked content switched off by --locked_content")
		return DotResult.success(null)
	var lock := find_lock()
	if lock == "":
		return DotResult.success(null)
	if cloud == null or not cloud.has_method(&"ensure_locked"):
		DotLog.warn(CHANNEL, "a content.lock.json is shipped but there is no dot-cloud client to mount it", {"lock": lock})
		return DotResult.success(null)
	if gate != null and is_instance_valid(gate) and not gate.is_open():
		gate.hold(REASON, "Fetching game content")
	DotLog.info(CHANNEL, "mounting locked content", {"lock": lock})
	var got: DotResult = await cloud.call(&"ensure_locked", lock, opts)
	if gate != null and is_instance_valid(gate):
		gate.release(REASON)
	DotWeb.sync_filesystem()
	if got.ok:
		DotLog.info(CHANNEL, "locked content ready", {
			"mounted": ", ".join(PackedStringArray(got.value["mounted"])),
			"skipped": (got.value["skipped"] as Array).size(),
		})
	else:
		DotLog.warn(CHANNEL, "locked content not mounted", {"lock": lock, "error": str(got.error)})
	return got
