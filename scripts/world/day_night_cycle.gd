extends Node

const WAKE_TIME := 5.5 / 24.0

@export var seconds_per_day: float = 120.0
@export var min_ambient_energy: float = 0.15
@export var day_night_enabled: bool = true

@onready var light: DirectionalLight3D = get_parent().get_node("DirectionalLight3D")
@onready var world_env: WorldEnvironment = get_parent().get_node("WorldEnvironment")

var _prev_time: float = -1.0

# [time(0-1), light_energy, light_color, ambient_energy, ambient_color, bg_color]
# 0.0=midnight, 0.25=dawn, 0.5=noon, 0.75=dusk, 1.0=midnight
const _KEYS := [
	[0.00, 0.0,  Color(0.2,  0.2,  0.4,  1), 0.05, Color(0.15, 0.15, 0.3,  1), Color(0.03, 0.03, 0.08, 1)],
	[0.25, 0.5,  Color(1.0,  0.6,  0.3,  1), 0.25, Color(0.5,  0.45, 0.4,  1), Color(0.55, 0.45, 0.35, 1)],
	[0.50, 1.2,  Color(1.0,  0.98, 0.9,  1), 0.40, Color(0.6,  0.65, 0.7,  1), Color(0.15, 0.18, 0.22, 1)],
	[0.75, 0.5,  Color(1.0,  0.5,  0.2,  1), 0.25, Color(0.5,  0.4,  0.35, 1), Color(0.45, 0.3,  0.2,  1)],
	[1.00, 0.0,  Color(0.2,  0.2,  0.4,  1), 0.05, Color(0.15, 0.15, 0.3,  1), Color(0.03, 0.03, 0.08, 1)],
]

func _process(delta: float) -> void:
	if day_night_enabled:
		var prev := GameState.time_of_day
		GameState.time_of_day = fmod(
			GameState.time_of_day + delta * GameState.game_speed / seconds_per_day, 1.0)
		if _prev_time >= 0.0 and prev < WAKE_TIME and GameState.time_of_day >= WAKE_TIME:
			GameState.day_count += 1
		_prev_time = GameState.time_of_day
	_apply(GameState.time_of_day)

func _apply(t: float) -> void:
	var a: Array = _KEYS[0]
	var b: Array = _KEYS[1]
	for i in range(_KEYS.size() - 1):
		if t >= _KEYS[i][0] and t <= _KEYS[i + 1][0]:
			a = _KEYS[i]
			b = _KEYS[i + 1]
			break
	var span: float = b[0] - a[0]
	var f: float = (t - a[0]) / span if span > 0.0 else 0.0

	light.light_energy = lerpf(a[1], b[1], f)
	light.light_color = (a[2] as Color).lerp(b[2], f)

	var env := world_env.environment
	env.ambient_light_energy = maxf(lerpf(a[3], b[3], f), min_ambient_energy)
	env.ambient_light_color = (a[4] as Color).lerp(b[4], f)
	env.background_color = (a[5] as Color).lerp(b[5], f)
