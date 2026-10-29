# Moving a game client onto `DotGameClient`

`DotGameClient` (dot-game API level 8) is the platform layer a client root adds: the loading cover, the settings and Escape menu, the console, the HUD's theme, Tab, M, the pointer, the input block and the browser's filesystem flush. Why it is a child node and not a base class is in [design.md](design.md#dotgameclient-the-platform-layer-every-client-wires). dot-game-template (`game/tpl_client.gd`) and mg-look-at-me (`game/lm_client.gd`) are the two converted clients to copy from.

**First 10 minutes** (a new game): start from [dot-game-template](https://github.com/modcommunity/dot-game-template), run `../dot-ci/scripts/resolve-deps.sh .` to link the addons, do the steps below, then run `./game.sh test`. Moving an existing client over is the same steps.

Settings layer the same way in every addon, weakest first: the addon's schema defaults, the addon's shipped `cfg/addon/<addon>/`, the game's `cfg/game/<game>/<addon>/`, the server operator's `cfg/server/addon/<addon>/` and `cfg/server/game/<game>/`, then environment variables, then the command line, then runtime changes (a console `set`). The folder is the addon name with `-` written as `_`. Secrets are read from files only: a key marked sensitive is refused from the environment and the command line. Details: [dot-core's addon-config.md](../../dot-core/docs/addon-config.md).

`./game.sh` is the one entry point every game repository has (copy it from the reference game, `game-arena`):

| Command | Does |
| --- | --- |
| `./game.sh play` | play offline in a window (the default) |
| `./game.sh online` | a local server plus the browser client; prints the link (`online down` stops it) |
| `./game.sh server` | a dedicated server only (`server check` boots, loads the game and exits 0) |
| `./game.sh test` | parse every script, then run every suite (`test NAME` runs one) |
| `./game.sh shot` | save a screenshot to `screenshots/` |
| `./game.sh soak [MAP] [MIN]` | a bot soak run, where the game has `tools/soak.tscn` |

## The steps

1. **Add it first in `_ready`**, before the world, the HUD or the camera are built, so the cover is the first thing drawn:

   ```gdscript
   platform = DotGameClient.new()
   platform.name = "Platform"
   platform.spawned_fn = func() -> bool: return player != null
   # a 2D game: platform.require_camera = false; platform.capture_pointer = false
   # a game whose key table has a scoreboard row: platform.scoreboard_action = MyBindings.SCOREBOARD
   add_child(platform)
   link = platform.link
   offline = platform.offline
   ```

   Delete the game's own `DotRegistry.get_node_service(&"dot_client_link")` and `--offline` test: `platform.link` and `platform.offline` are the same answer. Any extra hold (a map download, a course built) goes on `platform.gate`.

2. **Hand it the pieces, then call `setup()`**, after the HUD, the chat box and whatever the settings bind to exist:

   ```gdscript
   platform.settings = MySettings.new()   # the game's DotMenuSettings subclass; unset is dot-menu's stock one
   platform.hud = hud_root
   platform.hud_accent = MyHud.piece_theme()
   platform.chat = chat                   # DotGameChatClient (or a dot-ui chat window)
   platform.busy_fn = func() -> bool: return command_line.visible   # only if the game has its own line
   platform.board_snapshot_fn = board_snapshot
   platform.maps_rows_fn = game.course_rows
   platform.maps_change_fn = game.change_course_now
   platform.maps_title = "Change course"
   platform.maps_noun = "courses"
   DotLog.result(CHANNEL, "the platform", platform.setup())
   platform.input_blocked_changed.connect(_suspend_input)
   settings = platform.settings   # null when the settings refused to load
   board = platform.board
   ```

   A settings node the game adds to its own tree before `setup()` stays where it is; one that is not in the tree is added under the platform. The same goes for the chat box.

3. **After `setup()`**, bind the settings to the camera, audio, effects and look as before, and set the board's columns, title and `sort_by` (the platform has already fed it).

4. **Suspend input on `input_blocked_changed`**, one handler for every sampler the client has. It replaces the game's `menu_state_changed` handler and its chat `typing_changed` handler.

5. **Re-import** (`godot --headless --path . --import`): `DotGameClient` is a new `class_name`. Raise the game's dot-game requirement to API level 8 (`package.sh` derives it).

## What each game deletes

- The `DotLoadGate` construction (`_build_gate`) and its `require` for the player.
- The `DotConsoleKit.build(...)` call and the `follow_hud` call.
- `menu.busy = ...` (the platform sets it from `chat` and `busy_fn`).
- The board feeding (`feed_from(link)` / `source = board_snapshot`) and the held Tab in `_unhandled_input` (`_show_board`): the menu holds the board on `scoreboard_action`.
- `use_maps(...)` and its title and noun.
- `Input.mouse_mode` at the start, in the menu-state handler, and the click that captures it again (`_capture`, `_release`).
- The chat typing hook that suspended input, when it only did that.

What stays: the HUD, the game's keys (except Tab and M), an Escape fallback that opens the settings when the menu left an Escape alone, the board's columns, `board_snapshot`, the samplers, the camera, `new_chat()` and its channels.

## Hooks for what a game builds later or wants its own way (API level 11)

Each is additive; leaving it alone keeps the old behaviour.

- **`platform.set_hud(root, accent)` and `platform.set_chat(box)` after `setup()`.** A game that builds its HUD or chat after the platform (its HUD needs the world, or the settings' menu) hands it over when it exists instead of calling dot-menu's `follow_hud` itself. A HUD in a `CanvasLayer` passes the Control it holds. `set_hud` lets the previous HUD go (`unfollow_hud`); `set_chat` disconnects the previous box and wires the new one into the input block. Both are also fine before `setup()`.
- **A cover of your own: `platform.cover_scene` (a `PackedScene`, an export) or `platform.cover` (a node with `show_cover`, `hide_cover`, `set_status`, `set_progress`), set before `add_child`.** They are handed to the gate's own `cover_scene` / `cover`; unset keeps `DotLoadingCover`. A subclass can still override `_make_gate`.
- **`platform.pointer_fn`, a `func() -> bool`.** Asked wherever the platform would take the pointer back (a click, the menu closing); false leaves it free. For a game whose own screens or modes free the pointer, instead of a private rule reading `Input.mouse_mode`. Unset captures whenever nothing blocks input.
- **`platform.hold_pointer(key)` / `release_pointer(key)`.** For a modal the game draws itself (a shop, a loadout): frees the pointer, blocks input, and nothing recaptures it (a click outside the panel, another menu closing) until the same key is released. Keyed, not counted, so two modals cannot underflow it.
- **`platform.refresh_blocked()`.** Re-reads the input block and emits `input_blocked_changed` in the same frame, for an overlay or chat that opens mid-frame. It is otherwise polled once a frame.
- **`platform.menu = my_menu` (or `adopt_menu(menu, board)` after setup), no settings needed (API 12).** A game that built its own dot-menu `DotMenu` gets the input block, `menu_state_changed`, the HUD theme, Tab and M from the platform without handing over a settings node; no settings are built over an assigned menu. An assigned `board` is kept instead of the menu's, and `board_prepare_fn` (a `func(board)`) runs before it is fed.
- **The player's cfg tier (`user_cfg`, `listen_host_fn`, `user_cfg_files`).** `DotGameClient` turns dot-core's `DotAddonConfig.set_user_tier` on only when the client is solo (offline) or `listen_host_fn` (a `func() -> bool`) says it hosts the server it is on; a dedicated server (`OS.has_feature("dedicated_server")`) and a guest on someone else's server keep it off, and `user_cfg = false` opts out. `listen_host_fn` is not wired by `DotGameClient` itself: the game that starts a listen server assigns it before the client enters the tree (`client.listen_host_fn = func() -> bool: return my_server != null`). The tier is cleared again when the client leaves the tree. With files in `user_cfg_files` (`{addon, file, schema, label}`) the Advanced page gains a "Your mods" row opening dot-menu's `DotAddonConfigEditorScreen` (loaded by path; `open_user_cfg()` opens it for a game with its own menu).
- **`platform.add_console(manager)`.** Builds the console now, for a game whose console must come after its menu (turn `use_console` off, call this later). A second call keeps the first.
- **`platform.gate_only = true`.** `setup()` wires only the chat's keyboard and the input block: no settings, menu, console, board, Tab, M or pointer capture. The gate, the link, the web flush and the block stay.
- **`platform.escape_releases_pointer = true`.** The first Escape on a captured pointer frees it and is consumed; the next opens the menu. Not while a menu, the chat or `busy_fn` has the keys.
- **Map culling, opt in: `platform.attach_visibility(world, drawn)` on every map load (`detach_visibility()` on unload).** It builds dot-map's `DotMapVisibility` (by path) over a converted map's `DotMapBspMesh` and its drawn tree, by `vis_mode`: `off` (the default: nothing is built and the map draws whole), `pvs`, `occluders` or `both`. Every game's client console gets a `vis_mode` variable (left alone when the game binds its own), and `--vis_mode=` on the command line sets it; `set_vis_mode(mode)` is the same from code. A map with no visibility data stays drawn whole, with one line. A dedicated server draws nothing, so it never pays for this.
- **Hit flinch, opt in (API 32): `platform.add_hit_flinch(sampler_fn, camera_fn, aim_fn)` once, then `platform.note_hit(damage, weapon_scale)` wherever the client learns the local player was hurt.** A hit rolls and shakes the camera and wobbles the aim while sighted (dot-player-controller's `sv_hit_*` tunables, read from the sampler's tunables unless a fourth `tunables_fn` is given). The client applies it every frame after the game wrote the camera, undoing its own last offset, so the game keeps its camera code. Without dot-player-controller it does nothing.

## Gotchas

- **The cover blocks input until it lifts.** A suite that boots a client and steers or moves the mouse after a fixed number of frames now has to wait for `platform.is_shown()` (mg-look-at-me's `headless_run` has `_shown(client)`, capped at 240 frames).
- **A suite that pressed Tab through the client's `_unhandled_input`** must press it through `settings.menu.handle_event(tab)`: the menu holds the board now.
- **A suite that read `client.console`** keeps working only if the client keeps a `console` alias set from `platform.console` (mg-look-at-me does), or reads `client.platform.console` (dot-game-template's `headless_net`).
- **`spawned_fn` must be true only when the player can be shown.** A 3D game should include its camera (`camera.current`); the gate also waits for a current camera unless `require_camera` is off.
- **The gate is added under the host, deferred when the host is still readying its scene's children.** Never look it up by path; use `platform.gate` or `DotLoadGate.of(host)`.
- **`setup()` runs once**; a second call returns `CODE_STATE`.
- **Never name `DotMenu`, `DotMenuSettings` or `DotConsoleKit` in the base's place**: a delivered game in an older client shell must still parse. The game's own settings subclass already names dot-menu, which is the game's choice.
- **mg-\* games have no `class_name`**, but `DotGameClient` is the addon's and is named freely.

## Estimated difficulty for the rest

| Game | Estimate | Why |
| --- | --- | --- |
| mg-deathrun, mg-prop-hunt, mg-wipeout | easy to moderate | the same shape as look-at-me: `_build_gate`, `_build_settings` with the kit and `follow_hud`, `_capture`/`_release`, `_suspend_input`, `_show_board` |
| mg-smash-copter, mg-buses-from-hell, mg-dangerous-delivery | moderate | 2D or vehicle clients with their own pointer rules (`capture_pointer = false`) and their own chat window |
| game-hide-n-seek, game-zombie-zone, game-hungario, game-g2gfast | moderate | full settings pages and their own keys; check each suite's Tab and frame-count waits |
| game-arena, game-playground | hard | arena has its server browser as a menu page and its own chat flow; playground keeps its spawn menu and server browser on its own stack. Use `use_settings = false` or a `_make_settings` override first |

## Combat feel (spread, recoil, spread crosshair)

`DotGameCombatFeel` (API 27) is the opt-in for movement-dependent spread, recoil patterns and the `cl_crosshair_*` console cvars. `DotGameCombatFeel.new(true)` turns the rules on, `new(false)` registers them off (admins flip `sv_spread_enabled` / `sv_recoil_enabled`). Per game: `feel.attach(player.arsenal)` for every arsenal on both sides, `feel.sprint_defaults(config_tunables)` once and `feel.track_tunables(t)` for every player's `DotFpsTunables` (sprint and stamina cvars; `new(on, false)` for a game with no sprint), `feel.bind_cvars(add_cvar)` in the server module, `feel.follow_cvars(link)` on the client, and either `DotGameClient.add_combat_feel(feel, crosshair, arsenal_fn)` (follows, binds the console, drives the crosshair each frame) or `feel.bind_console(local_console, crosshair)` when the crosshair already pulls its spread. game-arena is the reference.
