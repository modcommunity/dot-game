extends "selftest_slide.gd"

## The stats feed and the key a player's numbers are filed under.

const KEY_A := "user://selftest_stats_a.key"
const KEY_B := "user://selftest_stats_b.key"


class _FakeIdentity extends RefCounted:
	var uid := ""
	var is_guest := false
	var claims: Dictionary = {}
	func _init(p_uid: String, guest: bool = false, p_claims: Dictionary = {}) -> void:
		uid = p_uid
		is_guest = guest
		claims = p_claims


class _FakePlatformPlayer extends RefCounted:
	var k := ""
	func key() -> String: return k


func _fake_session(peer_id: int, userid: int, who: String) -> DotClientSession:
	var session := DotClientSession.new()
	session.peer_id = peer_id
	session.userid = userid
	session.display_name = who
	return session


func _who(userid: int, uid: String, guest: bool = false, claims: Dictionary = {}) -> DotClientSession:
	var s := _fake_session(userid + 100, userid, uid)
	s.identity = _FakeIdentity.new(uid, guest, claims)
	return s


func _feed_on(file: String) -> DotGameStatsFeed:
	var f := DotGameStatsFeed.new()
	f.scope_key_file = file
	return f


class _FakeTracker extends RefCounted:
	var begun: Array = []
	var ended: Array = []
	func begin(id: StringName, who: String = "", meta: Dictionary = {}) -> void: begun.append([id, who, meta])
	func end(id: StringName) -> void: ended.append(id)


func _test_stats_feed() -> void:
	_section("a tracker, when there is one, gets a session per seat and bots flagged")

	var roster := _module.roster
	var feed := _module.stats_feed
	_check(feed != null, "the module builds a stats feed")
	var t := _FakeTracker.new()
	feed.tracker = t

	var cy := _fake_session(7, 71, "Cy")
	var rob := _fake_session(0, 72, "Rob")
	rob.local = true
	roster.add(cy)
	roster.add(rob)
	_check(t.begun.size() == 2, "each seat begins a session", str(t.begun))
	_check(t.begun[0][1] == "Cy" and t.begun[0][2]["is_bot"] == false, "a player is not flagged a bot")
	_check(t.begun[1][2]["is_bot"] == true, "a bot is flagged")
	_check(not t.begun[1][2].has("tmc_user"), "no account claim rides along")
	_check(str(t.begun[0][0]).begins_with("u"), "the key is not an account id", str(t.begun[0][0]))

	roster.remove(cy)
	_check(t.ended.size() == 1 and t.ended[0] == t.begun[0][0], "leaving ends that session")
	feed.end_all()
	_check(t.ended.size() == 2 and feed.open_count() == 0, "an unload ends the rest")

	feed.tracker = null
	var before := t.begun.size()
	roster.remove(rob)
	var dee := _fake_session(8, 73, "Dee")
	roster.add(dee)
	_check(t.begun.size() == before and feed.open_count() == 0, "with no tracker nothing is reported and nothing errors")
	roster.remove(dee)
	_done()


func _test_stats_keys() -> void:
	_section("stats keys: stable across a restart, scoped per server, never an account id")
	for f in [KEY_A, KEY_B]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	if not ResourceLoader.exists(DotGameStatsFeed.SCOPE_SCRIPT):
		_check(_feed_on(KEY_A).key_for(_who(1, "backbone:ann")) == &"u1", "without dot-user a key is the seat's")
		_done()
		return
	var boot1 := _feed_on(KEY_A)
	var ann := String(boot1.key_for(_who(1, "backbone:ann")))
	var bob := String(boot1.key_for(_who(2, "backbone:bob")))
	var guest := String(boot1.key_for(_who(3, "guest:dev-1", true)))
	_check(ann.length() == 22 and not ann.begins_with("backbone:") and not ann.contains("ann"), "a member's key is a scoped pseudonym", ann)
	_check(ann != bob, "two identities never share a key")
	_check(guest.length() == 22 and guest != ann and guest != bob, "a guest gets a scoped key of their own", guest)
	_check(FileAccess.file_exists(KEY_A), "the scope key is kept for the next boot")

	var boot2 := _feed_on(KEY_A)
	_check(String(boot2.key_for(_who(1, "backbone:bob"))) == bob, "after a restart the same identity on a reused seat id gets its old key")
	_check(String(boot2.key_for(_who(9, "backbone:ann"))) == ann, "and a reconnect on a new seat id does too")
	_check(String(boot2.key_for(_who(4, "guest:dev-1", true))) == guest, "a guest's device keeps its key across the restart")

	var other := _feed_on(KEY_B)
	_check(String(other.key_for(_who(1, "backbone:ann"))) != ann, "another server derives another key for the same member")
	_check(String(other.key_for(_who(3, "guest:dev-1", true))) != guest, "and for the same guest")

	var issued := _who(5, "backbone:cy", false, {"scoped_key": "SiteIssuedKey_0123456789"})
	_check(boot1.key_for(issued) == &"SiteIssuedKey_0123456789", "a key the backbone issued wins over a derived one")
	var plat := _who(6, "backbone:dee")
	var held := _FakePlatformPlayer.new()
	held.k = "ProfileKey_abcdefghijkl"
	plat.data["platform"] = held
	_check(boot1.key_for(plat) == &"ProfileKey_abcdefghijkl", "dot-platform's profile key wins over both")
	var bot := _who(7, "")
	bot.local = true
	_check(boot1.key_for(bot) == &"u7", "a bot keeps its seat's key")
	_check(String(boot1.key_for(_who(8, "guest:dev-1", true))) == guest + "-8", "a second seat on one uid at once does not merge into the first")

	var t := _FakeTracker.new()
	var roster := _module.roster
	var feed := _module.stats_feed
	feed.tracker = t
	feed.scope_key_file = KEY_A
	var eve := _who(11, "backbone:ann")
	roster.add(eve)
	_check(t.begun.size() == 1 and String(t.begun[0][0]) == ann, "a seat opens its session under the stable key", str(t.begun))
	roster.remove(eve)
	feed.open_sessions = false
	roster.add(eve)
	_check(t.begun.size() == 1 and feed.key_for(eve) == StringName(ann), "open_sessions off: no session, the key still answers")
	roster.remove(eve)
	feed.open_sessions = true
	feed.tracker = null
	for f in [KEY_A, KEY_B]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	_done()
