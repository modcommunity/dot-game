class_name DotGamePageGuard
extends RefCounted

## The browser's leave-site prompt for [DotGameClient]: armed while a game is live, so Ctrl+W does not lose a round silently.

const CHANNEL := "game.client"
const INSTALL := "install"
const ARM := "arm"
const DISARM := "disarm"

static func is_web(c: DotGameClient) -> bool:
	return c.web_guard_fn.is_valid() or DotPlatform.is_web()


## The listeners live in dot-core's web/dot_web.js, loaded by the shell page; only the flag is set from here.
static func run(c: DotGameClient, command: String) -> void:
	if c.web_guard_fn.is_valid():
		c.web_guard_fn.call(command)
	elif command == ARM or command == DISARM:
		DotWeb.set_tab_guard_armed(command == ARM)
	elif not DotWeb.has_tab_guard():
		DotLog.warn(CHANNEL, "the page does not load dot_web.js; no leave-site prompt or keyboard lock")


static func install(c: DotGameClient) -> void:
	if c._guard_installed or not is_web(c):
		return
	c._guard_installed = true
	run(c, INSTALL)


## Arms the prompt while online with a live link, or offline (a solo round lost to Ctrl+W is lost all the same).
static func refresh(c: DotGameClient) -> void:
	if not c._guard_installed:
		return
	var want := c.offline or c.is_in_live_game()
	if want == c._guard_armed:
		return
	c._guard_armed = want
	run(c, ARM if want else DISARM)
	DotLog.debug(CHANNEL, "leave-site prompt armed" if want else "leave-site prompt disarmed")


static func clear(c: DotGameClient, log := true) -> void:
	if c._guard_installed and c._guard_armed:
		c._guard_armed = false
		run(c, DISARM)
		if log:
			DotLog.debug(CHANNEL, "leave-site prompt cleared for a deliberate navigation")
