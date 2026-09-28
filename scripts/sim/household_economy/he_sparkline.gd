class_name HESparkline
extends Control

## Minimal single-line chart of a rolling numeric history -- no axes, ticks,
## or interaction, just a quick shape so a business's cash trend over its
## last N days is visible at a glance in the business detail panel (see
## he_dashboard.gd). A dashed baseline is drawn wherever 0 falls in the
## current data's range, so a business that's dipped into the red is
## visually obvious even without reading a single number.

const LINE_COLOR := Color(0.6, 0.85, 0.6)
const BASELINE_COLOR := Color(0.55, 0.55, 0.6, 0.6)
const PADDING := 4.0

var _values: Array[float] = []

func set_data(values: Array[float]) -> void:
	_values = values
	queue_redraw()

func _draw() -> void:
	if _values.size() < 2:
		return

	var min_v: float = _values[0]
	var max_v: float = _values[0]
	for v in _values:
		min_v = minf(min_v, v)
		max_v = maxf(max_v, v)
	# Guarantee 0 falls inside the range whenever the series actually
	# crosses it, so the baseline below is a meaningful reference line
	# rather than sitting outside the drawn area.
	min_v = minf(min_v, 0.0)
	max_v = maxf(max_v, 0.0)
	var span: float = max_v - min_v
	if span < 0.0001:
		span = 1.0

	var w: float = size.x - PADDING * 2.0
	var h: float = size.y - PADDING * 2.0
	if w <= 0.0 or h <= 0.0:
		return

	var y_for_value := func(v: float) -> float:
		return PADDING + h - (v - min_v) / span * h

	draw_dashed_line(Vector2(PADDING, y_for_value.call(0.0)), Vector2(size.x - PADDING, y_for_value.call(0.0)), BASELINE_COLOR, 1.0)

	var points := PackedVector2Array()
	for i in _values.size():
		var x: float = PADDING + w * (float(i) / float(_values.size() - 1))
		points.append(Vector2(x, y_for_value.call(_values[i])))
	draw_polyline(points, LINE_COLOR, 2.0, true)
