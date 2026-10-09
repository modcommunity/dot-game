class_name DotGameContent
extends RefCounted

## The map packs a SERVER names for the running game, fetched and found on the disk.
##
## [codeblock]
## # in a module's _game_load(), or wherever the catalogue is (re)built:
## for root in await DotGameContent.map_dirs(server, "courses"):
##     catalogue.add_directory(root)
## [/codeblock]
##
## [b]Why the server names them and the game does not.[/b] A game's `game.yml` travels in
## its pack and is replaced by each release's, so a map the game named there could only
## change with a release of the game -- and a server owner had no say at all. The server's
## own list (dot-server-deploy's `cfg/content.yml`, or any host that fills
## [member DotGameDescriptor.maps]) is now where maps come from; a game ships its own test
## maps in its pack and reads everything else through here. A map pack may hold one map or
## a hundred: it is a pack, and the game scans the same subdirectory in it that it scans in
## its own tree.
##
## [b]The four copies this replaces.[/b] Three games read `current_server_dependencies()`
## for a `courses/` or `maps/` directory and a fourth read its client dependencies the same
## way, each written out by hand. They differed only in the subdirectory name, and two of
## the three forgot to call it again after a catalogue reload, which dropped every
## delivered course on the first `wo_reload`. One function, and a game passes its
## subdirectory.
##
## [b]The packs are fetched here, because dot-server does not fetch them.[/b] A game's
## `maps` are not prefetched at load -- for a game with one large pack per map that would
## be a gigabyte before the first player -- so a game whose maps are small documents asks
## for all of them at once, and a game with large maps fetches one when it changes to it
## ([method ensure_one]). Both go through dot-cloud's `ensure`, which is idempotent and
## returns at once for a pack already mounted.
##
## [b]`server_dependencies` are read too[/b], because that is where a map pack used to be
## named and a server that has not moved its list to the host's config must keep working.
## Everything is duck-typed: a dot-server without `current_maps`, or a build with no
## dot-cloud at all, gets an empty list rather than a parse error.

const CHANNEL := "game.content"

## The service dot-cloud registers its client under.
const CLOUD_SERVICE := &"dot_cloud_client"


## The pack keys (`<owner>/<name>@<version>`) the server names for the running game's maps,
## the server-only dependencies after them. Empty when nothing is named or the server
## predates the fields.
static func map_keys(server: Object, with_server_dependencies := true) -> PackedStringArray:
	var out := PackedStringArray()
	var games: Object = server.get("games") if server != null else null

	if games == null:
		return out

	var getters := ["current_maps"]

	if with_server_dependencies:
		getters.append("current_server_dependencies")

	for getter in getters:
		if not games.has_method(getter):
			continue

		for key: String in games.call(getter):
			if not out.has(key):
				out.append(key)

	return out


## Where a pack key mounts: `res://dot_cloud/<id>/<version>`. dot-cloud's mount_prefix_for,
## spelled out so this file does not need dot-cloud to parse.
static func mount_of(key: String) -> String:
	var at := key.rfind("@")
	var id := key.substr(0, at) if at > 0 else key
	var version := key.substr(at + 1) if at > 0 else ""
	return "res://dot_cloud/%s/%s" % [id, version if version != "" else "0.0.0"]


## Fetches and mounts one pack by key. Succeeds at once when it is already mounted, and
## fails with the reason when there is no content client or the origin refuses it.
static func ensure_one(key: String) -> DotResult:
	var cloud: Object = DotRegistry.get_service(CLOUD_SERVICE)

	if cloud == null or not cloud.has_method("ensure"):
		return DotResult.fail(
			DotError.CODE_STATE,
			"There is no content client to fetch %s with." % key,
			"a build without dot-cloud plays only the maps in its own tree"
		)

	var at := key.rfind("@")

	if at <= 0:
		return DotResult.fail(DotError.CODE_INVALID, "A map pack is <owner>/<name>@<version>.", key)

	var got: Variant = await cloud.call("ensure", StringName(key.substr(0, at)), key.substr(at + 1))

	if not (got is DotResult):
		return DotResult.fail(DotError.CODE_INTERNAL, "The content client answered with something else.")

	return got


## Every map pack the server names, fetched, as `<mount>/<subdir>` directories that exist.
## A pack that cannot be fetched is logged and left out: one missing map is a map nobody
## can change to, not a game that will not load.
static func map_dirs(server: Object, subdir: String, with_server_dependencies := true) -> PackedStringArray:
	var out := PackedStringArray()

	for key in map_keys(server, with_server_dependencies):
		var root := mount_of(key)

		if not DirAccess.dir_exists_absolute(root):
			var got: DotResult = await ensure_one(key)

			if not got.ok:
				DotLog.warn(CHANNEL, "a map pack the server names could not be fetched", {
					"pack": key, "why": str(got.error),
				})
				continue

		var dir := root.path_join(subdir) if subdir != "" else root

		if DirAccess.dir_exists_absolute(dir):
			out.append(dir)
		else:
			DotLog.warn(CHANNEL, "a map pack has nothing where this game looks for maps", {
				"pack": key, "looked_in": subdir,
			})

	return out
