extends Node

signal gold_changed(amount: int)

var player_gold: int = 0:
	set(value):
		player_gold = value
		gold_changed.emit(value)
