class_name Ship
extends Node3D

const TRADE_REACH := 5.0
const TRADE_INTERVAL := 5.0

@export var speed: float = 5.0

var selected: bool = false
var _move_target: Vector3 = Vector3.INF
var _trade_obj: Node3D = null
var _trade_timer: float = 0.0

@onready var _mesh: MeshInstance3D = $MeshInstance3D
var _mat_normal: Material
var _mat_selected: StandardMaterial3D

func _ready() -> void:
	add_to_group("ships")
	_mat_normal = _mesh.get_surface_override_material(0)
	_mat_selected = StandardMaterial3D.new()
	_mat_selected.albedo_color = Color(0.5, 0.85, 1.0, 1)

func set_selected(value: bool) -> void:
	selected = value
	_mesh.set_surface_override_material(0, _mat_selected if selected else _mat_normal)

func set_move_target(pos: Vector3) -> void:
	_trade_obj = null
	_move_target = Vector3(pos.x, 0.05, pos.z)

func set_trade_objective(node: Node3D) -> void:
	_trade_obj = node
	_move_target = Vector3.INF
	_trade_timer = TRADE_INTERVAL

func objective_label() -> String:
	if is_instance_valid(_trade_obj):
		return "trading" if global_position.distance_to(_trade_obj.global_position) < TRADE_REACH else "en route"
	return "sailing" if _move_target != Vector3.INF else "idle"

func _process(delta: float) -> void:
	if is_instance_valid(_trade_obj):
		var dir := _trade_obj.global_position - global_position
		dir.y = 0.0
		if dir.length() > TRADE_REACH:
			_trade_timer = TRADE_INTERVAL
			var terrain = get_tree().get_first_node_in_group("heightmap_terrain")
			var next_pos := global_position + dir.normalized() * speed * GameState.game_speed * delta
			next_pos.y = 0.05
			if terrain == null or terrain.is_ocean_water(next_pos.x, next_pos.z):
				global_position = next_pos
		else:
			_trade_timer -= delta * GameState.game_speed
			if _trade_timer <= 0.0:
				_trade_timer = TRADE_INTERVAL
				GameState.player_gold += 1
		return
	if _move_target == Vector3.INF:
		return
	var dir := _move_target - global_position
	dir.y = 0.0
	if dir.length() < 0.3:
		_move_target = Vector3.INF
		return
	var terrain = get_tree().get_first_node_in_group("heightmap_terrain")
	var next_pos := global_position + dir.normalized() * speed * GameState.game_speed * delta
	next_pos.y = 0.05
	if terrain == null or terrain.is_ocean_water(next_pos.x, next_pos.z):
		global_position = next_pos
	else:
		_move_target = Vector3.INF
