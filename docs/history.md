# History

Bugs worth recognising if they come back. All parsed clean and none errored.

## The line two games got wrong

```gdscript
var session := server.session_by_userid(event.get_int("peer_id"))
```

`client_spawn` carries `userid` and `name`. It does not carry `peer_id`. So that lookup asked for session 0, found null, and returned, and **nobody ever joined those dedicated servers**, silently, for as long as those modules existed. A null session is a legitimate thing to find, so nothing errored; a dedicated-server suite passes without noticing, because it never connects a client. This is why dot-game exists, and why `DotGameRoster.session_fn` is injectable ([design](design.md#session_fn-exists-so-the-bug-above-can-be-asserted)).

## Two bugs in dot-server the first suite found

Neither is in this addon, and both had been there for as long as modules have.

**`DotModuleHost.load_module` did not await `_module_load`.** A module's load is allowed to be a coroutine and every non-trivial one is: an identity layer reaches a content host, a profile store, an avatar store. An un-awaited GDScript coroutine returns at its first suspension, which Godot reports as *"Trying to call an async function without 'await'"*, and then `result` is null and the next line reads `.ok` off it. It hid because it only fires when a load **actually** suspends: every module in the tree awaited things that happened to finish inside one call, so the coroutine ran to completion and returned like an ordinary function. The first module whose setup really waited was a fixture written to wait on purpose. In production it would have been a server failing to load its game because something it talks to was *slow*.

`_module_unload` is the other half and is deliberately **not** awaited: `unload_all` runs from `_exit_tree`, where there is no frame left to resume a coroutine in. It is enforced instead: the host calls it through `Object.call` (GDScript refuses to take the return value of a `-> void` function) and reports by name any module whose teardown suspended.

**A log line could fail the load it was describing.** `load_module` read `module.describe()["commands"]`, and `describe()` is a method the family expects every stateful object to override. An override that did not keep that key threw *inside the logging call*, after the module was already in `_modules`, so the load returned null and the next attempt said the module was already loaded. It is `.get("commands", 0)` now, and `DotGameModule.describe()` merges `super.describe()` rather than replacing it, which is the rule a subclass should follow anyway.

## A new class_name broke a game three repositories away

`DotGameServices` was added here and a dedicated server three repositories away spent a boot reporting *"Could not resolve script … bfh_services.gd"*: its own class cache had never heard of the base class. The addon was fine, the game was fine, and the cache was stale. See the family rule in [game-dev/CLAUDE.md](../../../CLAUDE.md#validating-anything).

## The platform module outlived the game

Before `_teardown` unloaded the dot-platform module `_build_identity` had loaded, it outlived the game: after `changelevel` away from mg-buses-from-hell, the next player to connect was admitted through the freed hub and the server crashed with signal 11. Found when dot-server-deploy's `live_switch` and `admin_live` suites started booting buses; both crashed without the fix.
