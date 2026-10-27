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

`start()` adds a **Server threads** set to every game's panel when a `DotServer` is registered: `sv_worker_threads`, `sv_threads_net`, `sv_threads_npc`, `net_native`, `net_native_interest` and `map_load_threads` (`THREAD_CVARS`), each field built from its cvar (range, description, current value). An edit sets the cvar, which dot-server applies live; Save writes `cfg/server/addon/dot_server/threads/server.yml`, and the next `start()` applies that file to the cvars before anything reads them. Only what an edit moved is pushed, so a cvar changed at the console since is left alone. `thread_cvars = false` leaves the set out. `cvar_set(console, {name: type}, kind, addon)` and `bind_cvar_set(set, runtime, console)` build the same thing over any other cvars.

## The relevance cvars

`DotGameNetcode.build` registers `net_interest_radius`, `net_far_every` and `net_far_distance` on the server console (`DotGameRelevance`, archive flag) and follows them into the manager's default `DotNetInterestDistance`, live; a game that assigns its own interest strategy is left alone. 0 keeps the game's value; the radius is a ceiling (the smaller wins), the far pair replaces. The same names in the operator's `server.yml` seed the defaults. The workbench offers them as a "Relevance" set; Save writes `cfg/server/addon/dot_server/relevance/server.yml`, applied at the next start (the console changes them at once). `DotGameWorkbench.relevance_cvars = false` hides the set.

## NPC level of detail

`DotGameModule.attach_npc_lod(spawner)` (a game calls it once, from its `_follow_npc_threads`) hands the horde spawner to `DotGameNpcLod`, which each tick copies `sv_threads_npc` into `sense_workers`, applies `npc_sense_quiet` to the spawner limits and, when `npc_lod` is 1, advances dot-npc-ai's scheduler. All cvars default off and appear in the workbench as "NPC level of detail". Requires dot-npc and dot-npc-ai in the game.

## Remote admin of a running server (API level 30)

Flagged admins edit profiles from a connected client; nobody else even gets a panel. Off until the owner sets `sv_workbench_remote 1`.

- **Wire.** `DotGameWorkbenchMessage` (both directions, reliable, not required) carries ask, request, reply and access frames. `DotGameNetcode.build` serves it; a client's bridge calls `DotGameWorkbenchMessage.register(net)` (or `DotGameWorkbenchRemoteClient.attach(net)`) before the schema seals.
- **Server.** `DotGameWorkbenchRemote` (found with `DotGameWorkbenchRemote.of(net)`; `wb.serve_remote(net)` binds it to the api, the console cvar and `DotServer.admins`). Every request is checked in order: cvar on, an identified account (a guest is never an admin), size (4096 bytes), rate (4/s, burst 8 per peer), then the flag the op needs, held now through `DotAdminManager.uid_has_permission`, so a revoked admin is refused on the next edit. Only then does the api see it, as the actor `remote:<uid>`, and the api's permit asks again. A refusal is a WARN with the uid and peer; an applied edit is an INFO `workbench edit` line with uid, peer, op, kind, id, key, old and new. Edits reach clients only if the game attached a `DotNetProfileLink` to the manager (before the seal, on both ends; `peer_joined` per ready peer, `release` on exit): that link is what sets the runtime's `broadcast`, nothing in `serve_remote` does.
- **Client.** `DotGameWorkbenchRemoteClient` asks once connected and is told `allowed` and the flags; `poll()` on the server tells it again when the flags change, so a revoked admin's panel is freed. Set `wb.remote_client` before `start()`: no panel node is built until the server allows it (`panel_built` tells the host to mount it, `host_on` does), edits go to the local copy and are forwarded (`DotWorkbenchApi.forward`), and the server's reply or replicated row is the truth. F9 and `workbench` do nothing visible for anybody else (the console says `workbench: not allowed`).
- **No local trust against a remote server.** `local_allowed(editor, debug, listen, remote)`: set `wb.remote_fn` to "connected to somebody else's server"; only a listen host stays trusted then.
- **Wired in** game-arena, game-zombie-zone, game-g2gfast, game-hide-n-seek, game-murder-mystery, mg-prop-hunt, mg-buses-from-hell, mg-dangerous-delivery, mg-wipeout, mg-deathrun, mg-smash-copter and mg-look-at-me, all with `sv_workbench_remote` at 0. Still open: game-hungario (uncommitted work in its tree) and game-playground.

### Wiring a game

1. Server: make the workbench and the bridge's `ensure_runtime()` runtime before the netcode, call `DotGameWorkbenchRemote.serve(net)` and attach a `DotNetProfileLink` to that runtime (`peer_joined` for each ready peer, `release` on unload), all before the seal; after the seal call `wb.serve_remote(net)`.
2. Client: before the seal create `DotGameWorkbenchRemoteClient.attach(net)` and its own `DotNetProfileLink` over the client's runtime; set `wb.remote_client` and `wb.remote_fn` before `wb.start(runtime)`, and call `ask()` once playing.
3. Keep the local F9 workbench for offline play only; online, only the remote one is trusted.
4. `examples/headless_net.gd` gets a section that registers both ends in that order and checks that an admin's edit applies and replicates, and that a guest, a non-admin, a revoked admin and the cvar off are refused.

Test: `examples/headless_workbench_remote.tscn` (the real-api half needs `addons/dot_workbench` linked and is counted as skipped otherwise).
