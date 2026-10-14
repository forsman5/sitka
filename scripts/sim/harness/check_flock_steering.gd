extends SceneTree

## Flocking acceptance check for OnFootSheep (see docs/sheep-flocking-plan.md).
## 14 sheep are driven by a scripted dog for a minute of sim time; cohesion C,
## polarization P and elongation E are compared against the paper's observables
## (Jadhav et al. 2024: C ~1.2 m, P ~0.85, E mode < 1). Run with:
##   godot --headless --script res://scripts/sim/harness/check_flock_steering.gd

const SheepScript = preload("res://scripts/on_foot/on_foot_sheep.gd")

const N := 14
const DRIVE_SECONDS := 60.0
const WARMUP_SECONDS := 10.0
## Dog trails the barycentre by this much along the drive direction.
const DOG_TRAIL := 5.0
const SEED := 20240

## Tolerances are looser than the paper's: our sheep run ~4x faster with a frame
## accel clamp, and spacing is body-scaled to the capsule.
const C_MAX := 4.0
const P_MIN := 0.7
const E_MAX := 1.0

class StubDog extends Node3D:
	signal barked(pos)
	func scare_radius() -> float:
		return 8.0
	func bark_radius() -> float:
		return 12.0

var _ok := true
var _sheep: Array = []
var _dog: StubDog
var _t := 0.0
var _c_sum := 0.0
var _p_sum := 0.0
var _e_samples: Array = []
var _samples := 0
var _max_straggle := 0.0

func _initialize() -> void:
	seed(SEED)
	var floor_body := StaticBody3D.new()
	var floor_col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1000, 1, 1000)
	floor_col.shape = box
	floor_body.add_child(floor_col)
	floor_body.position.y = -0.5
	root.add_child(floor_body)

	_dog = StubDog.new()
	_dog.add_to_group("on_foot_player")
	root.add_child(_dog)
	for i in N:
		var s: CharacterBody3D = SheepScript.new()
		s.position = Vector3(randf_range(-2.0, 2.0), 0.05, randf_range(-2.0, 2.0))
		root.add_child(s)
		_sheep.append(s)

func _physics_process(delta: float) -> bool:
	_t += delta
	var bary := _barycentre()
	# Drive along +X: dog sits DOG_TRAIL behind the barycentre.
	_dog.global_position = Vector3(bary.x - DOG_TRAIL, 0.0, bary.z)
	if _t >= WARMUP_SECONDS:
		_sample(bary)
	if _t >= WARMUP_SECONDS + DRIVE_SECONDS:
		_report()
		return true
	return false

func _barycentre() -> Vector3:
	var c := Vector3.ZERO
	for s in _sheep:
		c += s.global_position
	c /= _sheep.size()
	c.y = 0.0
	return c

func _sample(bary: Vector3) -> void:
	var c := 0.0
	var vsum := Vector3.ZERO
	var along: Array = []
	var across: Array = []
	var worst := 0.0
	for s in _sheep:
		var off: Vector3 = s.global_position - bary
		off.y = 0.0
		c += off.length()
		worst = maxf(worst, off.length())
		along.append(off.x)
		across.append(off.z)
		var v: Vector3 = s.velocity
		v.y = 0.0
		if v.length() > 0.2:
			vsum += v.normalized()
	_c_sum += c / _sheep.size()
	_p_sum += vsum.length() / _sheep.size()
	_max_straggle = maxf(_max_straggle, worst)
	_e_samples.append(_extent(along) / maxf(_extent(across), 0.01))
	_samples += 1

func _extent(vals: Array) -> float:
	var lo: float = vals.min()
	var hi: float = vals.max()
	return hi - lo

func _assert(condition: bool, message: String) -> void:
	if not condition:
		_ok = false
		push_error("FAIL: " + message)

func _report() -> void:
	var c := _c_sum / _samples
	var p := _p_sum / _samples
	_e_samples.sort()
	var e: float = _e_samples[_e_samples.size() / 2]
	var travelled := _barycentre().x
	print("flock: C=%.2f m  P=%.2f  E(median)=%.2f  max straggle=%.1f m  travelled=%.0f m" % [c, p, e, _max_straggle, travelled])
	_assert(c <= C_MAX, "cohesion %.2f > %.1f" % [c, C_MAX])
	_assert(p >= P_MIN, "polarization %.2f < %.2f" % [p, P_MIN])
	_assert(e < E_MAX, "median elongation %.2f >= %.1f" % [e, E_MAX])
	_assert(travelled > 50.0, "flock only travelled %.0f m (driven?)" % travelled)
	print("FLOCK STEERING %s" % ("OK" if _ok else "FAILED"))
	quit(0 if _ok else 1)
