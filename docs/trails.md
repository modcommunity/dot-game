# Player trails

The wiring for dot-trail; dot-game does not depend on it (duck-typed, emitters loaded by path).

- Server: `DotGameTrailRelay.serve(net, equip, groups_fn, entitlements_fn, roster)` with a `DotTrailEquip`. A client's `DotGameTrailMessage` (id only) is run through `equip`; success is told to everyone with the actor, a refusal is answered to the asker with the id still worn. `add_peer` tells a joiner who wears what, `remove_peer` clears, `revalidate(peer)` drops a trail whose group was lost.
- Client: `DotGameTrailClient.attach(net, registry)`, `node_for = func(actor) -> Node3D`, `request(id)`; an id the pack does not hold draws nothing.
- Delivery: the server advertises `sv_trail_pack=<content id>@<version>` in its rules; set `DotGamePrejoin.trails_fn` to `func(rules): return await trail_client.fetch_pack(cloud, rules)`. A failure is a warning and the join goes ahead.
- Suite: `examples/headless_trails.tscn` (needs `addons/dot_trail` linked).
