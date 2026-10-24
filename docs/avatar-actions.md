# Avatar actions

Emotes, poses and gestures: the server checks a request and tells everybody, and each client plays the clip on that player's figure.

`DotGameAvatarActionMessage` (BOTH directions, reliable, not required so an old client still connects) carries the action id; the server's reply adds the actor and the start tick. `DotGameNetcode.build` serves it through `DotGameAvatarActionRelay.serve`, which drops an id the player has not equipped (the starter 13 when the game has no `_avatar_actions_equipped(peer)`), a request faster than `min_interval_sec`, and anything the game's `_avatar_action_veto(peer, id)` refuses.

On the client, `DotGameClient.add_avatar_actions(net, figure_fn, backbone_actions = null)` builds `DotGameAvatarActionClient`: it sends a key press from dot-user-avatar's `DotAvatarActionInput` and plays a relayed start on `figure_fn(actor)` with `DotHumanoidFigure.play_action`, joining the clip late by the tick difference. dot-user-avatar and dot-player-char are reached by path and duck typing, never named. The client's settings node gets the three key rows (`DotMenuSettings.avatar_actions`).

Each game's client bridge must call `DotGameAvatarActionMessage.register(net)` before the schema seals, as the server does; a game that has not does not see the actions. Test: the "avatar actions" section of `examples/game_selftest.tscn`.
