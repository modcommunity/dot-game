# Touch layout: DotGameTouchLayout

`DotGameTouchLayout` (`addons/dot_game/runtime/dot_game_touch_layout.gd`) is the one place a touch button's id, place and size are decided. Eleven touch branches had each written their own: jump in five places at four radii, fire called `fire`, `attack` and `swing`, crouch called `crouch`, `duck` and `dot_fps_crouch`, the layout in a `*_touch.gd` static, a client const or a `DotTouchButtons` subclass, and three near-copies differing in one offset. It is data only: it never names dot-ui's `DotTouchButtons`, and it sizes through `DotGameClient.fit_touch_buttons` (`DotGameScreenFit`), so it is a layer under the routing proposal (`DotTouchControls`), not a replacement for it.

## The model

- **Slots** (`SLOTS`): named places in the bottom-right cluster, offsets from the corner in design units of the 720-unit canvas. `primary` (80,84) r44, `secondary` (190,60) r30, `below` (80,172) r32, `outer` (262,60) r28, `inner` (190,150) r26, `corner` (262,140) r22, `row1`..`row4` along y 246 at r22; and `steer_near` / `steer_far` (r46) for a left steering strip. These are the wipeout family's numbers (wipeout, playground, smash-copter, buses), the most tested set, with reload at 140.
- **Homes** (`HOMES`): fire is always `primary`, jump `below`, crouch `outer`, reload `corner`, in every preset that has them. The suite checks it.
- **Canonical ids**: `fire alt jump crouch reload use sprint next prev board chat gas brake handbrake respawn camera steer_left steer_right`, each a constant. Labels default from `LABELS` (crouch is labelled DUCK; the id stays `crouch`). `ALIASES` maps the old ids (`attack`, `swing`, `duck`, `dot_fps_crouch`, `dot_fps_jump`, `dot_fps_sprint`, `run`, `tab`, `hand`) to canonical ones; `canonical_id(id)` is for a router that must accept both during a migration, and `validate()` refuses an alias in a layout.
- **Presets** (`PRESETS`), per cluster (`RIGHT`, `LEFT`):

| Preset | Right cluster | Left cluster |
| --- | --- | --- |
| `fps` | fire, alt, jump, crouch, use, reload, next, prev, board, chat | none |
| `platformer` (`minigame` is the same) | use in `primary`, sprint, jump, crouch, board, chat | none |
| `driving` | gas in `primary`, brake, jump, handbrake, use, respawn, camera, board, chat | steer_right (near), steer_left (far) |

A game drops what it does not use rather than moving the rest, so a jump stays where a player's thumb learnt it.

## The API

| Call | What |
| --- | --- |
| `DotGameTouchLayout.build(preset, overrides = {}, cluster = RIGHT) -> DotResult` | the one call: make, override, validate; the value is the layout. CODE_INVALID for an unknown preset, a bad override or a failed validation, wrapped with the preset and cluster |
| `make(preset, cluster) -> DotResult`, `custom(cluster) -> DotGameTouchLayout` | the preset untouched; an empty layout for a game with its own ids (it still uses the slots) |
| `override(changes) -> DotResult` | per-game changes as data, all or nothing: id -> `null` (drop), a slot name (add or move), or `{slot, offset, radius, label}`; a new id needs a slot or an offset and a radius |
| `put(id, slot, label)`, `place(id, offset, radius, label)`, `drop`, `relabel`, `resize` | the same in code, chainable; an unknown slot in `put` is a `push_error` (the file's author must fix it) |
| `validate() -> DotResult` | refuses an alias id, a radius under `MIN_RADIUS` (22) and two buttons closer than `MIN_GAP` (4) |
| `buttons() -> Array[Dictionary]` | fresh rows of id, label, offset, radius: what `DotTouchButtons.set_buttons` takes |
| `apply(touch_buttons, client = null) -> float` | `set_buttons` (duck-typed), then `client.fit_touch_buttons` when the client has it; returns the scale, 1 without a fit. Call it again after a relabel: the fit replaces its remembered request for those buttons |
| `ids()`, `has(id)`, `row(id)`, `describe()` | reading it back |

```gdscript
# mg-wipeout: the fps preset less use, plus grab in its slot.
var res := DotGameTouchLayout.build(DotGameTouchLayout.FPS, {&"use": null, &"grab": &"inner"})
if not res.ok:
	DotLog.error(CHANNEL, "touch layout refused", {"error": str(res.error)})
	return
res.value.apply(touch.buttons, platform)
```

The suite is `examples/headless_touch_layout.tscn` (presets, homes, overrides, validate, apply through a real `DotGameClient` fit).

## Example migration: game-hungario `touch-buttons-rebased` (not applied)

Hungario shares no ids with a preset (split, throw, eject, boost), so it takes `custom()` and the slots: split goes where every other game's main button is. Its footprint grows by about 8 design units each way (`outer` reaches x 290 against 282, `below` y 204 against 200), so its minimap and board clearance want a phone screenshot (`tools/screenshot_touch.sh`) after the change. `headless_touch` keeps passing unchanged: `layout()` still returns the rows. `apply_safe_area()` stays out of this diff; `DotGameScreenFit` already pushes the safe-area insets into the margin, so it can go in a later commit.

```diff
--- a/game/client/hungry_touch.gd	2026-11-05 17:09:12.375493493 -0500
+++ b/game/client/hungry_touch.gd	2026-11-05 17:09:22.979966888 -0500
@@ -31,6 +31,8 @@
 var boost_held: bool = false
 
 var buttons: DotTouchButtons = null
+## The DotGameClient that fits the buttons; a relabel re-applies through it.
+var fit_client: Object = null
 
 ## What the throw button says it will throw. Set from the carry list.
 var _carried: StringName = &""
@@ -49,15 +51,18 @@
 	return touch
 
 
-## Offsets are from the bottom-right corner (see [DotTouchButtons]). Placed to leave the leaderboard's text columns and the minimap clear. Throw is disabled
+## dot-game's canonical slots, so split sits where every other game's main button does. Throw is disabled
 ## (drawn as its label only) until something is carried.
+static func touch_layout(throw_label: String) -> DotGameTouchLayout:
+	return DotGameTouchLayout.custom() \
+		.put(&"split", &"primary", "SPLIT") \
+		.put(&"throw", &"secondary", throw_label) \
+		.put(&"eject", &"below", "EJECT") \
+		.put(&"boost", &"outer", "BOOST")
+
+
 static func layout(throw_label: String) -> Array[Dictionary]:
-	return [
-		{"id": &"split", "label": "SPLIT", "offset": Vector2(80, 80), "radius": 46.0},
-		{"id": &"throw", "label": throw_label, "offset": Vector2(176, 52), "radius": 34.0},
-		{"id": &"eject", "label": "EJECT", "offset": Vector2(120, 170), "radius": 30.0},
-		{"id": &"boost", "label": "BOOST", "offset": Vector2(250, 52), "radius": 32.0},
-	]
+	return touch_layout(throw_label).buttons()
 
 
 func build() -> void:
@@ -71,7 +76,7 @@
 	buttons.margin = EDGE_MARGIN
 	buttons.set_anchors_preset(Control.PRESET_FULL_RECT)
 	buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
-	buttons.set_buttons(layout("THROW"))
+	touch_layout("THROW").apply(buttons)
 	buttons.button_down.connect(_on_down)
 	buttons.button_up.connect(_on_up)
 	add_child(buttons)
@@ -125,7 +130,7 @@
 		throw_held = false
 
 	if buttons != null:
-		buttons.set_buttons(layout(throw_label()))
+		touch_layout(throw_label()).apply(buttons, fit_client)
 
 
 ## What the throw button says.
--- a/game/client/hungry_client.gd	2026-11-05 17:09:12.375493493 -0500
+++ b/game/client/hungry_client.gd	2026-11-05 17:09:22.979966888 -0500
@@ -487,7 +487,8 @@
 	# is what puts them inside the safe area.
 	sampler.touch = hud.touch
 	if hud.touch != null:
-		platform.fit_touch_buttons(hud.touch.buttons, HungryTouch.layout(hud.touch.throw_label()))
+		hud.touch.fit_client = platform
+		HungryTouch.touch_layout(hud.touch.throw_label()).apply(hud.touch.buttons, platform)
 
 	if platform.board is DotMenuScoreboard:
 		HungryMenus.dress_board(platform.board as DotMenuScoreboard, world, bridge)
```

## Migration cost per game

From the touch branches named in `game-dev/docs/touch-branches-status.md`; the cost is the layout only (routing stays in the game until `DotTouchControls` exists). Each game's `headless_touch` must pass and a phone screenshot be looked at.

| Game | Preset and overrides | Ids renamed | Moves a player would notice | Cost |
| --- | --- | --- | --- | --- |
| mg-wipeout | fps, `{use: null, grab: inner}` | `duck` -> `crouch` | none | small: const block becomes one `build` |
| game-playground | fps, `{use: null, reload: null, menu: {slot: inner, label: "Q"}}` | `duck` -> `crouch` | none | small |
| mg-smash-copter | fps as is (`use` label "E") | `duck` -> `crouch` | reload 128 -> 140 | small |
| mg-buses-from-hell | platformer less sprint/crouch with fire, or fps `{alt: null, ...}`; brake to `secondary` | `swing` -> `fire` | none | small; also drop the stray `.uid` files |
| mg-prop-hunt | fps for the hunter (`aim` in `outer`, `gear` in `inner`), `custom()` for the prop | none | fire, jump, reload move from the compact family to the homes | medium: two role layouts, its suite's positions |
| mg-look-at-me | platformer `{sprint: null, flashlight: corner}` | none | use, jump, crouch move from the compact family | small layout, medium suite update |
| mg-deathrun | platformer `{sprint: null}` | none | jump (60,238) r36 -> below r32; use r54 -> r44 (override radius if wanted) | small; layout leaves the client const |
| game-murder-mystery | fps `{alt: null, reload: null, crouch: null, fire: {label: "HIT"}, holster: secondary}` and `use` stays `inner` | `attack` -> `fire` | HIT r50 -> r44, jump (60,200) -> below | small |
| game-hide-n-seek | platformer `{use: {label: "DOOR"}, taunt: corner}` | `dot_fps_jump/sprint/crouch` -> `jump/sprint/crouch` | jump r54 -> r32 in `below`; its router reads action names, so it needs `canonical_id` or a map | medium: the `DotTouchButtons` subclass's `LAYOUT` and the id-is-action trick go |
| mg-dangerous-delivery | driving, right `{camera: null, respawn: null}`; left adds `respawn`, `camera`, `lot` by offset | `hand` -> `handbrake`, `left`/`right` -> `steer_left`/`steer_right` | gas r54 -> r44 | medium: two clusters, its input reads the ids |
| game-hungario | `custom()` with four slots (above) | none | all four, by up to 12 units | small |
| game-arena, game-g2gfast, game-zombie-zone | fps, after their touch branches are rebased on `phone-scale` | per branch (not yet compared) | unknown | small each once rebased |

Order: this branch after `phone-scale` merges, then one builder per game, the wipeout family first (smallest change, proves the preset), the odd ones (dangerous-delivery, hide-n-seek, prop-hunt) last.
