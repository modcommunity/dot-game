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

## Accounts (API level 20)

`DotGameWorkbench.accounts` is on by default: when dot-auth is running a ticket key (`DotAuthServer.config.ticket_public_key` and `server_id`), a connect ticket is also accepted as the HTTP bearer, verified offline by `DotGameWorkbenchAuth` (audience-checked, expiry required, not burned). Only the uids in `admin_uids` and the groups in `admin_groups` of the `workbench:` block are let in; with neither listed nobody is. The game's own policy still decides each flag: `account_permit_fn(uid, flag)`, which falls back to `permit_fn`. `account_resolver` (`Callable(token) -> identity or null`) replaces the ticket check; `accounts = false` turns the whole thing off; `account_gate` is the dot-workbench `DotWorkbenchIdentity` once attached, else null. dot-auth and dot-workbench are reached by path, so a build without them has no account login and no error. Set the hooks before `start()`; a game wires nothing else.

## The server's thread cvars

`start()` adds a **Server threads** set to every game's panel when a `DotServer` is registered: `sv_worker_threads`, `sv_threads_net`, `sv_threads_npc` and `net_native` (`THREAD_CVARS`), each field built from its cvar (range, description, current value). An edit sets the cvar, which dot-server applies live; Save writes `cfg/server/addon/dot_server/threads/server.yml`, and the next `start()` applies that file to the cvars before anything reads them. Only what an edit moved is pushed, so a cvar changed at the console since is left alone. `thread_cvars = false` leaves the set out. `cvar_set(console, {name: type}, kind, addon)` and `bind_cvar_set(set, runtime, console)` build the same thing over any other cvars.

## The relevance cvars

`DotGameNetcode.build` registers `net_interest_radius`, `net_far_every` and `net_far_distance` on the server console (`DotGameRelevance`, archive flag) and follows them into the manager's default `DotNetInterestDistance`, live; a game that assigns its own interest strategy is left alone. 0 keeps the game's value; the radius is a ceiling (the smaller wins), the far pair replaces. The same names in the operator's `server.yml` seed the defaults. The workbench offers them as a "Relevance" set; Save writes `cfg/server/addon/dot_server/relevance/server.yml`, applied at the next start (the console changes them at once). `DotGameWorkbench.relevance_cvars = false` hides the set.

## NPC level of detail

`DotGameModule.attach_npc_lod(spawner)` (a game calls it once, from its `_follow_npc_threads`) hands the horde spawner to `DotGameNpcLod`, which each tick copies `sv_threads_npc` into `sense_workers`, applies `npc_sense_quiet` to the spawner limits and, when `npc_lod` is 1, advances dot-npc-ai's scheduler. All cvars default off and appear in the workbench as "NPC level of detail". Requires dot-npc and dot-npc-ai in the game.
