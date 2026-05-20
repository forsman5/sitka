extends Node

signal active_island_changed(island: Node)
signal islands_changed()

var islands: Array[Node] = []
var active_island: Node = null

func register_island(island: Node) -> void:
	if not islands.has(island):
		islands.append(island)
		islands_changed.emit()
	if active_island == null:
		_set_active(island)

func unregister_island(island: Node) -> void:
	islands.erase(island)
	islands_changed.emit()
	if active_island == island:
		_set_active(islands[0] if not islands.is_empty() else null)

func set_active_island(island: Node) -> void:
	_set_active(island)

func _set_active(island: Node) -> void:
	active_island = island
	active_island_changed.emit(island)

func get_jobs_manager() -> Node:
	return active_island.jobs_manager if active_island else null

func total_gold() -> int:
	var t := 0
	for i in islands:
		t += i.economy.gold
	return t

func total_wood() -> int:
	var t := 0
	for i in islands:
		t += i.economy.wood
	return t

func total_food() -> int:
	var t := 0
	for i in islands:
		t += i.economy.food
	return t
