class_name DotGameWorkbench
extends Node

## Hosts dot-workbench in a game: the in-game panel (F9, or the console command `workbench`) and,
## when asked for, the loopback HTTP page.
##
## The panel is on by default in the editor, in debug builds and for a listen host, and off in a
## production build; HTTP is off everywhere until `workbench.enabled: true` in cfg/server.yml.
## dot-workbench, dot-menu and dot-ui are reached by path, so a game without them just has no workbench.
##
## [codeblock]
## var wb := DotGameWorkbench.new()
## wb.add_set(npc_set, "NPCs")           # a game's DotProfileSets (or the binder's)
## add_child(wb)
## wb.start(profile_runtime)             # the game's DotProfileRuntime, so edits replicate
## client.add_workbench(wb)              # optional: menu overlay and console command
## [/codeblock]

const CHANNEL := "game.workbench"
const API_SCRIPT := "res://addons/dot_workbench/dot_workbench_api.gd"
const OVERLAY_SCRIPT := "res://addons/dot_workbench/dot_workbench_overlay.gd"
const HTTP_SCRIPT := "res://addons/dot_workbench/dot_workbench_http.gd"
const EXPORT_SCRIPT := "res://addons/dot_workbench/dot_workbench_export.gd"
## The actor of whoever sits at this machine; allowed only where [method local_allowed] says so.
const LOCAL_ACTOR := "workbench-local"
const DEFAULT_TOKEN_FILE := "user://workbench.token"

signal open_changed(open: bool)

## -1 follows [method default_panel], 0 never, 1 always.
@export_enum("auto", "off", "on") var panel_mode: int = 0
@export var toggle_key: Key = KEY_F9
@export var layer: int = 125
## Callable() -> bool: this process hosts a listen game. Unset means no.
var listen_host_fn: Callable = Callable()
## True on a dedicated server, where no panel is built (HTTP can still run).
var dedicated: bool = false
## Callable(actor, flag) -> bool for actors other than [constant LOCAL_ACTOR] (the console's or admin manager's permit).
var permit_fn: Callable = Callable()
## Callable() -> {cvar: value} of cvars changed from the shipped default, for the export.
var cvars_fn: Callable = Callable()
## The `workbench:` block; read from cfg/server.yml by [method start] when empty.
var config: Dictionary = {}

var api: RefCounted = null
var http: RefCounted = null
var overlay: Control = null
var exporter: RefCounted = null
var running_http := false

var _sets: Array = []
var _labels: Dictionary = {}
var _canvas: CanvasLayer = null


## Whether the panel is wanted when nothing says otherwise: editor, debug build or listen host.
static func default_panel(editor: bool, debug: bool, listen: bool, is_dedicated: bool) -> bool:
	return not is_dedicated and (editor or debug or listen)


## The panel's actor is trusted only where the player owns the process.
static func local_allowed(editor: bool, debug: bool, listen: bool) -> bool:
	return editor or debug or listen


static func available() -> bool:
	return ResourceLoader.exists(API_SCRIPT) and ResourceLoader.exists(OVERLAY_SCRIPT)


func add_set(set: Object, label: String = "") -> void:
	_sets.append(set)
	if not label.is_empty():
		_labels[set.get("rel_path")] = label


## Builds the api over [param runtime] (a fresh one when null) and opens what is wanted. Value: true when something is live.
func start(runtime: Object = null) -> DotResult:
	if not available():
		DotLog.info(CHANNEL, "dot-workbench is not in this build: no workbench")
		return DotResult.success(false)
	if config.is_empty():
		var http_script: GDScript = load(HTTP_SCRIPT)
		config = http_script.call("read_config")
	var api_script: GDScript = load(API_SCRIPT)
	api = api_script.new(runtime)
	for s in _sets:
		api.call("add_set", s)
	var editor := OS.has_feature("editor")
	var debug := OS.is_debug_build()
	var listen: bool = listen_host_fn.is_valid() and bool(listen_host_fn.call())
	var local_ok := local_allowed(editor, debug, listen)
	api.set("permit", func(actor: Variant, flag: String) -> bool:
		if actor is String and actor == LOCAL_ACTOR:
			return local_ok
		return permit_fn.is_valid() and bool(permit_fn.call(actor, flag)))
	var export_script: GDScript = load(EXPORT_SCRIPT)
	exporter = export_script.new(api)
	if cvars_fn.is_valid():
		exporter.set("cvars_provider", cvars_fn)
	var want_panel := panel_mode == 2 or (panel_mode == 0 and bool(config.get("panel", default_panel(editor, debug, listen, dedicated))))
	if dedicated or panel_mode == 1:
		want_panel = false
	if want_panel:
		_build_panel()
	var res := _start_http()
	if not res.ok:
		return res
	return DotResult.success(overlay != null or running_http)


func _build_panel() -> void:
	var o_script: GDScript = load(OVERLAY_SCRIPT)
	var built: Variant = o_script.call("create", api, LOCAL_ACTOR, _labels)
	if not (built is Control):
		DotLog.info(CHANNEL, "dot-menu or dot-ui is not linked: no workbench panel")
		return
	overlay = built
	overlay.visible = false
	overlay.get("exporter").set("cvars_provider", cvars_fn)
	_canvas = CanvasLayer.new()
	_canvas.name = "WorkbenchLayer"
	_canvas.layer = layer
	add_child(_canvas)
	_canvas.add_child(overlay)
	overlay.connect(&"closed", func() -> void: open_changed.emit(false))
	DotLog.info(CHANNEL, "workbench panel ready", {"key": OS.get_keycode_string(toggle_key)})


func _start_http() -> DotResult:
	if not bool(config.get("enabled", false)):
		return DotResult.success(0)
	var cfg := config.duplicate(true)
	var token_file := str(cfg.get("token_file", DEFAULT_TOKEN_FILE))
	cfg["token_file"] = token_file
	if not FileAccess.file_exists(token_file) and token_file.begins_with("user://"):
		var made := _make_token(token_file)
		if not made.ok:
			return made
	cfg["bind"] = cfg.get("bind", "127.0.0.1")
	var http_script: GDScript = load(HTTP_SCRIPT)
	http = http_script.new(api)
	var res: DotResult = http.call("start_from_config", cfg)
	if not res.ok:
		DotLog.result(CHANNEL, "workbench http", res)
		http = null
		return res
	running_http = true
	DotLog.info(CHANNEL, "workbench http listening", {"bind": cfg["bind"], "port": int(cfg.get("port", 8790)), "token_file": ProjectSettings.globalize_path(token_file)})
	return res


## A fresh random token in [param path], for a developer's machine; a deployment names its own token_file.
func _make_token(path: String) -> DotResult:
	var crypto := Crypto.new()
	var token := crypto.generate_random_bytes(24).hex_encode()
	var wrote := DotPaths.write_text(path, token + "\n")
	if wrote.ok:
		DotWeb.sync_filesystem()
	return wrote


func _process(_d: float) -> void:
	if running_http and http != null:
		http.call("poll")


func _unhandled_key_input(event: InputEvent) -> void:
	if overlay == null or not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if k.pressed and not k.echo and k.keycode == toggle_key:
		toggle()
		get_viewport().set_input_as_handled()


func is_open() -> bool:
	return overlay != null and overlay.visible


func toggle() -> void:
	if is_open():
		overlay.call("close")
	else:
		open()


func open() -> void:
	if overlay == null:
		return
	overlay.call("open")
	open_changed.emit(true)


## The `workbench` console command: open, close, export, http.
func console_command(args: PackedStringArray) -> Variant:
	var verb := args[0] if args.size() > 0 else "toggle"
	match verb:
		"open", "toggle", "close":
			if overlay == null:
				return DotResult.fail(DotError.CODE_STATE, "no workbench panel in this build or process")
			if verb == "open" or (verb == "toggle" and not is_open()):
				open()
			else:
				overlay.call("close")
			return "workbench " + ("open" if is_open() else "closed")
		"export":
			var res: DotResult = exporter.call("export_changes") if exporter != null else DotResult.fail(DotError.CODE_STATE, "workbench is not running")
			if not res.ok:
				return res
			return PackedStringArray(["exported to " + ProjectSettings.globalize_path(res.value["dir"]), "zip: " + ProjectSettings.globalize_path(res.value["zip"])])
		"http":
			return "http " + (JSON.stringify(http.call("describe")) if running_http else "off (workbench.enabled in cfg/server.yml)")
	return DotResult.fail(DotError.CODE_INVALID, "usage: workbench [open|close|toggle|export|http]")


func stop() -> void:
	if http != null:
		http.call("stop")
	http = null
	running_http = false


func _exit_tree() -> void:
	stop()


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"workbench   panel %s, http %s" % ["ready" if overlay != null else "off", "on" if running_http else "off"],
	])
