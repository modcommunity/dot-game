class_name DotGameClientDescribe
extends RefCounted

## The state dump of [DotGameClient].


static func describe(c: DotGameClient) -> Dictionary:
	return {
		"host": str(c.host.name) if c.host != null else "",
		"offline": c.offline,
		"user_tier": c.user_tier_on,
		"link": c.link != null,
		"gate": c.gate.describe() if c.gate != null and is_instance_valid(c.gate) else {},
		"set_up": c._set_up,
		"settings": c.settings != null,
		"menu": c.menu != null,
		"menu_open": c.is_menu_open(),
		"console": c.console != null,
		"chat": c.chat != null,
		"typing": c._chat_typing(),
		"board": c.board != null,
		"maps": c.maps != null,
		"scoreboard_action": String(c.scoreboard_action),
		"look_mute": c.look_mute != null,
		"look_conflicts": c.look_conflicts.size(),
		"input_blocked": c.is_input_blocked(),
		"capture_pointer": c.capture_pointer,
		"leave_guard": c._guard_armed,
		"leave_guard_installed": c._guard_installed,
	}


static func lines(c: DotGameClient) -> PackedStringArray:
	var d := describe(c)
	var out := PackedStringArray()
	out.append("client %s, %s" % [d["host"], "offline" if c.offline else "connected"])
	out.append("  cover %s" % ("lifted" if c.is_shown() else "up"))
	out.append("  settings %s, menu %s%s, console %s" % [
		"yes" if d["settings"] else "no", "yes" if d["menu"] else "no",
		" (open)" if d["menu_open"] else "", "yes" if d["console"] else "no"])
	out.append("  chat %s%s, board %s, maps %s" % [
		"yes" if d["chat"] else "no", " (typing)" if d["typing"] else "",
		"yes" if d["board"] else "no", "yes" if d["maps"] else "no"])
	out.append("  input %s" % ("blocked" if d["input_blocked"] else "live"))
	out.append("  leave-site prompt %s" % ("armed" if d["leave_guard"] else "off"))
	return out
