extends Node3D

const GRID_SIZE := 128
const WORLD_SIZE := 150.0
const ISLAND_RADIUS := 55.0
const SHORE_WIDTH := 5.0
const SEA_DEPTH := -3.0

const POND_CENTER := Vector2(5.0, -22.0)
const POND_RADIUS := 8.0
const POND_DEPTH := -2.0

const FLATTEN_CENTER := Vector2(0.0, 0.0)
const FLATTEN_RADIUS := 25.0

const HEIGHT_TEX_MIN   := -4.0
const HEIGHT_TEX_RANGE := 10.0

var height_data: PackedFloat32Array
var _height_tex: ImageTexture
var _nav_array_mesh: ArrayMesh
var _plane_mesh: PlaneMesh
var _visual_mat: ShaderMaterial

@onready var _mesh_instance: MeshInstance3D = $MeshInstance3D
@onready var _collision_shape: CollisionShape3D = $StaticBody3D/CollisionShape3D

func _ready() -> void:
	add_to_group("heightmap_terrain")
	generate()

func generate(p_seed: int = 0) -> void:
	_generate_heights(p_seed)
	_build_mesh()
	_build_collision()

func get_height(world_x: float, world_z: float) -> float:
	var half := WORLD_SIZE * 0.5
	var gx: float = clampf((world_x + half) / WORLD_SIZE * float(GRID_SIZE - 1), 0.0, float(GRID_SIZE) - 1.001)
	var gz: float = clampf((world_z + half) / WORLD_SIZE * float(GRID_SIZE - 1), 0.0, float(GRID_SIZE) - 1.001)
	var ix := int(gx)
	var iz := int(gz)
	var fx: float = gx - ix
	var fz: float = gz - iz
	var h00 := height_data[iz * GRID_SIZE + ix]
	var h10 := height_data[iz * GRID_SIZE + ix + 1]
	var h01 := height_data[(iz + 1) * GRID_SIZE + ix]
	var h11 := height_data[(iz + 1) * GRID_SIZE + ix + 1]
	return lerp(lerp(h00, h10, fx), lerp(h01, h11, fx), fz)

func _generate_heights(p_seed: int) -> void:
	height_data = PackedFloat32Array()
	height_data.resize(GRID_SIZE * GRID_SIZE)

	var noise := FastNoiseLite.new()
	noise.seed = p_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.018
	noise.fractal_octaves = 4

	for gz_i in range(GRID_SIZE):
		for gx_i in range(GRID_SIZE):
			var wx := (float(gx_i) / (GRID_SIZE - 1) - 0.5) * WORLD_SIZE
			var wz := (float(gz_i) / (GRID_SIZE - 1) - 0.5) * WORLD_SIZE

			var dist := Vector2(wx, wz).length()
			var island_mask := 1.0 - smoothstep(ISLAND_RADIUS - SHORE_WIDTH, ISLAND_RADIUS, dist)

			var noise_h := noise.get_noise_2d(wx, wz) * 1.5 + 2.5
			var h := lerpf(SEA_DEPTH, noise_h, island_mask)

			var pond_dist := Vector2(wx, wz).distance_to(POND_CENTER)
			if pond_dist < POND_RADIUS:
				var t := 1.0 - smoothstep(POND_RADIUS * 0.3, POND_RADIUS * 0.8, pond_dist)
				h = lerpf(h, POND_DEPTH, t)

			var flat_dist := Vector2(wx, wz).distance_to(FLATTEN_CENTER)
			if flat_dist < FLATTEN_RADIUS * 1.3 and dist < ISLAND_RADIUS - SHORE_WIDTH:
				var t := 1.0 - smoothstep(FLATTEN_RADIUS * 0.4, FLATTEN_RADIUS * 1.3, flat_dist)
				h = lerpf(h, 2.2, t)

			height_data[gz_i * GRID_SIZE + gx_i] = h

func _build_mesh() -> void:
	# Height texture for the visual shader.
	var img := Image.create(GRID_SIZE, GRID_SIZE, false, Image.FORMAT_RF)
	for gz_i in range(GRID_SIZE):
		for gx_i in range(GRID_SIZE):
			var h := height_data[gz_i * GRID_SIZE + gx_i]
			var n := (h - HEIGHT_TEX_MIN) / HEIGHT_TEX_RANGE
			img.set_pixel(gx_i, gz_i, Color(n, 0.0, 0.0, 1.0))
	_height_tex = ImageTexture.create_from_image(img)

	# ArrayMesh with real heights — used for navmesh baking (CPU-side reads), not rendering.
	# D3D12/Godot 4.6.2 bug: dynamically created ArrayMeshes are invisible on AMD hardware.
	var nav_cell := WORLD_SIZE / float(GRID_SIZE - 1)
	var nav_half := WORLD_SIZE * 0.5
	var nav_verts := PackedVector3Array()
	nav_verts.resize(GRID_SIZE * GRID_SIZE)
	var nav_indices := PackedInt32Array()
	for gz_i in range(GRID_SIZE):
		for gx_i in range(GRID_SIZE):
			var idx := gz_i * GRID_SIZE + gx_i
			nav_verts[idx] = Vector3(gx_i * nav_cell - nav_half, height_data[idx], gz_i * nav_cell - nav_half)
	for gz_i in range(GRID_SIZE - 1):
		for gx_i in range(GRID_SIZE - 1):
			var a := gz_i * GRID_SIZE + gx_i
			nav_indices.append(a); nav_indices.append(a + GRID_SIZE); nav_indices.append(a + 1)
			nav_indices.append(a + 1); nav_indices.append(a + GRID_SIZE); nav_indices.append(a + GRID_SIZE + 1)
	var nav_arrays: Array = []
	nav_arrays.resize(Mesh.ARRAY_MAX)
	nav_arrays[Mesh.ARRAY_VERTEX] = nav_verts
	nav_arrays[Mesh.ARRAY_INDEX]  = nav_indices
	_nav_array_mesh = ArrayMesh.new()
	_nav_array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, nav_arrays)

	# PlaneMesh renders correctly on D3D12 — vertex shader displaces by height texture.
	_plane_mesh = PlaneMesh.new()
	_plane_mesh.size = Vector2(WORLD_SIZE, WORLD_SIZE)
	_plane_mesh.subdivide_width = GRID_SIZE - 2
	_plane_mesh.subdivide_depth = GRID_SIZE - 2

	_visual_mat = ShaderMaterial.new()
	_visual_mat.shader = load("res://shaders/terrain.gdshader")
	_visual_mat.set_shader_parameter("height_map",       _height_tex)
	_visual_mat.set_shader_parameter("height_tex_min",   HEIGHT_TEX_MIN)
	_visual_mat.set_shader_parameter("height_tex_range", HEIGHT_TEX_RANGE)

	_mesh_instance.mesh = _plane_mesh
	_mesh_instance.material_override = _visual_mat
	_mesh_instance.custom_aabb = AABB(Vector3(-80, -5, -80), Vector3(160, 10, 160))

func prepare_for_bake() -> void:
	_mesh_instance.mesh = _nav_array_mesh
	_mesh_instance.material_override = null

func restore_visual() -> void:
	_mesh_instance.mesh = _plane_mesh
	_mesh_instance.material_override = _visual_mat

func _build_collision() -> void:
	var shape := HeightMapShape3D.new()
	shape.map_width  = GRID_SIZE
	shape.map_depth  = GRID_SIZE
	shape.map_data   = height_data
	_collision_shape.shape = shape
	var scale_xz: float = WORLD_SIZE / float(GRID_SIZE - 1)
	$StaticBody3D.scale = Vector3(scale_xz, 1.0, scale_xz)
