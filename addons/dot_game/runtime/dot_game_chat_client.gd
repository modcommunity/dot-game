class_name DotGameChatClient
extends Node

## The client's half of [DotGameServices]: the chat box and the microphone.
##
## [b]Five games had a copy of this file each[/b], two hundred lines apiece and different in
## nothing but the names of their own classes. What is a game's own is three lists — the
## channels the box offers, the colour of each channel a line can arrive on, and the voice
## format — and a bridge to send through. Everything else is here.
##
## [b]Built whether or not there is a server, and offline it echoes what you type.[/b] A box
## that only appeared on a connected client is a box nobody can test alone, and a box that did
## nothing at all reads as broken rather than as absent.
##
## [b]Nothing here decides anything about a line.[/b] What crosses the wire is a channel id and
## a string; who said it, whether they are gagged, how fast they are talking and who hears it
## are all the server's chat router. That separation is why a client cannot put somebody
## else's name on a line.
##
## [b]The bridge is duck-typed[/b], for the reason the rest of dot-game is: a game's bridge is
## its own class, and a delivered pack cannot name one. It is asked for `ask_say(channel,
## text)` and `send_voice(bytes)`, and connected to `chat_received(wire)`,
## `voice_arrived(payload)` and, if it has one, `hello_received(id)`.
##
## [b]dot-ui and dot-voice are found by path[/b], as [DotGameServices] finds dot-chat. A game
## without dot-voice has a chat box and no microphone, and one without dot-ui has a
## microphone and no box; neither fails to parse.

const CHANNEL := "game.chat_client"

const WINDOW_SCRIPT := "res://addons/dot_ui/hud/dot_chat_window.gd"
const VOICE_SCRIPT := "res://addons/dot_voice/runtime/dot_voice_manager.gd"

## Typing started or stopped. A client suspends its movement sampler on it: movement is
## polled, so without that, typing "sw" walks the player backwards.
signal typing_changed(typing: bool)

## The channels the box offers when a player opens it: `{id, label, colour}`. The first is
## what Y opens and the second what U opens. Set before the node enters the tree.
var channels: Array[Dictionary] = [
	{"id": &"all", "label": "All", "colour": Color(0.93, 0.94, 0.96)},
	{"id": &"team", "label": "Team", "colour": Color(0.55, 0.82, 0.95)},
]

## channel id -> the colour a line arriving on it is drawn in. A channel a player cannot send
## on (admin, a whisper) still arrives, which is why this is separate from [member channels].
var line_colours: Dictionary = {
	&"all": Color(0.93, 0.94, 0.96),
	&"team": Color(0.55, 0.82, 0.95),
	&"near": Color(0.82, 0.86, 0.72),
	&"admin": Color(0.98, 0.72, 0.35),
	&"whisper": Color(0.78, 0.71, 0.93),
}

## What a line arriving on a channel not in [member line_colours] is drawn in.
var default_colour: Color = Color(0.93, 0.94, 0.96)

## The longest line the SERVER accepts, so a line is refused here rather than sent and
## silently truncated there. Take it from the same rules the services layer reads.
var max_length: int = 127

## The voice format, a `DotVoiceConfig`. Null leaves dot-voice's own default, which is only
## right if the server's router uses the same default.
var voice_config: Resource = null

## The key held to talk. Physical, because the letter on it differs across layouts. KEY_NONE
## for no push-to-talk.
var talk_key: Key = KEY_V

## Whether remote voices are placed where their speaker is.
var positional_voice: bool = true

## The canvas layer the box draws on. Above a HUD's, because an admin's blind is drawn on the
## HUD's and a blinded player must still be able to read the line saying who did it.
var layer: int = 2

## The colour of a line the game itself puts in the box, and of a notice.
var local_colour: Color = Color(0.86, 0.88, 0.92)
var notice_colour: Color = Color(0.98, 0.72, 0.35)

## The box, a `DotChatWindow`, or null without dot-ui.
var window: Control = null

## The microphone and the speakers, a `DotVoiceManager`, or null without dot-voice.
var voice: Node = null

## The bridge this box sends through, or null offline.
var bridge: Object = null

## Which session this client is.
var local_player_id: int = 0

var _talking: bool = false


func _ready() -> void:
	_build_window()
	_build_voice()


func _build_window() -> void:
	var script := _script(WINDOW_SCRIPT, "the chat box")

	if script == null:
		return

	window = script.new() as Control
	window.name = "ChatWindow"
	window.set(&"channels", channels)
	window.set(&"max_length", max_length)

	# A CanvasLayer does not lay its children out, so the window goes under a full-rect
	# Control on it — the same lesson every HUD in the family learned.
	var canvas := CanvasLayer.new()
	canvas.name = "ChatLayer"
	canvas.layer = layer
	add_child(canvas)

	var screen := Control.new()
	screen.name = "Screen"
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(screen)
	screen.add_child(window)

	window.connect(&"submitted", _on_submitted)
	window.connect(&"opened", func(_id: StringName) -> void: typing_changed.emit(true))
	window.connect(&"closed", func() -> void: typing_changed.emit(false))


func _build_voice() -> void:
	var script := _script(VOICE_SCRIPT, "voice")

	if script == null:
		return

	voice = script.new() as Node
	voice.name = "Voice"
	# Not the shared name: a client and a server in one process would fight over it, which is
	# what every networked suite is.
	voice.set(&"register_service", false)

	if voice_config != null:
		voice.set(&"config", voice_config)

	voice.set(&"positional_playback", positional_voice)
	add_child(voice)


## Joins this box to a bridge, or to nothing at all.
##
## [param p_bridge] null is the offline case and is not an error: the box still opens, takes a
## line and shows it.
func attach(p_bridge: Object) -> DotResult:
	bridge = p_bridge

	if bridge == null:
		say_locally("Offline. Nobody can hear you, but the box works.", Color(0.72, 0.74, 0.78))
		return DotResult.success(null)

	if &"local_player_id" in bridge:
		local_player_id = int(bridge.get(&"local_player_id"))

	_connect(&"chat_received", _on_line)
	_connect(&"voice_arrived", _on_voice)
	_connect(&"hello_received", func(id: int) -> void: local_player_id = id)

	if voice == null:
		return DotResult.success(null)

	# One frame out, one call. dot-voice never touches a transport — which is what lets its
	# whole path run headless — so this is the seam, and without it a client captures,
	# encodes, counts a frame and sends it nowhere.
	voice.set(&"send_fn", func(bytes: PackedByteArray) -> void:
		if bridge != null and bridge.has_method(&"send_voice"):
			bridge.call(&"send_voice", bytes))

	var capturing: DotResult = voice.call(&"start_capture")

	if not capturing.ok:
		# Not fatal, and said once. A machine with no microphone is a legitimate client and
		# the player can still read everything anybody says.
		DotLog.info(CHANNEL, "no microphone on this machine", {"why": capturing.error.message})

	return DotResult.success(null)


func _connect(signal_name: StringName, handler: Callable) -> void:
	if bridge.has_signal(signal_name) and not bridge.is_connected(signal_name, handler):
		var _c := bridge.connect(signal_name, handler)


func _on_submitted(text: String, channel_id: StringName) -> void:
	typing_changed.emit(false)

	if text.strip_edges() == "":
		return

	if bridge == null:
		# Echoed rather than sent. Named "you", because offline there is no identity layer to
		# have a name.
		if window != null:
			window.call(&"add_said", "you", text, local_colour)
		return

	if bridge.has_method(&"ask_say"):
		bridge.call(&"ask_say", channel_id, text)


## One routed line, already decided: `{d: speaker, m: text, c: channel}`. Drawn exactly as
## the server addressed it.
func _on_line(wire: Dictionary) -> void:
	var speaker := str(wire.get("d", ""))
	var text := str(wire.get("m", ""))
	var channel_id := StringName(str(wire.get("c", "all")))

	if text == "" or window == null:
		return

	var colour: Color = line_colours.get(channel_id, default_colour)

	if speaker == "":
		window.call(&"add_text", text, colour)
		return

	window.call(&"add_said", speaker, text, colour)


func _on_voice(payload: PackedByteArray) -> void:
	if voice != null:
		var _played: Variant = voice.call(&"receive", payload)


## Something the server said to this player alone: a refusal, a rate limit, a reply.
func notice(text: String) -> void:
	if window != null:
		window.call(&"add_text", text, notice_colour)


## A line the game itself wants in the box: a death, a round, an award.
func say_locally(text: String, colour: Color = local_colour) -> void:
	if window != null:
		window.call(&"add_text", text, colour)


func is_typing() -> bool:
	return window != null and bool(window.call(&"is_open"))


## Whether the microphone is open right now.
func is_talking() -> bool:
	return _talking


## Push to talk. Held, never toggled.
##
## A held key and not an event, because talking is held: an event queue is sampled per frame
## and a frame is not a tick; what matters is whether the key is down right now.
func _process(_delta: float) -> void:
	if voice == null or talk_key == KEY_NONE:
		return

	var wanted := Input.is_physical_key_pressed(talk_key) and not is_typing()

	if wanted == _talking:
		return

	_talking = wanted
	voice.call(&"set_talking", wanted)


func _script(path: String, what: String) -> GDScript:
	if not ResourceLoader.exists(path):
		DotLog.info(CHANNEL, "%s is not installed in this build" % what, {"path": path})
		return null

	var script: Variant = load(path)

	if script == null or not (script is GDScript):
		DotLog.warn(CHANNEL, "%s would not load" % what, {"path": path})
		return null

	return script as GDScript


func describe() -> Dictionary:
	return {
		"box": window != null,
		"open": is_typing(),
		"talking": _talking,
		"lines": int(window.call(&"line_count")) if window != null and window.has_method(&"line_count") else 0,
		"voice": voice.call(&"describe") if voice != null else {},
		"online": bridge != null,
	}
