extends DotConfig

## Fixture for headless_config: a config that declares make_binder, grouped into two files.

const CFG_FILES := {"Movement": "move"}


static func make_binder(config: DotConfig, json_path := "") -> DotGameConfigBinder:
	var b := DotGameConfigBinder.create(config, "tg", "tg", json_path)
	b.grouped = true
	b.group_files = CFG_FILES
	return b


func env_prefix() -> String:
	return "TGTEST_"


@export_group("Movement")
## Metres per second.
@export var speed: float = 2.0

@export_group("Rules")
## Friendly fire on.
@export var friendly_fire: bool = false
