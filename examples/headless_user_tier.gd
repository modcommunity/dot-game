extends Node

## The player's user:// cfg tier end to end: a process that is a dedicated server ignores a user override, solo and a listen host apply it.

const ADDON := "dot_game_usertier_probe"
const FILE := "probe.yml"
const CHECKS := 16

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


## Stands in for the browser bridge and counts the flushes.
class SyncBridge extends Object:
	var syncs := 0

	func force_fs_sync() -> void:
		syncs += 1


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _run() -> void:
	print("dot-game: user cfg tier by process kind")
	_clean()
	var schema := [{"name": "mode", "type": "string", "default": "default"}]
	var defaults := {"mode": "default"}
	var host := Node.new()
	add_child(host)

	var solo := _client(host, true, false, false)
	_check(solo.user_tier_on and DotAddonConfig.user_tier_enabled, "solo: tier on")
	var bridge := SyncBridge.new()
	DotWeb._bridge_looked_up = true
	DotWeb._bridge = bridge
	var saved := DotAddonConfig.save_user(ADDON, FILE, {"mode": "mine"}, schema)
	DotWeb._bridge = null
	_check(saved.ok, "solo: the override is written")
	_check(bridge.syncs >= 1, "the write flushes the browser filesystem")
	_check(_mode(defaults) == "mine", "solo: the effective value is the override")
	bridge.free()
	host.remove_child(solo)
	solo.free()
	_check(not DotAddonConfig.user_tier_enabled, "leaving the tree clears the tier")

	var dedicated := _client(host, true, true, true)
	_check(not dedicated.user_tier_on and not DotAddonConfig.user_tier_enabled, "dedicated: tier off even offline and hosting")
	_check(_mode(defaults) == "default", "dedicated: the effective value ignores the override")
	_check(DotAddonConfig.file_layers(ADDON, FILE).size() <= 1, "dedicated: no user layer is listed")
	var refused := DotAddonConfig.save_user(ADDON, FILE, {"mode": "again"}, schema)
	_check(not refused.ok and refused.error.code == DotError.CODE_STATE, "dedicated: a write is refused")
	_check(DotAddonConfig.user_paths(ADDON, FILE) == {"mode": "mine"}, "dedicated: the file on disk is untouched")
	host.remove_child(dedicated)
	dedicated.free()

	var listen := _client(host, false, true, false)
	_check(listen.user_tier_on and _mode(defaults) == "mine", "listen host: the override applies")
	host.remove_child(listen)
	listen.free()

	var guest := _client(host, false, false, false)
	_check(not guest.user_tier_on and _mode(defaults) == "default", "guest of another server: ignored")
	host.remove_child(guest)
	guest.free()

	var solo2 := _client(host, true, false, false)
	_check(solo2.user_tier_on and _mode(defaults) == "mine", "solo again: applied")
	var reset := DotAddonConfig.reset_user(ADDON, FILE)
	_check(reset.ok and _mode(defaults) == "default", "reset returns the default")
	host.remove_child(solo2)
	solo2.free()

	_clean()
	_check(DotAddonConfig.user_paths(ADDON, FILE).is_empty(), "probe cleaned up")
	_check(not DotAddonConfig.user_tier_enabled, "tier left off")
	if _passed + _failed != CHECKS:
		_failed += 1
		_failures.append("ran %d checks, expected %d" % [_passed + _failed - 1, CHECKS])
	for f in _failures:
		print("FAIL: ", f)
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _client(host: Node, solo: bool, listen_host: bool, dedicated: bool) -> DotGameClient:
	var c := DotGameClient.new()
	c.use_gate = false
	c.force_offline = solo or dedicated
	c.listen_host_fn = func() -> bool: return listen_host
	c.dedicated_fn = func() -> bool: return dedicated
	if not c.force_offline:
		c.link = Link.new()
	host.add_child(c)
	return c


class Link extends RefCounted:
	func is_connected_to_server() -> bool:
		return true


func _mode(defaults: Dictionary) -> String:
	var res := DotAddonConfig.load_dir(ADDON, defaults)
	return str(res.value.get("mode", "")) if res.ok else "?"


func _clean() -> void:
	DotAddonConfig.set_user_tier(true)
	var _r := DotAddonConfig.reset_user(ADDON, FILE)
	DotAddonConfig.set_user_tier(false)


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what)
