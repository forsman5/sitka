extends SceneTree

## Generates a batch of landscapes, checks determinism and the spec contract,
## prints a per-seed report and writes a contact sheet. Run:
##   Godot --headless --path . --script scripts/valley/harness/check_valley_generator.gd [-- <out.png> <first_seed> <count> <landscape>]
## landscape is river_valley (default), coast or island.

const Generator = preload("res://scripts/valley/gen/valley_generator.gd")
const Relief = preload("res://scripts/valley/gen/valley_gen_relief.gd")
const Spec = preload("res://scripts/valley/gen/valley_spec.gd")

## Seeds that must pass for the harness to succeed; the sketch is allowed to
## reject some seeds, which is the point of stage 7.
const MIN_PASS_FRACTION := 0.3

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var out_path: String = args[0] if args.size() > 0 else "user://valley_gen_contact.png"
	var first_seed: int = int(args[1]) if args.size() > 1 else 1
	var count: int = int(args[2]) if args.size() > 2 else 8
	var landscape: String = args[3] if args.size() > 3 else "river_valley"

	var failures := 0
	var passed := 0
	var thumbs: Array[Image] = []
	var total_ms := 0
	print("landscape: %s" % landscape)
	for i in count:
		var seed_value := first_seed + i
		var result := Generator.generate_seed(seed_value, landscape)
		total_ms += result["ms"]
		var report: Dictionary = result["report"]
		var bad: Array[String] = []
		for c in report["checks"]:
			if not c["ok"]:
				bad.append("%s (%s)" % [c["name"], c["detail"]])
		print("seed %d: %s  %d sites, %d roads, %d fords, %d trees, %d ms%s" % [
			seed_value, "PASS" if report["ok"] else "FAIL", result["sites"].size(),
			result["roads"].size(), result["map"].crossings.size(), result["trees"].size(), result["ms"],
			"" if bad.is_empty() else "\n    " + "\n    ".join(bad)])
		if report["ok"]:
			passed += 1
		thumbs.append(Relief.thumbnail(result, 2))

	# Determinism, and a spec that round-trips through JSON generates the same valley.
	var first := Generator.generate_seed(first_seed, landscape)
	var spec: Spec = Spec.from_dict(JSON.parse_string(JSON.stringify(Spec.preset(landscape, first_seed).to_dict())))
	var again := Generator.generate(spec)
	if again["terrain"].heights != first["terrain"].heights or again["sites"].size() != first["sites"].size():
		print("FAIL: spec round-trip or determinism broke for seed %d" % first_seed)
		failures += 1
	else:
		for i in again["sites"].size():
			if again["sites"][i]["pos"] != first["sites"][i]["pos"]:
				print("FAIL: site %d moved between runs" % i)
				failures += 1

	# The spec is the input: changing it changes the valley.
	var changed: Spec = Spec.preset(landscape, first_seed)
	changed.settlements.append({"role": "fishing", "count": 1, "optional": false})
	changed.tributaries = 0
	var variant := Generator.generate(changed)
	var grew: bool = variant["sites"].size() + variant["failures"].size() == first["sites"].size() + first["failures"].size() + 1
	if variant["terrain"].rivers.size() != (1 if changed.main_river else 0) or not grew:
		print("FAIL: spec changes (no tributaries, extra fishing village) were not honoured")
		failures += 1
	var bad_spec: Spec = Spec.preset(landscape, first_seed)
	bad_spec.landscape = "swamp"
	bad_spec.tributaries = 5
	if bad_spec.validate().size() < 2 or not Generator.generate(bad_spec).has("spec_errors"):
		print("FAIL: invalid spec was not rejected")
		failures += 1

	if float(passed) / float(count) < MIN_PASS_FRACTION:
		print("FAIL: only %d/%d seeds pass validation" % [passed, count])
		failures += 1

	Relief.contact_sheet(thumbs, 4).save_png(out_path)
	print("contact sheet: %s" % ProjectSettings.globalize_path(out_path))
	print("%d/%d seeds pass, mean %d ms per valley" % [passed, count, total_ms / count])
	print("check_valley_generator: %s" % ("FAILED" if failures > 0 else "OK"))
	quit(1 if failures > 0 else 0)
