# Map edit commands

`DotGameMapEdit` is the admin command set from dot-spawn's `docs/map-data-tools.md`: `spawn_list`, `spawn_add`, `spawn_set`, `spawn_remove`, `spawn_toggle`, `spawn_test`, `spawn_strategy`, `nav_rebake`, `nav_link_mark`, `nav_link_add`, `nav_link_remove`, `mapdata_save`, `mapdata_revert`, `mapdata_export`, `mapdata_import`. Every command needs `map_edit_flag` (default `config`).

It is duck-typed on the host (`add_command` or `command`) like `DotModToolCommands`, and on three collaborators the game assigns: `points` (dot-spawn's `DotSpawnPointSet`), `store` (dot-map's `DotMapDataStore`: `load`, `save`) and `nav` (`rebake`, `add_link`, `remove_link`, `links_dict`, `load_links`). A missing collaborator makes its commands reply with a plain refusal. The contract is on the class doc.

`DotGameMapEditBundle` builds and checks the bundle. When the project has dot-map's `DotMapDataBundle` (found by path, so dot-game names no dot-map class and does not require it) it makes and imports through that class, which is what dot-map's stores take; without dot-map it falls back to a dictionary of the same shape with the same checks. Import refuses another map id, needs `force` for a different version or digest, keeps only known sections and caps strings, counts and depth.

Edits change the working set; `mapdata_save` persists it. Every edit is an INFO line and an audit record with the admin's id. Test: `examples/headless_mapedit.tscn` (fake host, set, store and nav).

## The overlay

`DotGameMapEditOverlay` is the client half: a `Node3D` the game places in the world, fed dictionaries (`points.to_dict()`, `nav.links_dict()`) through `set_points` and `set_links`, so it names no dot-spawn or dot-bot class. Each point is a pole coloured by kind (blue player, red npc, purple both) and tinted by team (`team_colors`, else a hue from the name), a disc and ring for a radius, an arrow for the facing, grey when disabled; hand-made links are lines and `nav_mesh` is drawn when `show_mesh` is on. The markers draw through walls so an admin sees what is behind them.

`pick_ray(origin, dir)` returns the marker nearest the ray and `pick_from_camera()` does it from the current camera and opens the panel; the game binds the key and keeps the mouse free while the panel is open. The panel is a `DotGameMapEditForm` built from the schema the game assigns to `schema` (`DotSpawnPointDef.schema()`): one row per entry, so a new setting is a new row with no UI change. Apply sends `spawn_set <id> key=value...` for what changed only, and the buttons send `spawn_toggle`, `spawn_test` and `spawn_remove`, all through `send_fn` (a console or chat line, `command_prefix` first). The overlay validates nothing: the server does, as for typed commands. Test: `examples/headless_mapedit_overlay.tscn`, which also feeds a form's line to the real `DotGameMapEdit`.
