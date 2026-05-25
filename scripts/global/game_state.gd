extends Node

signal gold_changed(amount: int)
signal wood_changed(amount: int)
signal food_changed(amount: int)

@export var gather_speed: float = 1.3
@export var game_speed: float = 1.0
@export var pause_on_escape: bool = true
@export var settler_cost: int = 30
@export var forest_hut_cost: int = 50
@export var house_cost: int = 40
@export var dock_cost: int = 60
@export var barn_cost: int = 60
@export var ship_cost: int = 50
var time_of_day: float = 0.25
var pending_load: Dictionary = {}
var current_save_name: String = ""
var day_count: int = 1
@export var show_day_counter: bool = false

var _economy_relay: IslandEconomy = null

func _ready() -> void:
	IslandsManager.active_island_changed.connect(_relay_economy)

func _relay_economy(island: Node) -> void:
	if _economy_relay:
		_economy_relay.gold_changed.disconnect(gold_changed.emit)
		_economy_relay.wood_changed.disconnect(wood_changed.emit)
		_economy_relay.food_changed.disconnect(food_changed.emit)
	_economy_relay = island.economy if island else null
	if _economy_relay:
		_economy_relay.gold_changed.connect(gold_changed.emit)
		_economy_relay.wood_changed.connect(wood_changed.emit)
		_economy_relay.food_changed.connect(food_changed.emit)
		gold_changed.emit(_economy_relay.gold)
		wood_changed.emit(_economy_relay.wood)
		food_changed.emit(_economy_relay.food)

var player_gold: int:
	get: return _economy_relay.gold if _economy_relay else 0
	set(v):
		if _economy_relay:
			_economy_relay.gold = v
		else:
			gold_changed.emit(v)

var player_wood: int:
	get: return _economy_relay.wood if _economy_relay else 0
	set(v):
		if _economy_relay:
			_economy_relay.wood = v
		else:
			wood_changed.emit(v)

var player_food: int:
	get: return _economy_relay.food if _economy_relay else 0
	set(v):
		if _economy_relay:
			_economy_relay.food = v
		else:
			food_changed.emit(v)

func reset() -> void:
	if _economy_relay:
		_economy_relay.reset()
	game_speed = 1.0
	time_of_day = 0.25
	current_save_name = ""
	day_count = 1
