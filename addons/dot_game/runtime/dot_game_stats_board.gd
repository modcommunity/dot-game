class_name DotGameStatsBoard
extends RefCounted

## Puts the stats a game's dot-stats tracker keeps on the Tab board snapshot: per player, this game's figure (`st_<id>`) and the lifetime total (`lt_<id>`), already formatted, and the list of stats as `stat_columns`. dot-menu's `DotMenuStats` and `DotMenuStatsPanel` draw them. Duck-typed: dot-stats is never named.
## Lifetime is the tracker store's total when the seat joined plus this game's figure, merged by the schema's rules. Without a store only the game's figure is sent.

const CHANNEL := "game.stats_board"

## Where the figures come from: its key scheme, and the tracker it opened sessions on.
var feed: DotGameStatsFeed = null

## userid -> DotStatsValues (the store's lifetime total when the seat joined).
var _baseline: Dictionary = {}


static func attach(on: DotGameStatsFeed, roster: DotGameRoster) -> DotGameStatsBoard:
	var made := DotGameStatsBoard.new()
	made.feed = on
	roster.seated.connect(made._on_seated)
	roster.unseated.connect(func(session: DotClientSession) -> void: made._baseline.erase(session.userid))
	return made


## The snapshot keys for one seat; empty when there is no tracker or session.
func fields(session: DotClientSession) -> Dictionary:
	var t := feed.active_tracker() if feed != null else null
	var schema: Variant = t.get(&"schema") if t != null else null
	if schema == null:
		return {}
	var key := feed.key_for(session)
	if not bool(t.call(&"has_player", key)):
		return {}
	var mine: Object = t.call(&"session_values", key)
	var lifetime: Object = (_baseline.get(session.userid) as Object)
	if lifetime != null:
		lifetime = lifetime.call(&"duplicate_values")
		lifetime.call(&"merge_from", mine, schema)
	var out := {}
	for def: Object in _listed(schema):
		var id: StringName = def.get(&"id")
		if bool(mine.call(&"has", id)) or lifetime != null and bool(lifetime.call(&"has", id)):
			out["st_%s" % id] = def.call(&"format_value", float(mine.call(&"get_value", id)))
			if lifetime != null:
				out["lt_%s" % id] = def.call(&"format_value", float(lifetime.call(&"get_value", id)))
	return out


## `{"stat_columns": [{key, title, column}]}` for the snapshot, or empty.
func extra() -> Dictionary:
	var t := feed.active_tracker() if feed != null else null
	var schema: Variant = t.get(&"schema") if t != null else null
	if schema == null:
		return {}
	var listed: Array = []
	for def: Object in _listed(schema):
		listed.append({"key": str(def.get(&"id")), "title": str(def.get(&"display_name")), "column": str(def.get(&"column"))})
	return {"stat_columns": listed} if not listed.is_empty() else {}


## The schema's stats a player may see: shown, stored (not derived) and not hidden.
func _listed(schema: Object) -> Array:
	var out: Array = []
	for id: Variant in schema.call(&"ids"):
		var def: Object = schema.call(&"find", StringName(str(id)))
		if def != null and bool(def.get(&"visible")) and def.get(&"derived") == null and str(def.get(&"column")) != "hidden":
			out.append(def)
	return out


func _on_seated(session: DotClientSession) -> void:
	var t := feed.active_tracker() if feed != null else null
	var store: Variant = t.get(&"store") if t != null else null
	if store == null or not (store as Object).has_method(&"values_for"):
		return
	var key := feed.key_for(session)
	var userid := session.userid
	var got: Variant = await (store as Object).call(&"values_for", key)
	if got is DotResult and (got as DotResult).ok and (got as DotResult).value is Object and not _baseline.has(userid):
		_baseline[userid] = (got as DotResult).value
