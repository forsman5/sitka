extends Node

signal gold_changed(amount: int)
signal wood_changed(amount: int)

@export var gather_speed: float = 1.0

var player_gold: int = 0:
	set(value):
		player_gold = value
		gold_changed.emit(value)

var player_wood: int = 0:
	set(value):
		player_wood = value
		wood_changed.emit(value)
