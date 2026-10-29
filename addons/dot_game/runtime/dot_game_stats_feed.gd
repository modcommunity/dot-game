class_name DotGameStatsFeed
extends RefCounted

## Opens and closes a dot-stats session for each seat, when a tracker exists. Duck-typed: dot-stats is never named.

const CHANNEL := "game.stats"
const SERVICE := &"dot_stats_tracker"
## dot-user's scope, by path: dot-user is not a dependency. Without it a key falls back to the seat's.
const SCOPE_SCRIPT := "res://addons/dot_user/core/dot_user_scope.gd"
## The scope name the local derivation uses; the key file, not the name, is what makes it per-server.
const SCOPE_NAME := "dot_game.stats"
## The shape of a key the backbone issued (dot-auth's `scoped_key` claim), as dot-user checks it.
const ISSUED_KEY_RE := "^[A-Za-z0-9_-]{8,64}$"

## The tracker to feed. Unset, it is looked up as the registry service [constant SERVICE] at each join.
var tracker: Object = null

## func(session) -> StringName. Replaces [method key_for] entirely, for a game with its own scheme.
var player_key_fn: Callable = Callable()

## The per-server MAC key behind [method key_for]'s own derivation, made on first use. Losing it renames every player.
var scope_key_file: String = "user://stats_scope.key"

## Whether seating opens a tracker session. A game that drives its own tracker sets false and only asks [method key_for].
var open_sessions: bool = true

## func(session) -> bool. Default: [member DotClientSession.local], which is what a bot is (no transport peer).
var bot_fn: Callable = Callable()

## func() -> String, the current map id for the session row.
var map_fn: Callable = Callable()

## userid -> player key, for every session this feed opened.
var _open: Dictionary = {}

## userid -> key, for every seated session [method key_for] was asked about.
var _keys: Dictionary = {}

var _scope: Object = null
var _issued_re: RegEx = RegEx.create_from_string(ISSUED_KEY_RE)


## The key [param session]'s stats are filed under: stable across restarts, per server, never an account id.
## In order: [member player_key_fn], dot-platform's profile key, the backbone's issued key, a keyed
## derivation of the uid (guests too); a bot or a session with no identity gets "u" + userid.
func key_for(session: DotClientSession) -> StringName:
	if player_key_fn.is_valid():
		return StringName(str(player_key_fn.call(session)))
	if _keys.has(session.userid):
		return _keys[session.userid]
	var key := _resolve(session)
	for other: int in _keys:
		if _keys[other] == key:
			# Two guests on one device share a uid, and so does a reconnect before the old seat
			# times out; the second seat gets its own key rather than ending the first one's row.
			key = StringName("%s-%d" % [key, session.userid])
			break
	_keys[session.userid] = key
	return key


## Drops [param userid]'s remembered key when it leaves; a game without a roster calls this itself.
func forget(userid: int) -> void:
	_keys.erase(userid)


func _resolve(session: DotClientSession) -> StringName:
	var seat := StringName("u%d" % session.userid)
	if session.local or session.uid() == "":
		return seat
	var platform: Variant = session.data.get("platform")
	if platform is Object and (platform as Object).has_method(&"key"):
		var profile_key := str((platform as Object).call(&"key"))
		if profile_key != "":
			return StringName(profile_key)
	var claims: Variant = session.identity.get("claims") if session.identity != null else null
	if claims is Dictionary and _issued_re.search(str((claims as Dictionary).get("scoped_key", ""))) != null:
		return StringName(str(claims["scoped_key"]))
	var scope := _scope_or_null()
	if scope == null:
		return seat
	var derived: DotResult = scope.call(&"derive", session.uid())
	return StringName(str(derived.value)) if derived.ok else seat


## Loads this server's scope key, or makes and keeps one; null without dot-user or a usable key.
func _scope_or_null() -> Object:
	if _scope != null or not ResourceLoader.exists(SCOPE_SCRIPT):
		return _scope
	var script: GDScript = load(SCOPE_SCRIPT)
	if FileAccess.file_exists(scope_key_file):
		var read := DotPaths.read_text(scope_key_file)
		var made: DotResult = script.call(&"from_secret_key", SCOPE_NAME, String(read.value).strip_edges()) if read.ok else read
		if not made.ok:
			# Never replaced: a new key would rename every player on this server.
			DotLog.error(CHANNEL, "stats scope key unreadable; keys fall back to seats", {"file": scope_key_file, "why": made.error.message})
			return null
		_scope = made.value
		return _scope
	var fresh: Object = script.call(&"generated", SCOPE_NAME)
	var written := DotPaths.write_text(scope_key_file, str(fresh.call(&"export_secret_key")))
	if not written.ok:
		DotLog.error(CHANNEL, "could not keep a stats scope key; keys fall back to seats", {"file": scope_key_file, "why": written.error.message})
		return null
	DotLog.info(CHANNEL, "generated a stats scope key; back it up, losing it renames every player", {"file": scope_key_file})
	_scope = fresh
	return _scope


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
	_keys.clear()


func open_count() -> int:
	return _open.size()


func _tracker() -> Object:
	var t: Object = tracker if tracker != null else DotRegistry.get_service(SERVICE)
	if t == null or not is_instance_valid(t) or not t.has_method("begin") or not t.has_method("end"):
		return null
	return t


func _on_seated(session: DotClientSession) -> void:
	var t := _tracker() if open_sessions else null
	if t == null or _open.has(session.userid):
		return
	var key := key_for(session)
	var bot: bool = bool(bot_fn.call(session)) if bot_fn.is_valid() else session.local
	var meta := {"is_bot": bot}
	if map_fn.is_valid():
		meta["map"] = str(map_fn.call())
	# No tmc_user: a seat is never linked to an account here, bot or not.
	t.call("begin", key, session.display_name, meta)
	_open[session.userid] = key
	DotLog.debug(CHANNEL, "stats session opened", {"userid": session.userid, "bot": bot})


func _on_unseated(session: DotClientSession) -> void:
	forget(session.userid)
	if not _open.has(session.userid):
		return
	var key: StringName = _open[session.userid]
	_open.erase(session.userid)
	var t := _tracker()
	if t != null:
		t.call("end", key)
