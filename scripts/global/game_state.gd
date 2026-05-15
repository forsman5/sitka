extends Node

signal gold_changed(amount: int)
signal wood_changed(amount: int)

@export var gather_speed: float = 1.3
@export var game_speed: float = 1.0
@export var pause_on_escape: bool = true
@export var settler_cost: int = 30
@export var forest_hut_cost: int = 50
var time_of_day: float = 0.25

var player_gold: int = 0:
	set(value):
		player_gold = value
		gold_changed.emit(value)

var player_wood: int = 0:
	set(value):
		player_wood = value
		wood_changed.emit(value)
