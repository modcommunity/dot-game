# Moving a game client onto `DotGameClient`

`DotGameClient` (dot-game API level 8) is the platform layer a client root adds: the loading cover, the settings and Escape menu, the console, the HUD's theme, Tab, M, the pointer, the input block and the browser's filesystem flush. Why it is a child node and not a base class is in [design.md](design.md#dotgameclient-the-platform-layer-every-client-wires). dot-game-template (`game/tpl_client.gd`) and mg-look-at-me (`game/lm_client.gd`) are the two converted clients to copy from.

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
