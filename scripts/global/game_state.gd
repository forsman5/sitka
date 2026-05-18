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
@export var ship_cost: int = 50
var time_of_day: float = 0.25
var pending_load: Dictionary = {}
var current_save_name: String = ""
var day_count: int = 1
@export var show_day_counter: bool = false

var player_gold: int = 0:
	set(value):
		player_gold = value
		gold_changed.emit(value)

var player_wood: int = 0:
	set(value):
		player_wood = value
		wood_changed.emit(value)

var player_food: int = 50:
	set(value):
		player_food = value
		food_changed.emit(value)

func reset() -> void:
	player_gold = 0
	player_wood = 0
	player_food = 50
	game_speed = 1.0
	time_of_day = 0.25
	current_save_name = ""
	day_count = 1
