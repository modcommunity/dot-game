# dot-game

The wiring every server game repeats, once: resolve the game, build the netcode and its bridge, identity then services, a roster, one authoritative tick, and a teardown in reverse. It holds no rules; those are dot-match's and dot-objective's.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to this addon.

**dot-core, dot-server and dot-net are required.** Everything else a game touches (a map director, a vote, dot-chat, dot-voice, dot-moderation, dot-ui, dot-platform) is duck-typed or loaded by path and named nowhere.

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | `DotGameModule`, `DotGameNetcode`, `DotGameRoster`, `DotGameChatClient`: why it exists, what belongs here, what is fatal, teardown order, `session_fn`, schema refusal, `report_map`, the Tab board, the suite |
| [docs/services.md](docs/services.md) | `DotGameServices`: build order, loading by path, the live tools, the hooks, hibernation |
| [docs/map-config.md](docs/map-config.md) | a game taking per-map settings (`DotGameMapConfig`, `_map_config_keys`, `DotGameClient.map_changed`) |
| [docs/config-binder.md](docs/config-binder.md) | a game's `*Config` made server-tunable: `DotGameConfigBinder`, strict boot, the cvars, the workbench kind, the yml diff |
| [docs/noblock.md](docs/noblock.md) | teammates passing through each other: `DotGameNoblock`, the module's `_noblock_*` hooks, `DotGameClient.add_noblock`, the `noblock` cfg kind |
| [docs/workbench.md](docs/workbench.md) | hosting dot-workbench: `DotGameWorkbench`, `DotGameClient.add_workbench` |
| [docs/history.md](docs/history.md) | the bugs, and how each looked |

## Layout

| Path | What |
| --- | --- |
| `addons/dot_game/core/` | `DotGameModule` (the `DotModule` a game subclasses), `DotGameContent` |
| `addons/dot_game/net/` | `DotGameNetcode`: the dot-net manager with the four settings every game had, and `refuse_peer`; `DotGameLink`, a game's RPC link attached under the server node and freed with its bridge |
| `addons/dot_game/runtime/` | `DotGameRoster`, `DotGameServices`, `DotGameChatClient`, `DotGameClient` (the client's platform layer), `DotGameWorkbench` (F9 tuning window and optional HTTP), `DotGameMapConfig` (per-map settings) |
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
- `DotGameChatClient` drops a self-muted player's line and hands its voice manager to the block list (dot-chat's `DotChatSelfMute`, by path); `!sm` is stopped by the box, before the bridge. [design](docs/design.md#dotgamechatclient-the-clients-half)
- `describe()` overrides merge `super.describe()`. [history](docs/history.md#two-bugs-in-dot-server-the-first-suite-found)
- `DotGameChatClient` never opens the microphone on attach: the first press of dot-voice's `dot_voice_talk` action does (`update_talk`), so a browser asks then. It follows the replicated `sv_voice_enable` and publishes its manager as `dot_voice_client`; `DotGameModule` binds `sv_voice_enable`/`sv_voice_mode` on the services' router. [design](docs/design.md#dotgamechatclient-the-clients-half)
- A headless server gets dot-cloud's `DotCloudAutoUpdate` (by path, one per process, parented to the `DotServer`, `start_auto_update`): it watches every delivered game's packs (`watched_packs`), counts `sessions()`, warns through `broadcast_message` and exits 75 after `shutdown`. A game built into the binary watches nothing. Contract: dot-cloud's `docs/auto-update.md`.
- Positional voice needs `voice_position_fn`; without it voices are flat.
- Only the server starts a loading state (a spawn, `report_map` with a new map, `mark_reloading`); a client's `game.cover` report can confirm or end one, never start one, and `load_timeout_sec` bounds it. [design](docs/design.md#still-loading-the-server-knows-who-is-behind-a-cover) [design](docs/design.md#dotgamechatclient-the-clients-half)
- A peer whose dot-net schema is refused is kicked through `DotGameNetcode.refuse_peer`.
- `DotGameClient` is a child the client root adds first in `_ready`, never a base class (roots are Node, Node2D and Node3D); `setup()` comes after the HUD, the chat and what the settings bind to. dot-menu and dot-console are loaded by path, never named. [design](docs/design.md#dotgameclient-the-platform-layer-every-client-wires) [design](docs/design.md#a-client-whose-message-schema-cannot-play-is-disconnected-here)

- A game's RPC link node is attached with `DotGameLink.attach(link, parent, bridge, NODE_NAME)`, never a bare `parent.add_child` and never `remove_child` in an `_exit_tree`: the first leaves a second link after a reload (RPCs silently lost), the second errors when the server tree is torn down. [design](docs/design.md#dotgamelink-the-rpc-link-outlives-nothing)

## Where a game plugs in

| To change | Where |
| --- | --- |
| The game itself | `DotGameModule._game_service()`, `_game_load()`, `_game_hibernation()`, `_can_tick()` |
| The operator's net limits (rate, budget, mtu) on the game's own | the host sets the `dot_net_ceiling` meta on the `DotServer` (`DotGameNetcode.CEILING_META`); `DotGameModule._net_ceiling()` reads it and `DotGameNetcode.cap` applies min(game, operator), 0 = no limit |
| Identity | `_make_identity()` returning dot-platform's `DotPlatformIdentity`; `_wants_platform_module()` |
| Chat, voice, moderation | a `DotGameServices` subclass: channels, rules, voice config, `_can_hear`, `_peer_can_receive` |
| The live admin tools | `_mod_abilities()`, `_mod_unsupported()`, `_mod_can_teleport()` / `_mod_position()` / `_mod_teleport()`, `_mod_configure_commands()`, `_mod_configure_tools()`; call `mod_player_respawned(id)` from the spawn path |
| The map the server lists, and the per-map settings it applies | `report_map(map_id)`, on every change; `_map_config_keys()` (+ `_map_config_defaults`, `_map_config_game`, `_map_config_get`/`_set`); client `map_changed`. [map-config](docs/map-config.md) |
| Tab board columns and teams | `_game_board_fields`, `_game_board_extra` |
| The client's chat and voice | `DotGameChatClient`: `channels`, `line_colours`, `max_length`, `voice_config`, `window_settings`, `voice_method`, `server_lines`, `self_mute_enabled`, `attach(bridge)` |
| Who a peer is, for a lobby | `DotGameRoster.session_fn` |
| Who is still loading (not to be hurt, eliminated or counted) | server: `DotGameModule.is_loading(seat)` / `is_peer_loading(peer_id)`, `can_be_harmed` / `can_peer_be_harmed` (override for a spawn shield), `loading_changed`, `load_timeout_sec`, `reload_grace_sec`, `mark_reloading()`, or `var peer_loading_fn: Callable` on the game object; the client side is automatic on `DotGameClient` (`report_loading`), else `DotGameClient.report_cover(link, covered)` ([design](docs/design.md#still-loading-the-server-knows-who-is-behind-a-cover)) |
| Look at a player to gag (G) or mute (K) them | `DotGameClient`: on by default when the chat has a voice and dot-voice is in the build; `use_look_mute`, `look_gag_action` / `look_mute_action`, `look_separate_keys`, `look_position_fn(roster row) -> head position` (the one hook a game needs; the chat block list supplies who is whose peer), or `look_positions_fn` / `look_target_fn`, `look_chat_mute_fn` (default: the `!sm` block list); a client with its own voice manager and chat sets `look_voice` / `look_chat` and calls `build_look_mute()` once the voice exists; rows are added to the game's key table unless it has its own on those actions; `look_conflicts` / `find_look_conflicts()` report a key another action holds. Never default to H: dot-menu's help |
| The client's cover, settings, menu, console, Tab, M, pointer | `DotGameClient`: `spawned_fn`, `require_camera`, `use_gate` / `use_settings` / `use_console` / `capture_pointer` / `sync_on_exit`, `settings`, `hud` + `hud_accent`, `chat`, `busy_fn`, `board_snapshot_fn`, `maps_*`, `scoreboard_action`; `_make_gate()`, `_make_settings()`; holds on `gate` ([migration](docs/client-migration.md)) |

## Open

- **arena, g2gfast and hungario are not converted** to `DotGameModule` or `DotGameServices`, and still carry their own copies of both (including `_refuse_peer`). **Convert arena first**: it is the reference game and the smallest of the hand-written modules, and its `headless_match` must still play a whole deathmatch before touching the others. Not started.
- **game-playground is half-way**: its services subclass `DotGameServices` (hook overrides only, base mod tools switched off), but its module is still a `DotModule`, deliberately for now; why is in [game-playground/docs/simulation.md](../game-playground/docs/simulation.md#the-server-module).
- Every game written since (the `mg-*` games, game-hide-n-seek, game-zombie-zone) is on both bases.
