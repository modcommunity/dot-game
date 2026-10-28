class_name DotGameClientMenu
extends RefCounted

## The board and map-vote wiring of [DotGameClient]'s adopted menu; the client keeps the state.


static func wire_board(c: DotGameClient) -> void:
	var board: Object = c.board
	if board == null:
		return
	if c.board_prepare_fn.is_valid() and not c._prepared_boards.has(board.get_instance_id()):
		c._prepared_boards.append(board.get_instance_id())
		c.board_prepare_fn.call(board)
	if not c.offline and c.link != null and c.link.has_signal(&"scoreboard_received") and board.has_method(&"feed_from"):
		board.call(&"feed_from", c.link)
	elif c.board_snapshot_fn.is_valid():
		board.set(&"source", c.board_snapshot_fn)


static func wire_maps(c: DotGameClient) -> void:
	var owner: Object = c.settings if c.settings != null and c.settings.has_method(&"use_maps") else c.menu
	if not (c.maps_rows_fn.is_valid() and c.maps_change_fn.is_valid() and owner != null \
			and owner.has_method(&"use_maps")):
		return
	var made: Variant = owner.call(&"use_maps", c.maps_rows_fn, c.maps_change_fn)
	c.maps = made if made is Object else null
	if c.maps == null:
		return
	if c.maps_title != "":
		c.maps.set(&"title", c.maps_title)
	if c.maps_noun != "":
		c.maps.set(&"noun", c.maps_noun)
	# Played offline beside a link (--offline): there is no server to ask.
	if c.offline:
		c.maps.set(&"link_service", &"")


static func connect_state(c: DotGameClient) -> void:
	var settings: Node = c.settings
	if settings != null and settings.has_signal(&"menu_state_changed") \
			and not settings.is_connected(&"menu_state_changed", c._on_menu_state):
		settings.connect(&"menu_state_changed", c._on_menu_state)
	var menu: Object = c.menu
	if menu == null or not menu.has_signal(&"overlays_changed"):
		return
	if menu == c._settings_menu() and settings != null and settings.has_signal(&"menu_state_changed"):
		return
	if not menu.is_connected(&"overlays_changed", c._on_menu_state):
		menu.connect(&"overlays_changed", c._on_menu_state)
		c._wired_menu = menu
		c._wired_signal = &"overlays_changed"


static func unwire(c: DotGameClient) -> void:
	var old: Object = c.menu
	if old == null or not is_instance_valid(old):
		c._wired_menu = null
		return
	if old.has_signal(&"overlays_changed") and old.is_connected(&"overlays_changed", c._on_menu_state):
		old.disconnect(&"overlays_changed", c._on_menu_state)
	c._wired_menu = null
	c._wired_signal = &""
	if &"busy" in old:
		old.set(&"busy", Callable())
	if c.hud != null and is_instance_valid(c.hud) and old.has_method(&"unfollow_hud"):
		old.call(&"unfollow_hud", c.hud)
	c._menu_open = false


static func is_open(c: DotGameClient) -> bool:
	var settings: Node = c.settings
	var menu: Object = c.menu
	if settings != null and is_instance_valid(settings) and settings.has_method(&"is_open"):
		if bool(settings.call(&"is_open")):
			return true
		var own: Object = c._settings_menu()
		if menu != null and menu != own and is_instance_valid(menu):
			return _menu_answer(menu, false)
		return false
	# A menu adopted without settings: its own answer, else what its signal last said.
	if settings == null and menu != null and is_instance_valid(menu):
		return _menu_answer(menu, c._menu_open)
	return c._menu_open


static func _menu_answer(menu: Object, fallback: bool) -> bool:
	for method: StringName in [&"any_open", &"is_open"]:
		if menu.has_method(method):
			return bool(menu.call(method))
	return fallback


static func ensure_scoreboard_action(c: DotGameClient) -> void:
	var action: StringName = c.scoreboard_action
	if action != DotGameClient.SCOREBOARD_ACTION or InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var tab := InputEventKey.new()
	tab.physical_keycode = KEY_TAB
	InputMap.action_add_event(action, tab)
