class_name DotGameStorePanel
extends PanelContainer

## What the player owns from the site store, and a button to the store. Plain controls, so any game's menu or HUD can parent it.
##
## The same read the server's [DotGameStoreEntitlements] merges into the loadout, here with names for the player to see.

const CHANNEL := "game.store"
const PATH := "store/entitlements"
const STORE_PATH := "/dashboard/store"

## Emitted by the button with the address to open; a game that cannot open a browser listens instead.
signal store_requested(url: String)
signal owned_changed()

## Where "Get more" goes. Empty means the site this client signs in against.
var store_url: String = ""

var _owned: Array = []
var _list: VBoxContainer = null
var _title: Label = null
var _button: Button = null


## Items from an entitlements response as `{key, name, kind, store}`, one per key.
static func owned_from(body: Dictionary) -> Array:
	var out: Array = []
	var seen := {}
	var items: Variant = body.get("items", [])
	if not items is Array:
		return out
	for item: Variant in items:
		if not item is Dictionary:
			continue
		var d: Dictionary = item
		var key := str(d.get("key", ""))
		if key == "" or seen.has(key):
			continue
		seen[key] = true
		out.append({"key": key, "name": str(d.get("name", key)), "kind": str(d.get("kind", "")), "store": str(d.get("store", ""))})
	return out


## Adds a "Store" page to a dot-menu (found by duck typing: null or no `add_page` does nothing) that shows a fresh panel each time it opens. [param player_key_fn] returns the player key; [param client_fn] the backbone client (default: the registry's `dot_backbone_client`). Returns the page, or null.
static func add_to_menu(menu: Object, player_key_fn: Callable, client_fn: Callable = Callable(), before: StringName = &"") -> Object:
	if menu == null or not menu.has_method(&"add_page"):
		return null
	var page_script: Script = DotGameStoreEntitlements._class_script("DotMenuPage")
	if page_script == null:
		return null
	var cache: Array = []
	var page: Object = page_script.call("make", &"store", "Store", "What you own from the site store.")
	page.set("build", func(_kit: Object, body: Control) -> void:
		var panel := DotGameStorePanel.new()
		panel.set_owned(cache)
		body.add_child(panel)
		var client: Object = client_fn.call() if client_fn.is_valid() else DotRegistry.get_service(&"dot_backbone_client")
		var key: String = str(player_key_fn.call()) if player_key_fn.is_valid() else ""
		if client == null or key == "":
			return
		await panel.refresh(client, key)
		cache.assign(panel.owned()))
	menu.call(&"add_page", page, before)
	return page


func _init() -> void:
	name = "StorePanel"
	custom_minimum_size = Vector2(260, 0)
	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", 6)
	add_child(col)
	_title = Label.new()
	col.add_child(_title)
	_list = VBoxContainer.new()
	col.add_child(_list)
	_button = Button.new()
	_button.name = "GetMore"
	_button.text = "Get more in the store"
	_button.pressed.connect(open_store)
	col.add_child(_button)
	_rebuild()


## Replaces what is shown with [param items] (see [method owned_from]).
func set_owned(items: Array) -> void:
	_owned = items.duplicate()
	_rebuild()
	owned_changed.emit()


func owned() -> Array:
	return _owned


func is_owned(key: String) -> bool:
	for d: Variant in _owned:
		if str((d as Dictionary).get("key", "")) == key:
			return true
	return false


## Reads the player's entitlements through a backbone client (`get_integration`, dot-auth's). The failure is returned and logged, the list is left as it was.
func refresh(client: Object, player_key: String) -> DotResult:
	if client == null or not client.has_method("get_integration"):
		return DotResult.fail(DotError.CODE_STATE, "No backbone client with get_integration.")
	var res: DotResult = await client.call("get_integration", PATH, {"player": player_key})
	if not res.ok:
		DotLog.warn(CHANNEL, "store panel read failed", {"error": str(res.error)})
		return res
	if not res.value is Dictionary:
		return DotResult.fail(DotError.CODE_INVALID, "The entitlements response is not an object.")
	set_owned(owned_from(res.value))
	return DotResult.success(_owned.size())


## The address "Get more" opens: [member store_url], else [method default_store_url].
func resolved_store_url() -> String:
	return store_url if store_url != "" else default_store_url()


## The sign-in site's store page; empty when the site is not known. Shared with the loadout menu's locked items.
static func default_store_url() -> String:
	var site := DotGameAvatarContent.default_site_url()
	return site + STORE_PATH if site != "" else ""


func open_store() -> void:
	var url := resolved_store_url()
	if url == "":
		return
	store_requested.emit(url)
	if store_requested.get_connections().size() == 0:
		OS.shell_open(url)


func _rebuild() -> void:
	if _list == null:
		return
	for c: Node in _list.get_children():
		c.queue_free()
		_list.remove_child(c)
	_title.text = "Store items you own (%d)" % _owned.size()
	if _owned.is_empty():
		var none := Label.new()
		none.text = "Nothing yet."
		_list.add_child(none)
	for d: Variant in _owned:
		var row := Label.new()
		row.text = "%s  [%s]" % [str((d as Dictionary)["name"]), str((d as Dictionary)["kind"])] if str((d as Dictionary)["kind"]) != "" else str((d as Dictionary)["name"])
		_list.add_child(row)
	_button.visible = resolved_store_url() != ""
