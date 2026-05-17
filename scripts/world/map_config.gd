class_name MapConfig
extends Resource

@export_group("Island Shape")
@export var world_size: float = 150.0
@export var island_radius: float = 55.0
@export var shore_width: float = 5.0
@export var sea_depth: float = -3.0

@export_group("Noise")
@export var noise_seed: int = 0
@export var noise_frequency: float = 0.018
@export var noise_amplitude: float = 1.5
@export var noise_base_height: float = 2.5

@export_group("Pond")
@export var pond_center: Vector2 = Vector2(5.0, -22.0)
@export var pond_radius: float = 8.0
@export var pond_depth: float = -2.0

@export_group("Spawn Zone")
@export var flatten_center: Vector2 = Vector2(0.0, 0.0)
@export var flatten_radius: float = 25.0
@export var flatten_height: float = 2.2

@export_group("Forest Biome")
@export var forest_center: Vector2 = Vector2(-35.0, 0.0)
@export var forest_radius: float = 25.0

@export_group("Bush Spawning")
@export var bush_zone_center: Vector2 = Vector2(-60.0, -3.0)
@export var bush_zone_radius: float = 70.0

@export_group("Appearance")
@export var beach_height: float = 0.55

@export_group("Gameplay")
@export var town_exclusion_radius: float = 6.0
