class_name DotGameClient
extends Node

## The client's half of [DotGameModule]: the platform layer every game client wires, once.
## [codeblock]
## # First thing in the client root's _ready():
## platform = DotGameClient.new()
## platform.spawned_fn = func() -> bool: return player != null
## add_child(platform)                 # the cover is up; link and offline are known
## # ... build the world, the HUD, the audio ...
## platform.hud = hud_root
## platform.chat = chat                   # DotGameChatClient, a DotChatWindow, or null
## platform.setup()                    # settings, menu, console, theme, Tab, M, pointer
## platform.input_blocked_changed.connect(_suspend_input)
## [/codeblock]
##
## A child the client root adds, never a base class: roots are Node, Node2D and Node3D. [method _ready] puts the cover up before the game builds anything; [method setup] builds the settings and menu after the game made what they bind to.
##
## dot-menu and dot-console are found by path and driven by `call` and `set`, so a build without either still parses. Each piece switches off ([member use_gate], [member use_settings], [member use_console], [member capture_pointer], [member sync_on_exit], an empty [member scoreboard_action]); override [method _make_settings] or [method _make_gate] to build one differently.
##
## A HUD or chat built after setup goes through [method set_hud] and [method set_chat]; a game with its own menu assigns [member menu] or calls [method adopt_menu]; [member gate_only] takes only the gate, link, input block and web flush.

const CHANNEL := "game.client"

## The shell's [code]DotClientLink[/code], by registry name.
const LINK_SERVICE := &"dot_client_link"
## dot-menu's settings node, made when a game assigns none. Never named: dot-menu is optional.
const SETTINGS_SCRIPT := "res://addons/dot_menu/runtime/dot_menu_settings.gd"
## dot-console's one-call console. Never named, for the same reason.
const LOCAL_SCRIPT := "res://addons/dot_console/core/dot_console_local.gd"
const CONSOLE_KIT_SCRIPT := "res://addons/dot_console/runtime/dot_console_kit.gd"
## The Tab action made when the game's own key table has none.
const SCOREBOARD_ACTION := &"dot_game_scoreboard"
const LOOK_MUTE_SCRIPT := "res://addons/dot_voice/runtime/dot_voice_look_mute.gd"
const BINDINGS_SCRIPT := "res://addons/dot_menu/core/dot_menu_bindings.gd"
## The gate's requirement for the local player.
const REASON_SPAWNED := &"spawned"
const _Vis := preload("res://addons/dot_game/runtime/dot_game_client_vis.gd")

## Whether the player's input should be off now: the cover is up, a menu or the console is open, or the chat or [member busy_fn] has the keyboard.
signal input_blocked_changed(blocked: bool)
## A menu (or the console) opened, or the last one closed.
signal menu_state_changed(any_open: bool)


## The client root: the gate goes under it so its camera check and [method DotLoadGate.of] see the game. The parent when unset.
@export var host_ref: DotNodeRef = null

## Play offline even with a link (a suite, [code]--offline[/code]).
@export var force_offline: bool = false

## Build the load gate and its cover. Off for a client whose shell covers it some other way.
@export var use_gate: bool = true
## Hold the cover until a current camera exists in the game. Off for a game with none.
@export var require_camera: bool = true
## Compile what the first frame draws under the cover before lifting it. Never headless, where the warm-up would only wait out its timeout.
@export var warm_up: bool = true
## A scene instanced as the gate's cover instead of [DotLoadingCover]. Null keeps the stock cover.
@export var cover_scene: PackedScene = null
## A cover node of your own, assigned before add_child; wins over [member cover_scene].
var cover: Node = null
## The status line while [member spawned_fn] is false.
@export var spawned_text: String = "Joining"
## Tell the server when the cover lifts and returns, so [DotGameModule.is_loading] can spare a player who cannot see yet. Connected only.
@export var report_loading: bool = true

## [code]func() -> bool[/code]: true once the local player exists. Held under [constant REASON_SPAWNED] until then; unset holds nothing.
var spawned_fn: Callable = Callable()


## Look at a player and press a key to gag or mute them, on every game with a voice chat. The keys are rows in the game's table unless it has them.
@export var use_look_mute: bool = true
## The look-mute script, by path (dot-voice's); a suite points it at a stand-in.
var look_mute_script: String = LOOK_MUTE_SCRIPT
## The two actions. Defaults are G and K (never H: dot-menu's help key); a game binds its own.
@export var look_gag_action: StringName = &"voice_gag"
@export var look_mute_action: StringName = &"voice_mute"
## Gag and mute on their own keys; off, one key taps gag and double-taps mute.
@export var look_separate_keys: bool = true
@export var look_max_distance: float = 30.0
@export var look_max_angle_deg: float = 6.0
## [code]func() -> int[/code]: the peer under the crosshair, 0 for nobody. Wins over the next.
var look_target_fn: Callable = Callable()
## [code]func() -> Dictionary[/code] of peer id to head position; the key picks the nearest to the view axis. Unset, the chat's `voice_position_fn` answers for speakers.
var look_positions_fn: Callable = Callable()
## [code]func(row: Dictionary) -> Variant[/code]: a head position (Vector3, or null) for a roster row `{id, name, key, peer, bot}` of the chat's block list. The one hook a game needs; [member look_positions_fn] wins.
var look_position_fn: Callable = Callable()
## [code]func(peer: int, muted: bool)[/code]: also drop that player's chat. Unset, the chat's block list (the one `!sm` uses) is used.
var look_chat_mute_fn: Callable = Callable()
## For a client whose voice manager or chat is not [member chat]'s: the manager the keys act on and the node holding `self_mute`. Then call [method build_look_mute].
var look_voice: Node = null
var look_chat: Node = null
## The dot-voice look-mute node, once built; null without dot-voice or a voice chat.
var look_mute: Node = null
## Keys held by another action at the time of the check: [code]{action, key, other}[/code].
var look_conflicts: Array[Dictionary] = []

## Turns on dot-core's player cfg tier (and its menu entry) when this process is solo or the listen host.
@export var user_cfg: bool = true
## [code]func() -> bool[/code]: this client also hosts the server it is connected to. Unset means a connected client is a guest and gets no tier.
var listen_host_fn: Callable = Callable()
## Files the player may edit, each `{addon, file, schema, label}`; append before [method setup]. Empty hides the entry.
var user_cfg_files: Array[Dictionary] = []

## Build the settings and the Escape menu (dot-menu).
@export var use_settings: bool = true
## Where a stock settings node keeps its document, when [member settings] is unset.
@export var settings_directory: String = ""
## The stock settings node's namespace, when [member settings] is unset.
@export var app_namespace: StringName = &"game"
## Build the console (dot-console) on the key under Escape.
@export var use_console: bool = true
## The script whose static `build(host, settings, menu)` makes the console; dot-console's kit unless replaced.
var console_kit_path: String = CONSOLE_KIT_SCRIPT
## Hold Tab for the board: the menu's `scoreboard_action`, made on Tab when nothing defines it. Empty is no key.
@export var scoreboard_action: StringName = SCOREBOARD_ACTION
## Capture the pointer on a desktop, free it while a menu is open, take it back on close (or on a click in a browser). Off for a game that keeps its pointer.
@export var capture_pointer: bool = true
## [code]func() -> bool[/code]: whether the pointer should be captured now; unset captures whenever nothing blocks input. Needs [member capture_pointer].
var pointer_fn: Callable = Callable()
## Escape on a captured pointer only frees it; the next Escape opens the menu. Needs [member capture_pointer].
@export var escape_releases_pointer: bool = false
## Gate-only mode: [method setup] wires only the chat's keyboard and the input block, for a game that owns the rest.
@export var gate_only: bool = false
## Flush [code]user://[/code] to the browser's storage when the game goes. A no-op off the web.
@export var sync_on_exit: bool = true

## The game's settings node (a `DotMenuSettings` subclass), assigned before [method setup]; null makes the stock one.
var settings: Node = null
## The HUD's root Control: it follows the menu's theme and HUD size.
var hud: Control = null
## The game's accent over the theme (dot-menu's [code]follow_hud[/code]); null for none.
var hud_accent: Theme = null
## The chat box: a [DotGameChatClient], a dot-ui window, or anything with `is_typing()` or `is_open()`. Typing blocks input and keeps Escape off the menu.
var chat: Node = null
## [code]func() -> bool[/code]: something else of the game's has the keyboard (a command line). Blocks input and frees the pointer.
var busy_fn: Callable = Callable()
## [code]func() -> Dictionary[/code]: the Tab board offline (dot-menu's snapshot shape); connected, the link's roster feeds it.
var board_snapshot_fn: Callable = Callable()
## The map menu on M: `func() -> Array` of rows and `func(id) -> DotResult` to change. Both unset leave M doing nothing.
var maps_rows_fn: Callable = Callable()
var maps_change_fn: Callable = Callable()
## The map menu's title and plural noun ("Change house", "houses"); empty keeps dot-menu's.
var maps_title: String = ""
var maps_noun: String = ""

## Per-map settings on the client (cvars a map's file sets, see [DotGameMapConfig]): the whitelist, key -> `{type, min, max}`. Empty takes none.
var map_config_keys: Dictionary = {}
## The weakest layer for a map with no file: key -> value.
var map_config_defaults: Dictionary = {}
## The `cfg/game/<game>/dot_map/` game name; [code]DotAddonConfig.game[/code] when empty.
var map_config_game: String = ""
## `(key) -> Variant` and `(key, value) -> bool` over the client's cvars; both needed.
var map_config_get_fn: Callable = Callable()
var map_config_set_fn: Callable = Callable()
## The built applier, after the first [method map_changed].
var map_config: DotGameMapConfig = null


## The client root this serves.
var host: Node = null
## The shell's link, or null offline. Assign before add_child to use another.
var link: Object = null
## The avatar actions' client half, once [method add_avatar_actions] has run.
var avatar_actions: DotGameAvatarActionClient = null

## The content fetcher of the last [method prepare_avatar_content], whose cache holds the files.
var avatar_fetcher: RefCounted = null

## The site and its id for this server, where other players' clips are fetched; empty, [method avatar_site] and [method avatar_server] find them.
var avatar_site_url: String = ""
var avatar_server_id: int = 0
var _avatar_library := {}
## No server: no link, [member force_offline], or [code]--offline[/code] on the command line.
var offline: bool = true
## Whether this client turned the cfg tier on ([member user_cfg] and solo or listen host).
var user_tier_on: bool = false
var user_cfg_overlay: DotGameUserCfg.Overlay = null
## dot-core's load gate, under [member host]. Hold more on it: [code]gate.hold(&"map")[/code].
var gate: DotLoadGate = null
## Set by [method add_noblock].
var noblock: DotGameNoblock = null
## The settings' menu (dot-menu's `DotMenu`), its board and its map menu. A game with its own menu assigns [member menu] before [method setup] (or calls [method adopt_menu]); an assigned [member board] is kept.
var menu: Object = null
var board: Object = null:
	set(value):
		board = value
		_board_auto = false
## [code]func(board)[/code]: the game's own preparation of the board (columns, teams, a header), run before it is fed. Unset does nothing.
var board_prepare_fn: Callable = Callable()
var maps: Object = null
## dot-console's controller.
var console: Node = null
## Map culling for a converted map ([method attach_visibility]): `off` (the default, nothing is built), `pvs`, `occluders` or `both`. The console's `vis_mode` and `--vis_mode=` on the command line set it.
@export_enum("off", "pvs", "occluders", "both") var vis_mode: String = "off"
## dot-map's DotMapVisibility while one is attached and on, else null.
var visibility: Node = null
var _vis_world: RefCounted = null
var _vis_drawn: WeakRef = null
var _vis_parent: WeakRef = null

var _set_up: bool = false
# True while board came from the menu's own scoreboard: adopting another menu then takes that menu's board.
var _board_auto: bool = false
# Boards already given to board_prepare_fn: each is prepared once, however often it is wired.
var _prepared_boards: Array[int] = []
# The menu whose signal and busy callable are currently wired, and the signal used.
var _wired_menu: Object = null
var _wired_signal: StringName = &""
var _blocked: bool = false
var _menu_open: bool = false

## Test seam: when valid, the page-guard JavaScript goes here and the client acts as if on the web.
var web_eval_fn: Callable = Callable()
var _guard_armed: bool = false
var _guard_installed: bool = false

func _ready() -> void:
	host = _resolve_host()
	var mp := multiplayer
	if mp != null and not mp.server_disconnected.is_connected(restore_map_config):
		mp.server_disconnected.connect(restore_map_config)
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
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--vis_mode="):
			var _v := set_vis_mode(a.get_slice("=", 1))
	_blocked = is_input_blocked()
	DotGamePageGuard.install(self)


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


## Tells the server this client's loading cover went up ([param covered] true) or lifted. False when nothing was sent (no link, or an older server that releases the seat by timeout).
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
				# Under the host: the gate marks its parent for DotLoadGate.of. A host still readying refuses a child, so wait a frame.
	if host.is_node_ready():
		host.add_child(made)
	else:
		host.add_child.call_deferred(made)
	return made


## The settings, menu, console, theme, Tab, M, the chat's keyboard and the pointer. Call once, after the HUD and chat exist. A piece that cannot be built is logged and the rest go on.
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
	DotGameClientLook.build(self)

	if capture_pointer and not DotPlatform.is_web():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	_refresh_blocked()
	return DotResult.success(self)


## Hands over a HUD built after [method setup]: it follows the menu's theme and HUD size. Safe before setup() too; replaces an earlier HUD.
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


## Hands over a chat box built after [method setup] (before it, setup() wires it). Typing in it blocks input; the previous chat is let go.
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
	made.set(&"avatar_actions", true)
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

	DotGameClientLook.add_rows(self)
	var built: Variant = settings.call(&"setup")
	if built is DotResult and not (built as DotResult).ok:
		DotLog.warn(CHANNEL, "no settings; everything is at its default", {"why": (built as DotResult).error.message})
		settings.queue_free()
		settings = null
		return

	var got: Variant = settings.get(&"menu")
	menu = got if got is Object else null
	_add_user_cfg_entry()


func _add_user_cfg_entry() -> void:
	DotGameUserCfg.add_entry(self)


## Opens the cfg editor over the menu. False without the tier, files, menu or editor.
func open_user_cfg() -> bool:
	return DotGameUserCfg.open(self)


## Hands over a menu the game built itself, with its own board if any. Before [method setup] it is the same as assigning [member menu]; after, it is wired at once.
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


## Puts the last map's settings back. Called when the server connection drops, on teardown, and by a game that leaves a match another way; safe to call twice.
func restore_map_config() -> void:
	if map_config != null:
		map_config.restore()


## The map changed on this client: applies the map's settings and puts the last map's back. Call it on every map load (a map's own load, a round's new layout); a no-op until [member map_config_keys] or its defaults and both functions are set.
func map_changed(map_id: String) -> void:
	if map_config == null:
		if (map_config_keys.is_empty() and map_config_defaults.is_empty()) \
				or not map_config_get_fn.is_valid() or not map_config_set_fn.is_valid():
			return
		map_config = DotGameMapConfig.new()
		map_config.game_id = map_config_game if map_config_game != "" else DotAddonConfig.game
		map_config.keys = map_config_keys
		map_config.defaults = map_config_defaults
		map_config.get_fn = map_config_get_fn
		map_config.set_fn = map_config_set_fn
	map_config.apply(map_id)


## Builds the console now, over [param manager] and the menu. [method setup] calls it; a game that builds its menu first turns [member use_console] off and calls this. The first console stays.
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
	var _v := _Vis.add_console_var(self)
	return console


## Culls [param world] (a dot-map DotMapBspMesh) drawn as [param drawn] by [member vis_mode], under [param parent] (default [param drawn]); call on every map load. Null while off, without dot-map, or for a map with no visibility data.
func attach_visibility(world: RefCounted, drawn: Node3D, parent: Node = null) -> Node:
	return _Vis.attach(self, world, drawn, parent)


## Drops the culling of the last map: call when it is unloaded.
func detach_visibility() -> void:
	_Vis.detach(self)


## Sets [member vis_mode] and applies it to the attached map. False for an unknown name.
func set_vis_mode(mode: String) -> bool:
	return _Vis.set_mode(self, mode)


## Relays the menu's open and close as [signal menu_state_changed], from the settings node else the menu (an adopted menu also via `overlays_changed`).
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


## Undoes _wire_menu for the menu being replaced: its signal, busy callable and HUD follow.
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


func _look_chat_mute(peer: int, muted: bool) -> void:
	DotGameClientLook.chat_mute(self, peer, muted)


func _look_target() -> int:
	return DotGameClientLook.target(self)


## The first of [param candidates] no action holds and no row of [param table] defaults to.
func free_look_key(candidates: Array, table: Object = null) -> String:
	return DotGameClientLook.free_key(self, candidates, table)


## Actions other than the look-mute pair that hold [param keycode] (physical or logical).
func key_holders(keycode: int) -> PackedStringArray:
	return DotGameClientLook.holders(self, keycode)


## Builds the look keys now; [method setup] does it, so call this only when the voice came later.
func build_look_mute() -> void:
	DotGameClientLook.build(self)


## The look-mute actions whose key another action also holds, as [code]{action, key, other}[/code].
func find_look_conflicts() -> Array[Dictionary]:
	return DotGameClientLook.conflicts(self)


func _on_menu_state(any_open: bool) -> void:
	_menu_open = any_open
	if capture_pointer:
		if any_open:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif not DotPlatform.is_web() and not _busy() and _pointer_wanted():
						# A browser refuses a capture that is not a click; _unhandled_input takes it.
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	menu_state_changed.emit(any_open)
	_refresh_blocked()


func _input(event: InputEvent) -> void:
	# Before the menu's own _unhandled_input, which would open on this same press.
	if _release_pointer_on_escape(event):
		get_viewport().set_input_as_handled()


## Whether [param event] was an Escape that only freed the captured pointer; nothing is freed while a menu, the chat or the game's keyboard owner has the keys.
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


## True while this client is online with the link connected; the main menu, a normal leave and a dropped link are false.
func is_in_live_game() -> bool:
	if offline or link == null or not is_instance_valid(link):
		return false
	return link.has_method(&"is_connected_to_server") and bool(link.call(&"is_connected_to_server"))


func _refresh_page_guard() -> void:
	DotGamePageGuard.refresh(self)


## Drops the leave-site prompt now, for code that deliberately navigates the page. The next frame re-arms it if the link is live, so call it in the same frame.
func clear_leave_guard() -> void:
	DotGamePageGuard.clear(self)


## Re-reads whether input is blocked and emits [signal input_blocked_changed] on a change. Polled each frame; call it the frame a chat or overlay opens.
func refresh_blocked() -> void:
	_refresh_blocked()


func _refresh_blocked(_unused: Variant = null) -> void:
	var now := is_input_blocked()
	if now != _blocked:
		_blocked = now
		input_blocked_changed.emit(now)



## True while the player's input should be off: covered, a menu open, typing, or busy.
func is_input_blocked() -> bool:
	return not is_shown() or is_menu_open() or _chat_typing() or _busy()


## Follows the server's `mp_teamblock` family so this client predicts against the same pairs: the game's `block_rules` feeds `body_rules.pair_fn`. Call after [method setup]; fails when dot-team is absent or the link cannot replicate cvars.
func add_noblock(game: Object, side_fn: Callable) -> DotResult:
	return DotGameNoblock.add_to_client(self, game, side_fn)


## Downloads what a server advertises ([constant DotGameAvatarContent.CVAR]) before connecting, holding [member gate]; on failure the gate stays held and the caller must not connect.
func prepare_avatar_content(rules: Dictionary, base_url: String, server_id: int, http: DotHttp = null) -> DotResult:
	return await DotGameClientAvatars.prepare_content(self, rules, base_url, server_id, http)


## [member avatar_site_url], else the site this client signs in against.
func avatar_site() -> String:
	return avatar_site_url if avatar_site_url != "" else DotGameAvatarContent.default_site_url()


## [member avatar_server_id], else the server's replicated [constant DotGameAvatarContent.SERVER_CVAR].
func avatar_server() -> int:
	if avatar_server_id > 0:
		return avatar_server_id
	var source: Object = link if link != null else DotRegistry.get_service(LINK_SERVICE)
	var cvars: Variant = source.get(&"replicated_cvars") if source != null and is_instance_valid(source) else null
	return DotGameAvatarContent.server_id_from_rules(cvars) if cvars is Dictionary else 0


## The signed-in member's equipped actions from the avatar read, for [method add_avatar_actions]. Null (starters) when none.
func read_avatar_actions(http: DotHttp, user_key: String, headers: Dictionary = {}) -> DotResult:
	var path := "res://addons/dot_user_avatar/net/dot_avatar_sync.gd"
	if http == null or not ResourceLoader.exists(path):
		return DotResult.success(null)
	return await (load(path) as GDScript).call(&"fetch_actions", http, user_key, headers)


## Wires the avatar actions (emote `,`, pose `.`, gesture `/`) to the figures: a press plays on [param figure_fn] (peer id -> figure) and is relayed through [param net] (null offline). Register [DotGameAvatarActionMessage] before the manager is sealed. Call after [method setup].
func add_avatar_actions(net: DotNetManager, figure_fn: Callable, backbone_actions: Variant = null) -> DotResult:
	return DotGameClientAvatars.add_actions(self, net, figure_fn, backbone_actions)


## Hosts a [DotGameWorkbench] on this client: its window counts as a menu overlay and the console gets `workbench`. Call after [method setup] and the workbench's `start()`.
func add_workbench(wb: Node) -> void:
	DotGameWorkbench.host_on(self, wb)


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
	if what == NOTIFICATION_EXIT_TREE:
		restore_map_config()
	if what == NOTIFICATION_EXIT_TREE and user_tier_on:
		# The flag is process-wide: leaving it on would hand the next server's addons the player's files.
		user_tier_on = false
		DotAddonConfig.set_user_tier(false)
	if what == NOTIFICATION_EXIT_TREE:
		DotGamePageGuard.clear(self, false)
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
		"look_mute": look_mute != null,
		"look_conflicts": look_conflicts.size(),
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
