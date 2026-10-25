class_name DotGameClientLook
extends RefCounted

## The look-to-gag keys of [DotGameClient]: which keys, the dot-voice node, and the target under the crosshair.

const CHANNEL := "game.client"


static func voice(c: DotGameClient) -> Node:
	if c.look_voice != null:
		return c.look_voice
	return c.chat.get(&"voice") as Node if c.chat != null and c.chat.get(&"voice") is Node else null


static func chat_of(c: DotGameClient) -> Node:
	return c.look_chat if c.look_chat != null else c.chat


static func wanted(c: DotGameClient) -> bool:
	return c.use_look_mute and voice(c) != null


## Rows in the game's key table (so the Controls page and help list them), unless it has its own.
static func add_rows(c: DotGameClient) -> void:
	if not wanted(c) or not ("bindings" in c.settings):
		return
	var table: Object = c.settings.get(&"bindings")
	if table == null:
		if not ResourceLoader.exists(DotGameClient.BINDINGS_SCRIPT):
			return
		var script: Variant = load(DotGameClient.BINDINGS_SCRIPT)
		if not (script is GDScript):
			return
		table = (script as GDScript).new()
		c.settings.set(&"bindings", table)
	if not table.has_method(&"row_for_action") or not table.has_method(&"add"):
		return
	if table.call(&"row_for_action", c.look_gag_action).is_empty():
		var gag_label := "Look at a player: stop (or resume) hearing them"
		if not c.look_separate_keys:
			gag_label = "Look at a player: tap to gag, double-tap to mute"
		var _g: Variant = table.call(&"add", c.look_gag_action, &"bind_voice_gag", gag_label,
			free_key(c, ["G", "Y", "U"], table), "Communication")
	if c.look_separate_keys and table.call(&"row_for_action", c.look_mute_action).is_empty():
		var _m: Variant = table.call(&"add", c.look_mute_action, &"bind_voice_mute",
			"Look at a player: mute (or unmute) their voice and chat",
			free_key(c, ["K", "J", "N", "L"], table), "Communication")


static func free_key(c: DotGameClient, candidates: Array, table: Object = null) -> String:
	for cand in candidates:
		var code := OS.find_keycode_from_string(str(cand))
		if code == KEY_NONE or not holders(c, code).is_empty():
			continue
		if table != null and table.has_method(&"row_for_action") and _default_taken(table, str(cand)):
			continue
		return str(cand)
	return str(candidates.back()) if not candidates.is_empty() else ""


static func _default_taken(table: Object, key: String) -> bool:
	for row: Variant in table.get(&"rows"):
		if str((row as Dictionary).get("default", "")).to_upper() == key.to_upper():
			return true
	return false


static func holders(c: DotGameClient, keycode: int) -> PackedStringArray:
	var out := PackedStringArray()
	for action: StringName in InputMap.get_actions():
		if action == c.look_gag_action or action == c.look_mute_action or str(action).begins_with("ui_") \
				or action == &"voice_gag" or action == &"voice_mute":
			continue
		for e in InputMap.action_get_events(action):
			if e is InputEventKey and ((e as InputEventKey).physical_keycode == keycode \
					or (e as InputEventKey).keycode == keycode):
				out.append(String(action))
				break
	return out


## Without a menu table the actions are made here, on a key nobody holds.
static func ensure_actions(c: DotGameClient) -> void:
	var pairs: Array = [[c.look_gag_action, ["G", "Y", "U"]]]
	if c.look_separate_keys:
		pairs.append([c.look_mute_action, ["K", "J", "N", "L"]])
	for pair: Array in pairs:
		if InputMap.has_action(pair[0]):
			continue
		InputMap.add_action(pair[0])
		var key := InputEventKey.new()
		key.physical_keycode = OS.find_keycode_from_string(free_key(c, pair[1]))
		InputMap.action_add_event(pair[0], key)


static func build(c: DotGameClient) -> void:
	if not wanted(c) or c.look_mute != null:
		return
	if not ResourceLoader.exists(c.look_mute_script):
		DotLog.info(CHANNEL, "dot-voice is not in this build: no look-to-gag keys")
		return
	var script: Variant = load(c.look_mute_script)
	if not (script is GDScript):
		DotLog.warn(CHANNEL, "dot-voice's look-mute would not load", {"path": c.look_mute_script})
		return
	ensure_actions(c)
	var node := (script as GDScript).new() as Node
	c.look_mute = node
	node.name = "LookMute"
	node.set(&"manager", voice(c))
	node.set(&"separate_keys", c.look_separate_keys)
	node.set(&"gag_action", c.look_gag_action)
	node.set(&"mute_action", c.look_mute_action)
	node.set(&"target_fn", c.look_target_fn if c.look_target_fn.is_valid() else Callable(c, "_look_target"))
	node.set(&"chat_mute_fn", c.look_chat_mute_fn if c.look_chat_mute_fn.is_valid() else Callable(c, "_look_chat_mute"))
	c.add_child(node)
	var source: Object = c.link if c.link != null else DotRegistry.get_service(DotGameClient.LINK_SERVICE)
	if source != null and node.has_method(&"follow_cvars"):
		var _f: Variant = node.call(&"follow_cvars", source)
	c.look_conflicts = conflicts(c)
	for k in c.look_conflicts:
		DotLog.warn(CHANNEL, "a look-to-gag key is also another action's key; rebind one",
			{"action": k["action"], "key": k["key"], "other": k["other"]})


static func conflicts(c: DotGameClient) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var actions: Array = [c.look_gag_action]
	if c.look_separate_keys:
		actions.append(c.look_mute_action)
	for action: StringName in actions:
		if not InputMap.has_action(action):
			continue
		for e in InputMap.action_get_events(action):
			if not (e is InputEventKey):
				continue
			var code := (e as InputEventKey).physical_keycode
			if code == KEY_NONE:
				code = (e as InputEventKey).keycode
			for other in holders(c, code):
				out.append({"action": String(action), "key": OS.get_keycode_string(code), "other": other})
	return out


static func roster(c: DotGameClient) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var holder := chat_of(c)
	var list: Object = holder.get(&"self_mute") if holder != null else null
	if list == null or not (list.get(&"roster") is Array):
		return out
	var you := int(list.get(&"you"))
	for row: Dictionary in list.get(&"roster"):
		if not bool(row.get("bot", false)) and int(row.get("peer", 0)) > 0 and (you == 0 or int(row["id"]) != you):
			out.append(row)
	return out


static func chat_mute(c: DotGameClient, peer: int, muted: bool) -> void:
	var holder := chat_of(c)
	var list: Object = holder.get(&"self_mute") if holder != null else null
	if list == null or not list.has_method(&"set_muted"):
		return
	for row: Dictionary in roster(c):
		if int(row["peer"]) == peer:
			list.call(&"set_muted", {"key": row["key"], "name": row["name"]}, muted)


## The other player nearest the view axis, from the game's positions or the chat's speaker positions.
static func target(c: DotGameClient) -> int:
	var cam := c.get_viewport().get_camera_3d() if c.is_inside_tree() else null
	if cam == null:
		return 0
	var positions: Dictionary = {}
	if c.look_positions_fn.is_valid():
		positions = c.look_positions_fn.call()
	elif c.look_position_fn.is_valid():
		for row: Dictionary in roster(c):
			var at: Variant = c.look_position_fn.call(row)
			if at is Vector3 and int(row["peer"]) > 0:
				positions[int(row["peer"])] = at
	elif c.chat != null and c.chat.get(&"voice_position_fn") is Callable \
			and (c.chat.get(&"voice_position_fn") as Callable).is_valid():
		var v: Object = voice(c)
		var at: Callable = c.chat.get(&"voice_position_fn")
		if v != null and v.has_method(&"active_speakers"):
			for peer in v.call(&"active_speakers"):
				var pos: Variant = at.call(int(peer))
				if pos is Vector3:
					positions[int(peer)] = pos
	if positions.is_empty() or c.look_mute == null:
		return 0
	return int(c.look_mute.get_script().call(&"pick_by_angle", cam.global_transform, positions,
		c.look_max_distance, c.look_max_angle_deg))
