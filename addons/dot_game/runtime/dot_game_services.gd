@tool
class_name DotGameServices
extends Node

## Chat, a website relay, moderation and voice, in the one order that works.
##
## [b]Five games wrote this and they wrote the same thing.[/b] 557, 559, 635, 716 and 718
## lines, and a diff of any two of them is renamed preloads, a different set of channels
## and a different voice range. The relay is identical in all five, including the comments;
## so is the admission check, the peer fan-out, the punishment subject, and — most
## importantly — the ORDER, which is the part that has a bug behind it:
##
## [b]Moderation is built FIRST because it publishes `dot_mute_source`, and both routers
## look that name up when they start.[/b] A chat router started first finds nothing, warns
## once, and then enforces no gag for the life of the server. The relay is built after chat
## because it wraps the router, and voice last because it is the only one that is optional
## per deployment.
##
## [codeblock]
## extends DotGameServices
##
## func _chat_channels() -> Array:
##     return [DotChatChannel.make(&"all", "All", DotChatChannel.Scope.EVERYONE)]
##
## func _position_of(peer_id: int) -> Vector3:
##     var player := _player_of(peer_id)
##     return player.controller.state.position if player != null else Vector3.ZERO
## [/codeblock]
##
## [b]Nothing here names dot-chat, dot-voice or dot-moderation.[/b] They are not
## dependencies of this addon and must not become them — a game with no chat is a
## legitimate game, and a script that so much as mentions an absent `class_name` fails to
## parse and takes everything referencing it down. So each layer is loaded BY PATH and
## driven through `set()` and `call()`, exactly as [DotGameModule] loads dot-platform's
## module, and a missing addon is a layer that is skipped with a line rather than a server
## that will not boot. What a subclass hands back — channels, rules, a voice config — it
## may name freely, because a game that configures chat is a game that has dot-chat.

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
## `user://` rather than `res://`: it is an operator's file on a running server, and an
## exported build cannot be written to. Absent is the normal case and costs nothing — the
## file layer is skipped and the environment and command line still apply, which is how a
## container turns the relay on with no file at all.
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
## An [Object] rather than a named class, so that dot-chat need not depend on dot-auth and
## this addon need not depend on either.
var backbone: Object = null

## Distinguishes two of these in one process — a server and a client, or a test.
var service_scope: StringName = &""

var punishments_loaded: bool = false

var _started: bool = false


# --- The sequence ----------------------------------------------------------

## Builds all four, in the order the class note sets out.
##
## [b]Not a coroutine, and that is enforced by its caller.[/b] [DotGameModule] awaits this
## — but dot-moderation's `load_all` is a coroutine only because a store MAY be an HTTP
## one, and the file store is not, so it runs to completion without suspending.
func setup(p_server: DotServer, p_game: Object, p_link: Object) -> DotResult:
	if _started:
		return DotResult.fail(DotError.CODE_STATE, "Already set up.")

	if p_server == null:
		return DotResult.fail(DotError.CODE_STATE, "Services need a server.")

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
## [b]By path, like the manager.[/b] dot-moderation is not a dependency of this addon, and
## `DotModToolCommands` binds to the console duck-typed so neither side names the other.
## What every ability does is [method _mod_abilities]; the rest — immunity, the audit
## record, who has what toggled on, clearing it on a respawn — is the tools' own, which is
## the reason a game gets it from here rather than writing it a sixth time.
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

	if "proximity_range" in config:
		voice.set("proximity_range", config.get("proximity_range"))

	if "max_bytes_per_second" in config:
		voice.set("max_bytes_per_second", config.get("max_bytes_per_second"))

	add_child(voice)
	return DotResult.success(voice)


# --- The website relay -----------------------------------------------------

## Joins this server's chat to its room on the website.
##
## [b]Every seam points at something that already existed.[/b] The backbone client is
## dot-auth's. The permission answer is dot-server's admin manager, through
## `uid_has_permission` — the method written for exactly this, deciding what somebody may
## do when they are not connected. The command runner is `DotServer.run_command_as_uid`,
## which builds a context with that uid's OWN flags rather than RCON's root.
##
## Nothing here is a new policy. A relayed command is checked against the same file, by the
## same flags, as the same person typing it in game.
func _build_relay() -> DotResult:
	if chat == null:
		return DotResult.success(null)

	if relay_config == null:
		relay_config = _instance_refcounted(
			CHAT_RELAY_CONFIG_SCRIPT, "the relay configuration", []
		)

		if relay_config == null:
			return DotResult.success(null)

		# LAYERED, and in one game it was not: a `DotConfig` that is merely `new()`d has
		# only its exported defaults, so `DOT_CHAT_RELAY_ENABLED=1` and
		# `--chat-relay-enabled` both did nothing and the whole addon was unreachable from
		# every documented route, with nothing erroring, because a disabled relay is a
		# legitimate configuration.
		#
		# Only on the config this builds. A config a host handed over is the host's, and
		# re-layering it would overwrite a deliberate choice with an environment variable
		# somebody set for a different server.
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
## A method rather than a lambda because the relay re-reads it on every publish: the table
## changes when a module loads, and a callable that closed over a list would publish the
## table as it was at boot, for ever.
func _relay_command_document() -> Array[Dictionary]:
	if server == null or server.console == null or relay_config == null:
		return []

	return server.console.command_document(int(relay_config.get("command_source")))


# --- What a subclass fills in ----------------------------------------------

## The channels this game talks on. An [Array] of `DotChatChannel`.
##
## [b]There is no sensible default and there must not be one.[/b] A deathmatch has a team
## channel and a sandbox has a proximity one; a game given channels it did not choose is a
## game whose players can hear a conversation the designer meant to be private.
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
## [b]The simulated state, not the node, in every game that has ever implemented this.[/b]
## A player riding a vehicle is reparented into the seat, so the node's global position is
## the seat's — right for a camera and wrong for everything asking where the *person* is.
func _position_of(_peer_id: int) -> Vector3:
	return Vector3.ZERO


## What each live admin ability does in this game: `{DotModTools.ACTION_*: Callable}`.
##
## Each callable is `func(id: StringName, args: Dictionary) -> DotResult`, where `id` is
## the player's userid as a string — the id [method _mod_session] resolves. The keys are
## plain strings (`"noclip"`, `"slay"`) so a subclass need not name dot-moderation either.
## Empty is a game with no live tools but the teleport verbs, and every command then
## answers with [method _mod_unsupported]'s reason.
##
## [b]Called once, at setup.[/b] A handler that reaches the world should look the player up
## each time, not capture one — the player a handler was built next to may have left.
func _mod_abilities() -> Dictionary:
	return {}


## Why this game refuses the abilities it has no handler for: `{"noclip": "…"}`.
func _mod_unsupported() -> Dictionary:
	return {}


## Whether [method _mod_position] and [method _mod_teleport] mean anything here.
##
## Off by default, and deliberately: a services layer that set both callables to the
## defaults below would answer "cannot find where you are" to every bring, which reads as
## a bug rather than as a game with no positions.
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


# --- The seams a subclass rarely needs to touch ----------------------------

## Who a peer is, for a PUNISHMENT: the durable account uid.
##
## [b]Deliberately not the same answer [method _key_of] gives dot-chat.[/b] A punishment is
## against a person who will come back, so it is keyed by something that survives a
## reconnect — otherwise a gag lasts until the gagged player presses reconnect, which is
## the first thing anybody who has been gagged tries.
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
## [b]Not the account uid.[/b] Two guests behind one device id share a uid, so keying by
## that puts the second person's words under the first person's name — game-simple-lobby
## found that with two clients in one process, and every count matched throughout.
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
## Through the game's own link, because chat rides the game's wire: a client that has a
## chat box has a bridge, and a second path through dot-server's chat manager would be a
## second set of rules to keep in step.
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


# --- What the module and the bridge call -----------------------------------

## Whether this person may join at all. dot-server's admission runs first; this is the
## second gate, and it is checked HERE rather than at connect because dot-server's own mute
## is two booleans on a session — and a session dies with its connection, so a muted player
## reconnects and talks.
func check_admission(session: DotClientSession) -> DotResult:
	if moderation == null or session == null:
		return DotResult.success(null)

	var checked: Variant = moderation.call(
		"check_admission", str(session.userid), session.address
	)

	return checked if checked is DotResult else DotResult.success(null)


## A voice frame from the wire. What [DotGameModule] wires the bridge's relay to.
##
## [b]The speaker is stamped here, from the peer the transport reported.[/b] A speaker id
## inside the payload is a claim, and without this any client can put words in any other
## player's mouth.
func relay_voice(speaker_peer: int, bytes: PackedByteArray) -> void:
	if voice != null:
		voice.call("relay", speaker_peer, bytes)


## Somebody typed a line. Everything about what it means is dot-chat's.
func say(peer_id: int, channel_id: StringName, text: String) -> DotResult:
	if chat == null:
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "This server has no chat.")

	var sent: Variant = chat.call("submit", peer_id, channel_id, text)
	return sent if sent is DotResult else DotResult.success(null)


## A client is in the game: it may be heard, and it is handed the backlog.
func add_peer(peer_id: int) -> void:
	if voice != null:
		voice.call("add_peer", peer_id)

	if chat == null:
		return

	# The backlog, which is the difference between joining a conversation and joining a
	# silence. dot-chat keeps it per channel and only for channels that asked for one.
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


# --- Building things this addon may not name -------------------------------

## Loads a script by path and instances it as a [Node], or null with a line.
##
## [b]Absent is a configuration, not a failure.[/b] A project without dot-voice is a
## project whose players do not talk, and refusing to load over it would cost them the game
## they came for.
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


# --- Reporting -------------------------------------------------------------

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
