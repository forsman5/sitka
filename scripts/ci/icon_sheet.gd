## Renders every good icon (plus gold) at 64px and 20px on dark+light backgrounds
## to user://icon_sheet.png. Run: godot --path . --script res://scripts/ci/icon_sheet.gd
extends SceneTree

func _init() -> void:
	var tex: Array[Texture2D] = []
	for t in Commodity.ALL:
		var icon := Commodity.icon_of(t)
		print("%s -> %s" % [Commodity.name_of(t), "OK" if icon else "MISSING"])
		tex.append(icon)
	tex.append(Commodity.gold_icon())
	print("Gold -> %s" % ("OK" if tex[-1] else "MISSING"))
	var sheet := Image.create(tex.size() * 80, 180, false, Image.FORMAT_RGBA8)
	sheet.fill_rect(Rect2i(0, 0, sheet.get_width(), 90), Color(0.1, 0.1, 0.14))
	sheet.fill_rect(Rect2i(0, 90, sheet.get_width(), 90), Color(0.85, 0.85, 0.8))
	for i in tex.size():
		if tex[i] == null:
			continue
		var img := tex[i].get_image()
		img.convert(Image.FORMAT_RGBA8)
		for row in 2:
			var big := img.duplicate()
			sheet.blend_rect(big, Rect2i(0, 0, big.get_width(), big.get_height()), Vector2i(i * 80 + 8, row * 90 + 4))
			var small := img.duplicate()
			small.resize(20, 20, Image.INTERPOLATE_LANCZOS)
			sheet.blend_rect(small, Rect2i(0, 0, 20, 20), Vector2i(i * 80 + 30, row * 90 + 70))
	sheet.save_png("C:/Users/jrfor/.claude/jobs/5f9df8f0/tmp/icon_sheet.png")
	quit()
