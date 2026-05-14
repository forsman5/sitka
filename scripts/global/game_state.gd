extends Node

signal gold_changed(amount: int)

@export var gather_speed: float = 1.0

var player_gold: int = 0:
	set(value):
		player_gold = value
		gold_changed.emit(value)
