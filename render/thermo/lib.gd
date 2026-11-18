extends RefCounted
# shared helpers for the pilot
const ASSETS := "/home/claude/gd/assets/"
static var _glb_cache := {}
static var _tex_cache := {}

static func load_glb(path: String) -> Node3D:
	var doc := GLTFDocument.new(); var st := GLTFState.new()
	if doc.append_from_file(path, st) != OK:
		push_error("glb load fail " + path); return Node3D.new()
	return doc.generate_scene(st)

static func anim_player(n: Node) -> AnimationPlayer:
	return n.find_child("AnimationPlayer", true, false)

static func play(n: Node, anim: String, speed := 1.0, offset := 0.0, loop := true, blend := 0.3) -> void:
	var ap := anim_player(n)
	if ap == null: return
	if not ap.has_animation(anim):
		push_error("no anim " + anim); return
	var a := ap.get_animation(anim); a.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	ap.play(anim, blend, speed); ap.seek(fmod(offset, a.length) if loop else minf(offset, a.length), true)

static func tex(path: String) -> Texture2D:
	if _tex_cache.has(path): return _tex_cache[path]
	var img := Image.load_from_file(path)
	if img == null or img.is_empty(): push_error("tex fail " + path); return null
	img.generate_mipmaps()
	var t := ImageTexture.create_from_image(img); _tex_cache[path] = t; return t

static func ph_tex(name: String, map := "Diffuse") -> Texture2D:
	var base := ASSETS + "polyhaven/textures/%s/%s_%s." % [name, name, map]
	if FileAccess.file_exists(base + "jpg"): return tex(base + "jpg")
	if FileAccess.file_exists(base + "png"): return tex(base + "png")
	return null

static func mat(name: String, uv := 1.0, tint := Color(1,1,1)) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = ph_tex(name); m.albedo_color = tint
	var nt := ph_tex(name, "nor_gl")
	if nt: m.normal_enabled = true; m.normal_texture = nt
	var rt := ph_tex(name, "Rough")
	if rt: m.roughness_texture = rt
	m.uv1_scale = Vector3(uv, uv, uv); m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return m

static func ph_model(name: String) -> Node3D:
	var p := ASSETS + "polyhaven/models/%s/%s.gltf" % [name, name]
	if _glb_cache.has(p): return (_glb_cache[p] as Node3D).duplicate()
	var n := load_glb(p); _glb_cache[p] = n
	return n.duplicate()

static func set_shadows(n: Node, on: bool) -> void:
	for c in n.find_children("*", "GeometryInstance3D", true, false):
		(c as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

# ---------- terrain ----------
static func terrain(size: float, res: int, height_fn: Callable, material: Material) -> MeshInstance3D:
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var step := size / res
	for z in range(res + 1):
		for x in range(res + 1):
			var px := -size * 0.5 + x * step; var pz := -size * 0.5 + z * step
			st.set_uv(Vector2(x, z) / res)
			st.add_vertex(Vector3(px, height_fn.call(px, pz), pz))
	for z in range(res):
		for x in range(res):
			var i := z * (res + 1) + x
			st.add_index(i); st.add_index(i + 1); st.add_index(i + res + 1)
			st.add_index(i + 1); st.add_index(i + res + 2); st.add_index(i + res + 1)
	st.generate_normals()
	var mi := MeshInstance3D.new(); mi.mesh = st.commit(); mi.material_override = material
	return mi
