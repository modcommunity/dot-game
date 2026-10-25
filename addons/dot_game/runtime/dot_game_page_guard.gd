class_name DotGamePageGuard
extends RefCounted

## The browser's leave-site prompt for [DotGameClient]: armed while a game is live, so Ctrl+W does not lose a round silently.

const CHANNEL := "game.client"
const ARM_JS := "window.__dotTabGuard.armed = true;"
const DISARM_JS := "window.__dotTabGuard.armed = false;"

# Runs once per page (`window.__dotTabGuard` is the flag). The keyboard lock lives here because
# only some games build the menu's applier; the beforeunload prompt covers Ctrl+W/T/N, which a
# page cannot cancel. A function, so a global eval leaves no `g` on the game's window.
const INSTALL_JS := """
(function () {
if (!window.__dotTabGuard) {
	var g = window.__dotTabGuard = { armed: false };
	window.addEventListener('beforeunload', function (e) {
		if (!g.armed) { return; }
		e.preventDefault();
		e.returnValue = '';
		return '';
	});
	document.addEventListener('fullscreenchange', function () {
		var k = navigator.keyboard;
		if (!k) { return; }
		try {
			if (document.fullscreenElement) {
				if (k.lock) { var p = k.lock(); if (p && p.catch) { p.catch(function () {}); } }
			} else if (k.unlock) { k.unlock(); }
		} catch (err) {}
	});
}
})();
"""


static func is_web(c: DotGameClient) -> bool:
	return c.web_eval_fn.is_valid() or DotPlatform.is_web()


static func run(c: DotGameClient, code: String) -> void:
	if c.web_eval_fn.is_valid():
		c.web_eval_fn.call(code)
	else:
		DotWeb.eval(code, true)


static func install(c: DotGameClient) -> void:
	if c._guard_installed or not is_web(c):
		return
	c._guard_installed = true
	run(c, INSTALL_JS)


## Arms the prompt while online with a live link, or offline (a solo round lost to Ctrl+W is lost all the same).
static func refresh(c: DotGameClient) -> void:
	if not c._guard_installed:
		return
	var want := c.offline or c.is_in_live_game()
	if want == c._guard_armed:
		return
	c._guard_armed = want
	run(c, ARM_JS if want else DISARM_JS)
	DotLog.debug(CHANNEL, "leave-site prompt armed" if want else "leave-site prompt disarmed")


static func clear(c: DotGameClient, log := true) -> void:
	if c._guard_installed and c._guard_armed:
		c._guard_armed = false
		run(c, DISARM_JS)
		if log:
			DotLog.debug(CHANNEL, "leave-site prompt cleared for a deliberate navigation")
