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


func _test_stats_report() -> void:
	_section("stats_report is one switch for any game, and an old name follows it")

	var calls: Array = []
	var cv := _module.bind_stats_report(
		func(on: bool) -> DotResult:
			calls.append(on)
			return DotResult.success(on),
		PackedStringArray(["old_stats_report"]))
	var old: DotConVar = _module.console.find_cvar("old_stats_report")
	_check(cv != null and cv.get_string() == "0", "stats_report is off by default")
	_check(old != null and calls.is_empty(), "the old name is registered and nothing applies at boot")
	var _r1 := cv.set_value("1")
	_check(calls == [true] and old.get_string() == "1", "turning it on applies once and moves the old name", str(calls))
	var _r2 := old.set_value("0")
	_check(cv.get_string() == "0" and calls == [true, false], "the old name turns the new one off, once", str(calls))
	var _r3 := cv.set_value("0")
	_check(calls.size() == 2, "setting the value it already has applies nothing")
	var res := DotGameStatsReport.apply_default(_module, true)
	_check(not res.ok, "the default apply refuses, not crashes, with no real tracker")
	_done()


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


class _FakeValues extends RefCounted:
	var v: Dictionary = {}
	func has(id: StringName) -> bool: return v.has(id)
	func get_value(id: StringName, fallback: float = 0.0) -> float: return float(v.get(id, fallback))
	func duplicate_values() -> _FakeValues:
		var c := _FakeValues.new()
		c.v = v.duplicate()
		return c
	func merge_from(other: _FakeValues, _schema: Object) -> void:
		for id in other.v:
			v[id] = float(v.get(id, 0.0)) + float(other.v[id])


class _FakeDef extends RefCounted:
	var id: StringName = &""
	var display_name := ""
	var column := "default"
	var visible := true
	var derived = null
	func format_value(x: float) -> String: return "%d" % x


class _FakeSchema extends RefCounted:
	var defs: Dictionary = {}
	func ids() -> PackedStringArray: return PackedStringArray(defs.keys())
	func find(id: StringName) -> _FakeDef: return defs.get(id)


class _FakeStore extends RefCounted:
	var lifetime: Dictionary = {}
	func values_for(key: StringName) -> DotResult:
		var out := _FakeValues.new()
		out.v = lifetime.get(key, {}).duplicate()
		return DotResult.success(out)


class _FakeBoardTracker extends RefCounted:
	var schema := _FakeSchema.new()
	var store := _FakeStore.new()
	var sessions: Dictionary = {}
	func begin(id: StringName, _who: String = "", _meta: Dictionary = {}) -> void: sessions[id] = _FakeValues.new()
	func end(id: StringName) -> void: sessions.erase(id)
	func has_player(id: StringName) -> bool: return sessions.has(id)
	func session_values(id: StringName) -> _FakeValues: return sessions[id]


func _test_stats_board() -> void:
	_section("the Tab board carries each stat this game and for life, and the list of stats")
	var feed := _module.stats_feed
	var board := _module.stats_board
	_check(board != null, "the module builds a stats board")
	var t := _FakeBoardTracker.new()
	for spec in [["kills", "Kills", "default", true], ["secret", "Secret", "hidden", true], ["off", "Off", "default", false]]:
		var d := _FakeDef.new()
		d.id = StringName(spec[0])
		d.display_name = spec[1]
		d.column = spec[2]
		d.visible = spec[3]
		t.schema.defs[d.id] = d
	feed.tracker = t
	var cy := _fake_session(7, 81, "Cy")
	t.store.lifetime[feed.key_for(cy)] = {&"kills": 40.0}
	_module.roster.add(cy)
	await get_tree().process_frame
	t.sessions[feed.key_for(cy)].v[&"kills"] = 3.0
	var f := board.fields(cy)
	_check(f.get("st_kills") == "3" and f.get("lt_kills") == "43", "this game's 3 and the lifetime 40 + 3", str(f))
	_check(not f.has("st_secret") and not f.has("st_off"), "a hidden or invisible stat is not sent", str(f))
	var cols: Array = board.extra().get("stat_columns", [])
	_check(cols.size() == 1 and cols[0]["key"] == "kills" and cols[0]["title"] == "Kills", "the list names only the shown stats", str(cols))
	_module.roster.remove(cy)
	feed.tracker = null
	_check(board.fields(cy).is_empty() and board.extra().is_empty(), "with no tracker nothing is sent")
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
	var late := _who(12, "backbone:fay")
	var first := boot1.key_for(late)
	late.data["platform"] = held
	_check(boot1.key_for(late) == first, "a profile key attached after the first ask does not change the key by itself")
	_check(boot1.upgrade(late) and boot1.key_for(late) == &"ProfileKey_abcdefghijkl", "upgrade() moves the seat to the profile key, deliberately")
	_check(not boot1.upgrade(late), "and only once")
	var lt := _FakeTracker.new()
	boot1.tracker = lt
	var gina := _who(13, "backbone:gina")
	boot1._on_seated(gina)
	gina.data["platform"] = held
	boot1.upgrade(gina)
	_check(lt.ended.size() == 1 and lt.begun.size() == 2 and lt.begun[1][0] == &"ProfileKey_abcdefghijkl", "an open session is ended under the old key and begun under the new", str(lt.begun))
	boot1.tracker = null
	boot1.forget(12)
	boot1.forget(13)
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
