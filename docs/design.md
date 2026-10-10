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
