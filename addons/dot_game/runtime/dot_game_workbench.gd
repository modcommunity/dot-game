class_name DotGameWorkbench
extends Node

## Hosts dot-workbench in a game: the in-game panel (F9, or console `workbench`) and, when asked for,
## the loopback HTTP page. The panel is on in the editor, debug builds and listen hosts; HTTP needs
## `workbench.enabled: true` in cfg/server.yml. Everything is reached by path. Use: `add_set`, `add_child`, `start`.

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
## On by default: with dot-auth running a ticket key, a connect ticket is also accepted as the bearer ([DotGameWorkbenchAuth]).
var accounts: bool = true
## Callable(token) -> identity or null, replacing the ticket check. Unset means dot-auth's offline ticket check.
var account_resolver: Callable = Callable()
## Callable(uid, flag) -> bool for a listed account; unset means [member permit_fn].
var account_permit_fn: Callable = Callable()
## The account gate once attached; null without dot-auth, a ticket key or `admin_uids` / `admin_groups` to resolve.
var account_gate: RefCounted = null
## The `workbench:` block; read from cfg/server.yml by [method start] when empty.
var config: Dictionary = {}

var api: RefCounted = null
var http: RefCounted = null
var overlay: Control = null
var exporter: RefCounted = null
var running_http := false

## Offer the DotServer's [constant THREAD_CVARS] as a set; Save writes `cfg/server/addon/dot_server/threads/server.yml`, applied at the next start.
var thread_cvars: bool = true

## The server's thread cvars and their profile types.
const THREAD_CVARS := {"sv_worker_threads": "int", "sv_threads_net": "bool", "sv_threads_npc": "bool"}
const THREADS_KIND := "threads"
const THREADS_ADDON := "dot_server"
## The one profile id a cvar set has.
const CVAR_SET_ID := "server"

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
	if thread_cvars:
		var server := DotRegistry.get_node_service(DotServer.SERVICE) as DotServer
		if server != null and server.console != null:
			var made := cvar_set(server.console, THREAD_CVARS, THREADS_KIND, THREADS_ADDON)
			if made != null:
				bind_cvar_set(made, api.get("runtime"), server.console)
				add_set(made, "Server threads")
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
	_attach_accounts()
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


## A profile set over [param types] ({cvar name: "int" | "bool" | "float" | "string"}) of [param console]'s cvars, one implicit id [constant CVAR_SET_ID]; names that are not cvars are left out. Null when none is.
static func cvar_set(console: DotConsole, types: Dictionary, kind: String, addon: String = "") -> DotProfileSet:
	var fields: Array = []
	for name: String in types:
		var c := console.find_cvar(name)
		if c == null:
			continue
		var opts := {"description": c.description}
		if c.has_min:
			opts["min"] = c.min_value
		if c.has_max:
			opts["max"] = c.max_value
		fields.append(DotProfileSet.field(name, types[name], _cvar_value(c, types[name]), opts))
	if fields.is_empty():
		return null
	var made := DotProfileSet.create(addon, "", kind, fields)
	made.implicit_ids = PackedStringArray([CVAR_SET_ID])
	return made


## Applies a saved file of [param set] to the cvars, then follows [param runtime]'s edits of it into them. Value: the cvars the file set.
static func bind_cvar_set(set: DotProfileSet, runtime: DotProfileRuntime, console: DotConsole) -> int:
	var pushed := {}
	for f: Dictionary in set.schema:
		pushed[f["name"]] = f["default"]
	var applied := 0
	var loaded := set.load_profile(CVAR_SET_ID)
	if loaded.ok:
		var p: DotProfile = loaded.value
		for path in p.file_keys:
			var name := String(path).split(".")[0]
			if pushed.has(name) and _push_cvar(console, name, p.values[name]):
				pushed[name] = p.values[name]
				applied += 1
	if applied > 0:
		DotLog.info(CHANNEL, "saved cvars applied", {"kind": set.rel_path, "cvars": applied})
	if runtime != null:
		runtime.profile_changed.connect(func(kind: String, id: String, _rev: int) -> void:
			if kind != set.rel_path or id != CVAR_SET_ID:
				return
			var now := set.load_profile(CVAR_SET_ID)
			if not now.ok:
				return
			var values: Dictionary = (now.value as DotProfile).values
			# Only what this edit moved: a cvar changed at the console since is left alone.
			for name: String in pushed:
				if values.has(name) and str(values[name]) != str(pushed[name]):
					pushed[name] = values[name]
					_push_cvar(console, name, values[name]))
	return applied


static func _cvar_value(c: DotConVar, type: String) -> Variant:
	match type:
		"int":
			return c.get_int()
		"bool":
			return c.get_bool()
		"float":
			return c.get_float()
	return c.get_string()


static func _push_cvar(console: DotConsole, name: String, value: Variant) -> bool:
	var text := ("1" if value else "0") if value is bool else str(value)
	var res := console.set_cvar(name, text)
	if not res.ok:
		DotLog.warn(CHANNEL, "cvar refused the workbench value", {"cvar": name, "value": text, "error": res.error.message})
	return res.ok


func _attach_accounts() -> void:
	if not accounts:
		return
	var resolver := account_resolver
	if not resolver.is_valid():
		resolver = DotGameWorkbenchAuth.ticket_resolver(DotRegistry.get_node_service(DotGameWorkbenchAuth.AUTH_SERVICE))
	var permit: Callable = account_permit_fn if account_permit_fn.is_valid() else permit_fn
	account_gate = DotGameWorkbenchAuth.attach(self, resolver, permit)
	if account_gate != null:
		DotLog.info(CHANNEL, "workbench accepts dot-auth accounts")


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


## Hosts [param wb] on [param c]: its window is a menu overlay and the console gets `workbench`.
static func host_on(c: DotGameClient, wb: Node) -> void:
	if wb.get_parent() == null:
		c.add_child(wb)
	var panel: Variant = wb.get(&"overlay")
	if panel is Control and c.menu != null and c.menu.has_method(&"add_overlay"):
		c.menu.call(&"add_overlay", panel)
		wb.connect(&"open_changed", func(open: bool) -> void:
			if open and c.menu != null and is_instance_valid(c.menu) and c.menu.has_method(&"overlay_opened"):
				c.menu.call(&"overlay_opened"))
	if c.console != null and is_instance_valid(c.console) and ResourceLoader.exists(DotGameClient.LOCAL_SCRIPT):
		var local: Object = (load(DotGameClient.LOCAL_SCRIPT) as GDScript).new()
		local.call(&"add_command", &"workbench", "Tuning panel: workbench [open|close|toggle|export|http]", Callable(wb, &"console_command"))
		c.console.call(&"add_source", local)
