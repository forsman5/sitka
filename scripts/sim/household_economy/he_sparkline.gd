class_name HESparkline
extends Control

## Minimal line chart of rolling numeric histories -- no ticks or interaction,
## just a quick shape so a business's cash trend (or goods produced) over its
## last N days is visible at a glance in the business detail panel (see
## he_dashboard.gd). A dashed baseline is drawn wherever 0 falls in the
## current data's range, so a business that's dipped into the red is
## visually obvious even without reading a single number.
##
## set_data() draws one series; set_series() draws several on one shared
## y-axis (an array of {"values": Array[float], "color": Color, "dashed":
## bool (optional)}), which is how the goods-flow charts show several goods,
## and inputs vs. outputs, together. A separate
## axis per series is deliberately not supported yet.

const LINE_COLOR := Color(0.6, 0.85, 0.6)
const BASELINE_COLOR := Color(0.55, 0.55, 0.6, 0.6)
const PADDING := 4.0
## Distinct enough to tell apart on the dark panel; series i uses color i.
const SERIES_COLORS := [
	Color(0.6, 0.85, 0.6),
	Color(0.95, 0.75, 0.4),
	Color(0.5, 0.75, 0.95),
	Color(0.85, 0.6, 0.85),
]
const LABEL_COLOR := Color(0.65, 0.65, 0.7)
const LABEL_FONT_SIZE := 11

## When true, the top of the y-range is printed in the upper-left corner so
## the chart's scale can be read -- useful for unit counts, noise for cash.
var show_max_label := false

var _series: Array = [] # [{"values": Array[float], "color": Color}]

func set_data(values: Array[float]) -> void:
	set_series([{"values": values, "color": LINE_COLOR}])

func set_series(series: Array) -> void:
	_series = series
	queue_redraw()

static func color_for_series(index: int) -> Color:
	return SERIES_COLORS[index % SERIES_COLORS.size()]

func _draw() -> void:
	var longest := 0
	for s in _series:
		longest = maxi(longest, (s["values"] as Array).size())
	if longest < 2:
		return

	# 0 is always inside the range, so the baseline below is a meaningful
	# reference line rather than sitting outside the drawn area.
	var min_v := 0.0
	var max_v := 0.0
	for s in _series:
		for v in s["values"]:
			min_v = minf(min_v, v)
			max_v = maxf(max_v, v)
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

	for s in _series:
		var values: Array = s["values"]
		if values.size() < 2:
			continue
		var points := PackedVector2Array()
		for i in values.size():
			var x: float = PADDING + w * (float(i) / float(values.size() - 1))
			points.append(Vector2(x, y_for_value.call(values[i])))
		if s.get("dashed", false):
			for i in range(points.size() - 1):
				draw_dashed_line(points[i], points[i + 1], s["color"], 2.0, 4.0)
		else:
			draw_polyline(points, s["color"], 2.0, true)

	if show_max_label:
		draw_string(ThemeDB.fallback_font, Vector2(PADDING + 2.0, PADDING + LABEL_FONT_SIZE), "%.1f" % max_v, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE, LABEL_COLOR)
