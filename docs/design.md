# Design

Why `DotGameModule`, `DotGameNetcode` and `DotGameRoster` are shaped this way. `DotGameServices` and the hooks are [services.md](services.md); the bugs are [history.md](history.md).

## Why this exists, measured rather than asserted

Five games were written before it. Their modules were 837 to 1,816 lines, and a diff of any two of them is almost entirely renamed types: `_build_netcode`, `_build_identity`, `_build_services`, `_build_vote`, a net bridge, `_joined`, `_tick`, `_on_client_spawn`, `_on_client_disconnected`, `_build_query_provider`, `_register_game`. Two of the `_build_identity`s differed by one assigned property and a variable name, comments included.

That much duplication is a nuisance. What makes it a *bug* is that **two of the five got the same line wrong**: they read `peer_id` off `client_spawn`, which carries `userid` and `name`, and nobody ever joined those dedicated servers ([history](history.md#the-line-two-games-got-wrong)). Five copies of a thing is five chances to write it wrong and five places to fix it. The argument for a base class here is not tidiness, it is that there is one line to be right.

A game written on this base from the start (mg-buses-from-hell, the first) has a module of about ninety lines and a services layer of about sixty, against the hand-written games' 837 to 1,816 and 557 to 718.

## The split, and where the line is

**This holds no rules.** Whether a round has ended, what a team is, what the objective is and who won are dot-match's and dot-objective's. A game may use neither and still use this.

The test for whether something belongs here: **would every game write it the same way with only the class names changed?**

- The netcode's four non-obvious settings: yes. Every game got them identically right because each copied the last.
- The order identity comes up in relative to services: yes, and the reason is a real bug (a backbone assigned after `setup` is one the relay has already decided it does not have).
- A map rotation: **no.** Some games have one, some do not, and the ones that do wire it differently. So `DotGameRoster.follow()` will tell a rotation when somebody leaves, through duck-typing, and this addon does not know what a rotation is.

The identity layer was the last extraction, and it is not here: it is dot-platform's `DotPlatformIdentity`, because every type it builds is dot-platform's dependency and none is this addon's. A subclass returns one from `_make_identity()`. With it on, `_wants_platform_module()` stays true and this module loads dot-platform's module beside it.

## What is fatal and what is not

`_module_load` refuses on two things and shrugs at everything else:

| | |
| --- | --- |
| No game object under `_game_service()` | **Fatal.** A module that loads and does nothing leaves a server admitting players into a match that does not exist, and the symptom is players who connect and never spawn. |
| The netcode would not start | **Fatal**, for the same reason. |
| The identity layer failed | Logged. A server where everybody is a guest is a configuration. |
| The services layer failed | Logged. A server with no chat is a server nobody stays on, but it *is* a server, and taking the game down because a punishment file was unreadable makes a permissions mistake cost the players what they came for. |
| `_game_load()` refused | Fatal, **and it unwinds**: otherwise a module that reported it could not load leaves a ticking netcode and an open link under a node the host is about to free. |

## Teardown is in reverse, and the order is not cosmetic

Services hold a callable the bridge calls; the roster holds subsystems it notifies; the netcode is what everything else attached to. Tearing the netcode down first leaves each of the others calling into a freed object for as long as it takes them to notice, which is never. `_teardown` goes: signals, roster, services, identity, bridge, manager.

`DotGameRoster.clear()` is deliberately **not** "remove everybody". A module being torn down is not a room emptying: the subsystems that would be notified are going away in the same breath, and calling `remove_peer` on a freed one is the crash the ordering exists to avoid.

**The platform module a game loaded goes with it.** `_build_identity` loads dot-platform's module when none is loaded and remembers that it did (`_loaded_platform`); `_teardown` unloads it before freeing the identity layer whose hub it holds. Otherwise it outlives the game and the next player is admitted through a freed hub ([history](history.md#the-platform-module-outlived-the-game)).

## `session_fn` exists so the bug above can be asserted

`DotGameRoster.session_fn` is injectable, and the reason is narrow: the bug this addon exists to prevent is reading the **wrong field** off the spawn event, and a test that cannot substitute the lookup cannot distinguish "read the right field" from "found nothing either way", which is exactly what the two broken games looked like from outside. With it substituted, `examples/game_selftest.gd` feeds in an event carrying only `peer_id`, with a session that a `peer_id` read *would* find, and asserts that nobody is seated.

A game with its own session source (a lobby that seats people who never connected) gets the same hook for free.

## A client whose message schema cannot play is disconnected here

dot-net compares the two ends' message tables when the client's arrives and refuses a pair where either lacks a type the other REQUIRES (dot-net's [Two builds on one wire](../../dot-net/docs/wire.md#two-builds-on-one-wire)), but it owns no socket, so all it can do is emit `peer_schema_refused`. `DotGameNetcode.build` connects that to `refuse_peer`, which kicks the session with dot-net's sentence as the reason and its `DotError` as the cause, so the client reads `CODE_VERSION` and a line that says who has to update. `refuse_peer` is public and static for a game that builds its own manager; the games whose modules are not on `DotGameModule` (arena, g2gfast, hungario, playground) carry the same three lines as `_refuse_peer`. dot-server-deploy's `smash_client` drives it over a real socket in a delivered game.

## `report_map`, because the map is the game's to say

`DotGameModule.report_map(map_id)` hands the game's own map to `DotGameManager.set_current_map`, which A2S, DQP and the backbone report print in their map field. It is duck-typed (`has_method`), so a game built against this addon still loads on a dot-server from before `set_current_map` and is listed under its own name there, with one INFO line. The server forgets the map whenever a game unloads, so a game that changes map calls it on every change, not once at load.

## The Tab board's server half

dot-server sends a client holding its scoreboard the roster (name, score, ping, time connected) and asks `scoreboard_fields(session)` and `scoreboard_extra()` for the game's own columns and teams. `_game_board_fields` and `_game_board_extra` are those two, overridable, attached after `_game_load` succeeds and detached first thing in `_teardown`, so a game module overrides a method and never touches the server. Both are set with `server.set` behind an `in` check, because a game pack runs on whatever dot-server the host has and one from before the roster has neither property. Detach only clears a hook this module set (`get_object() == self`). dot-menu's `DotMenuScoreboard` draws the result.

## `DotGameChatClient`, the client's half

Five games had a client chat file each that differed in nothing but their own class names: a `DotChatWindow` on its own canvas layer above the HUD, a `DotVoiceManager` with push-to-talk on V, an offline echo, and a bridge's `chat_received` / `voice_arrived` / `hello_received` drawn and played. It is one node here. A game sets `channels` (what Y and U open), `line_colours` (every channel a line can arrive on, admin and whisper included), `max_length` from its own chat rules and `voice_config` from its own voice format, and calls `attach(bridge)` or `attach(null)` offline. dot-ui and dot-voice are loaded by path like everything `DotGameServices` drives, so a build without one gets the other half and parses. The bridge is duck-typed: `ask_say(channel, text)`, `send_voice(bytes)` and the three signals.

**It also draws what the server itself says.** dot-server's chat manager (the vote between games, "Ada joined the game.", an admin's `say`, a chat command's reply) sends a `chat.line` envelope on the shell's client link, which lands on `DotClientLink.chat_received` and never on the game's bridge. Eight games read only the bridge and showed none of it. On `attach(bridge)` the box finds the link in the registry (`dot_client_link`) or takes `link` if set, and draws the server's own kinds only, `system` and `admin`: what players say is the bridge's to deliver (and on a module that also lets dot-server's player chat through, drawing it from both would show it twice), chat's `state` is not a line, and a payload in dot-chat's shape (`m`) is the bridge's. `DotGameChatClient.draw_server_line(box, payload)` is the same drawing as a static, for a game with its own box (buses, playground). A game that reads the link itself sets `server_lines = false`. The connection is a method on the box so it goes when a game switch frees it; the link is the shell's and outlives every game. `window_settings` sets the box's properties before it builds (smash's six rows), and `voice_method` names a bridge's client voice call when `send_voice` is already the server's.

**It honours the player's own block list (`sm`).** On `_ready` it finds dot-chat's `DotChatSelfMute` (registry `dot_self_mute`, else made by its script path; none without dot-chat) and keeps it as `self_mute`: a routed line whose sender `is_muted_line(wire)` names is not drawn (by sender key against the roster, then by name), and the voice manager it builds is handed over with `attach_voice`, which mutes each muted player's peer. `!sm` / `/sm` never reach the bridge because the box (`DotChatWindow`) runs them before it emits anything. `self_mute_enabled = false` turns it off.

**Voice opens on the first press, and the server can turn it off.** `attach` sets the manager's `send_fn` and does not open the microphone; `_process` hands dot-voice's `update_talk(held)` the `dot_voice_talk` action (created on `talk_key` when no key table bound it), and the first press opens it. That press is the player's consent and, in a browser, the moment the permission prompt appears; an attach that opened it asked every browser for a microphone as the game loaded. The manager follows the replicated `sv_voice_enable` on the shell's link (`follow_cvars`), `voice_available_changed` tells a HUD, and the manager is published as `dot_voice_client`, which dot-menu's applier binds for the voice rows and hides them while voice is off. `DotGameModule._build_services` binds `sv_voice_enable` and `sv_voice_mode` on the services' router through its own `add_cvar`, replicated, so they go when the module unloads and a value from `content.yml` set before the load wins. `positional_voice` without `voice_position_fn` is flat: positional with no positions put every voice at the world's origin.

## `DotGameClient`, the platform layer every client wires

Thirteen game clients each wired the same platform pieces by hand, and each missed different ones: counted on 2026-10-18, six had no loading cover, five no Escape menu, nine no settings, nine no console, eight no chat box, six no render warm-up. What a player could rely on (Escape, the console under it, Tab, M, the theme following the HUD) depended on which game they were in. The client half of every game had converged on one shape, so it is written once.

**A node the client root adds, not a base class.** The roots are `Node`, `Node2D` and `Node3D`, and a script has one base: a `DotGameClient` base would force every game's scene onto one type, or need three copies. It is a child, configured by properties and two overridable builders (`_make_gate`, `_make_settings`), the shape `DotGameChatClient` already has.

**Two phases, because the cover must be first and the settings last.** `_ready` (the moment the root adds it) resolves the host (`host_ref`, else the parent), finds the shell's link (`dot_client_link`), decides `offline` (no link, `force_offline`, or `--offline`) and puts dot-core's `DotLoadGate` under the host, so its cover is the first thing on screen and its camera check and `DotLoadGate.of` see the game. `spawned_fn` is held as the `spawned` requirement; the game adds its own holds on `gate`. `setup()` comes after the game has built its HUD, chat box and whatever its settings bind to: it builds the settings (the game's `DotMenuSettings` subclass, else dot-menu's stock one by path), the console (dot-console's `DotConsoleKit.build`, by path), sets the menu's `busy` to the chat line or `busy_fn`, hands the HUD to `follow_hud` with the game's accent, sets the menu's `scoreboard_action` (making `dot_game_scoreboard` on Tab when the game's key table has no row), feeds the board from the link connected or from `board_snapshot_fn` offline, and wires M through `use_maps` (with the server not asked when played `--offline` beside a link).

**One input block.** `is_input_blocked()` is true while the cover is up, a menu or the console is open, the chat line is being typed or `busy_fn` says the game's own line has the keyboard, and `input_blocked_changed` fires when that changes (from the gate's and the chat's signals, and polled each frame because `busy_fn` cannot signal). A game suspends its samplers on it. Games had wired the menu's state and forgotten the chat's, or the other way round, so a sentence typed into chat walked the player.

**The pointer.** Captured at `setup()` on a desktop, freed when a menu opens, taken back when the last closes (desktop, nothing busy) or on the next click in the game (a browser refuses a capture that is not a click). `capture_pointer = false` for a 2D game or one that keeps its pointer.

**Why `DotWeb.sync_filesystem()` is here.** The settings store flushes its own writes; a game's other `user://` writes (progress, a replay) did not, and a tab closed before the next flush lost them. The node flushes on the close request, on pause (a phone backgrounding the tab) and when it leaves the tree.

**The page guard (browser only).** Browsers reserve Ctrl+W, Ctrl+T/N and Ctrl+Tab and a page cannot cancel them, so a player holding Duck (Ctrl) and pressing forward closes the tab mid-game. `_ready` installs, once per page behind the `window.__dotTabGuard` flag (a second client or a reconnect stacks nothing), two listeners: `fullscreenchange` calls `navigator.keyboard.lock()` / `unlock()` where the API exists, which is here and not only in dot-menu's applier because 9 of the 14 games never build the applier; and `beforeunload`, which prompts only while `armed`. The client arms it while `is_in_live_game()` (online and the link's `is_connected_to_server()`), polled in `_process`, and disarms it on a drop, a leave and `_exit_tree`, so the main menu and a normal leave never prompt. Code that navigates on purpose (dot-server-deploy's shell reloads the page to apply an update) must call `clear_leave_guard()` first or the player is asked about something the game chose. Off the web it is a no-op; `web_eval_fn` is the suite's seam. It uses `DotWeb.eval`, so a page whose CSP refuses `eval` gets neither half (dot-menu's call has the same limit).

**What stayed in the games.** The HUD, the keys beyond Tab and M, the board's columns and title, the samplers and what they drive, the camera, and the chat box's channels and voice format (`DotGameChatClient`). Each differs by game, so none passes the test above.

The suite drives it through stand-ins (`examples/fixtures/test_client_settings.gd`, `test_console_kit.gd`, `test_chat_box.gd`), and once in a build with neither dot-menu nor dot-console, which must be quiet and still give the cover, the input block and the pointer. The real menu is checked in dot-game-template's and mg-look-at-me's suites.

## Still loading: the server knows who is behind a cover

A client behind dot-core's `DotLoadGate` cover freezes its own player and cannot see, but online the server did not know: its hazards (a server-side monster, a trap, a vehicle) hurt and eliminated a player who was still loading, and a round counted them. `DotGameModule.is_loading(seat)` is that knowledge, and `can_be_harmed(seat)` (overridable, default "not loading") is the question a hazard asks; both have peer-id twins (`is_peer_loading`, `can_peer_be_harmed`), because most server game code holds the peer. A game object that declares `var peer_loading_fn: Callable` is handed `is_peer_loading` before `_game_load` and has it cleared at unload, so a hazard inside the game asks without holding the module. `loading_changed(seat, loading)` fires both ways; `describe()` lists the loading seats.

**When a seat is loading.** From the spawn event (when the roster seats it) until its client says its cover lifted; again from a map change until the client says so again. `report_map` with a different map is a map change (the first report is not, and the same map again is nothing); `mark_reloading()` is the same for a change `report_map` does not see. A bot or a listen server's own player (`DotClientSession.local`) is never loading, nor is anybody the roster does not hold.

**The client's half is automatic.** `DotGameClient` sends `DotGameRoster.COVER_KIND` (`game.cover`, `{"covered": bool}`) on its gate's `opened` and `closed`, connected only (`report_loading = false` turns it off). A client not on it calls the static `DotGameClient.report_cover(link, covered)` from its own cover's equivalents. It is a kind on dot-server's envelope rather than a new RPC (the RPC set is frozen; one more breaks every shipped client) or a message on the game's bridge (each game's own, so no base can send on it). The module registers the handler when it builds the roster and clears it at teardown; the kind stays advertised.

**Only the server starts a loading state, and the timeout bounds it.** A client may confirm a cover (covered true while loading) or end it (false); a cover report while loaded starts nothing, because a client that could make itself loading could make itself unharmable whenever it liked. It is remembered for `reload_grace_sec` so a client that heard about a map change and covered before the server called `report_map` is not then released while still covered. Every loading state ends after `load_timeout_sec` (30, exported) with one `DotLog.warn`, counted from the server's own mark, so a client cannot extend it; that is what releases a client from before the kind, and one that joined before any game on this base loaded (a client sends only kinds the server advertised at its challenge). After a map change a client that does not say its cover went up within `reload_grace_sec` (5) counts as loaded: its game did not cover for that change, and leaving it unharmable in plain view for thirty seconds is worse than the race. The timeouts are polled in the module's `_physics_process`, before `_can_tick`.

**What a game adds is one line per hazard**, because who an entity is and what hurts it are the game's: `if not module.can_peer_be_harmed(peer_id): return` (or `peer_loading_fn`) where a hazard applies damage or eliminates, and where a round counts the living. dot-combat's `DotDamageResolver.adjust` and dot-match's `DotRulesElimination.alive_fn` are the natural places for a game using them, but both are keyed on the game's own entity ids, so the base cannot fill them in.

## `DotGameLink`: the RPC link outlives nothing

A game's one `@rpc` node has to sit at a fixed path under the server node (`Server/<NODE_NAME>`), because Godot routes an RPC by node path, so it cannot be a child of the bridge. Added with a bare `parent.add_child` it also outlived the bridge: after a module reload a second link existed, Godot renamed the live one `@Node@n`, and every RPC to a real client was dropped without an error (found in mg-deathrun, then mg-look-at-me; the template's bridge was the pattern twelve games copied). `DotGameLink.attach(link, parent, owner, name)` adds the link and frees it when `owner` (the bridge) leaves the tree. **It never calls `remove_child`**: the first local fix did, and logged "Parent node is busy adding/removing children" whenever the whole server tree was torn down at once, because the parent is itself mid-exit. It renames the link to a unique `retired_*` name, which frees the name at once, and `queue_free`s it. A same-named link already present (an unclean unload) is retired the same way. `retire(link)` is public for a game that frees a link by hand. Level 10. The suite's section 9 reloads twice and tears a whole server tree down with an engine `Logger` attached, so an engine ERROR fails it.

## The suite

`examples/game_selftest.tscn` boots a real `DotServer` with a real `DotModuleHost` and loads the fixture module by path, because that is how a game is loaded in production: `load_module` takes a path so an operator can name one in a config file, which means a pre-built instance with its fields already assigned is thrown away and a fresh one made with them null.

**The fixtures suspend on purpose.** `test_identity.setup()` and `test_services.setup()` both await a frame, because every real one reaches a network, and a skeleton that only worked with collaborators which happen to finish synchronously would pass a suite and fail on the first deployment. That is precisely what found dot-server's `load_module` bug ([history](history.md#two-bugs-in-dot-server-the-first-suite-found)).

The suite runs in a project with none of dot-chat, dot-voice, dot-moderation or dot-ui, which is the only path this addon can test and the one that has to be quiet and complete. What it cannot reach, and where that is checked instead:

| What | Checked by |
| --- | --- |
| A line crossing a wire, a gag silencing somebody | mg-buses-from-hell `examples/headless_net.tscn` |
| Mod-tool commands leaving and coming back over a module reload | mg-buses-from-hell `dedicated` |
| `_can_hear` wired into both routers, `_mod_configure_tools` across a game change | was the scratched lobby's `sandbox` and `dedicated`; no current suite is known to cover it |
| A chat line crossing a wire through `DotGameChatClient` | mg-prop-hunt `headless_net` |
| The schema refusal over a real socket in a delivered game | dot-server-deploy `smash_client` |
| `game.cover` crossing a real socket, a hazard skipping a loading player | no suite yet; the suite drives the envelope's dispatch and a stand-in link |
