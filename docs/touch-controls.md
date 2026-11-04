# Touch controls

A phone game needs on-screen buttons for what the keyboard and mouse give a desktop player; the look and move halves of the screen are not buttons. Two classes do the work: `DotTouchButtons` (a full-rect Control that draws circular buttons from a layout and emits `button_down(id)` and `button_up(id)`) and `DotFpsTouchSampler` (the left half of the screen moves, the right half looks, jump and crouch are held through its `hold(bit, down)`). The game supplies only the layout and the routing.

## The pattern

Keep the layout in one static function returning an array of dictionaries `{id, label, offset, radius}`, the offset measured from the bottom-right corner towards the middle and small enough for a 375 px tall screen. Build a `DotTouchButtons` with `mouse_filter = MOUSE_FILTER_IGNORE`, full-rect anchors, `set_buttons(layout)` and add it under the HUD. Make the sampler with `DotFpsTouchSampler.new(tunables)` only when `DotPlatform.has_touch()` (the plain `DotFpsSampler` otherwise), call `DotFpsSampler.register_default_actions(sampler)`, and set `sampler.ignore_fn = buttons.contains_point`. Without `ignore_fn` a finger on FIRE also steers the look stick, because the sampler cannot tell a button from the empty screen; `ignore_fn` is asked with a screen position and returns true when a button owns it. Read the sampler through a callable (`sampler_fn`), not a held reference: the active sampler changes when the player joins.

## The handlers dictionary

Connect `button_down` and `button_up` to one `route(id, down, sampler_fn, handlers)` function. Jump and crouch go to the sampler (`sampler.hold(DotFpsCommand.BUTTON_JUMP, down)`); every other id is looked up in a `handlers` dictionary of button id to a Callable taking `down: bool`, so the game wires fire, use, grab, scoreboard and chat without the touch class knowing what they do. A held button (fire, the scoreboard) acts on both edges; a tap button acts when `down` is true. The route is static so a suite can call it with a stub sampler and a dictionary of recorders.

## The menu button corner

The Escape menu's button sits in the top-right by default, where the role label and the clock usually are. dot-menu has a `menu_button_corner` setting for it; a game on a phone moves it to the top-left. Guard the line, because older dot-menu releases do not have the property (it arrived with dot-menu commit 2a79d3d):

```gdscript
if &"menu_button_corner" in config:
    config.set(&"menu_button_corner", &"top_left")
```

It needs the dot-menu release with menu-overlap support; with an older one the guard skips it and the button stays where it was.

## A headless_touch suite

Add `examples/headless_touch.tscn` extending `DotGameCheckSuite`, with the usual `CHECKS`, entered and finished section counts, and `_report_sections`. Check, in this order: every button id is unique and the ids the game needs exist; the sampler is the touch one with `DotPlatform.touch_override = 1` and the plain one with `0` (reset it afterwards); for each of 844x390, 667x375 and 932x430, make a `DotTouchButtons` of that `size`, `set_buttons` the layout, add it, and check `Rect2(Vector2.ZERO, size).encloses(buttons.footprint())`; check no two buttons overlap, using `centre_of` and `radius_of` and requiring a gap of at least 4 px; check `contains_point` is true on a button centre and false on a point in the left half (the stick's); check `ignore_fn` is valid and true on a button; and check each handler receives down and up and jump reaches the sampler through `route`. Free every `DotTouchButtons` you create (`free()`, not `queue_free()`, inside the loop) and reset any static `ignore_fn` the game keeps. Check the `menu_button_corner` line both ways: the corner when the property exists, a passing no-op when it does not.

## Rendering a phone frame

No assertion shows that the HUD is readable. `addons/dot_game/tools/dot_game_phone_shot.sh` renders one 844x390 frame of the game's real client with touch on, HUD and menu built, to `screenshots/phone.png`; a game's `tools/phone_shot.sh` execs it (the GPU runner only runs `tools/*.sh`). It needs xvfb, not `--headless`, which gives a 64x64 viewport. Options: `--scene=`, `--out=`, `--set=key=value`, `RESOLUTION=WxH` with `--size=WxH`, `--no-touch`, and `RENDERER=gl_compatibility` for a 3D map that would otherwise pass the memory cap in Forward+ on software rendering. The tool lives on the `phoneshot` branch of dot-game until it is merged; a game takes it with the addon update that includes it. Look at the frame after any HUD or layout change.

## HUD text placement

Three things went wrong on a phone that never did on a desktop. Labels placed in the bottom-right, such as ammo, the tool name or a hint, end up under the FIRE circle, which is the biggest button and the one a thumb covers; keep the bottom-right for buttons and put such text bottom-left or at the top. Role labels (hider, runner, murderer) placed top-right sit under the Menu button, so either move the menu button to the other corner or anchor role text to the top centre. And a label that is readable at 1280x720 shrinks to a smudge at 844x390, so check the phone frame, not the desktop one. Size HUD fonts from the viewport height rather than a fixed pixel count; no shipped touch HUD does this yet, so treat it as advice.

## Rollout checklist

Lessons from rolling touch controls across the games; walk it for each one.

1. A `DotTouchButtons` offset is measured from the margin-inset corner, so a button's centre is at `size - margin - offset * scale`, not `size - offset`. Compute layouts and expected positions from that, or every button sits closer to the edge than planned.
2. Hide keyboard-only hint lists and labels when `DotPlatform.has_touch()`, and give touch a button for every key-only action (the loadout menu, for one). A hint for a key nobody can press is noise, and an action with no button is unreachable.
3. Move HUD text (status lines, role labels, money plates) away from the button clusters. Render at 844x390, 667x375 and 932x430 and Read the PNG; the desktop frame hides every collision.
4. `headless_touch` checks fit inside the screen, a minimum button size of 44 px, a gap of at least 4 px between buttons, that touch-off hides the buttons, and that the buttons are freed.
5. A button-up must always be delivered, even when a menu or chat cover opened while the button was held. Route releases past any "UI is open" guard, or the action sticks on (a held fire, a scoreboard that never closes).
6. When the HUD can be rebuilt, guard stored references with `is_instance_valid(node)`, not `!= null`: a freed node is not null, and the next call on it errors.
