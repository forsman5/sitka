extends Building

var _light: OmniLight3D

func _ready() -> void:
	super._ready()
	add_to_group("capital")
	_light = OmniLight3D.new()
	_light.position = Vector3(0.0, 1.5, 0.0)
	_light.light_color = Color(1.0, 0.8, 0.45)
	_light.omni_range = 10.0
	_light.light_energy = 0.0
	add_child(_light)

func _process(_delta: float) -> void:
	# square the distance from noon so lights are mostly off during day
	var night := pow(absf(GameState.time_of_day - 0.5) * 2.0, 2.0)
	_light.light_energy = night * 2.5
