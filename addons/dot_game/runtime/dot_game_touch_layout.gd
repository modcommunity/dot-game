class_name DotGameTouchLayout
extends RefCounted

## Named touch-button presets (fps, driving, platformer) with canonical ids, places and sizes, so jump, fire, crouch and reload sit in the same spot in every game.
## A game takes a preset, overrides per button, and hands the result to dot-ui's DotTouchButtons and [method DotGameClient.fit_touch_buttons] through [method apply].
##
## [codeblock]
## var res := DotGameTouchLayout.build(DotGameTouchLayout.FPS, {&"alt": null, &"grab": &"inner"})
## if res.ok: res.value.apply(touch_buttons, platform)
## [/codeblock]

const CHANNEL := "game.touch_layout"

const FIRE := &"fire"
const ALT := &"alt"
const JUMP := &"jump"
const CROUCH := &"crouch"
const RELOAD := &"reload"
const USE := &"use"
const SPRINT := &"sprint"
const NEXT := &"next"
const PREV := &"prev"
const BOARD := &"board"
const CHAT := &"chat"
const GAS := &"gas"
const BRAKE := &"brake"
const HANDBRAKE := &"handbrake"
const RESPAWN := &"respawn"
const CAMERA := &"camera"
const STEER_LEFT := &"steer_left"
const STEER_RIGHT := &"steer_right"

const FPS := &"fps"
const DRIVING := &"driving"
const PLATFORMER := &"platformer"
## Same buttons as [constant PLATFORMER]: the mini-games are jump-and-use games.
const MINIGAME := &"minigame"

## The thumbs' cluster in the bottom-right corner, and the driving games' steering strip on the left (a second DotTouchButtons).
const RIGHT := &"right"
const LEFT := &"left"

## The smallest radius a button may have, and the least gap between two, in design units.
const MIN_RADIUS := 22.0
const MIN_GAP := 4.0

## Slot -> [offset from the bottom-right corner, radius], in design units (the 720-unit canvas DotGameScreenFit scales).
const SLOTS := {
	&"primary": [Vector2(80, 84), 44.0],
	&"secondary": [Vector2(190, 60), 30.0],
	&"below": [Vector2(80, 172), 32.0],
	&"outer": [Vector2(262, 60), 28.0],
	&"inner": [Vector2(190, 150), 26.0],
	&"corner": [Vector2(262, 140), 22.0],
	&"row1": [Vector2(80, 246), 22.0],
	&"row2": [Vector2(138, 246), 22.0],
	&"row3": [Vector2(196, 246), 22.0],
	&"row4": [Vector2(254, 246), 22.0],
	&"steer_near": [Vector2(96, 100), 46.0],
	&"steer_far": [Vector2(212, 100), 46.0],
}

## The four buttons whose place never changes between presets.
const HOMES := {FIRE: &"primary", JUMP: &"below", CROUCH: &"outer", RELOAD: &"corner"}

## Preset -> cluster -> [[id, slot], ...]. A game drops what it does not use rather than moving the rest.
const PRESETS := {
	FPS: {RIGHT: [[FIRE, &"primary"], [ALT, &"secondary"], [JUMP, &"below"], [CROUCH, &"outer"], [USE, &"inner"], [RELOAD, &"corner"], [NEXT, &"row1"], [PREV, &"row2"], [BOARD, &"row3"], [CHAT, &"row4"]]},
	PLATFORMER: {RIGHT: [[USE, &"primary"], [SPRINT, &"secondary"], [JUMP, &"below"], [CROUCH, &"outer"], [BOARD, &"row3"], [CHAT, &"row4"]]},
	DRIVING: {
		RIGHT: [[GAS, &"primary"], [BRAKE, &"secondary"], [JUMP, &"below"], [HANDBRAKE, &"outer"], [USE, &"inner"], [RESPAWN, &"corner"], [CAMERA, &"row1"], [BOARD, &"row3"], [CHAT, &"row4"]],
		LEFT: [[STEER_RIGHT, &"steer_near"], [STEER_LEFT, &"steer_far"]],
	},
}

const LABELS := {
	FIRE: "FIRE", ALT: "ALT", JUMP: "JUMP", CROUCH: "DUCK", RELOAD: "R", USE: "USE", SPRINT: "RUN",
	NEXT: ">", PREV: "<", BOARD: "TAB", CHAT: "CHAT", GAS: "GAS", BRAKE: "BRAKE", HANDBRAKE: "HAND",
	RESPAWN: "BACK", CAMERA: "CAM", STEER_LEFT: "<", STEER_RIGHT: ">",
}

## Ids games used before the presets, and the canonical id each is; [method validate] refuses them.
const ALIASES := {
	&"attack": FIRE, &"swing": FIRE, &"duck": CROUCH, &"dot_fps_crouch": CROUCH, &"dot_fps_jump": JUMP,
	&"dot_fps_sprint": SPRINT, &"run": SPRINT, &"tab": BOARD, &"hand": HANDBRAKE,
}

var preset_name: StringName = &""
var cluster: StringName = RIGHT
var _rows: Array[Dictionary] = []


## The preset's layout for [param p_cluster], unchanged; CODE_INVALID for an unknown preset. A preset with nothing in the cluster gives an empty layout.
static func make(preset: StringName, p_cluster: StringName = RIGHT) -> DotResult:
	var key := PLATFORMER if preset == MINIGAME else preset
	if not PRESETS.has(key):
		return DotResult.fail(DotError.CODE_INVALID, "unknown touch preset", String(preset))
	var out := DotGameTouchLayout.new()
	out.preset_name = key
	out.cluster = p_cluster
	for pair: Array in PRESETS[key].get(p_cluster, []):
		out.put(pair[0], pair[1])
	return DotResult.success(out)


## [method make], then [method override] with [param overrides], then [method validate]: the one call a game makes.
static func build(preset: StringName, overrides: Dictionary = {}, p_cluster: StringName = RIGHT) -> DotResult:
	var res := make(preset, p_cluster)
	if res.ok:
		res = (res.value as DotGameTouchLayout).override(overrides)
	if res.ok:
		res = (res.value as DotGameTouchLayout).validate()
	if not res.ok:
		return res.wrap("touch layout %s/%s" % [preset, p_cluster])
	DotLog.debug(CHANNEL, "touch layout built", {"preset": String(preset), "cluster": String(p_cluster), "ids": res.value.ids()})
	return res


## An empty layout, for a game whose buttons share no preset (it still uses the slots).
static func custom(p_cluster: StringName = RIGHT) -> DotGameTouchLayout:
	var out := DotGameTouchLayout.new()
	out.cluster = p_cluster
	return out


## The canonical id for [param id]: itself, or what [constant ALIASES] maps it to. A router accepting old ids calls this.
static func canonical_id(id: StringName) -> StringName:
	return ALIASES.get(id, id)


## Adds [param id] at [param slot_name] (or moves it there, keeping its label unless one is given).
func put(id: StringName, slot_name: StringName, label: String = "") -> DotGameTouchLayout:
	if not SLOTS.has(slot_name):
		push_error("DotGameTouchLayout: unknown slot %s" % slot_name)
		return self
	var slot: Array = SLOTS[slot_name]
	return place(id, slot[0], slot[1], label, slot_name)


## Adds or moves [param id] to a free position, for a button no slot suits.
func place(id: StringName, offset: Vector2, radius: float, label: String = "", slot_name: StringName = &"") -> DotGameTouchLayout:
	var i := _find(id)
	var text := label
	if text == "":
		text = _rows[i]["label"] if i >= 0 else LABELS.get(id, String(id).to_upper())
	var row := {"id": id, "label": text, "offset": offset, "radius": radius, "slot": slot_name}
	if i >= 0:
		_rows[i] = row
	else:
		_rows.append(row)
	return self


func drop(id: StringName) -> DotGameTouchLayout:
	var i := _find(id)
	if i >= 0:
		_rows.remove_at(i)
	return self


func relabel(id: StringName, label: String) -> DotGameTouchLayout:
	var i := _find(id)
	if i >= 0:
		_rows[i]["label"] = label
	return self


func resize(id: StringName, radius: float) -> DotGameTouchLayout:
	var i := _find(id)
	if i >= 0:
		_rows[i]["radius"] = radius
	return self


## Per-game changes as data: id -> null (drop), a slot name, or {slot, offset, radius, label}. All or nothing; CODE_INVALID names the first bad entry.
func override(changes: Dictionary) -> DotResult:
	var saved := _rows.duplicate(true)
	for key: Variant in changes:
		var id := StringName(key)
		var change: Variant = changes[key]
		var bad := ""
		if change == null:
			drop(id)
		elif change is StringName or change is String:
			bad = "" if SLOTS.has(StringName(change)) else "unknown slot %s" % change
			if bad == "":
				put(id, StringName(change))
		elif change is Dictionary:
			bad = _override_one(id, change)
		else:
			bad = "an override is null, a slot name or a Dictionary"
		if bad != "":
			_rows = saved
			return DotResult.fail(DotError.CODE_INVALID, "bad touch override for %s" % id, bad)
	return DotResult.success(self)


## Ok with this layout, or CODE_INVALID for an alias id, a radius under [constant MIN_RADIUS] or two buttons closer than [constant MIN_GAP].
func validate() -> DotResult:
	for i in _rows.size():
		var a := _rows[i]
		if ALIASES.has(a["id"]):
			return DotResult.fail(DotError.CODE_INVALID, "touch id is an alias", "%s is %s" % [a["id"], ALIASES[a["id"]]])
		if float(a["radius"]) < MIN_RADIUS:
			return DotResult.fail(DotError.CODE_INVALID, "touch button too small", "%s radius %s" % [a["id"], a["radius"]])
		for j in range(i + 1, _rows.size()):
			var b := _rows[j]
			var gap: float = (a["offset"] as Vector2).distance_to(b["offset"]) - float(a["radius"]) - float(b["radius"])
			if gap < MIN_GAP:
				return DotResult.fail(DotError.CODE_INVALID, "touch buttons overlap", "%s and %s, gap %.1f" % [a["id"], b["id"], gap])
	return DotResult.success(self)


## The rows dot-ui's DotTouchButtons.set_buttons takes (id, label, offset, radius); fresh copies.
func buttons() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for r in _rows:
		out.append({"id": r["id"], "label": r["label"], "offset": r["offset"], "radius": r["radius"]})
	return out


## Sets the rows on [param touch_buttons] (anything with set_buttons) and fits them through [param client]'s fit_touch_buttons when it has one. Returns the scale, 1 without a fit.
func apply(touch_buttons: Control, client: Object = null) -> float:
	var rows := buttons()
	if touch_buttons.has_method(&"set_buttons"):
		touch_buttons.call(&"set_buttons", rows)
	if client != null and client.has_method(&"fit_touch_buttons"):
		return float(client.call(&"fit_touch_buttons", touch_buttons, rows))
	return 1.0


func ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for r in _rows:
		out.append(r["id"])
	return out


func has(id: StringName) -> bool:
	return _find(id) >= 0


## The row for [param id] (id, label, offset, radius, slot), or empty.
func row(id: StringName) -> Dictionary:
	var i := _find(id)
	return _rows[i].duplicate() if i >= 0 else {}


func describe() -> Dictionary:
	return {"preset": String(preset_name), "cluster": String(cluster), "ids": ids()}


func _find(id: StringName) -> int:
	for i in _rows.size():
		if _rows[i]["id"] == id:
			return i
	return -1


func _override_one(id: StringName, change: Dictionary) -> String:
	for k: Variant in change:
		if not String(k) in ["slot", "offset", "radius", "label"]:
			return "unknown key %s" % k
	if change.has("slot"):
		if not SLOTS.has(StringName(change["slot"])):
			return "unknown slot %s" % change["slot"]
		put(id, StringName(change["slot"]))
	elif not has(id) and not (change.has("offset") and change.has("radius")):
		return "a new button needs a slot, or an offset and a radius"
	elif not has(id):
		place(id, change["offset"], float(change["radius"]))
	var i := _find(id)
	if change.has("offset"):
		_rows[i]["offset"] = change["offset"]
		_rows[i]["slot"] = &""
	if change.has("radius"):
		_rows[i]["radius"] = float(change["radius"])
	if change.has("label"):
		_rows[i]["label"] = String(change["label"])
	return ""
