class_name DotGameAvatarActionClient
extends Node

## The client half of avatar actions: a key press plays on the local figure at once and is sent
## to the server; what the server relays plays on that peer's figure. An uploaded clip in a
## told loadout is fetched once through [member content_fn]. Built by [method DotGameClient.add_avatar_actions].

const CHANNEL := "game.avatar_action"

var net: DotNetManager = null
var input: Object = null

## func(peer_id: int) -> Object with play_action(id: StringName, loop: bool, elapsed: float): the figure of that peer, or null.
var figure_fn: Callable = Callable()

## func() -> bool: true while a menu, a chat box or the like has the keyboard.
var blocked_fn: Callable = Callable()

## func(entry: Dictionary) -> DotResult (may await) of a Node3D holding the clip; the caller owns
## it. Null leaves uploaded clips unplayed (built-ins still play).
var content_fn: Callable = Callable()

## func(id: String) -> String: the site library's file url for an upload id, "" while the library is unread.
var url_fn: Callable = Callable()

## func(id: String) -> Dictionary: the site library's row for a wearable id (slot, bone, offset, sha256, url), empty while unread.
var wearable_row_fn: Callable = Callable()

## func(rows: Dictionary) -> DotResult of the input's actions; default dot-user-avatar's `from_backbone`, by path.
var actions_fn: Callable = Callable()

## Seconds between looks at whether a figure has appeared, or been rebuilt, since its wearables were last hung.
const WEAR_RETRY_SEC := 1.0

## Uploaded clip scenes kept, at most this many; a hostile server cannot make it fetch thousands.
const MAX_SCENES := 64

## peer id -> the entries the server said they have equipped.
var loadouts: Dictionary = {}

var _online := false
## Asks left for the loadouts; repeated, further apart each time, until one arrives (the first may
## leave before the connection is up).
var _ask_tries := 0
var _ask_wait := 0.0
var _ask_gap := 1.0
var _scenes: Dictionary = {}
var _fetching: Dictionary = {}
## peer id -> the wearable ids the server said they wear, and what is hung on which figure.
var worn: Dictionary = {}
var _wearers: Dictionary = {}
var _worn_on: Dictionary = {}
var _wear_wait := 0.0
## Wearable ids already fetched once, so a failed download is not retried every second.
var _wear_tried: Dictionary = {}
## Whether the keys were last built with a placeholder url, to rebuild them once the library names the real one.
var _flags: Dictionary = {}


## [param p_net] is null offline: the action plays locally and goes nowhere.
func attach(p_net: DotNetManager, p_input: Object, p_figure_fn: Callable) -> void:
	net = p_net
	input = p_input
	figure_fn = p_figure_fn
	input.connect(&"action_requested", _on_requested)
	if net != null:
		var on := net.messages.on(DotGameAvatarActionMessage.NAME, _on_message)
		_online = on.ok
		if not on.ok:
			DotLog.warn(CHANNEL, "type not registered before the seal; actions stay local",
				{"why": on.error.message})
		var _l := net.messages.on(DotGameAvatarLoadoutMessage.NAME, _on_loadout)
		if _online and net.messages.type_names().has(String(DotGameAvatarLoadoutAsk.NAME)):
			_ask_tries = 5
			_ask_gap = 1.0
			_ask()


func _exit_tree() -> void:
	for scene: Variant in _scenes.values():
		if scene is Node and is_instance_valid(scene):
			(scene as Node).free()
	_scenes.clear()


func _process(delta: float) -> void:
	if _ask_tries > 0:
		_ask_wait -= delta
		if _ask_wait <= 0.0:
			_ask()
	if input != null and blocked_fn.is_valid():
		input.set(&"enabled", not bool(blocked_fn.call()))
	_wear_wait -= delta
	if _wear_wait <= 0.0 and not worn.is_empty():
		_wear_wait = WEAR_RETRY_SEC
		for peer: int in worn:
			var _w := wear(peer)


## Asks the server for every loadout: the ones told at the join reached no handler if this attached late.
func _ask() -> void:
	_ask_tries -= 1
	_ask_wait = _ask_gap
	_ask_gap *= 2.0
	var sent := net.send(DotGameAvatarLoadoutAsk.new())
	if not sent.ok:
		DotLog.debug(CHANNEL, "loadout ask not sent", {"why": sent.error.message})


func _on_requested(entry: Dictionary) -> void:
	var id := String(entry.get("id", ""))
	var loop := bool(entry.get("loop", false))
	_play(net.local_peer_id if net != null else 0, id, loop, 0.0)
	if not _online:
		return
	var request := DotGameAvatarActionMessage.new()
	request.id = id
	request.loop = loop
	var sent := net.send(request)
	if not sent.ok:
		DotLog.debug(CHANNEL, "request not sent", {"why": sent.error.message})


func _on_message(message: DotNetMessage) -> void:
	var m := message as DotGameAvatarActionMessage
	if m == null or m.actor == net.local_peer_id:
		return
	var late := maxi(0, net.clock.tick - m.start_tick)
	_play(m.actor, m.id, m.loop, float(late) / float(maxi(1, net.clock.tick_rate)))


func _on_loadout(message: DotNetMessage) -> void:
	var m := message as DotGameAvatarLoadoutMessage
	if m == null:
		return
	_ask_tries = 0
	if m.wearables.is_empty():
		var _x := worn.erase(m.actor)
	else:
		worn[m.actor] = m.wearables
		_worn_on.erase(m.actor)
	var _w := wear(m.actor)
	if m.entries.is_empty():
		var _e := loadouts.erase(m.actor)
		return
	loadouts[m.actor] = m.entries
	if net != null and m.actor == net.local_peer_id:
		apply_to_input(m.entries)
	for e: Dictionary in m.entries:
		if String(e.get("clip", "")) != "":
			fetch_clip(e)


## Makes the local keys play what the server says is equipped, keeping the rows [member input] has
## for an id so their names and urls survive; otherwise a re-equip or a failed read leaves the keys
## different from what the server accepts.
func apply_to_input(entries: Array) -> bool:
	if input == null or not input.get(&"actions") is Object:
		return false
	var current: Object = input.get(&"actions")
	_flags.clear()
	var rows := DotGameAvatarActionSupport.input_rows(entries, current, url_fn, _flags)
	var read: Variant = null
	if actions_fn.is_valid():
		read = actions_fn.call(rows)
	else:
		var script := DotGameAvatarActionSupport.script("res://addons/dot_user_avatar/actions/dot_avatar_actions.gd")
		read = script.call(&"from_backbone", rows) if script != null else null
	if read is DotResult and (read as DotResult).ok:
		input.set(&"actions", (read as DotResult).value)
		return true
	return false


## Fetches an uploaded entry's clip once, in the background. False when it is kept, on its way,
## or cannot be (no [member content_fn], the cap reached).
func fetch_clip(entry: Dictionary) -> bool:
	var id := String(entry.get("id", ""))
	if id == "" or _scenes.has(id) or _fetching.has(id) or not content_fn.is_valid():
		return false
	if _scenes.size() + _fetching.size() >= MAX_SCENES:
		DotLog.debug(CHANNEL, "clip cap reached", {"id": id})
		return false
	_fetching[id] = true
	_fetch_clip(entry)
	return true


func _fetch_clip(entry: Dictionary) -> void:
	var id := String(entry["id"])
	var res: Variant = await content_fn.call(entry)
	var _f := _fetching.erase(id)
	if _flags.has("placeholder") and net != null and loadouts.has(net.local_peer_id):
		var _a := apply_to_input(loadouts[net.local_peer_id])
	if res is DotResult and (res as DotResult).ok and (res as DotResult).value is Node3D:
		if id.begins_with("wearable/"):
			# The file is in the cache now; each figure builds its own copy from there.
			((res as DotResult).value as Node3D).free()
			for peer: int in worn:
				var _w := wear(peer)
		else:
			_scenes[id] = (res as DotResult).value
	else:
		DotLog.debug(CHANNEL, "clip not fetched", {"id": id,
			"why": (res as DotResult).error.message if res is DotResult and not (res as DotResult).ok else "no scene"})


## The entry [param peer_id] has equipped under [param id], or empty.
func entry_of(peer_id: int, id: String) -> Dictionary:
	for e: Dictionary in loadouts.get(peer_id, []):
		if e["id"] == id:
			return e
	return {}


## Whether the clip for [param id] has arrived (always true for a built-in).
func has_clip(id: String) -> bool:
	return not id.contains("/") or _scenes.has(id)


func _play(peer_id: int, id: String, loop: bool, elapsed: float) -> void:
	var figure: Object = figure_fn.call(peer_id) if figure_fn.is_valid() else null
	if figure == null or not is_instance_valid(figure) or not figure.has_method(&"play_action"):
		return
	if bool(figure.call(&"play_action", StringName(id), loop, elapsed)):
		return
	var entry := entry_of(peer_id, id)
	if entry.is_empty() or String(entry.get("clip", "")) == "" or not figure.has_method(&"add_action_scene"):
		return
	if not _scenes.has(id):
		var _f := fetch_clip(entry)
		return
	var added: Variant = figure.call(&"add_action_scene", StringName(id), _scenes[id], String(entry["clip"]), bool(entry["loop"]))
	if added is DotResult and (added as DotResult).ok:
		figure.call(&"play_action", StringName(id), loop, elapsed)
	else:
		DotLog.debug(CHANNEL, "clip not playable on this figure", {"id": id,
			"why": (added as DotResult).error.message if added is DotResult else "?"})


## Hangs [param peer_id]'s wearables on their figure's skeleton once per figure; a figure not drawn
## yet or a library not yet read is tried again later. Items are fetched through [member content_fn].
## True when something is hung, or nothing is to be.
func wear(peer_id: int) -> bool:
	var ids: PackedStringArray = worn.get(peer_id, PackedStringArray())
	var figure: Object = figure_fn.call(peer_id) if figure_fn.is_valid() else null
	if figure == null or not is_instance_valid(figure) or not figure.has_method(&"skeleton"):
		return false
	var skeleton: Skeleton3D = figure.call(&"skeleton")
	if skeleton == null:
		return false
	if _worn_on.get(peer_id) == [figure.get_instance_id(), ids]:
		return true
	var wearer: RefCounted = _wearers.get(peer_id)
	if ids.is_empty():
		if wearer != null:
			wearer.call(&"clear")
		_worn_on[peer_id] = [figure.get_instance_id(), ids]
		return true
	var rows := DotGameAvatarActionSupport.wear_rows(ids, wearable_row_fn, _wear_tried, fetch_clip)
	if rows.size() < ids.size():
		return false
	if wearer == null:
		wearer = DotGameAvatarActionSupport.new_wearer()
		if wearer == null:
			return false
		_wearers[peer_id] = wearer
	var res: DotResult = wearer.call(&"apply", skeleton, rows)
	if not res.ok:
		DotLog.debug(CHANNEL, "wearables not hung", {"peer": peer_id, "why": res.error.message})
		return false
	_worn_on[peer_id] = [figure.get_instance_id(), ids]
	return true
