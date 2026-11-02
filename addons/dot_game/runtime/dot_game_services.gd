@tool
class_name DotGameServices
extends Node

## Chat, a website relay, moderation and voice, in the one order that works.
##
## Moderation is built FIRST because it publishes `dot_mute_source`, which both routers look up at start (else no gag is ever enforced); the relay follows chat because it wraps the router; voice is last as the optional one. Nothing here names dot-chat, dot-voice or dot-moderation: each is loaded BY PATH and driven through `set()` and `call()`, and a missing addon is a skipped layer.

const CHANNEL := "game.services"

## Where each layer lives. By path, for the reason in the class note.
const CHAT_ROUTER_SCRIPT := "res://addons/dot_chat/runtime/dot_chat_router.gd"
const CHAT_RELAY_SCRIPT := "res://addons/dot_chat/net/dot_chat_relay.gd"
const CHAT_RELAY_CONFIG_SCRIPT := "res://addons/dot_chat/core/dot_chat_relay_config.gd"
const VOICE_ROUTER_SCRIPT := "res://addons/dot_voice/runtime/dot_voice_router.gd"
const MODERATION_SCRIPT := "res://addons/dot_moderation/runtime/dot_moderation_manager.gd"
const MOD_TOOLS_SCRIPT := "res://addons/dot_moderation/tools/dot_mod_tools.gd"
const MOD_COMMANDS_SCRIPT := "res://addons/dot_moderation/integrations/dot_mod_tool_commands.gd"
const PUNISHMENT_STORE_SCRIPT := "res://addons/dot_moderation/store/dot_punishment_store_file.gd"

## The registry names dot-chat and dot-moderation agree on. Written out rather than read
## off the classes, because naming the classes is the one thing this file may not do.
const MUTE_SERVICE := &"dot_mute_source"
const CHAT_SERVICE := &"dot_chat_router"

## Where the relay reads its own settings when the host assigned no config.
##
## `user://`, an operator's file on a running server. Absent is normal: the environment and command line still apply.
const RELAY_CONFIG_PATH := "user://chat_relay.json"


## Somebody typed a line that was a command rather than chat.
signal command_entered(peer_id: int, command: String, args: PackedStringArray)

## A line was accepted and sent. What a game hooks to score, log or echo it.
signal said(peer_id: int, wire: Dictionary)


@export_group("Moderation")

## Where punishments are kept. Empty uses `user://<module>_punishments.json`.
@export_file("*.json") var punishments_file: String = ""

## The scope a punishment is recorded against. Empty is a single-server community, which
## is the only case most deployments are in and the one dot-moderation shipped a bug about.
@export var server_scope: String = ""

## Build dot-moderation's live tools — noclip, god, freeze, slay, bring and the rest — and
## put their commands on the server's console. What each one DOES is the subclass's; see
## [method _mod_abilities].
@export var mod_tools_enabled: bool = true

@export_group("Website chat")

## Left null, a default is built and layered, and the relay stays OFF unless configured.
@export var relay_config: Resource = null

@export_group("Voice")

@export var voice_enabled: bool = true


var server: DotServer = null

## The game object. Duck-typed: this addon holds no opinion about what a game is.
var game: Object = null

## Whatever the bridge opened — the node with `send_chat` and `send_voice` on it.
var link: Object = null

var chat: Node = null
var voice: Node = null
var moderation: Node = null
var relay: Node = null

## dot-moderation's `DotModTools`, when it is installed and [member mod_tools_enabled].
var mod_tools: Node = null

## Its `DotModToolCommands`, bound to the server's console.
var mod_commands: Object = null

## The backbone client the relay posts through. Assigned by a host BEFORE setup, or found.
##
## An [Object], so neither dot-chat nor this addon depends on dot-auth.
var backbone: Object = null

## Distinguishes two of these in one process — a server and a client, or a test.
var service_scope: StringName = &""

var punishments_loaded: bool = false

var _started: bool = false


## Builds all four, in the order the class note sets out.
##
## Not a coroutine: dot-moderation's `load_all` runs to completion for the file store. [param p_server] may be null (an offline game); only what is bound TO a server is skipped then. A subclass that wants no live tools offline sets [member mod_tools_enabled] false first.
func setup(p_server: DotServer, p_game: Object, p_link: Object) -> DotResult:
	if _started:
		return DotResult.fail(DotError.CODE_STATE, "Already set up.")

	if p_server == null:
		DotLog.debug(CHANNEL, "services with no server: offline, and nothing is bound to a console")

	server = p_server
	game = p_game
	link = p_link

	# FIRST. See the class note: it publishes the mute source both routers look up when
	# they start, and a router that starts before it enforces no gag, for ever, silently.
	var moderated := _build_moderation()
	DotLog.result(CHANNEL, "moderation", moderated)

	# After moderation, so every action lands on the target's history; reported rather
	# than fatal, because a server with no noclip is a server.
	if mod_tools_enabled:
		var tooled := _build_mod_tools()
		DotLog.result(CHANNEL, "the live mod tools", tooled)

	var chatted := _build_chat()

	if not chatted.ok:
		return chatted

	# After chat, because it wraps the router; reported rather than fatal, because a relay
	# that cannot start is a server that still runs a perfectly good match.
	var relayed := _build_relay()
	DotLog.result(CHANNEL, "the website chat relay", relayed)

	if voice_enabled:
		var voiced := _build_voice()
		DotLog.result(CHANNEL, "voice", voiced)

	_started = true
	return DotResult.success(self)


func _build_moderation() -> DotResult:
	var made := _instance(MODERATION_SCRIPT, "moderation")

	if made == null:
		return DotResult.success(null)

	moderation = made
	moderation.name = "Moderation"

	var store := _instance_refcounted(
		PUNISHMENT_STORE_SCRIPT, "the punishment store", [_punishments_path()]
	)

	if store != null:
		moderation.set("store", store)

	moderation.set("server_scope", server_scope)
	moderation.set("register_mute_source", true)
	moderation.set("register_ban_source", true)
	# Zero means "no immunity to respect", not "the highest rank there is".
	moderation.set("equal_immunity_may_act", true)
	moderation.set("key_for_peer", Callable(self, "_subject_for_peer"))

	add_child(moderation)

	# A bare statement call: `load_all` is a coroutine because a store MAY be an HTTP one,
	# and the file store is not — so this runs to completion. It cannot be awaited from a
	# module load, which is the constraint the whole sequence is written under.
	moderation.call("load_all")
	punishments_loaded = true

	return DotResult.success(moderation)


## The live tools and their commands.
##
## By path, like the manager; `DotModToolCommands` binds to the console duck-typed. What each ability does is [method _mod_abilities]; the rest (immunity, audit, respawn clearing) is the tools' own.
func _build_mod_tools() -> DotResult:
	var made := _instance(MOD_TOOLS_SCRIPT, "the mod tools")

	if made == null:
		return DotResult.success(null)

	mod_tools = made
	mod_tools.name = "ModTools"
	# Two servers in one process (a test, a listen server) must not fight over one registry
	# name, and nothing here looks the tools up by name.
	mod_tools.set("register_service", false)

	if moderation != null:
		mod_tools.set("manager", moderation)

	mod_tools.set("immunity_fn", Callable(self, "_mod_immunity"))

	if _mod_can_teleport():
		mod_tools.set("position_fn", Callable(self, "_mod_position"))
		mod_tools.set("teleport_fn", Callable(self, "_mod_teleport"))

	var handlers: Dictionary = mod_tools.get("handlers")
	var abilities := _mod_abilities()
	for action: Variant in abilities:
		handlers[StringName(action)] = abilities[action]

	var reasons: Dictionary = mod_tools.get("unsupported_reasons")
	var refusals := _mod_unsupported()
	for action: Variant in refusals:
		reasons[StringName(action)] = str(refusals[action])

	# The subclass's last word on the tools themselves, before they are in the tree and
	# before any command can reach them. See [method _mod_configure_tools].
	_mod_configure_tools(mod_tools)

	add_child(mod_tools)

	if server == null or server.console == null:
		return DotResult.success(mod_tools)

	var commands_script: Variant = load(MOD_COMMANDS_SCRIPT) if ResourceLoader.exists(MOD_COMMANDS_SCRIPT) else null

	if not (commands_script is GDScript):
		return DotResult.success(mod_tools)

	mod_commands = (commands_script as GDScript).new()
	mod_commands.set("tools", mod_tools)
	mod_commands.set("server", server)
	_mod_configure_commands(mod_commands)

	var bound: Variant = mod_commands.call("bind", server.console)

	if bound is DotResult and not (bound as DotResult).ok:
		return (bound as DotResult).wrap("the mod tool commands would not bind")

	return DotResult.success(mod_tools)


func _punishments_path() -> String:
	if punishments_file != "":
		return punishments_file

	return "user://%s_punishments.json" % _services_name()


func _build_chat() -> DotResult:
	var made := _instance(CHAT_ROUTER_SCRIPT, "chat")

	if made == null:
		# Not a failure. A server with no chat is a server nobody stays on and it IS a
		# server; the same judgement [DotGameModule] makes about this whole layer.
		return DotResult.success(null)

	chat = made
	chat.name = "Chat"
	chat.set("rules", _chat_rules())
	chat.set("rules_file", "")
	chat.set("install_default_channels", false)
	chat.set("handle_me_command", true)
	chat.set("register_as", _scoped(CHAT_SERVICE))
	chat.set("mute_service", MUTE_SERVICE)

	chat.set("send_fn", Callable(self, "_send_chat"))
	chat.set("peers_fn", Callable(self, "_chat_peers"))
	chat.set("name_fn", Callable(self, "_name_of"))
	chat.set("key_fn", Callable(self, "_key_of"))
	chat.set("position_fn", Callable(self, "_position_of"))
	chat.set("is_admin_fn", Callable(self, "_is_admin"))
	# The same function as voice's, so nobody can read a line from somebody they could not
	# hear. See [method _can_hear].
	chat.set("can_hear_fn", Callable(self, "_can_hear"))

	add_child(chat)

	var started: Variant = chat.call("start")

	if started is DotResult and not (started as DotResult).ok:
		return (started as DotResult).wrap("the chat router would not start")

	for channel in _chat_channels():
		var added: Variant = chat.call("add_channel", channel)

		if added is DotResult and not (added as DotResult).ok:
			return (added as DotResult).wrap("a chat channel was refused")

	chat.connect("command_entered", _on_command_entered)
	chat.connect("message_accepted", _on_message_accepted)

	return DotResult.success(chat)


func _build_voice() -> DotResult:
	var made := _instance(VOICE_ROUTER_SCRIPT, "voice")

	if made == null:
		return DotResult.success(null)

	var config := _voice_config()

	if config == null:
		return DotResult.fail(DotError.CODE_INVALID, "No voice configuration.")

	var problem: Variant = config.call("validate") if config.has_method("validate") else null

	if problem is DotResult and not (problem as DotResult).ok:
		return (problem as DotResult).wrap("the voice configuration is not usable")

	voice = made
	voice.name = "Voice"
	voice.set("config", config)
	voice.set("default_channel", _voice_default_channel())
	voice.set("send_fn", Callable(self, "_send_voice"))
	voice.set("position_fn", Callable(self, "_position_of"))
	voice.set("can_hear_fn", Callable(self, "_can_hear"))

	if "proximity_range" in config:
		voice.set("proximity_range", config.get("proximity_range"))

	if "max_bytes_per_second" in config:
		voice.set("max_bytes_per_second", config.get("max_bytes_per_second"))

	add_child(voice)
	return DotResult.success(voice)


## Joins this server's chat to its room on the website.
##
## Every seam is existing code: dot-auth's backbone client, dot-server's `uid_has_permission`, and `DotServer.run_command_as_uid` (that uid's OWN flags, not RCON's root). A relayed command is checked like the same person typing it in game.
func _build_relay() -> DotResult:
	if chat == null:
		return DotResult.success(null)

	if relay_config == null:
		relay_config = _instance_refcounted(
			CHAT_RELAY_CONFIG_SCRIPT, "the relay configuration", []
		)

		if relay_config == null:
			return DotResult.success(null)

				# LAYERED: a bare `DotConfig.new()` has only defaults, so the environment and command
				# line did nothing and nothing errored. Only on the config built here; a host's own
				# config is not re-layered over a deliberate choice.
		var layered: Variant = relay_config.call("load_layered", RELAY_CONFIG_PATH)

		if layered is DotResult and not (layered as DotResult).ok:
			DotLog.warn(CHANNEL, "the chat relay configuration is not usable", {
				"why": str((layered as DotResult).error),
			})
			return DotResult.success(null)

	if not bool(relay_config.get("enabled")):
		return DotResult.success(null)

	if backbone == null:
		# **Found, not handed over.** A backbone client is built by whatever owns the
		# server's credential, and a relay built during module load exists before any host
		# could assign one.
		backbone = DotRegistry.get_service(&"dot_backbone_client")

	if backbone == null:
		# Info and success, not a failure. A fleet that exports the relay's switch and
		# holds a credential for only some of its boxes is the ordinary case, and a red
		# line on every boot of the others is how a real warning stops being read.
		DotLog.info(
			CHANNEL,
			"the chat relay is on but there is no backbone client, so it will not start",
			{"fix": "give this server a scoped integration token"}
		)
		return DotResult.success(null)

	var made := _instance(CHAT_RELAY_SCRIPT, "the chat relay")

	if made == null:
		return DotResult.success(null)

	relay = made
	relay.name = "ChatRelay"
	relay.set("router", chat)
	relay.set("config", relay_config)
	relay.set("client", backbone)
	relay.set("permission_fn", Callable(self, "_uid_has_permission"))
	relay.set("command_fn", Callable(self, "_run_relayed_command"))
	relay.set("commands_fn", Callable(self, "_relay_command_document"))

	add_child(relay)

	var started: Variant = relay.call("start")

	if started is DotResult and not (started as DotResult).ok:
		remove_child(relay)
		relay.queue_free()
		relay = null
		return started

	relay.connect("site_command", _on_site_command)

	# [b]Tell the clients.[/b] A player whose lines already reach a page they are looking at
	# does not need a chat box in front of the game, and a player whose lines reach nothing
	# but this server needs one badly. Only the server knows which.
	if server != null and server.chat != null and server.chat.has_method("watch_relay"):
		server.chat.call("watch_relay", relay)

	return DotResult.success(relay)


func _uid_has_permission(uid: String, flag: String) -> bool:
	if server == null or server.admins == null:
		return false

	return server.admins.uid_has_permission(uid, flag)


func _run_relayed_command(
	uid: String, command: String, args: PackedStringArray, source: int
) -> void:
	if server == null:
		return

	for reply in server.run_command_as_uid(uid, command, args, source):
		DotLog.info(CHANNEL, "relayed command reply", {"uid": uid, "line": reply})


func _on_site_command(uid: String, command: String, allowed: bool) -> void:
	# Audited either way. A refusal is the half worth having a record of: it is somebody
	# trying to drive the server from a web page without the rights to.
	if server != null and server.audit != null:
		server.audit.record("relay_command", "web:%s" % uid, command, {"allowed": allowed})


## What this server accepts, for the site's menu.
##
## A method, not a lambda: the relay re-reads it on every publish and the table changes when a module loads.
func _relay_command_document() -> Array[Dictionary]:
	if server == null or server.console == null or relay_config == null:
		return []

	return server.console.command_document(int(relay_config.get("command_source")))


## The channels this game talks on. An [Array] of `DotChatChannel`.
##
## No default on purpose: channels the designer did not choose can expose a private conversation.
func _chat_channels() -> Array:
	return []


## What a line may be. A `DotChatRules`, or null to take dot-chat's own defaults.
func _chat_rules() -> Object:
	return null


## The voice format, which both ends must agree on exactly. A `DotVoiceConfig`.
func _voice_config() -> Object:
	return null


## `DotVoiceRouter.Channel`. Zero is that enum's first entry, which is ALL.
func _voice_default_channel() -> int:
	return 0


## Where somebody is standing, for a proximity channel.
##
## The simulated state, not the node: a player in a vehicle is reparented into the seat.
func _position_of(_peer_id: int) -> Vector3:
	return Vector3.ZERO


## Whether [param listener] can hear [param speaker] through the world, once the distance test passed.
##
## Both routers ask it, for chat and voice, so nobody reads what they could not hear. The level's question, not the addons': they know a radius, not walls. True (the radius is the whole answer) is the default.
func _can_hear(
	_listener_peer: int, _speaker_peer: int, _listener_at: Vector3, _speaker_at: Vector3
) -> bool:
	return true


## Whether a peer can receive a message yet, asked by [method add_peer] before it sends the chat backlog.
##
## True by default. A game whose clients build their scene AFTER seating answers false (else one "Node not found" per line) and calls [method send_backlog] when the peer is ready.
func _peer_can_receive(_peer_id: int) -> bool:
	return true


## What each live admin ability does in this game: `{DotModTools.ACTION_*: Callable}`.
##
## Each is `func(id: StringName, args: Dictionary) -> DotResult` with `id` the userid string; keys are plain strings (`"noclip"`). Empty means no live tools but teleport. Called once; look the player up per call, not capture one.
func _mod_abilities() -> Dictionary:
	return {}


## Why this game refuses the abilities it has no handler for: `{"noclip": "…"}`.
func _mod_unsupported() -> Dictionary:
	return {}


## Whether [method _mod_position] and [method _mod_teleport] mean anything here.
##
## Off by default: the defaults would answer "cannot find where you are" to every bring.
func _mod_can_teleport() -> bool:
	return false


## Where a player is, for bring, goto, send and return. Vector2 or Vector3, or null.
func _mod_position(_id: StringName) -> Variant:
	return null


func _mod_teleport(_id: StringName, _to: Variant) -> void:
	pass


## A last chance to set the commands' `alive_fn`, `team_fn`, `items_fn`, `names` or
## `permissions` before they are bound. `commands` is a `DotModToolCommands`.
func _mod_configure_commands(_commands: Object) -> void:
	pass


## A last chance to configure the tools themselves (`goto_standoff`, `persist_on_respawn`) before they enter the tree or any command is bound.
##
## An [Object] rather than `DotModTools`, since dot-moderation is loaded by path; a subclass that configures it may cast.
func _mod_configure_tools(_tools: Object) -> void:
	pass


## The session behind a live-tools id.
func _mod_session(id: StringName) -> DotClientSession:
	if server == null or not String(id).is_valid_int():
		return null

	return server.session_by_userid(String(id).to_int())


## A player's immunity, from their session. A player who has left has none.
func _mod_immunity(id: StringName) -> int:
	var session := _mod_session(id)
	return session.immunity if session != null else 0


## The name this services layer keeps its files under. Override for a nicer filename.
func _services_name() -> String:
	return "game"


## Who a peer is, for a PUNISHMENT: the durable account uid.
##
## Not what [method _key_of] gives dot-chat: a punishment must survive a reconnect, or a gag ends when the player reconnects.
func _subject_for_peer(peer_id: int) -> String:
	var session := _session_for(peer_id)

	if session == null:
		return ""

	# By path, like everything else here: dot-moderation is not a dependency.
	var subject: Variant = load("res://addons/dot_moderation/core/dot_punishment_subject.gd")

	if subject != null and subject.has_method("for_uid"):
		return str(subject.call("for_uid", session.uid()))

	return "uid:%s" % session.uid()


## The key a chat line is attributed to. The session's userid, as a string.
##
## Not the account uid: two guests behind one device id share it, putting one's words under the other's name.
func _key_of(peer_id: int) -> String:
	var session := _session_for(peer_id)
	return str(session.userid) if session != null else ""


func _name_of(peer_id: int) -> String:
	var session := _session_for(peer_id)
	return session.display_name if session != null else "player %d" % peer_id


func _is_admin(peer_id: int) -> bool:
	var session := _session_for(peer_id)
	return session != null and session.is_admin()


## Everybody who is actually in the game, which is dot-server's own answer.
func _chat_peers() -> PackedInt32Array:
	var out := PackedInt32Array()

	if server == null:
		return out

	for session in server.playing_sessions():
		out.append(session.peer_id)

	return out


## One accepted line, to whoever may hear it.
##
## Through the game's own link, since chat rides the game's wire; a second path would be a second set of rules.
func _send_chat(wire: Dictionary, recipients: PackedInt32Array) -> void:
	if link == null or not link.has_method("send_chat"):
		return

	for peer_id in recipients:
		link.call("send_chat", int(peer_id), wire)


func _send_voice(peer_id: int, payload: PackedByteArray) -> void:
	if link != null and link.has_method("send_voice"):
		link.call("send_voice", peer_id, payload)


func _session_for(peer_id: int) -> DotClientSession:
	return server.session_of(peer_id) if server != null else null


func _scoped(base: StringName) -> StringName:
	return base if service_scope == &"" else StringName("%s:%s" % [base, service_scope])


func _on_command_entered(
	peer_id: int, command: String, args: PackedStringArray, _raw: String
) -> void:
	command_entered.emit(peer_id, command, args)


func _on_message_accepted(message: Object, _recipients: PackedInt32Array) -> void:
	if message == null:
		return

	var wire: Variant = message.call("to_dictionary") if message.has_method("to_dictionary") else {}
	said.emit(int(message.get("sender_peer")), wire if wire is Dictionary else {})


## Whether this person may join at all. dot-server's admission runs first; this is the second gate.
## Checked HERE, not at connect, because dot-server's mute dies with the session and a muted player would reconnect and talk.
func check_admission(session: DotClientSession) -> DotResult:
	if moderation == null or session == null:
		return DotResult.success(null)

	var checked: Variant = moderation.call(
		"check_admission", str(session.userid), session.address
	)

	return checked if checked is DotResult else DotResult.success(null)


## A voice frame from the wire. What [DotGameModule] wires the bridge's relay to.
##
## The speaker is stamped here from the transport's peer: an id inside the payload is a claim any client could forge.
func relay_voice(speaker_peer: int, bytes: PackedByteArray) -> void:
	if voice != null:
		voice.call("relay", speaker_peer, bytes)


## Somebody typed a line. Everything about what it means is dot-chat's.
func say(peer_id: int, channel_id: StringName, text: String) -> DotResult:
	if chat == null:
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "This server has no chat.")

	var sent: Variant = chat.call("submit", peer_id, channel_id, text)
	return sent if sent is DotResult else DotResult.success(null)


## A client is in the game: it may be heard, and — if it can receive yet — it is handed
## the backlog. See [method _peer_can_receive].
func add_peer(peer_id: int) -> void:
	if voice != null:
		voice.call("add_peer", peer_id)

	if _peer_can_receive(peer_id):
		send_backlog(peer_id)


## The chat backlog, to one peer, so a newcomer joins a conversation, not a silence.
##
## Called by [method add_peer] when [method _peer_can_receive] says yes, or by the game once the peer is ready. Once per seating: a second call sends it twice.
func send_backlog(peer_id: int) -> void:
	if chat == null:
		return

	for row in chat.call("backlog_for", peer_id):
		_send_chat(row, PackedInt32Array([peer_id]))


## Everything the live tools hold about a person who has left. [DotGameRoster] calls it.
func forget_player(id: StringName) -> void:
	if mod_tools != null:
		mod_tools.call("forget", id)


## A player came back with a new body. A game calls this from its own spawn path, so the
## tools can switch a freeze or a noclip off and put god back on — see
## `DotModTools.respawned`.
func mod_player_respawned(id: StringName) -> void:
	if mod_tools != null:
		mod_tools.call("respawned", id)


func remove_peer(peer_id: int) -> void:
	if voice != null:
		voice.call("remove_peer", peer_id)

	if chat != null:
		# The rate limiter's and the repeat detector's memory of this peer. Without it a
		# reconnecting player inherits whatever the last holder of that peer id had been
		# saying, and is told they are repeating themselves on their first line.
		chat.call("forget", peer_id)


func _exit_tree() -> void:
	# The commands were bound to the server's console, which outlives this layer. Left
	# there, the next `noclip` calls into a freed object.
	if mod_commands != null and server != null and is_instance_valid(server) and server.console != null:
		mod_commands.call("unbind", server.console)
	mod_commands = null


## Loads a script by path and instances it as a [Node], or null with a line.
##
## Absent is a configuration, not a failure: a project without dot-voice has players who do not talk.
func _instance(path: String, what: String) -> Node:
	if not ResourceLoader.exists(path):
		DotLog.info(CHANNEL, "%s is not installed in this build, so it is skipped" % what, {
			"path": path,
		})
		return null

	var script: Variant = load(path)

	if script == null or not (script is GDScript):
		DotLog.warn(CHANNEL, "%s would not load" % what, {"path": path})
		return null

	var made: Variant = (script as GDScript).new()

	if not (made is Node):
		DotLog.warn(CHANNEL, "%s is not a Node" % what, {"path": path})
		return null

	return made as Node


## The same, for something that is not a Node. [param args] is passed to `new()`.
func _instance_refcounted(path: String, what: String, args: Array) -> Object:
	if not ResourceLoader.exists(path):
		DotLog.info(CHANNEL, "%s is not installed in this build" % what, {"path": path})
		return null

	var script: Variant = load(path)

	if script == null or not (script is GDScript):
		DotLog.warn(CHANNEL, "%s would not load" % what, {"path": path})
		return null

	return (script as GDScript).callv("new", args)


func describe() -> Dictionary:
	return {
		"chat": chat.call("describe") if chat != null else {},
		"voice": voice.call("describe") if voice != null else {},
		"moderation": moderation.call("describe") if moderation != null else {},
		"mod_tools": mod_tools.call("describe") if mod_tools != null else {},
		"relay": relay != null,
		"punishments_loaded": punishments_loaded,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	for layer in [chat, voice, moderation, mod_tools]:
		if layer != null and layer.has_method("describe_lines"):
			out.append_array(layer.call("describe_lines"))

	if moderation != null:
		out.append("punishments  %s" % (
			"loaded" if punishments_loaded else "STILL LOADING — nothing is enforced"
		))

	out.append("relay        %s" % ("on" if relay != null else "off"))
	return out
