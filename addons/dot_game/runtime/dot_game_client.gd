class_name DotGameClient
extends Node

## The client's half of [DotGameModule]: the platform layer every game client wires, once.
##
## [codeblock]
## # First thing in the client root's _ready():
## platform = DotGameClient.new()
## platform.spawned_fn = func() -> bool: return player != null
## add_child(platform)                 # the cover is up; link and offline are known
## # ... build the world, the HUD, the audio ...
## platform.settings = MySettings.new()   # a DotMenuSettings subclass; null is the stock one
## platform.hud = hud_root
## platform.chat = chat                   # DotGameChatClient, a DotChatWindow, or null
## platform.board_snapshot_fn = board_snapshot
## platform.setup()                    # settings, menu, console, theme, Tab, M, pointer
## platform.input_blocked_changed.connect(_suspend_input)
## [/codeblock]
##
## [b]Why it exists.[/b] Thirteen game clients each wrote the same platform wiring by hand,
## and each missed different parts of it: six had no loading cover, nine no console, eight no
## chat box, nine no settings. What a player could rely on depended on which game they were
## in. Everything here is something every client wrote the same way with only its class names
## changed; what a game draws, its keys and its rules stay in the game.
##
## [b]A node the client root adds, not a base class to extend.[/b] Client roots are [Node],
## [Node2D] and [Node3D], and GDScript has one base: a base class would force every game's
## scene onto one type. So this is a child, and each piece is a property or an overridable
## method on it, the shape [DotGameChatClient] already has.
##
## [b]Two steps, on purpose.[/b] [method _ready] puts the cover up and finds the link before
## the game has built anything, because the cover has to be first on screen; [method setup]
## builds the settings and the menu after the game has made what they bind to.
##
## [b]Nothing optional is named.[/b] dot-menu (the Escape menu, the settings, the Tab board,
## the map menu) and dot-console are found by path and driven by [code]call[/code] and
## [code]set[/code], like everything [DotGameServices] drives, so a build without either still
## parses and gets the rest. The load gate is dot-core's and is named.
##
## [b]Each piece switches off:[/b] [member use_gate], [member use_settings],
## [member use_console], [member capture_pointer], [member sync_on_exit], and an empty
## [member scoreboard_action]. Subclass and override [method _make_settings] or
## [method _make_gate] to build a piece differently.

const CHANNEL := "game.client"

## The shell's [code]DotClientLink[/code], by registry name.
const LINK_SERVICE := &"dot_client_link"
## dot-menu's settings node, made when a game assigns none. Never named: dot-menu is optional.
const SETTINGS_SCRIPT := "res://addons/dot_menu/runtime/dot_menu_settings.gd"
## dot-console's one-call console. Never named, for the same reason.
const CONSOLE_KIT_SCRIPT := "res://addons/dot_console/runtime/dot_console_kit.gd"
## The Tab action made when the game's own key table has none.
const SCOREBOARD_ACTION := &"dot_game_scoreboard"
## The gate's requirement for the local player.
const REASON_SPAWNED := &"spawned"

## Whether the player's input should be off now: the cover is up, a menu or the console is
## open, the chat line or [member busy_fn] has the keyboard. What a client suspends its input
## samplers on.
signal input_blocked_changed(blocked: bool)
## A menu (or the console) opened, or the last one closed.
signal menu_state_changed(any_open: bool)

# --- Set before add_child ---------------------------------------------------------

## The client root: the gate goes under it, so its camera check and [method DotLoadGate.of]
## see the game. The parent when unset.
@export var host_ref: DotNodeRef = null

## Play offline even with a link (a suite, [code]--offline[/code]).
@export var force_offline: bool = false

## Build the load gate and its cover. Off for a client whose shell covers it some other way.
@export var use_gate: bool = true
## Hold the cover until a current camera exists in the game. Off for a game with none.
@export var require_camera: bool = true
## Compile what the first frame draws under the cover before lifting it. Never headless: a
## headless run draws nothing, so the warm-up would only wait out its timeout and every
## suite that boots a client would wait with it.
@export var warm_up: bool = true
## The status line while [member spawned_fn] is false.
@export var spawned_text: String = "Joining"

## [code]func() -> bool[/code]: true once the local player exists and can be shown. Held
## under [constant REASON_SPAWNED] until then. Unset holds nothing for it.
var spawned_fn: Callable = Callable()

# --- Set before setup -------------------------------------------------------------

## Build the settings and the Escape menu (dot-menu).
@export var use_settings: bool = true
## Where a stock settings node keeps its document, when [member settings] is unset.
@export var settings_directory: String = ""
## The stock settings node's namespace, when [member settings] is unset.
@export var app_namespace: StringName = &"game"
## Build the console (dot-console) on the key under Escape.
@export var use_console: bool = true
## The script whose static [code]build(host, settings, menu)[/code] makes the console;
## dot-console's kit unless replaced (the suite points it at a fixture).
var console_kit_path: String = CONSOLE_KIT_SCRIPT
## Hold Tab for the board: the menu's [code]scoreboard_action[/code]. The default action is
## made on Tab when nothing defines it; a game with a key-table row names that row's action.
## Empty is no key.
@export var scoreboard_action: StringName = SCOREBOARD_ACTION
## Capture the pointer at the start on a desktop, free it while a menu is open, take it back
## on close (on a desktop) or on a click (in a browser, which refuses a capture without one).
## Off for a game that keeps its pointer.
@export var capture_pointer: bool = true
## Flush [code]user://[/code] to the browser's storage when the game goes. A no-op off the web.
@export var sync_on_exit: bool = true

## The game's settings node (a [code]DotMenuSettings[/code] subclass), assigned before
## [method setup]; null makes the stock one ([method _make_settings]).
var settings: Node = null
## The HUD's root Control: it follows the menu's theme and HUD size.
var hud: Control = null
## The game's accent over the theme (dot-menu's [code]follow_hud[/code]); null for none.
var hud_accent: Theme = null
## The chat box: a [DotGameChatClient], a dot-ui chat window, or anything with
## [code]is_typing()[/code] or [code]is_open()[/code]. Typing blocks input and keeps Escape
## off the menu. Added under this node if it is not in the tree yet.
var chat: Node = null
## [code]func() -> bool[/code]: something else of the game's has the keyboard (a command
## line). Blocks input, keeps the menu's keys away, keeps the pointer free.
var busy_fn: Callable = Callable()
## [code]func() -> Dictionary[/code]: the Tab board offline (dot-menu's snapshot shape).
## Connected, the board is fed from the link's roster instead, when the link has one.
var board_snapshot_fn: Callable = Callable()
## The map menu on M: [code]func() -> Array[/code] of rows and [code]func(id) -> DotResult
## [/code] to change. Both unset leave M doing nothing.
var maps_rows_fn: Callable = Callable()
var maps_change_fn: Callable = Callable()
## The map menu's title and plural noun ("Change house", "houses"); empty keeps dot-menu's.
var maps_title: String = ""
var maps_noun: String = ""

# --- Built ------------------------------------------------------------------------

## The client root this serves.
var host: Node = null
## The shell's link, or null offline. Assign before add_child to use another.
var link: Object = null
## No server: no link, [member force_offline], or [code]--offline[/code] on the command line.
var offline: bool = true
## dot-core's load gate, under [member host]. Hold more on it: [code]gate.hold(&"map")[/code].
var gate: DotLoadGate = null
## The settings' menu (dot-menu's [code]DotMenu[/code]), its board and its map menu.
var menu: Object = null
var board: Object = null
var maps: Object = null
## dot-console's controller.
var console: Node = null

var _set_up: bool = false
var _blocked: bool = false
var _menu_open: bool = false


func _ready() -> void:
	host = _resolve_host()
	if link == null:
		link = DotRegistry.get_service(LINK_SERVICE)
	offline = force_offline or link == null or OS.get_cmdline_user_args().has("--offline")
	if use_gate:
		gate = _make_gate()
		if gate != null:
			gate.opened.connect(_refresh_blocked)
			gate.closed.connect(_refresh_blocked)
	_blocked = is_input_blocked()


func _resolve_host() -> Node:
	if host_ref != null:
		var found := host_ref.resolve_or_null(self, CHANNEL)
		if found != null:
			return found
	return get_parent()


## Builds the gate under [member host]. Override for a gate of your own; null is no gate.
func _make_gate() -> DotLoadGate:
	var made := DotLoadGate.new()
	made.require_camera = require_camera
	made.warm_up_on_open = warm_up and DisplayServer.get_name() != "headless"
	if spawned_fn.is_valid():
		made.require(REASON_SPAWNED, spawned_fn, spawned_text)
	# Under the host, not under this node: the gate marks its parent for DotLoadGate.of, looks
	# for the camera under it, and gives it the ready_to_show signal an older shell watches.
	# A host still readying its scene's children refuses a new one, so that case waits a frame.
	if host.is_node_ready():
		host.add_child(made)
	else:
		host.add_child.call_deferred(made)
	return made


## The settings, the menu, the console, the theme, Tab, M, the chat's keyboard and the
## pointer. Call once, after the HUD, the chat box and what the settings bind to are built.
## Nothing here is fatal: a piece that cannot be built is logged and the rest go on.
func setup() -> DotResult:
	if _set_up:
		return DotResult.fail(DotError.CODE_STATE, "This game client's platform is already set up.")
	_set_up = true

	_wire_chat()
	if use_settings:
		_build_settings()
	if use_console:
		_build_console()
	_wire_menu()

	if capture_pointer and not DotPlatform.is_web():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	_refresh_blocked()
	return DotResult.success(self)


func _wire_chat() -> void:
	if chat == null:
		return
	if not chat.is_inside_tree():
		add_child(chat)
	# typing_changed(bool) on DotGameChatClient, opened(channel) / closed() on dot-ui's box.
	for signal_name: StringName in [&"typing_changed", &"opened", &"closed"]:
		if chat.has_signal(signal_name):
			chat.connect(signal_name, _refresh_blocked)


## The stock settings node, by path, when the game assigned none. Override to build your own.
func _make_settings() -> Node:
	if not ResourceLoader.exists(SETTINGS_SCRIPT):
		DotLog.info(CHANNEL, "dot-menu is not in this build: no settings or Escape menu")
		return null
	var script: Variant = load(SETTINGS_SCRIPT)
	if not (script is GDScript):
		DotLog.warn(CHANNEL, "dot-menu's settings would not load", {"path": SETTINGS_SCRIPT})
		return null
	var made: Node = (script as GDScript).new()
	made.set(&"app_namespace", app_namespace)
	made.set(&"directory", settings_directory if settings_directory != "" else "user://%s_settings" % app_namespace)
	return made


func _build_settings() -> void:
	if settings == null:
		settings = _make_settings()
	if settings == null:
		return
	if settings.name == &"":
		settings.name = "Settings"
	if not settings.is_inside_tree():
		add_child(settings)
	if not settings.has_method(&"setup"):
		DotLog.warn(CHANNEL, "the settings node has no setup(); it is left alone", {"node": str(settings)})
		return

	var built: Variant = settings.call(&"setup")
	if built is DotResult and not (built as DotResult).ok:
		DotLog.warn(CHANNEL, "no settings; everything is at its default", {"why": (built as DotResult).error.message})
		settings.queue_free()
		settings = null
		return

	var got: Variant = settings.get(&"menu")
	menu = got if got is Object else null
	if settings.has_signal(&"menu_state_changed"):
		settings.connect(&"menu_state_changed", _on_menu_state)


func _build_console() -> void:
	if not ResourceLoader.exists(console_kit_path):
		DotLog.info(CHANNEL, "dot-console is not in this build: no console")
		return
	var kit: Variant = load(console_kit_path)
	if not (kit is GDScript):
		DotLog.warn(CHANNEL, "dot-console's kit would not load", {"path": console_kit_path})
		return
	var manager: Variant = settings.get(&"settings") if settings != null else null
	var built: Variant = (kit as GDScript).call(&"build", self, manager, menu)
	console = built if built is Node else null


func _wire_menu() -> void:
	if menu == null:
		return
	# The chat line and the game's own keyboard owners keep Escape and the menu's keys.
	menu.set(&"busy", func() -> bool: return _chat_typing() or _busy())
	# By name: a game delivered to an older client shell finds a dot-menu without it.
	if hud != null and menu.has_method(&"follow_hud"):
		menu.call(&"follow_hud", hud, hud_accent)

	if scoreboard_action != &"" and &"scoreboard_action" in menu:
		_ensure_scoreboard_action()
		menu.set(&"scoreboard_action", scoreboard_action)
	var got: Variant = menu.get(&"scoreboard")
	board = got if got is Object else null
	if board != null:
		if not offline and link != null and link.has_signal(&"scoreboard_received") and board.has_method(&"feed_from"):
			board.call(&"feed_from", link)
		elif board_snapshot_fn.is_valid():
			board.set(&"source", board_snapshot_fn)

	if maps_rows_fn.is_valid() and maps_change_fn.is_valid() and settings.has_method(&"use_maps"):
		var made: Variant = settings.call(&"use_maps", maps_rows_fn, maps_change_fn)
		maps = made if made is Object else null
		if maps != null:
			if maps_title != "":
				maps.set(&"title", maps_title)
			if maps_noun != "":
				maps.set(&"noun", maps_noun)
			# Played offline beside a link (--offline): there is no server to ask.
			if offline:
				maps.set(&"link_service", &"")


func _ensure_scoreboard_action() -> void:
	if scoreboard_action != SCOREBOARD_ACTION or InputMap.has_action(scoreboard_action):
		return
	InputMap.add_action(scoreboard_action)
	var tab := InputEventKey.new()
	tab.physical_keycode = KEY_TAB
	InputMap.action_add_event(scoreboard_action, tab)


func _on_menu_state(any_open: bool) -> void:
	_menu_open = any_open
	if capture_pointer:
		if any_open:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif not DotPlatform.is_web() and not _busy():
			# A browser refuses a capture that is not a click; the click that follows is
			# taken in _unhandled_input.
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	menu_state_changed.emit(any_open)
	_refresh_blocked()


func _unhandled_input(event: InputEvent) -> void:
	if not capture_pointer or not _set_up:
		return
	var click := event as InputEventMouseButton
	if click == null or not click.pressed or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		return
	if is_menu_open() or _chat_typing() or _busy() or not is_shown():
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(_delta: float) -> void:
	# Polled as well as signalled: busy_fn is the game's and says nothing when it changes.
	_refresh_blocked()


func _refresh_blocked(_unused: Variant = null) -> void:
	var now := is_input_blocked()
	if now != _blocked:
		_blocked = now
		input_blocked_changed.emit(now)


# --- Asked ------------------------------------------------------------------------

## True while the player's input should be off: covered, a menu open, typing, or busy.
func is_input_blocked() -> bool:
	return not is_shown() or is_menu_open() or _chat_typing() or _busy()


## True once the gate has lifted (or when there is none).
func is_shown() -> bool:
	return gate == null or not is_instance_valid(gate) or gate.is_open()


## True while the Escape menu, one of its screens or the console is open.
func is_menu_open() -> bool:
	if settings != null and is_instance_valid(settings) and settings.has_method(&"is_open"):
		return bool(settings.call(&"is_open"))
	return _menu_open


func _chat_typing() -> bool:
	if chat == null or not is_instance_valid(chat):
		return false
	if chat.has_method(&"is_typing"):
		return bool(chat.call(&"is_typing"))
	if chat.has_method(&"is_open"):
		return bool(chat.call(&"is_open"))
	return false


func _busy() -> bool:
	return busy_fn.is_valid() and bool(busy_fn.call())


func _notification(what: int) -> void:
	if not sync_on_exit:
		return
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED \
			or what == NOTIFICATION_EXIT_TREE:
		DotWeb.sync_filesystem()


func describe() -> Dictionary:
	return {
		"host": str(host.name) if host != null else "",
		"offline": offline,
		"link": link != null,
		"gate": gate.describe() if gate != null and is_instance_valid(gate) else {},
		"set_up": _set_up,
		"settings": settings != null,
		"menu": menu != null,
		"menu_open": is_menu_open(),
		"console": console != null,
		"chat": chat != null,
		"typing": _chat_typing(),
		"board": board != null,
		"maps": maps != null,
		"scoreboard_action": String(scoreboard_action),
		"input_blocked": is_input_blocked(),
		"capture_pointer": capture_pointer,
	}


func describe_lines() -> PackedStringArray:
	var d := describe()
	var out := PackedStringArray()
	out.append("client %s, %s" % [d["host"], "offline" if offline else "connected"])
	out.append("  cover %s" % ("lifted" if is_shown() else "up"))
	out.append("  settings %s, menu %s%s, console %s" % [
		"yes" if d["settings"] else "no", "yes" if d["menu"] else "no",
		" (open)" if d["menu_open"] else "", "yes" if d["console"] else "no"])
	out.append("  chat %s%s, board %s, maps %s" % [
		"yes" if d["chat"] else "no", " (typing)" if d["typing"] else "",
		"yes" if d["board"] else "no", "yes" if d["maps"] else "no"])
	out.append("  input %s" % ("blocked" if d["input_blocked"] else "live"))
	return out
