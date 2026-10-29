@tool
class_name DotGameRoster
extends RefCounted

## Who is actually in the game, as opposed to who is connected.
##
## [b]Every game in this family wrote this twice and one of them wrote it wrong for its
## whole life.[/b] A player joining is not one step: the bridge has to add them to the
## match AND register them as a replicated entity, chat has to learn their peer, the map
## sync has to start waiting on them, and a vote has to be told when they leave. Miss any
## one of those and the failure is silent and specific -- a player the server simulates
## alone, a map change that waits out five minutes for somebody who left, a tally that
## never shrinks.
##
## [codeblock]
## roster = DotGameRoster.new()
## roster.server = server
## roster.add_fn = func(s): return bridge.add_player(s.peer_id, s.userid, s.display_name)
## roster.remove_fn = func(s): bridge.remove_peer(s.peer_id)
## roster.follow(services)      # anything with add_peer / remove_peer / forget_voter / forget_player
## roster.follow(maps)
## roster.follow(vote)
## [/codeblock]
##
## [b]Keyed on the userid, never on the peer id.[/b] A peer id is reassigned the moment
## somebody reconnects, so everything hung off it -- a scoreboard row, a combat entity,
## damage attribution -- is handed to the next player to join. dot-server's userid is
## stable for the life of the session, and the peer id is what the connection-shaped
## things (chat, voice, a map sync) are keyed on because all three are about a socket.

const CHANNEL := "game.roster"

## The envelope kind a client sends when its loading cover goes up or comes down:
## [code]{"covered": bool}[/code], client to server, reliable. [DotGameClient] sends it on its
## gate's [code]opened[/code] and [code]closed[/code]; [method DotGameClient.report_cover] is
## the same send for a client that is not on it. [DotGameModule] handles it.
const COVER_KIND := &"game.cover"

## A seat became loading (joined, or a map change began) or stopped being (its cover lifted,
## it timed out, it left).
signal loading_changed(userid: int, loading: bool)

## A session joined the game (after [member add_fn]).
signal seated(session: DotClientSession)

## A session left the game (after [member remove_fn]).
signal unseated(session: DotClientSession)

## The server this roster reads sessions out of.
var server: DotServer = null

## How a userid becomes a session. Defaults to [member server].
##
## [b]Injectable so the one line that has been wrong twice can be asserted.[/b] The bug
## this file exists to prevent is reading the wrong FIELD off the spawn event, and a
## test that cannot substitute the lookup cannot tell the difference between "read the
## right field" and "found nothing either way" -- which is exactly what the two games
## that shipped the bug looked like from outside. A game with its own session source
## (a lobby that seats people who never connected) gets the same hook for free.
var session_fn: Callable = Callable()

## Puts a player into the game. Returns a [DotResult]; a failure leaves them out.
##
## Normally the bridge's `add_player`, because adding them to the match without
## registering them as a replicated entity gives the server a player nothing is ever
## sent about: the manager builds snapshots only for peers it knows, so it simulates
## them perfectly and alone.
var add_fn: Callable = Callable()

## Takes a player out again. The bridge's `remove_peer`, which also releases their
## entities, their input buffer and their acknowledgement record.
var remove_fn: Callable = Callable()

## userid -> true, for everybody currently in the game.
var joined: Dictionary = {}

## Total joins and leaves this roster has processed, for `describe`.
var joins: int = 0
var leaves: int = 0

## Subsystems told when somebody arrives or goes.
##
## Duck-typed, and the reason is the family rule: dot-map, dot-vote and a game's own
## services layer are all optional, and a script that so much as mentions an absent
## [code]class_name[/code] fails to parse and takes everything referencing it down.
var followers: Array[Object] = []

# --- Still loading -------------------------------------------------------------------

## Seconds a seat may stay loading before it counts as loaded anyway, with a warning. What
## releases a client that never says (one built before [constant COVER_KIND]), and the bound
## on how long anybody is unharmable: a client cannot extend it.
var load_timeout_sec: float = 30.0

## After a server-driven map change ([method mark_reloading]), seconds to wait for the
## client to say its cover went up again. A client that does not re-cover for this change
## (or predates the kind) counts as loaded once it passes, rather than sitting out the whole
## timeout in plain view.
var reload_grace_sec: float = 5.0

## [code]func() -> int[/code], milliseconds. [method Time.get_ticks_msec] when unset; the
## suite substitutes it so a timeout is checked without waiting thirty seconds.
var now_fn: Callable = Callable()

## Seats released by the timeout, for [method describe].
var load_timeouts: int = 0

## userid -> {"until": ms, "covered": bool, "grace_until": ms}, for every seat still loading.
var _loading: Dictionary = {}

## peer id -> userid, for everybody in [member joined]: the cover report arrives by peer.
var _peer_seat: Dictionary = {}

## userid -> ms of a cover report that came while the seat was loaded. A client that heard
## about a map change and covered before the server called [method mark_reloading] is not
## then released by the grace while it is still covered.
var _covered_at: Dictionary = {}

## userids with no client behind them (bots, a listen server's own player): never loading.
var _local: Dictionary = {}

## userids whose client said its cover lifted before the roster seated them.
var _shown_early: Dictionary = {}


## Adds a subsystem to be told about arrivals and departures.
##
## Whichever of [code]add_peer(peer)[/code], [code]remove_peer(peer)[/code] and
## [code]forget_voter(name)[/code] it has are called; the ones it does not have are not
## an error, because none of the three subsystems this exists for has all three.
func follow(subsystem: Object) -> void:
	if subsystem == null or followers.has(subsystem):
		return
	followers.append(subsystem)


func unfollow(subsystem: Object) -> void:
	followers.erase(subsystem)


## The handler for dot-server's [code]client_spawn[/code] event.
##
## [b]`client_spawn` carries `userid` and `name`. It does NOT carry `peer_id`.[/b] Two
## games in this family read `event.get_int("peer_id")` here, got 0 on every event, and
## looked up a session that does not exist -- so **nobody ever joined**, silently, for
## as long as those modules existed. A null session is a legitimate thing to find, so
## nothing errored, and a dedicated-server suite passes without noticing because it
## never connects a client.
##
## The lookup is in this file now so that it is written once and is right.
func on_client_spawn(event: DotEvent) -> void:
	var session := session_of(event.get_int("userid"))

	if session == null:
		return

	add(session)


## The session for a userid, through [member session_fn] or the server.
func session_of(userid: int) -> DotClientSession:
	if session_fn.is_valid():
		return session_fn.call(userid) as DotClientSession

	if server == null:
		return null

	return server.session_by_userid(userid)


## Puts a session into the game, if it is not already in.
func add(session: DotClientSession) -> DotResult:
	if session == null:
		return DotResult.fail(DotError.CODE_INVALID, "No session to add.")

	if joined.has(session.userid):
		return DotResult.success(false)

	if add_fn.is_valid():
		var added: Variant = add_fn.call(session)

		# A Callable that returns nothing is allowed -- a game whose add cannot fail
		# should not have to invent a result -- but one that returns a FAILURE is
		# obeyed, because the alternative is a roster that thinks somebody is playing
		# and a game that has never heard of them.
		if added is DotResult and not (added as DotResult).ok:
			DotLog.warn(CHANNEL, "could not add a player to the game", {
				"userid": session.userid,
				"error": str((added as DotResult).error),
			})
			return added

	joined[session.userid] = true
	_peer_seat[session.peer_id] = session.userid
	joins += 1

	# A bot, a listen server's own player or a test has no client to cover, so it is never
	# loading. A client that already said it was shown is not either.
	if session.local:
		_local[session.userid] = true
	elif not _shown_early.has(session.userid):
		_start_loading(session.userid, true)
	_shown_early.erase(session.userid)

	for follower in followers:
		if is_instance_valid(follower) and follower.has_method("add_peer"):
			follower.call("add_peer", session.peer_id)

	seated.emit(session)

	DotLog.info(CHANNEL, "player joined", {
		"userid": session.userid, "name": session.display_name
	})

	return DotResult.success(true)


## The handler for [signal DotServer.client_disconnected].
func on_client_disconnected(session: DotClientSession, _reason: String = "") -> void:
	# Somebody who left before they were seated said nothing that should outlive them.
	if session != null:
		_shown_early.erase(session.userid)
	remove(session)


## Takes a session out of the game, if it was in it.
func remove(session: DotClientSession) -> void:
	if session == null or not joined.has(session.userid):
		return

	if remove_fn.is_valid():
		remove_fn.call(session)

	joined.erase(session.userid)
	_peer_seat.erase(session.peer_id)
	_covered_at.erase(session.userid)
	_shown_early.erase(session.userid)
	_local.erase(session.userid)
	leaves += 1
	if _loading.erase(session.userid):
		loading_changed.emit(session.userid, false)

	for follower in followers:
		if not is_instance_valid(follower):
			continue

		if follower.has_method("remove_peer"):
			follower.call("remove_peer", session.peer_id)

		# A vote keys its tally on the voter's name rather than on a socket, and
		# `rtv_forgets_leavers` cannot do its job if nothing tells it they went.
		if follower.has_method("forget_voter"):
			follower.call("forget_voter", StringName(str(session.userid)))

		# Everything else keyed on the person — who they are frozen or noclipped by, where
		# a moderator would return them to. The same userid a vote uses, because it is the
		# id the live tools key a player on too.
		if follower.has_method("forget_player"):
			follower.call("forget_player", StringName(str(session.userid)))

	unseated.emit(session)

	DotLog.info(CHANNEL, "player left", {"userid": session.userid})


func has(userid: int) -> bool:
	return joined.has(userid)


func count() -> int:
	return joined.size()


## Empties the roster without telling anybody, for an unload.
##
## [b]Not the same as removing everyone.[/b] A module being torn down is not a room
## emptying: the subsystems being notified are going away in the same breath, and
## calling `remove_peer` on a freed one is the crash this whole addon's teardown order
## exists to avoid.
func clear() -> void:
	joined.clear()
	followers.clear()
	_loading.clear()
	_peer_seat.clear()
	_covered_at.clear()
	_shown_early.clear()
	_local.clear()


# --- Still loading -------------------------------------------------------------------

## Whether this seat's client is still behind its loading cover. False for anybody not in
## the game, a bot, and a seat whose timeout has passed.
func is_loading(userid: int) -> bool:
	return _loading.has(userid)


## [method is_loading], by peer id, which is what most server game code holds.
func is_peer_loading(peer_id: int) -> bool:
	return _loading.has(int(_peer_seat.get(peer_id, -1)))


## The seat a peer is in, or -1.
func seat_of_peer(peer_id: int) -> int:
	return int(_peer_seat.get(peer_id, -1))


## Every seat still loading, sorted.
func loading_seats() -> PackedInt32Array:
	var out := PackedInt32Array(_loading.keys())
	out.sort()
	return out


## A map change the server drives: every seat in the game is loading again until its client
## says its cover lifted, it does not re-cover within [member reload_grace_sec], or
## [member load_timeout_sec] passes. A seat already loading keeps its state.
func mark_reloading() -> void:
	var now := _now()
	for userid: int in joined.keys():
		if _loading.has(userid) or _local.has(userid):
			continue
		var covered_recently := _covered_at.has(userid) \
				and now - int(_covered_at[userid]) <= int(reload_grace_sec * 1000.0)
		_start_loading(userid, covered_recently)
	_covered_at.clear()


## A client's report, by peer: [param covered] true when its cover went up, false when it
## lifted.
##
## [b]A cover going up never makes a loaded seat loading.[/b] Only the server starts a
## loading state (a join, [method mark_reloading]); the client can confirm one or end it. A
## client allowed to start one could make itself unharmable whenever it liked.
func report_cover(peer_id: int, covered: bool) -> void:
	if not _peer_seat.has(peer_id):
		if not covered:
			# Seated later from the spawn event; remember it said shown.
			var session := _session_by_peer(peer_id)
			if session != null:
				_shown_early[session.userid] = true
		return
	var userid := int(_peer_seat[peer_id])
	if not covered:
		_finish_loading(userid, "shown")
		return
	if _loading.has(userid):
		_loading[userid]["covered"] = true
	else:
		_covered_at[userid] = _now()
		DotLog.debug(CHANNEL, "a cover report while loaded starts nothing", {"userid": userid})


## Releases seats whose grace or timeout has passed. [DotGameModule] calls it every frame.
func poll_loading() -> void:
	if _loading.is_empty():
		return
	var now := _now()
	for userid: int in _loading.keys():
		var entry: Dictionary = _loading[userid]
		if now >= int(entry["until"]):
			load_timeouts += 1
			DotLog.warn(CHANNEL, "a client never said its loading cover lifted; counting it as loaded", {
				"userid": userid, "after_sec": load_timeout_sec,
				"hint": "a client built before dot-game API 9, or one whose gate never opened",
			})
			_finish_loading(userid, "timeout")
		elif not bool(entry["covered"]) and now >= int(entry["grace_until"]):
			_finish_loading(userid, "did not re-cover")


func _start_loading(userid: int, covered: bool) -> void:
	var now := _now()
	_loading[userid] = {
		"until": now + int(load_timeout_sec * 1000.0),
		"covered": covered,
		"grace_until": now + int(reload_grace_sec * 1000.0),
	}
	DotLog.debug(CHANNEL, "seat loading", {"userid": userid, "covered": covered})
	loading_changed.emit(userid, true)


func _finish_loading(userid: int, why: String) -> void:
	if not _loading.erase(userid):
		return
	DotLog.debug(CHANNEL, "seat loaded", {"userid": userid, "why": why})
	loading_changed.emit(userid, false)


func _session_by_peer(peer_id: int) -> DotClientSession:
	if server == null:
		return null
	return server.session_of(peer_id)


func _now() -> int:
	if now_fn.is_valid():
		return int(now_fn.call())
	return Time.get_ticks_msec()


func describe() -> Dictionary:
	return {
		"playing": joined.size(),
		"joins": joins,
		"leaves": leaves,
		"followers": followers.size(),
		"loading": Array(loading_seats()),
		"load_timeouts": load_timeouts,
	}


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"playing    %d" % joined.size(),
		"joins      %d" % joins,
		"leaves     %d" % leaves,
		"followers  %d" % followers.size(),
		"loading    %s" % (", ".join(Array(loading_seats()).map(func(u: int) -> String: return str(u))) if not _loading.is_empty() else "nobody"),
	])
