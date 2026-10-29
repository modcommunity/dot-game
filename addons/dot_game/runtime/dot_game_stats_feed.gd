class_name DotGameStatsFeed
extends RefCounted

## Opens and closes a dot-stats session for each seat, when a tracker exists. Duck-typed: dot-stats is never named.

const CHANNEL := "game.stats"
const SERVICE := &"dot_stats_tracker"

## The tracker to feed. Unset, it is looked up as the registry service [constant SERVICE] at each join.
var tracker: Object = null

## func(session) -> StringName. The key a player is filed under; set it to dot-user's scoped key. Default: "u" + userid, never an account id.
var player_key_fn: Callable = Callable()

## func(session) -> bool. Default: [member DotClientSession.local], which is what a bot is (no transport peer).
var bot_fn: Callable = Callable()

## func() -> String, the current map id for the session row.
var map_fn: Callable = Callable()

## userid -> player key, for every session this feed opened.
var _open: Dictionary = {}


## Listens to a roster's seated and unseated signals.
func follow(roster: DotGameRoster) -> void:
	roster.seated.connect(_on_seated)
	roster.unseated.connect(_on_unseated)


func unfollow(roster: DotGameRoster) -> void:
	if roster.seated.is_connected(_on_seated):
		roster.seated.disconnect(_on_seated)
	if roster.unseated.is_connected(_on_unseated):
		roster.unseated.disconnect(_on_unseated)


## Ends every session this feed opened, for an unload.
func end_all() -> void:
	var t := _tracker()
	for userid: int in _open.keys():
		if t != null:
			t.call("end", _open[userid])
	_open.clear()


func open_count() -> int:
	return _open.size()


func _tracker() -> Object:
	var t: Object = tracker if tracker != null else DotRegistry.get_service(SERVICE)
	if t == null or not is_instance_valid(t) or not t.has_method("begin") or not t.has_method("end"):
		return null
	return t


func _on_seated(session: DotClientSession) -> void:
	var t := _tracker()
	if t == null or _open.has(session.userid):
		return
	var key: StringName = player_key_fn.call(session) if player_key_fn.is_valid() else StringName("u%d" % session.userid)
	var bot: bool = bool(bot_fn.call(session)) if bot_fn.is_valid() else session.local
	var meta := {"is_bot": bot}
	if map_fn.is_valid():
		meta["map"] = str(map_fn.call())
	# No tmc_user: a seat is never linked to an account here, bot or not.
	t.call("begin", key, session.display_name, meta)
	_open[session.userid] = key
	DotLog.debug(CHANNEL, "stats session opened", {"userid": session.userid, "bot": bot})


func _on_unseated(session: DotClientSession) -> void:
	if not _open.has(session.userid):
		return
	var key: StringName = _open[session.userid]
	_open.erase(session.userid)
	var t := _tracker()
	if t != null:
		t.call("end", key)
