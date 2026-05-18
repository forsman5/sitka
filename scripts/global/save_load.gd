extends Node

const SAVE_DIR := "user://saves/"

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

func delete_save(filename: String) -> void:
	DirAccess.remove_absolute(SAVE_DIR + filename)

func save_exists(display_name: String) -> bool:
	return FileAccess.file_exists(SAVE_DIR + _to_filename(display_name) + ".json")

func has_save() -> bool:
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		return false
	var dir := DirAccess.open(SAVE_DIR)
	if dir == null:
		return false
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			dir.list_dir_end()
			return true
		fname = dir.get_next()
	dir.list_dir_end()
	return false

func get_save_list() -> Array:
	var list: Array = []
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		return list
	var dir := DirAccess.open(SAVE_DIR)
	if dir == null:
		return list
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			var f := FileAccess.open(SAVE_DIR + fname, FileAccess.READ)
			if f:
				var data = JSON.parse_string(f.get_as_text())
				f.close()
				if data is Dictionary:
					list.append({
						"filename":    fname,
						"name":        data.get("name", fname.trim_suffix(".json")),
						"saved_at":    int(data.get("saved_at", 0)),
						"saved_local": data.get("saved_local", {}),
						"game_state":  data.get("game_state", {}),
					})
		fname = dir.get_next()
	dir.list_dir_end()
	list.sort_custom(func(a, b): return a["saved_at"] > b["saved_at"])
	return list

func save_game(scene_root: Node, display_name: String) -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var filename := _to_filename(display_name) + ".json"
	var trade_routes := scene_root.get_tree().get_nodes_in_group("trade_routes")
	var data := {
		"version":    1,
		"name":       display_name,
		"saved_at":   Time.get_unix_time_from_system(),
		"saved_local": Time.get_datetime_dict_from_system(false),
		"game_state": _pack_game_state(),
		"camera":     _pack_camera(scene_root),
		"persons":    _pack_group("persons", scene_root),
		"buildings":  _pack_group("buildings", scene_root),
		"foundations": _pack_group("foundations", scene_root),
		"resource_nodes": _pack_group("resource_nodes", scene_root),
		"ships":      _pack_ships(scene_root, trade_routes),
	}
	var f := FileAccess.open(SAVE_DIR + filename, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "\t"))
	f.close()

func load_game(filename: String) -> Dictionary:
	var path := SAVE_DIR + filename
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var text := f.get_as_text()
	f.close()
	var result = JSON.parse_string(text)
	return result if result is Dictionary else {}

func _to_filename(display_name: String) -> String:
	var s := display_name.strip_edges().left(64).replace(" ", "_")
	var result := ""
	for ch in s:
		var code := ch.unicode_at(0)
		if (code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
				or (code >= 97 and code <= 122) or ch == "_" or ch == "-":
			result += ch
	return result if result.length() > 0 else "save"

func _pack_game_state() -> Dictionary:
	return {
		"gold":        GameState.player_gold,
		"wood":        GameState.player_wood,
		"food":        GameState.player_food,
		"time_of_day": GameState.time_of_day,
		"game_speed":  GameState.game_speed,
		"day":         GameState.day_count,
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
