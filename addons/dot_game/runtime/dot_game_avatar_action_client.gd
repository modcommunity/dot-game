class_name DotGameAvatarActionClient
extends Node

## The client half of avatar actions: a key press plays on the local figure at once and is sent
## to the server; what the server relays plays on that peer's figure, started at the right
## moment by its tick. Built by [method DotGameClient.add_avatar_actions].
##
## The server also tells it every player's equipped loadout ([DotGameAvatarLoadoutMessage]); an
## uploaded clip in one is fetched once through [member content_fn] and handed to the figure
## (`add_action_scene`, dot-player-char) the first time that player plays it.

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

## Uploaded clip scenes kept, at most this many; a hostile server cannot make it fetch thousands.
const MAX_SCENES := 64

## peer id -> the entries the server said they have equipped.
var loadouts: Dictionary = {}

var _online := false
var _scenes: Dictionary = {}
var _fetching: Dictionary = {}


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


func _exit_tree() -> void:
	for scene: Variant in _scenes.values():
		if scene is Node and is_instance_valid(scene):
			(scene as Node).free()
	_scenes.clear()


func _process(_delta: float) -> void:
	if input != null and blocked_fn.is_valid():
		input.set(&"enabled", not bool(blocked_fn.call()))


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
	if m.entries.is_empty():
		var _e := loadouts.erase(m.actor)
		return
	loadouts[m.actor] = m.entries
	for e: Dictionary in m.entries:
		if String(e.get("clip", "")) != "":
			fetch_clip(e)


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
	if res is DotResult and (res as DotResult).ok and (res as DotResult).value is Node3D:
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
