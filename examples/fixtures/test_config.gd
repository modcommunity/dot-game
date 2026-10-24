extends DotConfig

## Fixture for headless_config: every kind of field the binder maps.

func env_prefix() -> String:
	return "TGTEST_"


func validate() -> DotResult:
	if count == 13:
		return DotResult.fail(DotError.CODE_INVALID, "count 13 is unlucky")
	return DotResult.success(null)


@export_group("Movement")
## Metres per second on foot. Second sentence is kept.
##
## Second paragraph is dropped.
@export_range(0.0, 20.0, 0.5) var speed: float = 2.0

## Jumps allowed.
@export_range(0, 100, 1) var count: int = 5

@export_group("Rules")
## Who wins a tie.
@export_enum("draw", "left", "right:5") var tie: int = 1

## Friendly fire on.
@export var friendly_fire: bool = false

## Name shown on the board.
@export var label: String = "default"

## Tags.
@export var tags: PackedStringArray = PackedStringArray(["x"])

var not_exported_state := 1
