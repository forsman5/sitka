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
## y-axis (an array of {"values": Array[float], "color": Color, "name":
## String (optional), "dashed": bool (optional)}), which is how the goods-flow
## charts show several goods, and inputs vs. outputs, together.
##
## Hovering any chart built on this control shows a marker and a readout of
## each series' value at that day (prefixed with the series' "name" when it
## has one), so a new chart gets the readout for free -- just name its series.
## A series may also carry "details": [{"name", "values"}], extra per-day
## numbers listed under its value in the readout without being drawn. A separate
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

var _series: Array = [] # [{"values": Array[float], "color": Color, optional "name": String}]
## Index of the data point under the mouse, or -1 when not hovering.
var _hover_index := -1

func _ready() -> void:
	mouse_exited.connect(_on_mouse_exited)

func _on_mouse_exited() -> void:
	_hover_index = -1
	queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if not event is InputEventMouseMotion:
		return
	var longest := 0
	for s in _series:
		longest = maxi(longest, (s["values"] as Array).size())
	var w: float = size.x - PADDING * 2.0
	if longest < 2 or w <= 0.0:
		_hover_index = -1
	else:
		var t: float = clampf((event.position.x - PADDING) / w, 0.0, 1.0)
		_hover_index = roundi(t * float(longest - 1))
	queue_redraw()

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
		if min_v < -0.0001:
			draw_string(ThemeDB.fallback_font, Vector2(PADDING + 2.0, size.y - PADDING), "%.1f" % min_v, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE, LABEL_COLOR)

	if _hover_index >= 0 and _hover_index < longest:
		_draw_hover(longest, w, y_for_value)

## Vertical marker at the hovered point plus a small readout box listing each
## series' value there (and how many days ago, for the x position).
func _draw_hover(longest: int, w: float, y_for_value: Callable) -> void:
	var x: float = PADDING + w * (float(_hover_index) / float(longest - 1))
	draw_line(Vector2(x, PADDING), Vector2(x, size.y - PADDING), BASELINE_COLOR, 1.0)
	var font := ThemeDB.fallback_font
	var lines: Array = ["%d days ago" % (longest - 1 - _hover_index) if _hover_index < longest - 1 else "latest"]
	var colors: Array = [LABEL_COLOR]
	for s in _series:
		var values: Array = s["values"]
		if _hover_index >= values.size():
			continue
		var label: String = s.get("name", "")
		lines.append("%s%.2f" % [label + ": " if label != "" else "", values[_hover_index]])
		colors.append(s["color"])
		# Readout-only extras (not drawn): {"name", "values"} entries shown
		# under the series' own value, e.g. the day's made/sold beside stock.
		for detail in s.get("details", []):
			var detail_values: Array = detail["values"]
			if _hover_index < detail_values.size():
				lines.append("   %s %.2f" % [detail["name"], detail_values[_hover_index]])
				colors.append(LABEL_COLOR)
		draw_circle(Vector2(x, y_for_value.call(values[_hover_index])), 3.0, s["color"])
	var line_h: float = LABEL_FONT_SIZE + 3.0
	var box_w := 0.0
	for line in lines:
		box_w = maxf(box_w, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE).x)
	box_w += 8.0
	var box_h: float = line_h * lines.size() + 4.0
	var box_x: float = x + 8.0
	if box_x + box_w > size.x:
		box_x = x - 8.0 - box_w
	var box_rect := Rect2(box_x, PADDING, box_w, box_h)
	draw_rect(box_rect, Color(0.1, 0.1, 0.13, 0.92))
	draw_rect(box_rect, BASELINE_COLOR, false, 1.0)
	for i in lines.size():
		draw_string(font, Vector2(box_x + 4.0, PADDING + 2.0 + line_h * (i + 1) - 3.0), lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE, colors[i])
