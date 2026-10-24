class_name DotGamePrejoin
extends RefCounted

## Fetches the avatar files a server advertises before a shell connects to it, so every game
## gets it at the one place a connection starts, not in each game.
##
## A dead CDN must never keep a player out, so this never blocks past [member timeout_sec] and
## a failure is a warning: the caller joins anyway and the figures fall back to the stock avatar.

const CHANNEL := "game.prejoin"

## The query that reads the server's advertised rules (dot-browser, by path; absent is no ids).
const BROWSER_SCRIPT := "res://addons/dot_browser/runtime/dot_browser.gd"
const TARGET_SCRIPT := "res://addons/dot_browser/core/dot_browser_target.gd"

## Longest the downloads may take before the join goes ahead without them.
var timeout_sec: float = 20.0
## Longest the rules query may take.
var query_timeout_sec: float = 3.0
## The site the library is read from, and this server's id on it.
var site_url: String = ""
var server_id: int = 0
## Called as `func(fraction: float, text: String)` while files arrive; the shell's loading screen.
var progress_fn: Callable = Callable()
## Assigned, replaces the rules query: `func(address: String) -> Dictionary`.
var rules_fn: Callable = Callable()
## Assigned, replaces the download: `func(ids: Array, gate: DotLoadGate) -> DotResult`. For suites.
var fetch_fn: Callable = Callable()
var http: DotHttp = null


## Success holds the number of files downloaded. A failure means the files are not ready;
## the caller logs it and connects regardless.
func prepare(host: Node, address: String) -> DotResult:
	var rules: Dictionary = await _rules(host, address)
	var ids := DotGameAvatarContent.ids_from_rules(rules)
	if ids.is_empty():
		return DotResult.success(0)
	var gate := DotLoadGate.new()
	gate.register_service = false
	gate.require_camera = false
	if progress_fn.is_valid():
		gate.progress_changed.connect(progress_fn)
	var state := {"done": false, "res": null}
	_run(host, ids, gate, state)
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	var tree := host.get_tree()
	while not state["done"] and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	var res: DotResult
	if state["done"]:
		res = state["res"]
	else:
		res = DotResult.fail(DotError.CODE_TIMEOUT, "Avatar downloads took longer than %.1f s." % timeout_sec)
	if not res.ok:
		DotLog.warn(CHANNEL, "avatar content not ready; joining anyway", {"why": res.error.message, "address": address})
	if is_instance_valid(gate):
		gate.free()
	return res


func _run(host: Node, ids: Array, gate: DotLoadGate, state: Dictionary) -> void:
	var res: DotResult
	if fetch_fn.is_valid():
		res = await fetch_fn.call(ids, gate)
	else:
		res = await DotGameAvatarContent.prepare(host, ids, site_url, server_id, gate, http)
	state["res"] = res
	state["done"] = true


func _rules(host: Node, address: String) -> Dictionary:
	if rules_fn.is_valid():
		return await rules_fn.call(address)
	if not ResourceLoader.exists(BROWSER_SCRIPT) or not ResourceLoader.exists(TARGET_SCRIPT):
		return {}
	var parsed: DotResult = (load(TARGET_SCRIPT) as GDScript).call(&"parse", address)
	if not parsed.ok:
		return {}
	var browser: Node = (load(BROWSER_SCRIPT) as GDScript).new()
	browser.set(&"timeout_ms", int(query_timeout_sec * 1000.0))
	host.add_child(browser)
	var res: DotResult = await browser.call(&"query", parsed.value, PackedStringArray(["info", "rules"]))
	var rules := {}
	if res.ok and res.value != null:
		rules = (res.value.get(&"rules") as Dictionary) if res.value.get(&"rules") is Dictionary else {}
	browser.queue_free()
	return rules
