extends Node

## A stand-in for dot-menu's DotMenuSettings, in the shape DotGameClient duck-types: setup(),
## menu, settings, is_open(), use_maps() and menu_state_changed. The suite runs without
## dot-menu, so this is how the wiring is asserted at all; the real menu is in each game's.

signal menu_state_changed(any_open: bool)

class FakeBoard extends RefCounted:
	var source: Callable = Callable()
	var fed_from: Object = null
	func feed_from(link: Object) -> void:
		fed_from = link

class FakeMenu extends RefCounted:
	var busy: Callable = Callable()
	var scoreboard_action: StringName = &""
	var scoreboard: FakeBoard = FakeBoard.new()
	var followed: Array = []
	var unfollowed: Array = []
	func follow_hud(root: Control, accent: Theme = null) -> void:
		followed.append([root, accent])
	func unfollow_hud(root: Control) -> void:
		unfollowed.append(root)

class FakeMaps extends RefCounted:
	var title: String = ""
	var noun: String = ""
	var link_service: StringName = &"dot_client_link"
	var rows_fn: Callable
	var change_fn: Callable

## Refuse setup, as a settings file that will not load would.
var refuse: bool = false
var menu: FakeMenu = null
## The manager a console binds; any object will do here.
var settings: Object = null
var open_now: bool = false
var setups: int = 0


func setup() -> DotResult:
	setups += 1
	if refuse:
		return DotResult.fail(DotError.CODE_IO, "The settings file would not load.")
	menu = FakeMenu.new()
	settings = RefCounted.new()
	return DotResult.success(self)


func is_open() -> bool:
	return open_now


func set_open(on: bool) -> void:
	open_now = on
	menu_state_changed.emit(on)


func use_maps(rows_fn: Callable, change_fn: Callable) -> FakeMaps:
	var maps := FakeMaps.new()
	maps.rows_fn = rows_fn
	maps.change_fn = change_fn
	return maps
