class_name DotGameStoreEntitlements
extends RefCounted

## Adds what the site store says a player owns to a dot-loadout manager's entitlements, with no per-game code.
##
## dot-loadout is named nowhere: its classes are found through the global class list, and a
## project without it (or without a `dot_backbone_client`) is left exactly as it was.

const CHANNEL := "game.store"
const META := &"dot_game_store_entitlements"

static var _scripts: Dictionary = {}


## Wraps `manager.entitlement_source` so the player's site entitlements are merged in. False when already wrapped or not a loadout manager.
static func attach(manager: Object) -> bool:
	if manager == null or manager.has_meta(META) or not "entitlement_source" in manager:
		return false
	var site_script: Script = _class_script("DotLoadoutSiteSource")
	var ents_script: Script = _class_script("DotLoadoutEntitlements")
	if site_script == null or ents_script == null:
		return false
	manager.set_meta(META, true)
	if "store_url" in manager and str(manager.get("store_url")) == "":
		manager.set("store_url", DotGameStorePanel.default_store_url())
	var site: Object = site_script.new()
	var inner: Callable = manager.get("entitlement_source")
	manager.set("entitlement_source", func(key: String) -> Object:
		var base: Variant = inner.call(key) if inner.is_valid() else null
		var out: Object = ents_script.call("of", base if base is Array else [])
		if base is Object:
			out.call("merge", base)
		if site.get("client") == null:
			site.set("client", DotRegistry.get_service(&"dot_backbone_client"))
		if site.get("client") != null:
			site.call("source", key)
			out.call("merge", ents_script.call("of", site.call("ids_of", key)))
		return out)
	DotLog.debug(CHANNEL, "site store entitlements attached", {"manager": str(manager.get_path()) if manager is Node and manager.is_inside_tree() else ""})
	return true


## Gives a dot-menu loadout menu locked store items on the solo path: [param command_fn] returns the game's dot-loadout command (null before the match exists), [param key_fn] the player's storage key. Connected needs nothing more, the menu already asks `/loadout locked`. Returns false for a menu without the hooks.
static func wire_menu(menu: Object, command_fn: Callable, key_fn: Callable) -> bool:
	if menu == null or not "offer_fn" in menu or not "store_fn" in menu:
		return false
	menu.set("offer_fn", func() -> Variant:
		var command: Object = command_fn.call()
		var key := str(key_fn.call())
		if command == null or key == "":
			return DotResult.fail(DotError.CODE_STATE, "Join the match first.")
		attach(command.get("manager"))
		return await command.call("offer", key, bool(menu.get("include_locked"))))
	menu.set("store_fn", func(item_id: StringName) -> String:
		var command: Object = command_fn.call()
		var manager: Object = command.get("manager") if command != null else null
		if manager != null and manager.has_method("request_store"):
			return str(manager.call("request_store", item_id))
		return DotGameStorePanel.default_store_url())
	return true


## Attaches to every loadout manager under `root`. Harmless twice.
static func attach_tree(root: Node) -> int:
	var n := 0
	for node: Node in root.find_children("*", "", true, false):
		if "entitlement_source" in node and node.has_method("entitlements_for") and attach(node):
			n += 1
	return n


static func _class_script(class_id: String) -> Script:
	if _scripts.has(class_id):
		return _scripts[class_id]
	var found: Script = null
	for c: Dictionary in ProjectSettings.get_global_class_list():
		if str(c.get("class", "")) == class_id:
			found = load(str(c.get("path", ""))) as Script
			break
	_scripts[class_id] = found
	return found
