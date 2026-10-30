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
