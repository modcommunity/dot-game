# Map edit commands

`DotGameMapEdit` is the admin command set from dot-spawn's `docs/map-data-tools.md`: `spawn_list`, `spawn_add`, `spawn_set`, `spawn_remove`, `spawn_toggle`, `spawn_test`, `spawn_strategy`, `nav_rebake`, `nav_link_mark`, `nav_link_add`, `nav_link_remove`, `mapdata_save`, `mapdata_revert`, `mapdata_export`, `mapdata_import`. Every command needs `map_edit_flag` (default `config`).

It is duck-typed on the host (`add_command` or `command`) like `DotModToolCommands`, and on three collaborators the game assigns: `points` (dot-spawn's `DotSpawnPointSet`), `store` (dot-map's `DotMapDataStore`: `load`, `save`) and `nav` (`rebake`, `add_link`, `remove_link`, `links_dict`, `load_links`). A missing collaborator makes its commands reply with a plain refusal. The contract is on the class doc.

`DotGameMapEditBundle` builds and checks the bundle dictionary (`dot-map-data`, schema 1) until dot-map's own class exists. Import refuses another map id, needs `force` for a different version or digest, keeps only known sections and caps strings, counts and depth.

Edits change the working set; `mapdata_save` persists it. Every edit is an INFO line and an audit record with the admin's id. Test: `examples/headless_mapedit.tscn` (fake host, set, store and nav).
