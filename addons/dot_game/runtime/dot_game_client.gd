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
## [method _make_gate] to build a piece differently, or assign [member cover_scene] /
## [member cover] to change only the gate's cover.
##
## [b]A HUD or chat built after [method setup][/b] goes through [method set_hud] and
## [method set_chat]; [member pointer_fn] decides when the pointer may be taken back; and
## [method refresh_blocked] updates the input block in the frame something opens.
##
## [b]A game with its own menu[/b] ([member menu] assigned before [method setup], or
## [method adopt_menu] after) gets the same input block, [signal menu_state_changed], Tab board
## and HUD theme without settings from here; [method add_console] builds the console later,
## around a menu or manager the game made. [member gate_only] takes the gate, the link, the
## input block and the web flush and nothing else. [member escape_releases_pointer] makes the
## first Escape free the pointer and the second open the menu.

const CHANNEL := "game.client"

## The shell's [code]DotClientLink[/code], by registry name.
const LINK_SERVICE := &"dot_client_link"
## dot-menu's settings node, made when a game assigns none. Never named: dot-menu is optional.
const SETTINGS_SCRIPT := "res://addons/dot_menu/runtime/dot_menu_settings.gd"
## dot-console's one-call console. Never named, for the same reason.
const EDITOR_SCRIPT := "res://addons/dot_menu/ui/dot_addon_config_editor_screen.gd"
const ROW_SCRIPT := "res://addons/dot_menu/core/dot_menu_row.gd"
const USER_CFG_PAGE := &"advanced"
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
## A scene instanced as the gate's cover instead of [DotLoadingCover] (see
## [member DotLoadGate.cover_scene]). Null keeps the stock cover.
@export var cover_scene: PackedScene = null
## A cover node of your own, assigned before add_child (see [member DotLoadGate.cover]); wins
## over [member cover_scene]. Null keeps the stock cover.
var cover: Node = null
## The status line while [member spawned_fn] is false.
@export var spawned_text: String = "Joining"
## Tell the server when the cover lifts and when it comes back, so a server on
## [DotGameModule] does not hurt or count out a player who cannot see yet
## ([method DotGameModule.is_loading]). Connected only; offline there is nobody to tell.
@export var report_loading: bool = true

## [code]func() -> bool[/code]: true once the local player exists and can be shown. Held
## under [constant REASON_SPAWNED] until then. Unset holds nothing for it.
var spawned_fn: Callable = Callable()

# --- Set before setup -------------------------------------------------------------

## Turns on dot-core's player cfg tier (and the menu entry that edits it) when this process is
## solo or the listen host. Off keeps the tier off everywhere.
@export var user_cfg: bool = true
## [code]func() -> bool[/code]: this client also hosts the server it is connected to (a listen
## server). Unset means a connected client is somebody else's guest and gets no tier.
var listen_host_fn: Callable = Callable()
## Files the player may edit, each [code]{addon, file, schema, label}[/code] ([code]schema[/code] is
## [code]DotProfileSet.field[/code]s); addons and games append before [method setup]. Empty hides the entry.
var user_cfg_files: Array[Dictionary] = []

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
## [code]func() -> bool[/code]: whether the pointer should be captured now. The rule for the
## places this node would take the pointer back (a click, a menu closing); false leaves it
## free. Unset keeps the default (capture whenever nothing blocks input). For a game whose
## own screens or modes free the pointer. Needs [member capture_pointer].
var pointer_fn: Callable = Callable()
## Escape on a captured pointer frees it and does nothing else; the next Escape opens the menu
## as usual. For a game whose Escape would otherwise open a menu over a pointer the player
## was still using for the game (a screen stack of its own). Needs [member capture_pointer].
@export var escape_releases_pointer: bool = false
## Gate-only mode: [method setup] wires the chat's keyboard and the input block and builds
## nothing else (no settings, menu, console, board, Tab, M or pointer capture). For a game
## that owns those itself and wants the cover, the link, the web flush and the block.
@export var gate_only: bool = false
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
## Whether this client turned the cfg tier on ([member user_cfg] and solo or listen host).
var user_tier_on: bool = false
var user_cfg_overlay: UserCfgOverlay = null
## dot-core's load gate, under [member host]. Hold more on it: [code]gate.hold(&"map")[/code].
var gate: DotLoadGate = null
## The settings' menu (dot-menu's [code]DotMenu[/code]), its board and its map menu.
## A game that built its own menu assigns [member menu] before [method setup] (or calls
## [method adopt_menu]): no settings are built over it. Assigned [member board] is kept
## instead of the menu's own.
var menu: Object = null
var board: Object = null:
	set(value):
		board = value
		_board_auto = false
## [code]func(board)[/code]: the game's own preparation of the board, run before it is fed
## from the link or the snapshot (columns, teams, a header). Unset does nothing.
var board_prepare_fn: Callable = Callable()
var maps: Object = null
## dot-console's controller.
var console: Node = null

var _set_up: bool = false
# True while board came from the menu's own scoreboard, not from the caller: adopting another
# menu then takes that menu's board instead of keeping the old one.
var _board_auto: bool = false
# Boards already given to board_prepare_fn: each is prepared once, however often it is wired.
var _prepared_boards: Array[int] = []
# The menu whose signal and busy callable are currently wired, and the signal used.
var _wired_menu: Object = null
var _wired_signal: StringName = &""
var _blocked: bool = false
var _menu_open: bool = false

## Test seam: when valid, the page-guard JavaScript goes here instead of the browser, and the
## client behaves as if on the web. Unset in every real build.
var web_eval_fn: Callable = Callable()
var _guard_armed: bool = false
var _guard_installed: bool = false

# Runs once per page. [code]window.__dotTabGuard[/code] is the idempotence flag, so a second
# client or a reconnect adds no listeners. The keyboard lock lives here, not in the menu,
# because only some games build the menu's applier, and a page can enter fullscreen by other
# routes (F11 aside, a game's own button). Ctrl+W, Ctrl+T/N and Ctrl+Tab are the browser's and
# a page cannot cancel them; the lock (fullscreen only, where the API exists) hands them to the
# game, and the beforeunload prompt is the net for everything the lock cannot cover.
# Wrapped in a function because a global-scope eval would leave `g` on the game's window.
const _GUARD_JS := """
(function () {
if (!window.__dotTabGuard) {
	var g = window.__dotTabGuard = { armed: false };
	window.addEventListener('beforeunload', function (e) {
		if (!g.armed) { return; }
		e.preventDefault();
		e.returnValue = '';
		return '';
	});
	document.addEventListener('fullscreenchange', function () {
		var k = navigator.keyboard;
		if (!k) { return; }
		try {
			if (document.fullscreenElement) {
				if (k.lock) { var p = k.lock(); if (p && p.catch) { p.catch(function () {}); } }
			} else if (k.unlock) { k.unlock(); }
		} catch (err) {}
	});
}
})();
"""


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
			if report_loading:
				gate.opened.connect(_on_gate_cover.bind(false))
				gate.closed.connect(_on_gate_cover.bind(true))
	_apply_user_tier()
	_blocked = is_input_blocked()
	_install_page_guard()


## Whether the player's cfg tier may be on: solo or listen host, never a dedicated server or a guest.
static func user_tier_allowed(opt_in: bool, solo: bool, listen_host: bool, dedicated: bool) -> bool:
	return opt_in and not dedicated and (solo or listen_host)


func _apply_user_tier() -> void:
	var host_here := listen_host_fn.is_valid() and bool(listen_host_fn.call())
	user_tier_on = user_tier_allowed(user_cfg, offline, host_here, OS.has_feature("dedicated_server"))
	DotAddonConfig.set_user_tier(user_tier_on)


func _on_gate_cover(covered: bool) -> void:
	if not offline:
		report_cover(link, covered)


## Tells the server this client's loading cover went up ([param covered] true) or lifted.
## [DotGameClient] calls it from its gate; a client that is not on it calls this from its own
## cover's equivalents, with the shell's link ([code]DotRegistry.get_service(&"dot_client_link")
## [/code]). False when nothing was sent: no link, not connected, or a server that does not
## know the kind (an older one), which then releases the seat by its timeout.
static func report_cover(to_link: Object, covered: bool) -> bool:
	if to_link == null or not is_instance_valid(to_link) or not to_link.has_method(&"send_kind"):
		return false
	return bool(to_link.call(&"send_kind", DotGameRoster.COVER_KIND, {"covered": covered}))


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
	if cover != null:
		made.cover = cover
	elif cover_scene != null:
		made.cover_scene = cover_scene
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
	if gate_only:
		_refresh_blocked()
		return DotResult.success(self)
	if use_settings and menu == null:
		_build_settings()
	if use_console:
		add_console()
	_wire_menu()

	if capture_pointer and not DotPlatform.is_web():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	_refresh_blocked()
	return DotResult.success(self)


## Hands over a HUD built after [method setup]: it follows the menu's theme and HUD size from
## now on. [param root] is its root Control; a CanvasLayer HUD passes the Control it holds.
## Safe before setup() too (it is then wired by setup()). Replaces a HUD given earlier.
func set_hud(root: Control, accent: Theme = null) -> void:
	if _set_up and hud != null and hud != root and is_instance_valid(hud) \
			and menu != null and menu.has_method(&"unfollow_hud"):
		menu.call(&"unfollow_hud", hud)
	hud = root
	hud_accent = accent
	if _set_up:
		_follow_hud()


func _follow_hud() -> void:
	# By name: a game delivered to an older client shell finds a dot-menu without it.
	if hud != null and menu != null and menu.has_method(&"follow_hud"):
		menu.call(&"follow_hud", hud, hud_accent)


## Hands over a chat box built after [method setup] (or before it: then setup() wires it).
## Typing in it blocks input from now on; the previous chat is let go.
func set_chat(box: Node) -> void:
	if chat == box:
		return
	if chat != null and is_instance_valid(chat):
		for signal_name: StringName in [&"typing_changed", &"opened", &"closed"]:
			if chat.has_signal(signal_name) and chat.is_connected(signal_name, _refresh_blocked):
				chat.disconnect(signal_name, _refresh_blocked)
	chat = box
	if _set_up:
		_wire_chat()
		_refresh_blocked()


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
	_add_user_cfg_entry()


# The "Your mods" row on the Advanced page: a dot-menu row and editor loaded by path, so a build
# without dot-menu's newer editor just has no entry.
func _add_user_cfg_entry() -> void:
	if not user_tier_on or user_cfg_files.is_empty() or menu == null or not menu.has_method(&"page"):
		return
	if not ResourceLoader.exists(ROW_SCRIPT) or not ResourceLoader.exists(EDITOR_SCRIPT):
		DotLog.info(CHANNEL, "dot-menu has no cfg editor: no mods entry")
		return
	var page: Variant = menu.call(&"page", USER_CFG_PAGE)
	var row_script: Variant = load(ROW_SCRIPT)
	if page == null or not (row_script is GDScript):
		return
	var row: Variant = (row_script as GDScript).call(&"button", "Your mods",
			"Tune the game's own settings files for this device.", "Edit", open_user_cfg)
	var sec: Variant = (page as Object).call(&"section", "Mods", &"user_cfg")
	(sec as Object).call(&"add", row)


## Opens the cfg editor over the menu. False without the tier, files, menu or editor.
func open_user_cfg() -> bool:
	if not user_tier_on or user_cfg_files.is_empty() or menu == null:
		return false
	if not ResourceLoader.exists(EDITOR_SCRIPT):
		return false
	if user_cfg_overlay != null and is_instance_valid(user_cfg_overlay):
		user_cfg_overlay.open()
		return true
	# A CanvasLayer above the menu's own, or the editor draws underneath it.
	var layer := CanvasLayer.new()
	layer.layer = 200
	add_child(layer)
	user_cfg_overlay = UserCfgOverlay.new()
	layer.add_child(user_cfg_overlay)
	var ed: Control = (load(EDITOR_SCRIPT) as GDScript).new()
	user_cfg_overlay.host_editor(ed)
	for f in user_cfg_files:
		ed.call(&"add_file", f.get("addon", ""), f.get("file", ""), f.get("schema", []), f.get("label", ""))
	var first: Dictionary = user_cfg_files[0]
	var _opened: Variant = ed.call(&"open", first.get("addon", ""), first.get("file", ""))
	if menu.has_method(&"add_overlay"):
		menu.call(&"add_overlay", user_cfg_overlay)
	user_cfg_overlay.open()
	if menu.has_method(&"overlay_opened"):
		menu.call(&"overlay_opened")
	return true


## The editor, full screen, with a Close button; the shape dot-menu's add_overlay wants.
class UserCfgOverlay extends Control:
	signal closed()
	var _editor: Control = null

	func _init() -> void:
		set_anchors_preset(Control.PRESET_FULL_RECT)
		visible = false

	func host_editor(ed: Control) -> void:
		_editor = ed
		ed.set_anchors_preset(Control.PRESET_FULL_RECT)
		ed.offset_bottom = -48
		var back := ColorRect.new()
		back.color = Color(0.05, 0.06, 0.08, 1.0)
		back.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(back)
		add_child(ed)
		var b := Button.new()
		b.text = "Close"
		b.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		b.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		b.grow_vertical = Control.GROW_DIRECTION_BEGIN
		b.pressed.connect(close)
		add_child(b)

	func open() -> void:
		visible = true

	func close() -> void:
		if visible:
			visible = false
			closed.emit()

	func is_open() -> bool:
		return visible


## Hands over a menu the game built itself (dot-menu's [code]DotMenu[/code] or anything with
## [code]is_open()[/code]), with its own board if it has one other than the menu's. Before
## [method setup] it is the same as assigning [member menu]; after, it is wired at once: the
## input block, [signal menu_state_changed], the HUD theme, Tab and the board.
func adopt_menu(adopted: Object, adopted_board: Object = null) -> void:
	if _set_up:
		_unwire_menu()
	menu = adopted
	if adopted_board != null:
		board = adopted_board
	elif _board_auto:
		board = null
	if _set_up:
		_wire_menu()
		_refresh_blocked()


## Builds the console (dot-console) now, over [param manager] (the settings manager) and the
## menu. [method setup] calls it with the settings' own manager; a game that builds its menu
## first and its console later turns [member use_console] off and calls this itself. A second
## call replaces nothing: the first console stays.
func add_console(manager: Object = null) -> Node:
	if console != null and is_instance_valid(console):
		return console
	if not ResourceLoader.exists(console_kit_path):
		DotLog.info(CHANNEL, "dot-console is not in this build: no console")
		return null
	var kit: Variant = load(console_kit_path)
	if not (kit is GDScript):
		DotLog.warn(CHANNEL, "dot-console's kit would not load", {"path": console_kit_path})
		return null
	if manager == null and settings != null:
		var got: Variant = settings.get(&"settings")
		manager = got if got is Object else null
	var built: Variant = (kit as GDScript).call(&"build", self, manager, menu)
	console = built if built is Node else null
	return console


## Relays the menu's open and close as [signal menu_state_changed], once, from the settings
## node when there is one, else from the menu itself. An adopted menu that is not the
## settings' own (adopt_menu after setup with settings present) is relayed from its own
## [code]overlays_changed[/code] as well, and is_menu_open() asks it too: refusing would leave
## a game that built its own menu with no way to have it block input.
func _connect_menu_state() -> void:
	if settings != null and settings.has_signal(&"menu_state_changed") \
			and not settings.is_connected(&"menu_state_changed", _on_menu_state):
		settings.connect(&"menu_state_changed", _on_menu_state)
	if menu == null or not menu.has_signal(&"overlays_changed"):
		return
	if menu == _settings_menu() and settings != null and settings.has_signal(&"menu_state_changed"):
		return
	if not menu.is_connected(&"overlays_changed", _on_menu_state):
		menu.connect(&"overlays_changed", _on_menu_state)
		_wired_menu = menu
		_wired_signal = &"overlays_changed"


func _settings_menu() -> Object:
	if settings == null or not is_instance_valid(settings):
		return null
	var got: Variant = settings.get(&"menu")
	return got if got is Object else null


## Undoes _wire_menu for the menu being replaced: its signal, its busy callable and the HUD
## follow, so a menu no longer adopted cannot keep reporting or reacting.
func _unwire_menu() -> void:
	var old: Object = menu
	if old == null or not is_instance_valid(old):
		_wired_menu = null
		return
	if old.has_signal(&"overlays_changed") and old.is_connected(&"overlays_changed", _on_menu_state):
		old.disconnect(&"overlays_changed", _on_menu_state)
	_wired_menu = null
	_wired_signal = &""
	if &"busy" in old:
		old.set(&"busy", Callable())
	if hud != null and is_instance_valid(hud) and old.has_method(&"unfollow_hud"):
		old.call(&"unfollow_hud", hud)
	_menu_open = false


func _wire_menu() -> void:
	if menu != null:
		_connect_menu_state()
		# The chat line and the game's own keyboard owners keep Escape and the menu's keys.
		menu.set(&"busy", func() -> bool: return _chat_typing() or _busy())
		# By name: a game delivered to an older client shell finds a dot-menu without it.
		_follow_hud()
		if scoreboard_action != &"" and &"scoreboard_action" in menu:
			_ensure_scoreboard_action()
			menu.set(&"scoreboard_action", scoreboard_action)
		if board == null:
			var got: Variant = menu.get(&"scoreboard")
			board = got if got is Object else null
			_board_auto = board != null
	if board != null:
		if board_prepare_fn.is_valid() and not _prepared_boards.has(board.get_instance_id()):
			_prepared_boards.append(board.get_instance_id())
			board_prepare_fn.call(board)
		if not offline and link != null and link.has_signal(&"scoreboard_received") and board.has_method(&"feed_from"):
			board.call(&"feed_from", link)
		elif board_snapshot_fn.is_valid():
			board.set(&"source", board_snapshot_fn)

	var maps_owner: Object = settings if settings != null and settings.has_method(&"use_maps") else menu
	if maps_rows_fn.is_valid() and maps_change_fn.is_valid() and maps_owner != null \
			and maps_owner.has_method(&"use_maps"):
		var made: Variant = maps_owner.call(&"use_maps", maps_rows_fn, maps_change_fn)
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
		elif not DotPlatform.is_web() and not _busy() and _pointer_wanted():
			# A browser refuses a capture that is not a click; the click that follows is
			# taken in _unhandled_input.
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	menu_state_changed.emit(any_open)
	_refresh_blocked()


func _input(event: InputEvent) -> void:
	# Before the menu's own _unhandled_input, which would open on this same press.
	if _release_pointer_on_escape(event):
		get_viewport().set_input_as_handled()


## Whether [param event] was an Escape that only freed the captured pointer (see
## [member escape_releases_pointer]). Nothing is freed while a menu, the chat or the game's
## own keyboard owner has the keys: Escape is theirs then.
func _release_pointer_on_escape(event: InputEvent) -> bool:
	if not escape_releases_pointer or not capture_pointer or not _set_up or gate_only:
		return false
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.physical_keycode != KEY_ESCAPE:
		return false
	if not _pointer_captured() or is_menu_open() or _chat_typing() or _busy():
		return false
	_free_pointer()
	return true


# Two seams: a headless display server keeps no captured mode, so the suite overrides these.
func _pointer_captured() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _free_pointer() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _unhandled_input(event: InputEvent) -> void:
	if not capture_pointer or not _set_up or gate_only:
		return
	var click := event as InputEventMouseButton
	if click == null or not click.pressed or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		return
	if is_menu_open() or _chat_typing() or _busy() or not is_shown() or not _pointer_wanted():
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _pointer_wanted() -> bool:
	return not pointer_fn.is_valid() or bool(pointer_fn.call())


func _process(_delta: float) -> void:
	# Polled as well as signalled: busy_fn is the game's and says nothing when it changes.
	_refresh_blocked()
	_refresh_page_guard()


func _guard_web() -> bool:
	return web_eval_fn.is_valid() or DotPlatform.is_web()


func _guard_eval(code: String) -> void:
	if web_eval_fn.is_valid():
		web_eval_fn.call(code)
	else:
		DotWeb.eval(code, true)


func _install_page_guard() -> void:
	if _guard_installed or not _guard_web():
		return
	_guard_installed = true
	_guard_eval(_GUARD_JS)


## True while this client is in a live game: online and the link connected to the server. The
## main menu, a normal leave and a dropped link are all false, so none of them prompts.
func is_in_live_game() -> bool:
	if offline or link == null or not is_instance_valid(link):
		return false
	return link.has_method(&"is_connected_to_server") and bool(link.call(&"is_connected_to_server"))


func _refresh_page_guard() -> void:
	if not _guard_installed:
		return
	# Offline is a solo game in the tab (the shell starts the game scene with no link), and a
	# solo round lost to Ctrl+W is lost all the same; this client only exists while a game runs.
	var want := offline or is_in_live_game()
	if want == _guard_armed:
		return
	_guard_armed = want
	_guard_eval("window.__dotTabGuard.armed = %s;" % ("true" if want else "false"))
	DotLog.debug(CHANNEL, "leave-site prompt %s" % ("armed" if want else "disarmed"))


## Drops the leave-site prompt now. Code that deliberately navigates the page (a reload to
## apply an update, a return to the site) calls this first, or the player is asked to confirm
## something the game itself chose to do. The next frame re-arms it if the link is still live,
## so call it in the same frame as the navigation.
func clear_leave_guard() -> void:
	if _guard_installed and _guard_armed:
		_guard_armed = false
		_guard_eval("window.__dotTabGuard.armed = false;")
		DotLog.debug(CHANNEL, "leave-site prompt cleared for a deliberate navigation")


## Re-reads whether input is blocked now and emits [signal input_blocked_changed] if it
## changed. Polled once a frame anyway; call it the same frame a chat or an overlay opens.
func refresh_blocked() -> void:
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
		if bool(settings.call(&"is_open")):
			return true
		# An adopted menu beside the settings (see _connect_menu_state) counts too.
		var own: Object = _settings_menu()
		if menu != null and menu != own and is_instance_valid(menu):
			for method: StringName in [&"any_open", &"is_open"]:
				if menu.has_method(method):
					return bool(menu.call(method))
		return false
	# A menu adopted without settings: its own answer, else what its signal last said.
	if settings == null and menu != null and is_instance_valid(menu):
		for method: StringName in [&"any_open", &"is_open"]:
			if menu.has_method(method):
				return bool(menu.call(method))
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
	if what == NOTIFICATION_EXIT_TREE and _guard_armed:
		_guard_armed = false
		_guard_eval("window.__dotTabGuard.armed = false;")
	if not sync_on_exit:
		return
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED \
			or what == NOTIFICATION_EXIT_TREE:
		DotWeb.sync_filesystem()


func describe() -> Dictionary:
	return {
		"host": str(host.name) if host != null else "",
		"offline": offline,
		"user_tier": user_tier_on,
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
		"leave_guard": _guard_armed,
		"leave_guard_installed": _guard_installed,
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
	out.append("  leave-site prompt %s" % ("armed" if d["leave_guard"] else "off"))
	return out
