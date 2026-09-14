extends Control

const Dashboard = preload("res://scripts/sim/dashboard.gd")

## Small checked-in graph fixture for the "Large Valleys" button, per
## docs/multivalley-scale-probe.md's own exception for a small reproducible
## fixture. Regenerate with:
##   py tools/generate_multivalley.py --settlements 24 --valleys 4 --seed 42 --out data/sample_multivalley.json
const LARGE_VALLEYS_GRAPH := "res://data/sample_multivalley.json"

@onready var _load_btn: Button = $Panel/VBox/LoadButton

func _ready() -> void:
	get_tree().paused = false
	_load_btn.disabled = not SaveLoad.has_save()

func _on_start_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/world/world.tscn")

func _on_load_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/load_game.tscn")

func _on_single_valley_sim_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/sim/dashboard.tscn")

func _on_large_valleys_sim_pressed() -> void:
	Dashboard.pending_graph_path = LARGE_VALLEYS_GRAPH
	get_tree().change_scene_to_file("res://scenes/sim/dashboard.tscn")

func _on_river_valley_view_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/valley/river_valley.tscn")
