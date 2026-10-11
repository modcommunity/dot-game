# dot-game

The wiring every server game repeats, once: resolve the game, build the netcode and its bridge, identity then services, a roster, one authoritative tick, and a teardown in reverse. It holds no rules; those are dot-match's and dot-objective's.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to this addon.

**dot-core, dot-server and dot-net are required.** Everything else a game touches (a map director, a vote, dot-chat, dot-voice, dot-moderation, dot-ui, dot-platform) is duck-typed or loaded by path and named nowhere.

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | `DotGameModule`, `DotGameNetcode`, `DotGameRoster`, `DotGameChatClient`: why it exists, what belongs here, what is fatal, teardown order, `session_fn`, schema refusal, `report_map`, the Tab board, the suite |
| [docs/services.md](docs/services.md) | `DotGameServices`: build order, loading by path, the live tools, the hooks, hibernation |
| [docs/history.md](docs/history.md) | the bugs, and how each looked |

## Layout

| Path | What |
| --- | --- |
| `addons/dot_game/core/` | `DotGameModule` (the `DotModule` a game subclasses), `DotGameContent` |
| `addons/dot_game/net/` | `DotGameNetcode`: the dot-net manager with the four settings every game had, and `refuse_peer` |
| `addons/dot_game/runtime/` | `DotGameRoster`, `DotGameServices`, `DotGameChatClient` |
| `addons/dot_game/dot_game_api.gd` | the API level (`LEVEL`, `OLDEST`); the bump rule is on `DotAddonApi` |
| `examples/game_selftest.tscn` | the suite; `examples/fixtures/` the module, bridge, identity and services it loads |

## Running and testing

- The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `timeout 200 godot --headless --path . res://examples/game_selftest.tscn`.
- **A new `class_name` here breaks every consumer until each is re-imported.** Every converted game links this addon. [history](docs/history.md#a-new-class_name-broke-a-game-three-repositories-away)
- The suite runs with none of the addons the base loads by path; the wire half is in the games' suites. [design](docs/design.md#the-suite)
- Fixtures await a frame in `setup()` on purpose; keep them suspending. [design](docs/design.md#the-suite)

## Rules that bite

- Something belongs here only if every game would write it the same way with only class names changed; rules, rotations and objectives do not. [design](docs/design.md#the-split-and-where-the-line-is)
- Seat from `client_spawn`'s `userid`, never `peer_id`; `DotGameRoster.session_fn` lets the suite prove it. [history](docs/history.md#the-line-two-games-got-wrong)
- Only a missing game object, a netcode that will not start, or a refused `_game_load` (which unwinds) is fatal; identity and services failures are logged. [design](docs/design.md#what-is-fatal-and-what-is-not)
- Teardown runs signals, roster, services, identity, bridge, manager; `DotGameRoster.clear()` notifies nobody. [design](docs/design.md#teardown-is-in-reverse-and-the-order-is-not-cosmetic)
- A dot-platform module this module loaded (`_loaded_platform`) is unloaded in `_teardown`, before the identity layer. [design](docs/design.md#teardown-is-in-reverse-and-the-order-is-not-cosmetic)
- Moderation is built before chat and voice, because they look up `dot_mute_source` when they start. [services](docs/services.md#moderation-first)
- dot-chat, dot-voice, dot-moderation, dot-ui and dot-platform are never dependencies: load by path, drive by `set`/`call`, skip a missing one with a line. [services](docs/services.md#why-it-names-none-of-the-three-addons-it-drives)
- Mod-tool commands are unbound in `_exit_tree`; the roster calls `forget_player` and `forget_voter` as somebody leaves. [services](docs/services.md#the-live-tools-are-a-fourth-layer-and-the-verbs-are-the-subclasss)
- A new hook defaults to exactly the old behaviour. [services](docs/services.md#the-hooks-the-first-converted-game-needed)
- Anything set on the server that an older dot-server may lack (`set_current_map`, the board properties) is duck-typed behind `has_method` / `in`; detach only a hook this module set. [design](docs/design.md#the-tab-boards-server-half)
- `DotGameChatClient` also draws dot-server's own `system` and `admin` lines from the client link (never a player's line: that is the bridge's); a game that reads the link itself sets `server_lines = false`, and a game with its own box calls `draw_server_line`. [design](docs/design.md#dotgamechatclient-the-clients-half)
- `describe()` overrides merge `super.describe()`. [history](docs/history.md#two-bugs-in-dot-server-the-first-suite-found)
- A peer whose dot-net schema is refused is kicked through `DotGameNetcode.refuse_peer`. [design](docs/design.md#a-client-whose-message-schema-cannot-play-is-disconnected-here)

## Where a game plugs in

| To change | Where |
| --- | --- |
| The game itself | `DotGameModule._game_service()`, `_game_load()`, `_game_hibernation()`, `_can_tick()` |
| Identity | `_make_identity()` returning dot-platform's `DotPlatformIdentity`; `_wants_platform_module()` |
| Chat, voice, moderation | a `DotGameServices` subclass: channels, rules, voice config, `_can_hear`, `_peer_can_receive` |
| The live admin tools | `_mod_abilities()`, `_mod_unsupported()`, `_mod_can_teleport()` / `_mod_position()` / `_mod_teleport()`, `_mod_configure_commands()`, `_mod_configure_tools()`; call `mod_player_respawned(id)` from the spawn path |
| The map the server lists | `report_map(map_id)`, on every change |
| Tab board columns and teams | `_game_board_fields`, `_game_board_extra` |
| The client's chat and voice | `DotGameChatClient`: `channels`, `line_colours`, `max_length`, `voice_config`, `window_settings`, `voice_method`, `server_lines`, `attach(bridge)` |
| Who a peer is, for a lobby | `DotGameRoster.session_fn` |

## Open

- **arena, g2gfast and hungario are not converted** to `DotGameModule` or `DotGameServices`, and still carry their own copies of both (including `_refuse_peer`). **Convert arena first**: it is the reference game and the smallest of the hand-written modules, and its `headless_match` must still play a whole deathmatch before touching the others. Not started.
- **game-playground is half-way**: its services subclass `DotGameServices` (hook overrides only, base mod tools switched off), but its module is still a `DotModule`, deliberately for now; why is in [game-playground/docs/simulation.md](../game-playground/docs/simulation.md#the-server-module).
- Every game written since (the `mg-*` games, game-hide-n-seek, game-zombie-zone) is on both bases.
