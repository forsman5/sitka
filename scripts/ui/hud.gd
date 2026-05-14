extends CanvasLayer

@onready var _gold_label: Label = $Root/GoldLabel

func _ready() -> void:
	GameState.gold_changed.connect(_on_gold_changed)
	_gold_label.text = "Gold: %d" % GameState.player_gold

func _on_gold_changed(amount: int) -> void:
	_gold_label.text = "Gold: %d" % amount
