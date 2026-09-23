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
	joins += 1

	for follower in followers:
		if is_instance_valid(follower) and follower.has_method("add_peer"):
			follower.call("add_peer", session.peer_id)

	DotLog.info(CHANNEL, "player joined", {
		"userid": session.userid, "name": session.display_name
	})

	return DotResult.success(true)


## The handler for [signal DotServer.client_disconnected].
func on_client_disconnected(session: DotClientSession, _reason: String = "") -> void:
	remove(session)


## Takes a session out of the game, if it was in it.
func remove(session: DotClientSession) -> void:
	if session == null or not joined.has(session.userid):
		return

	if remove_fn.is_valid():
		remove_fn.call(session)

	joined.erase(session.userid)
	leaves += 1

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


func describe() -> Dictionary:
	return {
		"playing": joined.size(),
		"joins": joins,
		"leaves": leaves,
		"followers": followers.size(),
	}


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"playing    %d" % joined.size(),
		"joins      %d" % joins,
		"leaves     %d" % leaves,
		"followers  %d" % followers.size(),
	])
