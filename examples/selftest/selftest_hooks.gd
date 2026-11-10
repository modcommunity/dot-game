extends "selftest_stats.gd"

## The services-hook, page-guard, user-tier and server-thread sections of game_selftest.gd.

func _test_server_threads_reach_the_netcode() -> void:
	_section("sv_threads_net reaches DotNetConfig.snapshot_workers, and the game's own value wins")

	var sc := DotServerConfig.new()
	var c := DotNetConfig.new()
	_check(not DotGameNetcode.follow_server_threads(c, null), "no server config changes nothing")
	_check(DotGameNetcode.follow_server_threads(c, sc) and c.snapshot_workers == -1,
		"the default (switch on, automatic count) asks for -1")
	sc.threads_net = false
	DotGameNetcode.follow_server_threads(c, sc)
	_check(c.snapshot_workers == 0, "with the switch off it stays 0")
	sc.threads_net = true
	sc.worker_threads = 3
	_check(DotGameNetcode.follow_server_threads(c, sc) and c.snapshot_workers == 3,
		"switched on, the server's worker count is copied")
	sc.worker_threads = -1
	DotGameNetcode.follow_server_threads(c, sc)
	_check(c.snapshot_workers == -1, "a later cvar change is followed")
	sc.threads_net = false
	DotGameNetcode.follow_server_threads(c, sc)
	_check(c.snapshot_workers == 0, "switched off again, back to 0")

	var own := DotNetConfig.new()
	own.snapshot_workers = 2
	sc.threads_net = true
	sc.worker_threads = 5
	_check(not DotGameNetcode.follow_server_threads(own, sc) and own.snapshot_workers == 2,
		"a value the game set is kept")

	var nat := DotNetConfig.new()
	# Both default to true in dot-net; the game's own true would mask the cvar.
	nat.native = false
	nat.native_interest = false
	sc.net_native = false
	sc.net_native_interest = false
	DotGameNetcode.follow_server_threads(nat, sc)
	_check(not nat.native, "net_native off leaves the native core off")
	sc.net_native = true
	DotGameNetcode.follow_server_threads(nat, sc)
	_check(nat.native, "net_native on reaches DotNetConfig.native")
	sc.net_native = false
	DotGameNetcode.follow_server_threads(nat, sc)
	_check(not nat.native, "net_native off again turns it off")
	_check(not nat.native_interest, "net_native_interest off leaves native interest off")
	sc.net_native_interest = true
	DotGameNetcode.follow_server_threads(nat, sc)
	_check(nat.native_interest, "net_native_interest on reaches DotNetConfig.native_interest")
	sc.net_native_interest = false
	DotGameNetcode.follow_server_threads(nat, sc)
	_check(not nat.native_interest, "net_native_interest off again turns it off")
	var nat_own := DotNetConfig.new()
	nat_own.native = true
	DotGameNetcode.follow_server_threads(nat_own, sc)
	_check(nat_own.native, "the game's own native stays on with net_native off")

	# Through the module: the config the game returns, as the server's switch has it.
	_server.config.threads_net = true
	_server.config.worker_threads = 2
	var loaded: DotResult = await _load_module()
	if _check(loaded.ok, "the module loads", str(loaded.error)):
		var module := loaded.value as DotGameModule
		_check(module.net != null and module.net.config.snapshot_workers == 2,
			"the module wired it into the live netcode")
		_unload_module()
	_server.config.threads_net = false
	_server.config.worker_threads = -1
	_done()


## The hooks the first hand-written game converted needed, each of which it had worked
## round in a subclass.
func _test_services_hooks() -> void:
	_section("the services layer's hooks: no server, the backlog, the ear")

	# No server: offline play. This was refused, and it was the only line that needed one.
	var offline := TestHookServices.new()
	offline.name = "OfflineServices"
	add_child(offline)
	var ready_offline: DotResult = await offline.setup(null, _game, null)
	_check(
		ready_offline.ok, "it sets up with no server, for a game played offline",
		str(ready_offline.error) if not ready_offline.ok else ""
	)
	_check(
		offline.check_admission(_fake_session(9, 9, "Ada")).ok and offline.say(9, &"all", "hi").error != null,
		"and every seam past it answers \"no server\" rather than crashing"
	)
	offline.queue_free()

	# The backlog: at seating by default, and held for a game whose clients cannot receive
	# yet, which then sends it itself.
	var services := TestHookServices.new()
	services.name = "HookServices"
	add_child(services)
	var _r: DotResult = await services.setup(_server, _game, null)
	var link := TestHookServices.FakeLink.new()
	var chat := TestHookServices.FakeChat.new()
	add_child(link)
	add_child(chat)
	services.link = link
	services.chat = chat

	services.add_peer(9)
	_check(link.sent.size() == 2, "by default a seated peer is handed the backlog at once (%d lines)" % link.sent.size())

	link.sent.clear()
	services.receive = false
	services.add_peer(10)
	_check(link.sent.is_empty(), "a game whose peer cannot receive yet holds it (%d lines)" % link.sent.size())
	if services.has_method("send_backlog"):
		services.call("send_backlog", 10)
	_check(
		link.sent.size() == 2 and int(link.sent[0][0]) == 10,
		"and sends it itself when the peer is ready, to that peer"
	)

	# The ear. Wired into both routers when they exist; here, the default's answer.
	_check(
		services.has_method("_can_hear") and bool(services.call("_can_hear", 1, 2, Vector3.ZERO, Vector3(999, 0, 0))),
		"and _can_hear defaults to the radius being the whole answer"
	)

	services.chat = null
	services.link = null
	chat.queue_free()
	link.queue_free()
	services.queue_free()
	_done()


class GuardLink extends RefCounted:
	var up: bool = false
	func is_connected_to_server() -> bool:
		return up


## The player's cfg tier: on solo and for a listen host, off for a dedicated server, a guest, or an opt-out.
func _test_client_user_tier() -> void:
	_section("the user cfg tier: solo and listen host only")
	var host := Node.new()
	add_child(host)
	var solo := DotGameClient.new()
	solo.use_gate = false
	solo.force_offline = true
	host.add_child(solo)
	_check(solo.user_tier_on and DotAddonConfig.user_tier_enabled, "solo turns the tier on")
	_check(solo.describe()["user_tier"], "describe reports it")

	var guest := DotGameClient.new()
	guest.use_gate = false
	guest.link = GuardLink.new()
	host.add_child(guest)
	_check(not guest.offline and not guest.user_tier_on and not DotAddonConfig.user_tier_enabled,
		"joined to someone else's server turns it off")

	var listen := DotGameClient.new()
	listen.use_gate = false
	listen.link = GuardLink.new()
	listen.listen_host_fn = func() -> bool: return true
	host.add_child(listen)
	_check(listen.user_tier_on and DotAddonConfig.user_tier_enabled, "a listen host turns it on")

	var out := DotGameClient.new()
	out.use_gate = false
	out.force_offline = true
	out.user_cfg = false
	host.add_child(out)
	_check(not out.user_tier_on and not DotAddonConfig.user_tier_enabled, "user_cfg = false opts out")

	_check(not DotGameClient.user_tier_allowed(true, true, true, true), "a dedicated server never has it")
	_check(DotGameClient.locked_content_wanted(true, false, false, false)
			and not DotGameClient.locked_content_wanted(true, true, false, false)
			and not DotGameClient.locked_content_wanted(true, false, true, false)
			and DotGameClient.locked_content_wanted(true, true, true, true)
			and not DotGameClient.locked_content_wanted(false, false, false, true), "offline or headless skips the lock unless opted in")
	_check(not DotGameClient.offline_wanted(false, true, false, false)
			and DotGameClient.offline_wanted(false, true, true, false)
			and not DotGameClient.offline_wanted(false, true, true, true)
			and DotGameClient.offline_wanted(true, true, false, true)
			and DotGameClient.offline_wanted(false, false, true, true), "--offline drops a shell link, not a local one; forced or no link is offline")
	_check(DotGameClient.user_tier_allowed(true, false, true, false)
			and not DotGameClient.user_tier_allowed(true, false, false, false)
			and not DotGameClient.user_tier_allowed(false, true, false, false), "the rule table")
	_check(not out.open_user_cfg(), "and refuses without the tier")
	var solo2 := DotGameClient.new()
	solo2.use_gate = false
	solo2.force_offline = true
	host.add_child(solo2)
	_check(DotAddonConfig.user_tier_enabled, "a second solo client has the tier on")
	host.remove_child(solo2)
	_check(not DotAddonConfig.user_tier_enabled and not DotProfileSet.user_tier_enabled, "leaving the tree clears the process-wide tier")
	solo2.free()
	DotAddonConfig.set_user_tier(false)
	host.queue_free()
	_done()


## The browser guard: the leave-site prompt follows the live game, the keyboard lock listener is
## installed once, and a desktop or headless client does nothing at all.
func _test_client_page_guard() -> void:
	_section("the page guard: leave-site prompt follows the live game, installed once, silent off the web")

	var host := Node.new()
	add_child(host)
	var plain := DotGameClient.new()
	plain.use_gate = false
	plain.link = GuardLink.new()
	host.add_child(plain)
	plain._process(0.0)
	_check(not plain.describe()["leave_guard_installed"] and not plain.describe()["leave_guard"],
		"off the web nothing is installed or armed")

	var sent: Array = []
	var link := GuardLink.new()
	var client := DotGameClient.new()
	client.use_gate = false
	client.link = link
	client.web_guard_fn = func(code: String) -> void: sent.append(code)
	host.add_child(client)
	_check(sent.size() == 1 and sent[0] == "install", "the guard is installed once")
	client._process(0.0)
	_check(sent.size() == 1 and not client.describe()["leave_guard"], "a disconnected link does not arm it")
	link.up = true
	client._process(0.0)
	_check(sent.size() == 2 and "arm" == sent[1] and client.describe()["leave_guard"],
		"a connected link arms the prompt")
	client._process(0.0)
	_check(sent.size() == 2, "and a steady state sends nothing")
	client.clear_leave_guard()
	_check(sent.size() == 3 and "disarm" == sent[2] and not client.describe()["leave_guard"],
		"a deliberate navigation can clear it")
	client._process(0.0)
	link.up = false
	client._process(0.0)
	client._process(0.0)
	_check(not client.describe()["leave_guard"] and sent.size() == 5, "a dropped link disarms it")
	link.up = true
	client._process(0.0)
	client.queue_free()
	await get_tree().process_frame
	_check("disarm" == sent[sent.size() - 1], "leaving the tree disarms it")

	var offline := DotGameClient.new()
	offline.use_gate = false
	offline.link = GuardLink.new()
	offline.link.up = true
	offline.force_offline = true
	var off_sent: Array = []
	offline.web_guard_fn = func(code: String) -> void: off_sent.append(code)
	host.add_child(offline)
	offline._process(0.0)
	_check(off_sent.size() == 2 and "arm" == off_sent[1] and not offline.is_in_live_game(),
		"a solo game (offline) arms the prompt too")
	host.queue_free()
	await get_tree().process_frame
	_done()
