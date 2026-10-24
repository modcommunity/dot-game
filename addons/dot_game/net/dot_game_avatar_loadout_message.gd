class_name DotGameAvatarLoadoutMessage
extends DotNetMessage

## One player's equipped emotes, poses and gestures, as the server read them from the backbone:
## server to client only, so a client never claims a loadout. No entries means "forget this
## player" (they left, or play the starter set). Registered by [method DotGameAvatarActionMessage.register].

const NAME := &"game.avatar_loadout"

## Three kinds of at most eight (the site's AVATAR_ACTION_EQUIP_MAX).
const MAX_ENTRIES := 24
const MAX_ID := 32
const MAX_CLIP := 64

## Wire order of [code]kind[/code]: emote, pose, gesture.
const KINDS: PackedStringArray = ["emote", "pose", "gesture"]

var actor: int = 0

## [code]{"id": String, "kind": int, "loop": bool, "clip": String}[/code]; clip is "" for a built-in.
var entries: Array = []


func _type_name() -> StringName:
	return NAME


func _write(w: DotNetWriter) -> void:
	w.write_varint(actor)
	var n := mini(entries.size(), MAX_ENTRIES)
	w.write_uint(n, 5)
	for i in n:
		var e: Dictionary = entries[i]
		w.write_string(String(e.get("id", "")), MAX_ID)
		w.write_uint(clampi(int(e.get("kind", 0)), 0, 2), 2)
		w.write_bool(bool(e.get("loop", false)))
		w.write_string(String(e.get("clip", "")), MAX_CLIP)


func _read(r: DotNetReader) -> void:
	actor = r.read_varint()
	var n := r.read_uint(5)
	entries = []
	for i in mini(n, MAX_ENTRIES):
		var id := r.read_string(MAX_ID)
		var kind := r.read_uint(2)
		var loop := r.read_bool()
		var clip := r.read_string(MAX_CLIP)
		entries.append({"id": id, "kind": kind, "loop": loop, "clip": clip})


func _validate() -> DotResult:
	if actor <= 0 or entries.size() > MAX_ENTRIES:
		return DotResult.fail(DotError.CODE_INVALID, "avatar loadout out of range")
	for e: Dictionary in entries:
		var id := String(e.get("id", ""))
		if id == "" or id.length() > MAX_ID or int(e.get("kind", 0)) > 2 or String(e.get("clip", "")).length() > MAX_CLIP:
			return DotResult.fail(DotError.CODE_INVALID, "avatar loadout entry out of range")
	return DotResult.success(true)


## The equipped ids, in order.
func ids() -> PackedStringArray:
	var out := PackedStringArray()
	for e: Dictionary in entries:
		out.append(String(e["id"]))
	return out
