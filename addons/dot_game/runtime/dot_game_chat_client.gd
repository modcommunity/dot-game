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
## [b]The server's own lines arrive on a second wire, and this reads both.[/b] What players say
## crosses the game's bridge, routed by dot-game's services. What the SERVER says — a vote
## between games, "Ada joined the game.", an admin's `say`, the reply to a chat command — is
## dot-server's chat manager, sent as a `chat.line` envelope on the client link the shell
## owns, and lands on `DotClientLink.chat_received`. Eight games read only the bridge, so a
## player in any of them never saw the server's vote announce itself or an admin speak. The
## link is found in the registry by itself (`dot_client_link`), so a game passes nothing and
## the next one gets it too. Only the server's own kinds (`system`, `admin`) are drawn from
## it: what players say is the bridge's to deliver, and drawing it from both is how a line
## would show twice ([method draw_server_line]).
##
## [b]dot-ui and dot-voice are found by path[/b], as [DotGameServices] finds dot-chat. A game
## without dot-voice has a chat box and no microphone, and one without dot-ui has a
## microphone and no box; neither fails to parse.

const CHANNEL := "game.chat_client"

const LINK_SERVICE := &"dot_client_link"

const WINDOW_SCRIPT := "res://addons/dot_ui/hud/dot_chat_window.gd"
const VOICE_SCRIPT := "res://addons/dot_voice/runtime/dot_voice_manager.gd"

## dot-voice's talk action (`DotVoiceManager.TALK_ACTION`), as text: dot-voice is loaded by path.
const TALK_ACTION := &"dot_voice_talk"

## The player's own block list (`sm`), dot-chat's `DotChatSelfMute`: its registry name and
## its script, for a build that has not made it yet.
const SELF_MUTE_SERVICE := &"dot_self_mute"
const SELF_MUTE_SCRIPT := "res://addons/dot_chat/runtime/dot_chat_self_mute.gd"

## The server turned voice on or off (`sv_voice_enable`, replicated). A HUD hides its
## microphone on false; the talk key does nothing until it is true again.
signal voice_available_changed(available: bool)

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

## Properties set on the box before it is built, e.g. `{"max_lines": 6}` for a HUD whose
## health number sits where an eighth row would. Set before the node enters the tree: the
## box reads most of them once, as it builds.
var window_settings: Dictionary = {}

## The bridge method a voice frame goes out through, `(bytes)`. A bridge whose `send_voice`
## is already the server's `(peer_id, bytes)` names its client half here.
var voice_method: StringName = &"send_voice"

## The voice format, a `DotVoiceConfig`. Null leaves dot-voice's own default, which is only
## right if the server's router uses the same default.
var voice_config: Resource = null

## The key the talk action (dot-voice's `dot_voice_talk`) is created on when nothing has bound
## it; dot-menu's key table binds it first in every game that has the menu. Physical, because
## the letter on it differs across layouts. KEY_NONE for no push-to-talk.
var talk_key: Key = KEY_V

## Where a speaker is, `func(peer: int) -> Variant` (a Vector3, or null), for positional voice.
## Unset, voices are flat: positional with no position put every voice at the world's origin.
var voice_position_fn: Callable = Callable()

## Whether remote voices are placed where their speaker is.
var positional_voice: bool = true

## The canvas layer the box draws on. Above a HUD's, because an admin's blind is drawn on the
## HUD's and a blinded player must still be able to read the line saying who did it.
var layer: int = 2

## Whether the server's own lines (see the class description) are drawn. A game that reads
## `DotClientLink.chat_received` itself sets this false before [method attach], or both
## would draw every line.
var server_lines: bool = true

## The colour of a line dot-server's chat manager sent: a system line, an admin's.
var server_colour: Color = Color(0.98, 0.84, 0.40)

## The client link whose `chat_received` carries the server's own lines. Null looks it up in
## the registry as `dot_client_link` when [method attach] is given a bridge, which is where
## the shell, and every client that runs a game alone, publishes it.
var link: Object = null

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

## Whether the player's own block list (`sm`) is honoured: a muted player's line is not
## drawn and their voice is not played. `!sm` / `/sm` typed in the box never reach the
## bridge; the box (dot-ui's `DotChatWindow`) runs them before it emits anything.
var self_mute_enabled: bool = true

## The block list, or null: anything with `is_muted_line(wire)` and `attach_voice(manager)`.
## Found as the registry's `dot_self_mute`, else made by dot-chat's script, as the box is
## built. Null without dot-chat, and then nothing is muted.
var self_mute: Object = null

var _talking: bool = false


func _ready() -> void:
	_find_self_mute()
	_build_window()
	_build_voice()


## The shared list, made now if nothing has made it: it is what asks the server who is here,
## so a client that waited for the first line would not know whose voice to drop until then.
func _find_self_mute() -> void:
	if not self_mute_enabled or self_mute != null:
		return
	self_mute = DotRegistry.get_service(SELF_MUTE_SERVICE)
	if self_mute != null or not ResourceLoader.exists(SELF_MUTE_SCRIPT):
		return
	var script: Variant = load(SELF_MUTE_SCRIPT)
	if script is Script:
		var shared: Variant = (script as Script).call(&"shared")
		self_mute = shared if shared is Object else null


func _build_window() -> void:
	var script := _script(WINDOW_SCRIPT, "the chat box")

	if script == null:
		return

	window = script.new() as Control
	window.name = "ChatWindow"
	window.set(&"channels", channels)
	window.set(&"max_length", max_length)

	for key in window_settings:
		window.set(StringName(str(key)), window_settings[key])

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
	if voice_position_fn.is_valid():
		voice.set(&"speaker_position_fn", voice_position_fn)
	add_child(voice)

	# This player's own voice: what the menu's voice rows bind to (dot-menu finds it by this
	# name). Only the client's, never a server's router, so one per player at the keyboard.
	if voice.has_method(&"publish_as_client"):
		voice.call(&"publish_as_client")
	if voice.has_signal(&"server_enabled_changed"):
		voice.connect(&"server_enabled_changed", func(on: bool) -> void: voice_available_changed.emit(on))

	_ensure_talk_action()

	# The block list mutes a player's peer on this manager whenever the list or the roster
	# changes. dot-voice's manager also asks for it itself; attaching twice is one attachment.
	if self_mute != null and self_mute.has_method(&"attach_voice"):
		self_mute.call(&"attach_voice", voice)


## Joins this box to a bridge, or to nothing at all.
##
## [param p_bridge] null is the offline case and is not an error: the box still opens, takes a
## line and shows it.
func attach(p_bridge: Object) -> DotResult:
	bridge = p_bridge

	if bridge == null:
		say_locally("Offline. Nobody can hear you, but the box works.", Color(0.72, 0.74, 0.78))
		return DotResult.success(null)

	if &"local_player_id" in bridge and bridge.get(&"local_player_id") is int:
		local_player_id = int(bridge.get(&"local_player_id"))

	_connect(&"chat_received", _on_line)
	_connect(&"voice_arrived", _on_voice)
	# Untyped: a bridge whose players are keyed by name says hello with a StringName, and a
	# typed lambda would be a script error on every hello.
	_connect(&"hello_received", func(id: Variant) -> void:
		if id is int:
			local_player_id = id)
	_watch_link()

	if voice == null:
		return DotResult.success(null)

	# One frame out, one call. dot-voice never touches a transport — which is what lets its
	# whole path run headless — so this is the seam, and without it a client captures,
	# encodes, counts a frame and sends it nowhere.
	voice.set(&"send_fn", func(bytes: PackedByteArray) -> void:
		if bridge != null and bridge.has_method(voice_method):
			bridge.call(voice_method, bytes))

	# [b]No microphone yet.[/b] It opens on the first press of the talk key ([method
	# _process], dot-voice's update_talk): that press is the player agreeing, and in a
	# browser it is the moment the permission prompt appears, attached to the key they just
	# pressed. This used to call start_capture here, which in a browser would have asked for
	# the microphone the moment a game loaded.

	# The server's sv_voice_enable, replicated on the shell's link.
	var cvar_source: Object = link if link != null else DotRegistry.get_service(LINK_SERVICE)
	if cvar_source != null and cvar_source != bridge and voice.has_method(&"follow_cvars"):
		var _following: Variant = voice.call(&"follow_cvars", cvar_source)

	return DotResult.success(null)


## Connects the server's own lines, once. A method and not a lambda, so the connection goes
## with this node when a game switch frees it: the link is the shell's and outlives every game.
func _watch_link() -> void:
	if not server_lines:
		return

	if link == null:
		link = DotRegistry.get_service(LINK_SERVICE)

	if link == null or link == bridge or not link.has_signal(&"chat_received"):
		return

	if not link.is_connected(&"chat_received", _on_server_line):
		var _c := link.connect(&"chat_received", _on_server_line)


## One line from dot-server's chat manager: `{kind, name, text}`.
func _on_server_line(payload: Dictionary) -> void:
	var _drawn := draw_server_line(window, payload, server_colour, line_colours.get(&"admin", server_colour))


## Draws one of dot-server's own chat payloads in [param box] (a `DotChatWindow`, or anything
## with `add_text` and `add_said`), and says whether it was a line at all.
##
## Static, so a game with its own chat box draws them the same way: buses, playground and
## any client that reads `DotClientLink.chat_received` itself. Only `system` and `admin` are
## drawn: what PLAYERS say (`all`, `team`) a game routing its chat delivers over its own wire,
## and on a server whose module also lets dot-server's own player chat through, drawing it
## here too would be every line twice. `state` is not a line (it says what is carrying chat),
## and a payload with no `text` is dot-chat's. All of those come back false.
static func draw_server_line(
	box: Object,
	payload: Dictionary,
	system_colour: Color = Color(0.98, 0.84, 0.40),
	admin_colour: Color = Color(0.98, 0.72, 0.35)
) -> bool:
	var kind := str(payload.get("kind", ""))

	if box == null or not (kind == "system" or kind == "admin") or not payload.has("text"):
		return false

	var text := str(payload.get("text", "")).strip_edges()

	if text == "":
		return false

	var speaker := str(payload.get("name", ""))

	if kind == "system":
		box.call(&"add_text", text if speaker == "" else "%s %s" % [speaker, text], system_colour)
		return true

	box.call(&"add_said", speaker, text, admin_colour)
	return true


func _exit_tree() -> void:
	if link != null and is_instance_valid(link) and link.is_connected(&"chat_received", _on_server_line):
		link.disconnect(&"chat_received", _on_server_line)


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

	# A player this reader muted (`sm`): matched by the line's sender key against the
	# roster, then by name. The box's own `add_said` check is by name only.
	if speaker != "" and self_mute != null and self_mute.has_method(&"is_muted_line") \
			and bool(self_mute.call(&"is_muted_line", wire)):
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


## Whether this player is talking right now: the key held, and the server allowing voice.
func is_talking() -> bool:
	return _talking and voice != null and bool(voice.get(&"server_enabled") if &"server_enabled" in voice else true)


## Push to talk. Held, never toggled.
##
## A held key and not an event, because talking is held: an event queue is sampled per frame
## and a frame is not a tick; what matters is whether the key is down right now.
func _process(_delta: float) -> void:
	if voice == null or talk_key == KEY_NONE:
		return

	var wanted := _talk_held() and not is_typing()

	if wanted == _talking:
		return

	_talking = wanted

	if not voice.has_method(&"update_talk"):
		voice.call(&"set_talking", wanted)
		return

	# The first press opens the microphone; a refusal comes back once a press.
	var started: DotResult = voice.call(&"update_talk", wanted)

	if wanted and not started.ok:
		# Not fatal, and said once a press. A machine with no microphone is a legitimate
		# client and the player can still hear and read everything.
		DotLog.info(CHANNEL, "no microphone on this machine", {"why": started.error.message})


func _talk_held() -> bool:
	if InputMap.has_action(TALK_ACTION):
		return Input.is_action_pressed(TALK_ACTION)
	return Input.is_physical_key_pressed(talk_key)


## Creates the talk action on [member talk_key] if nothing has: a key table that binds it
## (dot-menu's) wins, because this only fills a gap.
func _ensure_talk_action() -> void:
	if talk_key == KEY_NONE or InputMap.has_action(TALK_ACTION):
		return
	InputMap.add_action(TALK_ACTION)
	var key := InputEventKey.new()
	key.physical_keycode = talk_key
	InputMap.action_add_event(TALK_ACTION, key)


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
		"self_mute": self_mute.call(&"describe") if self_mute != null and self_mute.has_method(&"describe") else {},
		"server_lines": server_lines and link != null and is_instance_valid(link)
			and link.is_connected(&"chat_received", _on_server_line),
	}
