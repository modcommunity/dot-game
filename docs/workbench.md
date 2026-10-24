# Hosting dot-workbench in a game

`DotGameWorkbench` (`runtime/dot_game_workbench.gd`) mounts dot-workbench's in-game window and, when asked, its loopback HTTP page. dot-workbench, dot-menu and dot-ui are reached by path: a build without them logs one line and has no workbench.

| | Default |
| --- | --- |
| Panel (F9, console `workbench`) | on in the editor, debug builds and for a listen host; off in a production build; never on a dedicated server |
| HTTP | off everywhere until `workbench: enabled: true` in `cfg/server.yml`; binds 127.0.0.1; the token is read from `token_file` (a random one is made at `user://workbench.token` when that file is missing) |
| Who may edit | the panel's own actor only where `local_allowed` (editor, debug, listen host); everyone else through `permit_fn(actor, flag)`, the game's admin or console permit |

## Wiring a game

```gdscript
var wb := DotGameWorkbench.new()
wb.listen_host_fn = func() -> bool: return is_listen_host
wb.permit_fn = func(actor, flag) -> bool: return admin_permit.call(actor, flag)
wb.cvars_fn = func() -> Dictionary: return changed_cvars()   # optional, written to game-cvars.yml
wb.add_set(binder.profile_set(), "Game settings")           # each DotProfileSet worth tuning
add_child(wb)
wb.start(profile_runtime)        # the game's DotProfileRuntime, so edits replicate
client.add_workbench(wb)         # menu overlay awareness and the `workbench` console command
```

Export builds need `*.html` in the preset's `include_filter` for the HTTP page. The round trip (Export changes as defaults, Import) is described in dot-workbench's README.
