extends Node

const SAVE_PATH := "user://sitka_save.json"

const BUILDING_SCENES := {
	"Capital":      "res://scenes/entities/building/capital.tscn",
	"Forest Hut":   "res://scenes/entities/building/forest_hut.tscn",
	"Dwelling":     "res://scenes/entities/building/house.tscn",
	"Fishing Dock": "res://scenes/entities/building/dock.tscn",
}

const FOUNDATION_SCENES := {
	"Forest Hut Foundation": "res://scenes/entities/building/forest_hut_foundation.tscn",
	"House Foundation":      "res://scenes/entities/building/house_foundation.tscn",
	"Dock Foundation":       "res://scenes/entities/building/dock_foundation.tscn",
}

const RESOURCE_SCENES := {
	0: "res://scenes/entities/resource_node_wood.tscn",
	2: "res://scenes/entities/resource_node_food.tscn",
	3: "res://scenes/entities/resource_node_gold.tscn",
}

func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)

func save_game(scene_root: Node) -> void:
	var trade_routes := scene_root.get_tree().get_nodes_in_group("trade_routes")
	var data := {
		"version": 1,
		"game_state": _pack_game_state(),
		"camera":     _pack_camera(scene_root),
		"persons":    _pack_group("persons", scene_root),
		"buildings":  _pack_group("buildings", scene_root),
		"foundations": _pack_group("foundations", scene_root),
		"resource_nodes": _pack_group("resource_nodes", scene_root),
		"ships":      _pack_ships(scene_root, trade_routes),
	}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "\t"))
	f.close()

func load_game() -> Dictionary:
	if not has_save():
		return {}
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	var text := f.get_as_text()
	f.close()
	var result = JSON.parse_string(text)
	return result if result is Dictionary else {}

func _pack_game_state() -> Dictionary:
	return {
		"gold":        GameState.player_gold,
		"wood":        GameState.player_wood,
		"food":        GameState.player_food,
		"time_of_day": GameState.time_of_day,
		"game_speed":  GameState.game_speed,
	}

func _pack_camera(scene_root: Node) -> Dictionary:
	var cam := scene_root.get_tree().get_first_node_in_group("rts_camera")
	if cam == null:
		return {"x": 0.0, "z": 0.0}
	return {"x": cam.position.x, "z": cam.position.z}

func _pack_group(group: String, scene_root: Node) -> Array:
	var result: Array = []
	for node in scene_root.get_tree().get_nodes_in_group(group):
		if is_instance_valid(node) and node.has_method("get_save_data"):
			result.append(node.get_save_data())
	return result

func _pack_ships(scene_root: Node, trade_routes: Array) -> Array:
	var result: Array = []
	for node in scene_root.get_tree().get_nodes_in_group("ships"):
		if is_instance_valid(node) and node.has_method("get_save_data"):
			result.append(node.get_save_data(trade_routes))
	return result
