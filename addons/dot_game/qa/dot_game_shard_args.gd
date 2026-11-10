class_name DotGameShardArgs
extends RefCounted

## What a sharded suite reads from its command line, once: `game.sh test NAME.SHARD` runs the suite with `-- --shard SHARD` and
## `test NAME.merge` with `-- --merge LOG...` (the `suite_shards` feature of dot-game-template's game.sh). Each shard is a whole run of its
## own part and fails on its own; the merge only holds that nothing went missing. Every function takes the arguments as a parameter
## (default: the process's user arguments) so a selftest can feed it.


## The shard this run plays, "" for the whole suite.
static func shard(args: PackedStringArray = OS.get_cmdline_user_args()) -> String:
	var at := args.find("--shard")
	return args[at + 1] if at >= 0 and at + 1 < args.size() else ""


## True when this run is a merge of the shards' logs.
static func is_merge(args: PackedStringArray = OS.get_cmdline_user_args()) -> bool:
	return args.has("--merge")


## The logs a merge run is given, empty when this is not a merge.
static func merge_logs(args: PackedStringArray = OS.get_cmdline_user_args()) -> PackedStringArray:
	var at := args.find("--merge")
	return PackedStringArray(args.slice(at + 1)) if at >= 0 else PackedStringArray()


## The items this shard plays when the suite deals them round-robin into [param count] shards named `m0`..`m<count-1>`
## (item i belongs to shard `m<i % count>`); "" plays all of them.
static func slice(items: Array, shard_name: String, count: int, prefix := "m") -> Array:
	if shard_name == "":
		return items.duplicate()
	var out := []
	for i in items.size():
		if shard_name == "%s%d" % [prefix, i % count]:
			out.append(items[i])
	return out


## Logs that are not on disk.
static func missing(logs: PackedStringArray) -> Array:
	return Array(logs).filter(func(path: String) -> bool: return not FileAccess.file_exists(path))


## The sum of "N sections entered" over the logs: the merge holds it against the whole suite's declared count.
static func sections_entered(logs: PackedStringArray) -> int:
	var total := 0
	var rx := RegEx.create_from_string("(?m)^(\\d+) sections entered")
	for path in logs:
		var m := rx.search(FileAccess.get_file_as_string(path))
		if m != null:
			total += int(m.get_string(1))
	return total
