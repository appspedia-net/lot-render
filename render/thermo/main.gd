extends Node3D
# Thermopylae — data-driven director. timeline.json: shots [{t0,t1,set,v,seg}]
const Lib = preload("res://lib.gd")
const CH := "/home/claude/gd/assets/chars/"
var T := 0.0
var fps := 24.0
var shots: Array = []
var END := 0.0
var cur_seg := -1
var seg_t0 := 0.0
var cur_set := ""
var world: Node3D
var actors: Array = []
var hfn: Callable
var cam: Camera3D
var env: Environment
var sun: DirectionalLight3D
var post: ColorRect
var fires: Array = []
var follow_parts: Array = []
var water_mats: Array = []
var cams: Array = []
var tmpl := {}
var rng := RandomNumberGenerator.new()
var only_t := -1.0
var stop_t := 1e9
var shot_i := 0
var marks := {}        # named positions per set (for camera tracking)
var obst: Array = []   # solid footprints [center(Vector3), half_x, half_z, rot] — nobody may walk through them

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var tl := "res://timeline.json"
	for a in args:
		if a.begins_with("t="): only_t = float(a.substr(2))
		if a.begins_with("start="): T = float(a.substr(6)) - 1.0 / fps
		if a.begins_with("stop="): stop_t = float(a.substr(5))
		if a.begins_with("tl="): tl = a.substr(3)
		if a == "nopost": set_meta("nopost", true)
		if a == "noshadow": set_meta("noshadow", true)
		if a == "noactors": set_meta("noactors", true)
	var d = JSON.parse_string(FileAccess.get_file_as_string(tl))
	shots = d.shots; END = d.end
	var we := WorldEnvironment.new(); env = Environment.new(); we.environment = env; add_child(we)
	sun = DirectionalLight3D.new(); sun.shadow_enabled = true; sun.directional_shadow_max_distance = 45.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL; add_child(sun)
	cam = Camera3D.new(); cam.far = 6000.0; cam.near = 0.1; add_child(cam); cam.current = true
	var cl := CanvasLayer.new(); add_child(cl)
	post = ColorRect.new(); post.set_anchors_preset(Control.PRESET_FULL_RECT); post.size = Vector2(1920, 1080)
	var sm := ShaderMaterial.new(); sm.shader = load("res://shaders/paint.gdshader"); post.material = sm; cl.add_child(post)
	if has_meta("nopost"): post.visible = false
	if has_meta("noshadow"): sun.shadow_enabled = false
	if only_t >= 0.0: T = only_t
	_update()

func _process(_delta: float) -> void:
	if only_t >= 0.0: return
	T += 1.0 / fps
	if T >= stop_t or T >= END: get_tree().quit(); return
	_update()

# ======================================================= update
func _find_shot() -> Dictionary:
	if shot_i >= shots.size() or T < shots[shot_i].t0: shot_i = 0
	while shot_i < shots.size() - 1 and T >= shots[shot_i].t1: shot_i += 1
	return shots[shot_i]

func _update() -> void:
	var sh := _find_shot()
	if int(sh.seg) != cur_seg:
		var t0: float = sh.t0
		for s in shots:
			if int(s.seg) == int(sh.seg): t0 = s.t0; break
		seg_t0 = t0; cur_seg = int(sh.seg)
		_build(sh.set)
	var tau := T - seg_t0
	_update_actors(tau)
	_camera(sh, tau)
	for f in fires:
		var l: OmniLight3D = f
		l.light_energy = l.get_meta("e", 2.2) * (1.0 + 0.22 * sin(T * 17.0 + l.position.x) + 0.12 * sin(T * 31.0 + l.position.z))
	for p in follow_parts:
		var pp: Node3D = p
		pp.global_position = cam.global_position + Vector3(0, pp.get_meta("dy", 6.0), 0) - cam.global_transform.basis.z * pp.get_meta("ahead", 8.0)
	for wm in water_mats: (wm as ShaderMaterial).set_shader_parameter("t", T)
	(post.material as ShaderMaterial).set_shader_parameter("time_s", T)

func _camera(sh: Dictionary, tau: float) -> void:
	if cams.is_empty(): return
	var c: Dictionary = cams[int(sh.v) % cams.size()]
	var dur: float = sh.t1 - sh.t0
	var k := clampf((T - sh.t0) / dur, 0.0, 1.0)
	k = k * k * (3.0 - 2.0 * k)
	var p0: Vector3 = c.p0; var p1: Vector3 = c.p1; var l0: Vector3 = c.l0; var l1: Vector3 = c.l1
	var p := p0.lerp(p1, k); var l := l0.lerp(l1, k)
	if c.has("track"):
		var a = _actor(c.track)
		if a != null:
			var ap: Vector3 = _actor_pos(a, tau)
			p += ap; l += ap
	if c.has("orbit"):
		var ctr: Vector3 = c.orbit; var ang: float = lerpf(c.a0, c.a1, k); var rad: float = lerpf(c.r0, c.r1, k); var hh: float = lerpf(c.h0, c.h1, k)
		p = ctr + Vector3(cos(ang) * rad, hh, sin(ang) * rad); l = ctr + Vector3(0, c.get("lh", 1.5), 0)
	# gentle handheld drift
	p += Vector3(sin(T * 0.37) * 0.03, sin(T * 0.53) * 0.02, cos(T * 0.29) * 0.03) * c.get("shake", 1.0)
	if hfn.is_valid(): p.y = maxf(p.y, hfn.call(p.x, p.z) + 0.6)
	cam.position = p
	if p.distance_to(l) > 0.01: cam.look_at(l, Vector3.UP)
	cam.fov = lerpf(c.get("f0", 45.0), c.get("f1", c.get("f0", 45.0)), k)

# ======================================================= actors
func char_tmpl(name: String) -> Node3D:
	if not tmpl.has(name): tmpl[name] = Lib.load_glb(CH + name + ".glb")
	return tmpl[name]

func spawn(name: String, pos: Vector3, rot_y: float, anim: String, start := -999.0, end := 99999.0, vel := Vector3.ZERO, extra := {}) -> Dictionary:
	var a := {"name": name, "node": null, "start": start, "end": end, "from": pos, "vel": vel, "rot": rot_y, "anim": anim, "speed": extra.get("speed", rng.randf_range(0.93, 1.07)),
		"off": rng.randf() * 4.0, "loop": true, "t_anim": start, "ev": [], "evi": 0}
	for k in extra: a[k] = extra[k]
	actors.append(a)
	return a

func _obst(c: Vector3, hx: float, hz: float, rot := 0.0) -> void:
	obst.append([c, hx, hz, rot])

func _blocked(p: Vector3, margin := 0.45) -> bool:
	for o in obst:
		var l: Vector3 = Basis(Vector3.UP, o[3]).inverse() * (p - o[0])
		if absf(l.x) < o[1] + margin and absf(l.z) < o[2] + margin: return true
	return false

func _path_clear(from: Vector3, vel: Vector3, dur: float) -> bool:
	var steps := int(dur / 0.5) + 1
	for i in range(steps):
		if _blocked(from + vel * (i * 0.5)): return false
	return true

func _free_spot(p: Vector3) -> Vector3:
	if not _blocked(p): return p
	for r in range(1, 16):
		for k in range(12):
			var a := k * TAU / 12.0
			var q := p + Vector3(cos(a), 0, sin(a)) * (r * 0.5)
			if not _blocked(q): return q
	return p

func _lod_actors() -> void:
	var pts: Array = []
	for c in cams:
		if c.has("orbit"): pts.append(c.orbit); continue
		pts.append(c.l0); pts.append(c.l1)
		pts.append(c.p0.lerp(c.l0, 0.25)); pts.append(c.p1.lerp(c.l1, 0.25))
	for a in actors:
		if a.has("id") or a.name in ["leonidas", "xerxes", "gorgo", "priestess", "ephialtes"]: continue
		var near := false
		for p in pts:
			if Vector2(a.from.x - p.x, a.from.z - p.z).length() < 7.0: near = true; break
		if a.vel.length() > 0.01: near = near and a.get("lo", false) == false
		a["lo"] = not near

func _fix_actors() -> void:
	# make sure nobody stands in or walks through walls, houses, tents or temples,
	# and that lone walkers do not walk through people standing still
	var vcount := {}
	for a in actors:
		var key := str(a.vel.snapped(Vector3(0.01, 0.01, 0.01)))
		vcount[key] = vcount.get(key, 0) + 1
	var base := obst.size()
	for a in actors:
		if a.vel.length() < 0.01 and a.ev.is_empty() and a.get("ground", true):
			obst.append([a.from, 0.25, 0.25, 0.0])
	for a in actors:
		if a.get("noclip", false) or not a.get("ground", true): continue
		var solo: bool = vcount.get(str(a.vel.snapped(Vector3(0.01, 0.01, 0.01))), 0) <= 3
		if a.vel.length() >= 0.01 and not solo:
			# formations only respect buildings, not people
			var keep := obst.slice(base); obst.resize(base)
			_fix_one(a)
			obst.append_array(keep)
		elif a.vel.length() >= 0.01:
			_fix_one(a)
			if a.has("wrap"): a["pp"] = true   # lone walkers turn around instead of popping back
	obst.resize(base)
	for a in actors:
		if a.get("noclip", false) or not a.get("ground", true): continue
		if a.vel.length() < 0.01: a.from = _free_spot(a.from)

func _fix_one(a: Dictionary) -> void:
	if true:
		a.from = _free_spot(a.from)
		var v: Vector3 = a.vel
		if v.length() < 0.01 or not a.ev.is_empty(): return
		var dur: float = a.get("wrap", minf(a.end - maxf(a.start, 0.0), 90.0))
		if _path_clear(a.from, v, dur): return
		var fixed := false
		for k in [1, -1, 2, -2, 3, -3, 4, -4, 6]:
			var nv := v.rotated(Vector3.UP, k * PI / 6.0)
			if _path_clear(a.from, nv, dur):
				a.vel = nv; a.rot = atan2(nv.x, nv.z); fixed = true; break
		if not fixed:
			a.vel = Vector3.ZERO
			if a.anim in ["walk", "carry", "run", "sprint", "march", "oldwalk"]: a.anim = "idle"

func ev(a: Dictionary, tau: float, anim: String, loop := true, vel = null, rot = null) -> void:
	a.ev.append({"t": tau, "anim": anim, "loop": loop, "vel": vel, "rot": rot})

func _actor(id: String):
	for a in actors:
		if a.get("id", "") == id: return a
	return null

func _actor_pos(a: Dictionary, tau: float) -> Vector3:
	var dt: float = tau - a.start
	if a.has("wrap"):
		var per: float = a.wrap
		if a.get("pp", false):
			var d := fposmod(tau - a.start, per * 2.0)
			dt = d if d < per else per * 2.0 - d
		else:
			dt = fposmod(tau - a.start, per)
	var p: Vector3 = a.from + a.vel * dt
	if a.get("ground", true) and hfn.is_valid(): p.y = hfn.call(p.x, p.z) + a.get("dy", 0.0)
	else: p.y += a.get("dy", 0.0)
	return p

func _update_actors(tau: float) -> void:
	if has_meta("noactors"): return
	for a in actors:
		var on: bool = tau >= a.start - 0.05 and tau < a.end
		if not on:
			if a.node != null: a.node.queue_free(); a.node = null
			continue
		# apply events (they may change velocity / animation)
		var replay := false
		while a.evi < a.ev.size() and tau >= a.ev[a.evi].t:
			var e: Dictionary = a.ev[a.evi]; a.evi += 1
			var cur: Vector3 = _actor_pos(a, e.t)
			a.from = Vector3(cur.x, a.from.y, cur.z); a.start = e.t; a.erase("wrap")
			if e.vel != null: a.vel = e.vel
			if e.rot != null: a.rot = e.rot
			a.anim = e.anim; a.loop = e.loop; a.t_anim = e.t; replay = true
		if a.node == null:
			_materialize(a, tau)
		elif replay:
			Lib.play(a.node, a.anim, a.speed, 0.0, a.loop, 0.25)
			(a.node as Node3D).rotation.y = a.rot
		var n: Node3D = a.node
		n.position = _actor_pos(a, tau)
		if a.get("pp", false) and a.has("wrap"):
			var back: bool = fposmod(tau - a.start, a.wrap * 2.0) >= a.wrap
			n.rotation.y = a.rot + (PI if back else 0.0)

func _materialize(a: Dictionary, tau: float) -> void:
	var nm: String = a.name
	if a.get("lo", false) and FileAccess.file_exists(CH + nm + "_lo.glb"): nm += "_lo"
	var n: Node3D = char_tmpl(nm).duplicate()
	world.add_child(n); n.rotation.y = a.rot; n.scale = Vector3.ONE * a.get("scale", 1.0)
	var since: float = maxf(0.0, tau - a.t_anim)
	Lib.play(n, a.anim, a.speed, (a.off if a.loop else 0.0) + since * a.speed, a.loop, 0.0)
	if _on(a, "torch"): _attach(n, "hand_r", _torchobj())
	elif _on(a, "sword"): _attach(n, "hand_r", _sword())
	elif _on(a, "spear"): _attach(n, "hand_r", _spear(a.get("spear_len", 2.4)))
	elif _on(a, "stick"): _attach(n, "hand_r", _stick())
	if _on(a, "shield"): _attach(n, "lowerarm_l", _shield(a.shield))
	elif _on(a, "wicker"): _attach(n, "lowerarm_l", _wicker())
	if _on(a, "bow"): _attach(n, "hand_l", _bow())
	if _on(a, "crest"): _attach(n, "head", _crest(a.crest))
	if a.get("lo", false): Lib.set_shadows(n, false)
	a.node = n

func _on(a: Dictionary, k: String) -> bool:
	if not a.has(k): return false
	var v = a[k]
	if v == null: return false
	if typeof(v) == TYPE_BOOL: return v
	return true

func _attach(n: Node3D, bone: String, obj: Node3D) -> void:
	var sk: Skeleton3D = null
	for c in n.find_children("*", "Skeleton3D", true, false): sk = c; break
	if sk == null: return
	var ba := BoneAttachment3D.new(); ba.bone_name = bone; sk.add_child(ba); ba.add_child(obj)

func _m(col: Color, metal := 0.0, rough := 0.7) -> StandardMaterial3D:
	var m := StandardMaterial3D.new(); m.albedo_color = col; m.metallic = metal; m.roughness = rough; return m

func _spear(length := 2.4) -> Node3D:
	var r := Node3D.new()
	var shaft := MeshInstance3D.new(); var cy := CylinderMesh.new(); cy.top_radius = 0.016; cy.bottom_radius = 0.018; cy.height = length; cy.radial_segments = 6; shaft.mesh = cy
	shaft.material_override = _m(Color(0.36, 0.24, 0.14), 0.0, 0.8)
	var tip := MeshInstance3D.new(); var cn := CylinderMesh.new(); cn.top_radius = 0.0; cn.bottom_radius = 0.035; cn.height = 0.28; cn.radial_segments = 6; tip.mesh = cn; tip.position.y = length * 0.5 + 0.12
	tip.material_override = _m(Color(0.62, 0.56, 0.45), 0.85, 0.3)
	r.add_child(shaft); r.add_child(tip); r.rotation_degrees = Vector3(90, 0, 0); r.position = Vector3(0, 0.08, 0.35)
	var h := Node3D.new(); h.add_child(r); return h

func _sword() -> Node3D:
	var r := Node3D.new()
	var bl := MeshInstance3D.new(); var bx := BoxMesh.new(); bx.size = Vector3(0.05, 0.62, 0.012); bl.mesh = bx; bl.position.y = 0.38; bl.material_override = _m(Color(0.75, 0.72, 0.66), 0.9, 0.25)
	var hi := MeshInstance3D.new(); var hb := BoxMesh.new(); hb.size = Vector3(0.16, 0.03, 0.04); hi.mesh = hb; hi.position.y = 0.06; hi.material_override = _m(Color(0.55, 0.42, 0.2), 0.8, 0.4)
	r.add_child(bl); r.add_child(hi); r.rotation_degrees = Vector3(90, 0, 0); r.position = Vector3(0, 0.08, 0.02)
	var h := Node3D.new(); h.add_child(r); return h

func _stick() -> Node3D:
	var m := MeshInstance3D.new(); var cy := CylinderMesh.new(); cy.top_radius = 0.018; cy.bottom_radius = 0.022; cy.height = 1.5; m.mesh = cy
	m.material_override = _m(Color(0.32, 0.22, 0.13), 0.0, 0.9); m.position = Vector3(0, 0.5, 0.02)
	var h := Node3D.new(); h.add_child(m); return h

func _torchobj() -> Node3D:
	var h := Node3D.new()
	var m := MeshInstance3D.new(); var cy := CylinderMesh.new(); cy.top_radius = 0.03; cy.bottom_radius = 0.022; cy.height = 0.7; m.mesh = cy
	m.material_override = _m(Color(0.25, 0.17, 0.1)); m.position = Vector3(0, 0.1, 0.0); h.add_child(m)
	var fl := _flame(0.12, 40); fl.position = Vector3(0, 0.5, 0); h.add_child(fl)
	var l := OmniLight3D.new(); l.light_color = Color(1.0, 0.55, 0.2); l.omni_range = 6.0; l.light_energy = 1.4; l.position = Vector3(0, 0.55, 0); h.add_child(l)
	return h

func _bow() -> Node3D:
	var h := Node3D.new()
	var m := MeshInstance3D.new(); var tm := TorusMesh.new(); tm.inner_radius = 0.55; tm.outer_radius = 0.575; tm.rings = 16; tm.ring_segments = 4; m.mesh = tm
	m.material_override = _m(Color(0.3, 0.2, 0.1)); m.scale = Vector3(0.5, 1, 1); m.rotation_degrees = Vector3(0, 0, 90); h.add_child(m)
	return h

func _shield(col: Color) -> Node3D:
	var m := MeshInstance3D.new(); var cy := CylinderMesh.new(); cy.top_radius = 0.46; cy.bottom_radius = 0.46; cy.height = 0.05; cy.radial_segments = 24; m.mesh = cy
	m.material_override = _m(col, 0.55, 0.4)
	var rim := MeshInstance3D.new(); var tr := TorusMesh.new(); tr.inner_radius = 0.43; tr.outer_radius = 0.48; tr.rings = 24; tr.ring_segments = 4; rim.mesh = tr; rim.material_override = _m(Color(0.72, 0.55, 0.3), 0.9, 0.3); m.add_child(rim)
	if col.r > col.g * 1.6:
		# Spartan lambda in bronze
		for s in [-1.0, 1.0]:
			var leg := MeshInstance3D.new(); var lb := BoxMesh.new(); lb.size = Vector3(0.05, 0.012, 0.5); leg.mesh = lb
			leg.material_override = _m(Color(0.78, 0.6, 0.3), 0.9, 0.3); leg.position = Vector3(s * 0.08, 0.03, 0.0); leg.rotation_degrees = Vector3(0, s * 22.0, 0); m.add_child(leg)
	m.rotation_degrees = Vector3(0, 0, 90); m.position = Vector3(-0.14, 0.15, 0.0)
	var h := Node3D.new(); h.add_child(m); return h

func _wicker() -> Node3D:
	var m := MeshInstance3D.new(); var bx := BoxMesh.new(); bx.size = Vector3(0.5, 0.03, 0.9); m.mesh = bx
	var wm := Lib.mat("thatch_roof_angled", 2.0, Color(0.8, 0.68, 0.45)); m.material_override = wm
	m.rotation_degrees = Vector3(0, 0, 90); m.position = Vector3(-0.13, 0.12, 0.0)
	var h := Node3D.new(); h.add_child(m); return h

func _crest(col: Color) -> Node3D:
	var h := Node3D.new()
	var m := MeshInstance3D.new(); var cy := CylinderMesh.new(); cy.top_radius = 0.13; cy.bottom_radius = 0.13; cy.height = 0.03; cy.radial_segments = 16; m.mesh = cy
	m.material_override = _m(col, 0.0, 0.95); m.rotation_degrees = Vector3(0, 0, 90); m.scale = Vector3(0.55, 1, 1.25)
	m.position = Vector3(0, 0.21, -0.02); h.add_child(m)
	return h

func _flame(r: float, amount: int) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount; p.lifetime = 0.8; p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE; p.emission_sphere_radius = r
	p.direction = Vector3.UP; p.spread = 12; p.initial_velocity_min = 0.5; p.initial_velocity_max = 1.2; p.gravity = Vector3(0, 0.8, 0)
	p.scale_amount_min = 0.3; p.scale_amount_max = 0.6; p.local_coords = false
	var sc := Curve.new(); sc.add_point(Vector2(0, 0.6)); sc.add_point(Vector2(0.3, 1.0)); sc.add_point(Vector2(1, 0.1)); p.scale_amount_curve = sc
	var qm := QuadMesh.new(); qm.size = Vector2(r * 2.0, r * 3.4); p.mesh = qm
	var fm := StandardMaterial3D.new(); fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD; fm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES; fm.vertex_color_use_as_albedo = true
	var gt := GradientTexture2D.new(); var g := Gradient.new(); g.set_color(0, Color(1, 1, 1, 1)); g.set_color(1, Color(1, 1, 1, 0)); gt.gradient = g; gt.fill = GradientTexture2D.FILL_RADIAL; gt.fill_from = Vector2(0.5, 0.5); gt.fill_to = Vector2(0.5, 0.0)
	fm.albedo_texture = gt; qm.material = fm
	var cr := Gradient.new(); cr.set_color(0, Color(1.0, 0.62, 0.22, 0.55)); cr.add_point(0.45, Color(0.95, 0.3, 0.06, 0.45)); cr.set_color(cr.get_point_count() - 1, Color(0.3, 0.08, 0.03, 0)); p.color_ramp = cr
	return p

# ======================================================= environment helpers
func _clear() -> void:
	for a in actors:
		if a.node != null: a.node.queue_free()
	if world: world.queue_free()
	world = Node3D.new(); add_child(world); actors.clear(); fires.clear(); follow_parts.clear(); water_mats.clear(); cams.clear(); marks.clear(); obst.clear()
	hfn = Callable()
	env.fog_enabled = false; env.volumetric_fog_enabled = false; env.ambient_light_energy = 1.0; env.tonemap_exposure = 1.0
	sun.light_energy = 1.0; sun.shadow_enabled = not has_meta("noshadow")
	var pm: ShaderMaterial = post.material
	pm.set_shader_parameter("tint", Vector3(1.0, 0.97, 0.9)); pm.set_shader_parameter("warmth", 0.06); pm.set_shader_parameter("saturation", 1.12)

func _sky(name: String, energy := 1.0, rot := 0.0) -> void:
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new(); var pm := PanoramaSkyMaterial.new(); pm.panorama = Lib.tex(Lib.ASSETS + "hdri/" + name + ".png"); pm.energy_multiplier = energy
	sky.sky_material = pm; env.sky = sky; env.sky_rotation = Vector3(0, deg_to_rad(rot), 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY; env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.ssao_enabled = false; env.glow_enabled = true; env.glow_intensity = 0.5; env.glow_bloom = 0.08

func _night_sky(top: Color, hor: Color, energy := 1.0) -> void:
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new(); var ps := ProceduralSkyMaterial.new()
	ps.sky_top_color = top; ps.sky_horizon_color = hor; ps.ground_horizon_color = hor * 0.6; ps.ground_bottom_color = top * 0.3
	ps.sun_angle_max = 2.0; ps.sky_energy_multiplier = energy; sky.sky_material = ps; env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY; env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.ssao_enabled = false; env.glow_enabled = true; env.glow_intensity = 0.7; env.glow_bloom = 0.06
	_stars_moon()

func _stars_moon(moon_dir := Vector3(0.35, 0.38, 0.85), count := 1600) -> void:
	var mm := MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D; mm.use_colors = true
	var qm := QuadMesh.new(); qm.size = Vector2(3.2, 3.2); mm.mesh = qm; mm.instance_count = count
	var sr := RandomNumberGenerator.new(); sr.seed = 777
	for i in range(count):
		var d := Vector3(sr.randf_range(-1, 1), sr.randf_range(0.04, 1.0), sr.randf_range(-1, 1)).normalized()
		var s := pow(sr.randf(), 3.0) * 1.8 + 0.35
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * s), d * 2600.0))
		var b := sr.randf_range(0.55, 1.0); mm.set_instance_color(i, Color(b, b, b * sr.randf_range(0.95, 1.1), 1))
	var mi := MultiMeshInstance3D.new(); mi.multimesh = mm; mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := StandardMaterial3D.new(); m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED; m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD; m.disable_fog = true
	var gt := GradientTexture2D.new(); var g := Gradient.new(); g.set_color(0, Color(1, 1, 1, 1)); g.add_point(0.25, Color(1, 1, 1, 0.5)); g.set_color(g.get_point_count() - 1, Color(1, 1, 1, 0)); gt.gradient = g; gt.fill = GradientTexture2D.FILL_RADIAL; gt.fill_from = Vector2(0.5, 0.5); gt.fill_to = Vector2(0.5, 0.0)
	m.albedo_texture = gt; mi.material_override = m; mi.set_meta("sky", true); world.add_child(mi)
	follow_parts.append(mi); mi.set_meta("dy", 0.0); mi.set_meta("ahead", 0.0)
	# moon: lit sphere + soft halo, plus a cool moonlight
	var md := moon_dir.normalized()
	var moon := MeshInstance3D.new(); var sp := SphereMesh.new(); sp.radius = 55.0; sp.height = 110.0; moon.mesh = sp
	var mmat := StandardMaterial3D.new(); mmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; mmat.albedo_color = Color(0.95, 0.95, 0.88); mmat.albedo_texture = Lib.ph_tex("rocks_ground_05"); mmat.uv1_scale = Vector3(0.6, 0.6, 0.6); mmat.disable_fog = true
	moon.material_override = mmat; moon.position = md * 2500.0; moon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var halo := MeshInstance3D.new(); var hq := QuadMesh.new(); hq.size = Vector2(520, 520); halo.mesh = hq
	var hm := StandardMaterial3D.new(); hm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; hm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED; hm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; hm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD; hm.disable_fog = true
	var g2 := Gradient.new(); g2.set_color(0, Color(0.7, 0.75, 0.9, 0.55)); g2.set_color(1, Color(0.3, 0.35, 0.5, 0.0)); var gt2 := GradientTexture2D.new(); gt2.gradient = g2; gt2.fill = GradientTexture2D.FILL_RADIAL; gt2.fill_from = Vector2(0.5, 0.5); gt2.fill_to = Vector2(0.5, 0.0)
	hm.albedo_texture = gt2; halo.material_override = hm; halo.position = md * 2560.0; halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mroot := Node3D.new(); mroot.add_child(moon); mroot.add_child(halo); world.add_child(mroot)
	follow_parts.append(mroot); mroot.set_meta("dy", 0.0); mroot.set_meta("ahead", 0.0)
	sun.light_color = Color(0.55, 0.65, 0.95); sun.light_energy = 0.32
	sun.look_at_from_position(Vector3.ZERO, -md, Vector3.UP)

func _fog(col: Color, density: float, aerial := 0.4, sky_aff := 0.25) -> void:
	env.fog_enabled = true; env.fog_light_color = col; env.fog_density = density; env.fog_aerial_perspective = aerial; env.fog_sky_affect = sky_aff

func _grade(tint: Vector3, warmth := 0.06, sat := 1.12) -> void:
	var pm: ShaderMaterial = post.material
	pm.set_shader_parameter("tint", tint); pm.set_shader_parameter("warmth", warmth); pm.set_shader_parameter("saturation", sat)

func _terrain_mat(low: String, mid: String, rock: String, top: String, top_h: float, mid_h: float, top_amount := 0.0, low_tint := Color(1, 1, 1)) -> ShaderMaterial:
	var m := ShaderMaterial.new(); m.shader = load("res://shaders/terrain.gdshader")
	m.set_shader_parameter("tex_low", Lib.ph_tex(low)); m.set_shader_parameter("tex_mid", Lib.ph_tex(mid))
	m.set_shader_parameter("tex_rock", Lib.ph_tex(rock)); m.set_shader_parameter("tex_snow", Lib.ph_tex(top))
	m.set_shader_parameter("snow_h", top_h); m.set_shader_parameter("mid_h", mid_h); m.set_shader_parameter("snow_amount", top_amount)
	m.set_shader_parameter("low_tint", Vector3(low_tint.r, low_tint.g, low_tint.b))
	return m

func _noise(seed: int, freq: float, oct := 5) -> FastNoiseLite:
	var n := FastNoiseLite.new(); n.seed = seed; n.frequency = freq; n.fractal_octaves = oct; n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH; return n

func _ground(p: Vector3) -> Vector3:
	return Vector3(p.x, hfn.call(p.x, p.z) if hfn.is_valid() else p.y, p.z)

const HEAVY := {"shrub_01": ["shrub_02", 1.0], "boulder_01": ["rock_07", 1.7], "namaqualand_cliff_01": ["rock_face_02", 1.6]}
func _place(model: String, pos: Vector3, scale := 1.0, rot := 0.0, sink := 0.0) -> Node3D:
	if HEAVY.has(model):
		scale *= HEAVY[model][1]; model = HEAVY[model][0]   # lighter stand-ins (render speed)
	var m := Lib.ph_model(model); world.add_child(m)
	m.position = pos - Vector3(0, sink, 0); m.scale = Vector3.ONE * scale; m.rotation.y = rot; return m

func _box(size: Vector3, pos: Vector3, mat: Material, rot := 0.0, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new(); var bx := BoxMesh.new(); bx.size = size; mi.mesh = bx; mi.material_override = mat; mi.position = pos; mi.rotation.y = rot
	(parent if parent else world).add_child(mi); return mi

func _cyl(r0: float, r1: float, hgt: float, pos: Vector3, mat: Material, parent: Node3D = null, seg := 12) -> MeshInstance3D:
	var mi := MeshInstance3D.new(); var cy := CylinderMesh.new(); cy.top_radius = r0; cy.bottom_radius = r1; cy.height = hgt; cy.radial_segments = seg; mi.mesh = cy; mi.material_override = mat; mi.position = pos
	(parent if parent else world).add_child(mi); return mi

func _tmat(name: String, tint := Color(1, 1, 1), sc := 0.5) -> StandardMaterial3D:
	var m := Lib.mat(name, 1.0, tint); m.uv1_triplanar = true; m.uv1_scale = Vector3(sc, sc, sc); return m

func _water(y := 0.0, size := 4000.0, deep := Vector3(0.02, 0.08, 0.13), shallow := Vector3(0.08, 0.22, 0.26), sky_col := Vector3(0.7, 0.76, 0.85)) -> void:
	var mi := MeshInstance3D.new(); var pm := PlaneMesh.new(); pm.size = Vector2(size, size); mi.mesh = pm; mi.position.y = y
	var sm := ShaderMaterial.new(); sm.shader = load("res://shaders/water.gdshader")
	sm.set_shader_parameter("deep", deep); sm.set_shader_parameter("shallow", shallow); sm.set_shader_parameter("sky_col", sky_col)
	mi.material_override = sm; world.add_child(mi); water_mats.append(sm)

func _conifer(pos: Vector3, h: float, col := Color(0.22, 0.34, 0.2)) -> void:
	var root := Node3D.new(); world.add_child(root); root.position = pos
	_cyl(0.05 * h / 6, 0.16 * h / 6, h * 0.35, Vector3(0, h * 0.17, 0), _m(Color(0.25, 0.17, 0.1)), root, 6)
	var lm := StandardMaterial3D.new(); lm.albedo_texture = Lib.ph_tex("forrest_ground_01"); lm.albedo_color = col; lm.uv1_scale = Vector3(3, 3, 3); lm.roughness = 0.95
	for i in range(5):
		var f := 1.0 - i * 0.17
		var c := _cyl(0.02, h * 0.24 * f, h * 0.34, Vector3(0, h * (0.22 + i * 0.15), 0), lm, root, 9); c.rotation.y = i * 0.7

func _olive(pos: Vector3, h: float) -> void:
	var root := Node3D.new(); world.add_child(root); root.position = pos
	var tr := _cyl(0.06 * h / 4, 0.14 * h / 4, h * 0.5, Vector3(0, h * 0.25, 0), _m(Color(0.33, 0.27, 0.2)), root, 6); tr.rotation.z = 0.12
	var lm := StandardMaterial3D.new(); lm.albedo_texture = Lib.ph_tex("forrest_ground_01"); lm.albedo_color = Color(0.42, 0.48, 0.3); lm.uv1_scale = Vector3(2, 2, 2); lm.roughness = 1.0
	for i in range(4):
		var s := MeshInstance3D.new(); var sp := SphereMesh.new(); sp.radius = h * rng.randf_range(0.2, 0.3); sp.height = sp.radius * 1.5; sp.radial_segments = 8; sp.rings = 5; s.mesh = sp; s.material_override = lm
		s.position = Vector3(rng.randf_range(-0.4, 0.4) * h * 0.4, h * rng.randf_range(0.55, 0.8), rng.randf_range(-0.4, 0.4) * h * 0.4); root.add_child(s)

func _fire(pos: Vector3, big := 1.0, pit := true) -> void:
	if pit: _place("stone_fire_pit", pos, big)
	var p := _flame(0.22 * big, int(90 * big)); world.add_child(p); p.position = pos + Vector3(0, 0.15, 0)
	var l := OmniLight3D.new(); world.add_child(l); l.position = pos + Vector3(0, 0.9 * big, 0); l.light_color = Color(1.0, 0.55, 0.22); l.omni_range = 9.0 * big; l.shadow_enabled = big >= 1.0
	l.set_meta("e", 2.2 * big); fires.append(l)

func _smoke(pos: Vector3, scale := 1.0, amount := 60, col := Color(0.25, 0.22, 0.2, 0.55)) -> void:
	var p := CPUParticles3D.new(); world.add_child(p); p.position = pos
	p.amount = amount; p.lifetime = 9.0; p.preprocess = 9.0; p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE; p.emission_sphere_radius = 2.0 * scale
	p.direction = Vector3(0.2, 1, 0); p.spread = 15; p.initial_velocity_min = 2.0 * scale; p.initial_velocity_max = 4.0 * scale; p.gravity = Vector3(0.6, 0.3, 0)
	p.scale_amount_min = 4.0 * scale; p.scale_amount_max = 9.0 * scale
	var qm := QuadMesh.new(); qm.size = Vector2(1, 1); p.mesh = qm
	var fm := StandardMaterial3D.new(); fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES; fm.vertex_color_use_as_albedo = true
	var gt := GradientTexture2D.new(); var g := Gradient.new(); g.set_color(0, Color(1, 1, 1, 1)); g.set_color(1, Color(1, 1, 1, 0)); gt.gradient = g; gt.fill = GradientTexture2D.FILL_RADIAL; gt.fill_from = Vector2(0.5, 0.5); gt.fill_to = Vector2(0.5, 0.0)
	fm.albedo_texture = gt; qm.material = fm
	var cr := Gradient.new(); cr.set_color(0, Color(col.r, col.g, col.b, 0.0)); cr.add_point(0.15, col); cr.set_color(cr.get_point_count() - 1, Color(col.r, col.g, col.b, 0.0)); p.color_ramp = cr

func _dust(amount := 120, col := Color(0.8, 0.7, 0.55, 0.05)) -> void:
	var p := CPUParticles3D.new(); world.add_child(p); p.set_meta("dy", 1.5); p.set_meta("ahead", 22.0)
	p.amount = amount; p.lifetime = 6.0; p.preprocess = 6.0; p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX; p.emission_box_extents = Vector3(16, 2, 16)
	p.direction = Vector3(1, 0.1, 0); p.spread = 30; p.initial_velocity_min = 0.3; p.initial_velocity_max = 1.0; p.gravity = Vector3.ZERO; p.local_coords = false
	p.scale_amount_min = 5.0; p.scale_amount_max = 11.0; p.emission_box_extents = Vector3(22, 2, 12)
	var qm := QuadMesh.new(); qm.size = Vector2(1, 1); p.mesh = qm
	var fm := StandardMaterial3D.new(); fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; fm.proximity_fade_enabled = true; fm.proximity_fade_distance = 3.0; fm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES; fm.vertex_color_use_as_albedo = true
	var gt := GradientTexture2D.new(); var g := Gradient.new(); g.set_color(0, Color(1, 1, 1, 1)); g.set_color(1, Color(1, 1, 1, 0)); gt.gradient = g; gt.fill = GradientTexture2D.FILL_RADIAL; gt.fill_from = Vector2(0.5, 0.5); gt.fill_to = Vector2(0.5, 0.0)
	fm.albedo_texture = gt; qm.material = fm
	var cr := Gradient.new(); cr.set_color(0, Color(col.r, col.g, col.b, 0)); cr.add_point(0.4, col); cr.set_color(cr.get_point_count() - 1, Color(col.r, col.g, col.b, 0)); p.color_ramp = cr
	follow_parts.append(p)

func _arrows(center: Vector3, ext: Vector3, amount := 500, from_dir := Vector3(-14, 0, 0)) -> void:
	var p := CPUParticles3D.new(); world.add_child(p); p.position = center + Vector3(0, 30, 0) - from_dir
	p.amount = amount; p.lifetime = 2.2; p.preprocess = 2.2; p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX; p.emission_box_extents = ext
	var dir := (from_dir.normalized() * 0.5 + Vector3(0, -1, 0)).normalized()
	p.direction = dir; p.spread = 4; p.initial_velocity_min = 22; p.initial_velocity_max = 28; p.gravity = Vector3(0, -6, 0)
	p.particle_flag_align_y = true; p.local_coords = false
	var bx := BoxMesh.new(); bx.size = Vector3(0.025, 0.85, 0.025); p.mesh = bx
	var am := StandardMaterial3D.new(); am.albedo_color = Color(0.12, 0.09, 0.07); am.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; bx.material = am

func _house(pos: Vector3, w: float, d: float, h: float, rot: float, wall: Color, roof_tiles := true) -> Node3D:
	var root := Node3D.new(); world.add_child(root); root.position = pos; root.rotation.y = rot
	_obst(pos, w * 0.5 + 0.1, d * 0.5 + 0.1, rot)
	var wm := _tmat("clay_plaster", wall, 0.5)
	_box(Vector3(w, h, d), Vector3(0, h * 0.5, 0), wm, 0.0, root)
	var sm := _tmat("stone_wall", Color(0.9, 0.85, 0.78), 0.7)
	_box(Vector3(w + 0.12, 0.6, d + 0.12), Vector3(0, 0.28, 0), sm, 0.0, root)
	if roof_tiles:
		var rm := _tmat("clay_roof_tiles", Color(0.95, 0.8, 0.7), 0.6)
		for s in [-1.0, 1.0]:
			var r := _box(Vector3(w + 0.5, 0.12, d * 0.58), Vector3(0, h + d * 0.13, s * d * 0.24), rm, 0.0, root); r.rotation.x = s * 0.42
		var gm := wm
		var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for sx in [-w * 0.5, w * 0.5]:
			for v in [Vector3(sx, h, -d * 0.5), Vector3(sx, h + d * 0.26, 0), Vector3(sx, h, d * 0.5)]: st.add_vertex(v)
		st.generate_normals(); var gi := MeshInstance3D.new(); gi.mesh = st.commit(); var gm2 := gm.duplicate(); gm2.cull_mode = BaseMaterial3D.CULL_DISABLED; gi.material_override = gm2; root.add_child(gi)
	else:
		_box(Vector3(w + 0.4, 0.22, d + 0.4), Vector3(0, h + 0.1, 0), _tmat("thatch_roof_angled", Color(0.85, 0.75, 0.6), 0.6), 0.0, root)
	var dm := _tmat("brown_planks_05", Color(0.7, 0.6, 0.5), 1.0)
	_box(Vector3(0.9, 1.8, 0.08), Vector3(0, 0.9, d * 0.5 + 0.02), dm, 0.0, root)
	var wmm := _m(Color(0.08, 0.06, 0.05))
	for wx in [-w * 0.3, w * 0.3]:
		_box(Vector3(0.5, 0.6, 0.06), Vector3(wx, h * 0.62, d * 0.5 + 0.02), wmm, 0.0, root)
	return root

func _column(pos: Vector3, h: float, r: float, mat: Material, parent: Node3D = null) -> void:
	_cyl(r * 0.86, r, h, pos + Vector3(0, h * 0.5, 0), mat, parent, 16)
	_box(Vector3(r * 2.6, r * 0.5, r * 2.6), pos + Vector3(0, h + r * 0.25, 0), mat, 0.0, parent)
	_cyl(r * 1.15, r * 1.25, r * 0.4, pos + Vector3(0, r * 0.2, 0), mat, parent, 16)

func _temple(pos: Vector3, rot: float, cols_x: int, cols_z: int, sp: float, ch: float, mat: Material, ruined := false) -> Node3D:
	var root := Node3D.new(); world.add_child(root); root.position = pos; root.rotation.y = rot
	var W := (cols_x - 1) * sp; var D := (cols_z - 1) * sp
	_obst(pos, W * 0.5 + 1.5, D * 0.5 + 1.5, rot)
	for i in range(3):
		_box(Vector3(W + 3.0 - i * 0.6, 0.35, D + 3.0 - i * 0.6), Vector3(0, 0.175 + i * 0.35, 0), mat, 0.0, root)
	var base := 1.05; var r := sp * 0.16
	for ix in range(cols_x):
		for iz in range(cols_z):
			if ix != 0 and ix != cols_x - 1 and iz != 0 and iz != cols_z - 1: continue
			if ruined and rng.randf() < 0.3: continue
			_column(Vector3(-W * 0.5 + ix * sp, base, -D * 0.5 + iz * sp), ch, r, mat, root)
	var top := base + ch + r * 0.5
	if not ruined:
		_box(Vector3(W + r * 3.0, 0.9, D + r * 3.0), Vector3(0, top + 0.45, 0), mat, 0.0, root)
		_box(Vector3(W - 1.0, ch * 0.8, D - 1.0), Vector3(0, base + ch * 0.4, 0), mat, 0.0, root)
		var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var y0 := top + 0.9; var hh := (W + r * 3.0) * 0.14; var hw := (W + r * 3.0) * 0.5; var hd := (D + r * 3.0) * 0.5
		var pts := [Vector3(-hw, y0, -hd), Vector3(0, y0 + hh, -hd), Vector3(hw, y0, -hd), Vector3(-hw, y0, hd), Vector3(0, y0 + hh, hd), Vector3(hw, y0, hd)]
		for t in [[0, 1, 4], [0, 4, 3], [1, 2, 5], [1, 5, 4], [0, 2, 1], [3, 4, 5]]:
			for i in t: st.add_vertex(pts[i])
		st.generate_normals(); var mi := MeshInstance3D.new(); mi.mesh = st.commit(); var mm: StandardMaterial3D = (mat as StandardMaterial3D).duplicate(); mm.cull_mode = BaseMaterial3D.CULL_DISABLED; mi.material_override = mm; root.add_child(mi)
	return root

func _tent(pos: Vector3, rot: float, col: Color, s := 1.0, pavilion := false) -> void:
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var w := 1.4 * s; var h := 1.6 * s; var L := 2.4 * s
	_obst(pos, w, w if pavilion else L, rot)
	var pts := [Vector3(-w, 0, -L), Vector3(0, h, -L), Vector3(w, 0, -L), Vector3(-w, 0, L), Vector3(0, h, L), Vector3(w, 0, L)]
	if pavilion:
		pts = [Vector3(-w, 0, -w), Vector3(0, h * 1.6, 0), Vector3(w, 0, -w), Vector3(w, 0, w), Vector3(-w, 0, w)]
		for t in [[0, 1, 2], [2, 1, 3], [3, 1, 4], [4, 1, 0]]:
			for i in t:
				st.set_uv(Vector2(pts[i].x + pts[i].z, pts[i].y) * 0.5); st.add_vertex(pts[i])
	else:
		for t in [[0, 1, 4], [0, 4, 3], [1, 2, 5], [1, 5, 4], [0, 2, 1], [3, 4, 5]]:
			for i in t:
				st.set_uv(Vector2(pts[i].x + pts[i].z, pts[i].y) * 0.5); st.add_vertex(pts[i])
	st.generate_normals()
	var mi := MeshInstance3D.new(); mi.mesh = st.commit()
	var m := Lib.mat("rough_linen", 1.0, col); m.cull_mode = BaseMaterial3D.CULL_DISABLED; mi.material_override = m
	world.add_child(mi); mi.position = pos; mi.rotation.y = rot

func _ship(pos: Vector3, rot: float, s := 1.0, sail := Color(0.9, 0.85, 0.75), oars := true, mast := true) -> Node3D:
	var root := Node3D.new(); world.add_child(root); root.position = pos; root.rotation.y = rot; root.scale = Vector3.ONE * s
	var hull := MeshInstance3D.new(); var cap := CapsuleMesh.new(); cap.radius = 1.4; cap.height = 16.0; cap.radial_segments = 12; cap.rings = 4; hull.mesh = cap
	hull.rotation_degrees = Vector3(90, 0, 0); hull.scale = Vector3(1.0, 1.0, 0.55); hull.position.y = 0.1
	hull.material_override = _tmat("brown_planks_05", Color(0.55, 0.4, 0.28), 0.6); root.add_child(hull)
	_box(Vector3(2.4, 0.12, 13.0), Vector3(0, 0.75, 0), _tmat("brown_planks_05", Color(0.7, 0.55, 0.4), 0.8), 0.0, root)
	var ram := _cyl(0.0, 0.35, 2.0, Vector3(0, 0.0, -8.6), _m(Color(0.6, 0.45, 0.25), 0.9, 0.3), root, 8); ram.rotation_degrees = Vector3(-90, 0, 0)
	var stern := _cyl(0.05, 0.3, 2.4, Vector3(0, 1.6, 7.4), _m(Color(0.4, 0.28, 0.18)), root, 6); stern.rotation_degrees = Vector3(-35, 0, 0)
	if mast:
		_cyl(0.08, 0.1, 7.0, Vector3(0, 4.2, -0.5), _m(Color(0.35, 0.24, 0.15)), root, 6)
		var sl := _box(Vector3(5.0, 3.6, 0.04), Vector3(0, 5.0, -0.4), _tmat("rough_linen", sail, 0.5), 0.0, root)
		(sl.material_override as StandardMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
	if oars:
		for side in [-1.0, 1.0]:
			for i in range(12):
				var o := _box(Vector3(3.2, 0.05, 0.08), Vector3(side * 2.2, 0.15, -5.5 + i * 0.95), _m(Color(0.42, 0.3, 0.2)), 0.0, root)
				o.rotation.z = side * 0.35
	return root

# ======================================================= build dispatch
var SPARTANS := ["spartan_a", "spartan_b", "spartan_c", "spartan_d", "spartan_e", "spartan_f"]
var GREEKS := ["soldier_a", "soldier_b", "soldier_c", "soldier_d", "soldier_f"]
var PERSIANS := ["persian_a", "persian_b", "persian_c", "persian_d"]
var IMMORTALS := ["immortal_a", "immortal_b"]
var SHIELD_SP := [Color(0.62, 0.12, 0.08), Color(0.7, 0.52, 0.28), Color(0.55, 0.1, 0.08)]
var SHIELD_GR := [Color(0.62, 0.5, 0.32), Color(0.3, 0.26, 0.2), Color(0.25, 0.3, 0.42), Color(0.5, 0.42, 0.3)]
var CREST := Color(0.6, 0.08, 0.06)

func _pick(arr: Array) -> String: return arr[rng.randi() % arr.size()]

func _spartan(pos: Vector3, rot: float, anim: String, extra := {}) -> Dictionary:
	var ex := {"spear": true, "shield": SHIELD_SP[rng.randi() % 3], "crest": CREST}
	for k in extra: ex[k] = extra[k]
	return spawn(_pick(SPARTANS), pos, rot, anim, extra.get("start", -999.0), extra.get("end", 99999.0), extra.get("vel", Vector3.ZERO), ex)

func _persian(pos: Vector3, rot: float, anim: String, extra := {}) -> Dictionary:
	var imm: bool = extra.get("immortal", false)
	var ex := {"spear": true, "wicker": true, "spear_len": 1.9}
	for k in extra: ex[k] = extra[k]
	return spawn(_pick(IMMORTALS if imm else PERSIANS), pos, rot, anim, extra.get("start", -999.0), extra.get("end", 99999.0), extra.get("vel", Vector3.ZERO), ex)

func _build(set_name: String) -> void:
	_clear(); cur_set = set_name
	rng.seed = hash(set_name) + cur_seg * 7919
	print("BUILD ", set_name, " seg ", cur_seg, " t ", seg_t0)
	match set_name:
		"pass_dawn": _pass("dawn"); _pass_dawn()
		"pass_wall": _pass("day"); _pass_wall()
		"pass_wait": _pass("day"); _pass_wait()
		"battle_day": _pass("day"); _battle()
		"last_stand": _pass("last"); _last_stand()
		"epitaph": _pass("sunset"); _epitaph()
		"battle_night", "spartan_camp_night": _pass("night"); _night_camp(set_name == "spartan_camp_night")
		"persian_camp": _pcamp(false)
		"persian_throne": _pcamp(true)
		"persian_night": _pcamp(true, true)
		"persian_march": _march()
		"hellespont": _hellespont()
		"persia_court": _palace()
		"sparta_city", "envoy_well", "sparta_council", "sparta_home": _sparta(set_name)
		"agoge": _agoge()
		"delphi": _delphi()
		"greek_march": _greek_march()
		"goat_path": _goat_path()
		"aftermath_athens": _athens()
		"salamis": _salamis()
		"plataea": _plataea()
		_: _pass("day"); _pass_wall()
	_fix_actors()
	_lod_actors()

func C(p0: Vector3, l0: Vector3, p1: Vector3, l1: Vector3, f0 := 45.0, f1 := 45.0, extra := {}) -> void:
	var c := {"p0": p0, "l0": l0, "p1": p1, "l1": l1, "f0": f0, "f1": f1}
	for k in extra: c[k] = extra[k]
	cams.append(c)

func CO(center: Vector3, a0: float, a1: float, r0: float, r1: float, h0: float, h1: float, f := 45.0, lh := 1.5) -> void:
	cams.append({"p0": Vector3.ZERO, "l0": Vector3.ZERO, "p1": Vector3.ZERO, "l1": Vector3.ZERO, "orbit": center, "a0": a0, "a1": a1, "r0": r0, "r1": r1, "h0": h0, "h1": h1, "f0": f, "lh": lh})

# ======================================================= THE PASS
# x: along the road (Persians come from +x), z: cliff at -z, sea at +z. Narrowest at x≈0 (wall at x=-6)
func _pass(mode: String) -> void:
	match mode:
		"dawn":
			_sky("qwantani_sunrise_puresky", 1.0, 200); sun.rotation_degrees = Vector3(-16, 60, 0); sun.light_color = Color(1.0, 0.72, 0.5); sun.light_energy = 1.5
			_fog(Color(0.8, 0.72, 0.68), 0.0011, 0.5); env.tonemap_exposure = 1.1; _grade(Vector3(1.0, 0.97, 0.94), 0.04)
		"day":
			_sky("kloofendal_48d_partly_cloudy_puresky", 1.0, 40); sun.rotation_degrees = Vector3(-48, 25, 0); sun.light_color = Color(1.0, 0.92, 0.8); sun.light_energy = 1.55
			_fog(Color(0.82, 0.86, 0.92), 0.0009, 0.55); env.tonemap_exposure = 0.92
		"last":
			_sky("belfast_sunset_puresky", 0.95, 120); sun.rotation_degrees = Vector3(-24, 50, 0); sun.light_color = Color(1.0, 0.8, 0.62); sun.light_energy = 1.3
			_fog(Color(0.62, 0.55, 0.52), 0.0016, 0.6); env.tonemap_exposure = 0.95; _grade(Vector3(0.98, 0.94, 0.9), 0.03, 0.95)
		"sunset":
			_sky("evening_road_01_puresky", 1.0, 160); sun.rotation_degrees = Vector3(-10, -40, 0); sun.light_color = Color(1.0, 0.75, 0.5); sun.light_energy = 1.3
			_fog(Color(0.8, 0.65, 0.55), 0.0012, 0.7); env.tonemap_exposure = 0.95; _grade(Vector3(1.0, 0.95, 0.88), 0.04)
		"night":
			_night_sky(Color(0.01, 0.015, 0.05), Color(0.06, 0.08, 0.16)); sun.light_energy = 0.3
			_fog(Color(0.07, 0.09, 0.16), 0.004, 0.5, 0.0); env.ambient_light_energy = 0.35; _grade(Vector3(0.92, 0.95, 1.05), 0.02, 1.0)
	var n := _noise(101, 0.02, 5); var big := _noise(102, 0.006, 6); var r := _noise(103, 0.08, 3)
	hfn = func(x: float, z: float) -> float:
		var half: float = 7.0 + absf(x) * 0.09 + n.get_noise_1d(x * 0.5) * 1.0
		var road: float = n.get_noise_2d(x, z) * 0.25 + r.get_noise_2d(x, z) * 0.1
		road += 1.4 * clampf(1.0 - Vector2(x + 15.0, z - 1.0).length() / 6.0, 0.0, 1.0)   # Kolonos hillock behind the wall
		if z < -half:
			var u: float = -z - half
			return road + u * 2.4 + n.get_noise_2d(x, z) * minf(u, 12.0) * 1.2 + absf(big.get_noise_2d(x, z)) * clampf(u - 10.0, 0.0, 300.0) * 1.4
		elif z > half:
			var dn: float = z - half
			return road - dn * 0.55 - n.get_noise_2d(x * 0.7, z) * minf(dn, 6.0) * 0.4
		return road
	world.add_child(Lib.terrain(1400.0, 230, hfn, _terrain_mat("coast_sand_rocks_02", "rocky_terrain_02", "cliff_side", "aerial_rocks_02", 200.0, 9.0, 0.0, Color(1.0, 0.92, 0.8))))
	_water(-2.2, 6000.0, Vector3(0.02, 0.09, 0.14) if mode != "night" else Vector3(0.01, 0.02, 0.05), Vector3(0.12, 0.34, 0.4) if mode != "night" else Vector3(0.02, 0.04, 0.08), Vector3(0.8, 0.82, 0.9) if mode != "night" else Vector3(0.05, 0.06, 0.12))
	# rocks on the cliff and shore
	for i in range(22):
		var p := Vector3(rng.randf_range(-90, 110), 0, rng.randf_range(-30, -8))
		var sc := rng.randf_range(1.5, 3.5)
		p.y = hfn.call(p.x, p.z); _place(["rock_face_01", "rock_face_02", "namaqualand_cliff_01", "boulder_01"][i % 4], p, sc, rng.randf() * TAU, sc * 0.9)
	for i in range(14):
		var p := Vector3(rng.randf_range(-90, 110), 0, rng.randf_range(9, 16))
		p.y = hfn.call(p.x, p.z); _place(["rock_07", "rock_09", "boulder_01"][i % 3], p, rng.randf_range(0.8, 2.2), rng.randf() * TAU, 0.3)
	for i in range(30):
		var p := Vector3(rng.randf_range(-150, 160), 0, rng.randf_range(-70, -14))
		p.y = hfn.call(p.x, p.z)
		if rng.randf() < 0.6: _conifer(p, rng.randf_range(5, 9), Color(0.25, 0.32, 0.2))
		else: _olive(p, rng.randf_range(3, 5))
	for i in range(26):
		var p := Vector3(rng.randf_range(-60, 80), 0, rng.randf_range(-7, 8)); if absf(p.z) < 3.5: continue
		p.y = hfn.call(p.x, p.z); _place(["shrub_01", "shrub_02", "grass_medium_01", "dry_branches_medium_01"][i % 4], p, rng.randf_range(0.6, 1.2), rng.randf() * TAU, 0.05)
	# the Phocian wall across the road at x=-6
	var wm := _tmat("stone_wall", Color(0.92, 0.86, 0.76), 0.6)
	for zz in range(-7, 8):
		var z := float(zz)
		var hgt := 2.4 + rng.randf_range(-0.3, 0.3)
		if zz == 0 or zz == 1: continue  # gate gap
		var gy: float = hfn.call(-6.0, z)
		if gy > 1.5: continue
		var b := _box(Vector3(1.3, hgt + 1.0, 1.05), Vector3(-6.0, gy + hgt * 0.5 - 0.7, z), wm); b.rotation.y = rng.randf_range(-0.04, 0.04)
		_obst(Vector3(-6.0, 0, z), 0.65, 0.53)
	marks["wall"] = Vector3(-6, 2, 0)

func _phalanx(x: float, facing: float, rows: int, cols: int, anim_front: String, anim_back: String, start := -999.0, end := 99999.0, gap := 1.0) -> Array:
	var out := []
	for r in range(rows):
		for c in range(cols):
			var z := (c - (cols - 1) * 0.5) * 0.95 + rng.randf_range(-0.06, 0.06)
			var p := Vector3(x - r * gap * signf(cos(facing - PI * 0.5)) * -1.0, 0, z)
			p.x = x + (r * gap if facing > 0 else -r * gap)
			var a := _spartan(p, facing, anim_front if r == 0 else anim_back, {"start": start, "end": end, "lo": r > 1})
			out.append(a)
	return out

func _pass_dawn() -> void:
	# 300 at dawn: phalanx in front of the wall facing +x (east)
	_phalanx(-3.0, PI * 0.5, 4, 9, "guard", "guard", -999, 99999, 1.1)
	_spartan(Vector3(-0.8, 0, 0.3), PI * 0.5, "look", {"id": "leo_dawn"})
	spawn("leonidas", Vector3(-1.2, 0, -0.6), PI * 0.5, "look", -999, 99999, Vector3.ZERO, {"id": "leo", "spear": true, "shield": SHIELD_SP[0], "crest": CREST, "speed": 0.8})
	# far persian mass on the plain to the east
	_far_army(Vector3(120, 0, 0), 60, 70, 900)
	C(Vector3(40, 26, 38), Vector3(-2, 2, 0), Vector3(25, 18, 26), Vector3(-3, 2, 0), 40, 36)
	C(Vector3(2.5, 2.6, 4.5), Vector3(-2.5, 3.6, -0.5), Vector3(1.8, 2.4, 3.8), Vector3(-2.5, 3.6, -0.6), 34, 30)
	C(Vector3(-14, 6, 6), Vector3(60, 3, 0), Vector3(-12, 5, 5), Vector3(80, 3, 0), 40, 34)
	C(Vector3(0.6, 3.8, 1.8), Vector3(-1.2, 3.6, -0.6), Vector3(0.5, 3.75, 1.2), Vector3(-1.2, 3.6, -0.6), 30, 26)
	C(Vector3(60, 9, 18), Vector3(0, 3, 0), Vector3(30, 7, 14), Vector3(-4, 3, 0), 38, 38)
	C(Vector3(-20, 30, -60), Vector3(10, 0, 10), Vector3(-28, 40, -70), Vector3(20, 0, 10), 50, 54)

func _far_army(center: Vector3, depth: float, width: float, count: int) -> void:
	# distant army: multimesh of small figures (reads as a mass from far away)
	var mm := MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D; mm.use_colors = true
	var cap := CapsuleMesh.new(); cap.radius = 0.28; cap.height = 1.75; cap.radial_segments = 6; cap.rings = 2; mm.mesh = cap
	mm.instance_count = count
	var cols := [Color(0.25, 0.3, 0.45), Color(0.55, 0.4, 0.25), Color(0.3, 0.42, 0.4), Color(0.6, 0.5, 0.3), Color(0.4, 0.2, 0.35)]
	for i in range(count):
		var p := center + Vector3(rng.randf_range(0, depth), 0, rng.randf_range(-width * 0.5, width * 0.5))
		p.y = (hfn.call(p.x, p.z) if hfn.is_valid() else 0.0) + 0.88
		mm.set_instance_transform(i, Transform3D(Basis(), p)); mm.set_instance_color(i, cols[i % cols.size()])
	var mi := MultiMeshInstance3D.new(); mi.multimesh = mm
	var m := StandardMaterial3D.new(); m.vertex_color_use_as_albedo = true; m.roughness = 0.9; mi.material_override = m; mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(mi)
	# spears sticking up
	var sm := MultiMesh.new(); sm.transform_format = MultiMesh.TRANSFORM_3D; var bx := BoxMesh.new(); bx.size = Vector3(0.03, 2.4, 0.03); sm.mesh = bx; sm.instance_count = count / 2
	for i in range(count / 2):
		var p := center + Vector3(rng.randf_range(0, depth), 0, rng.randf_range(-width * 0.5, width * 0.5)); p.y = (hfn.call(p.x, p.z) if hfn.is_valid() else 0.0) + 1.6
		sm.set_instance_transform(i, Transform3D(Basis().rotated(Vector3(0, 0, 1), rng.randf_range(-0.1, 0.1)), p))
	var si := MultiMeshInstance3D.new(); si.multimesh = sm; si.material_override = _m(Color(0.3, 0.22, 0.15)); si.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; world.add_child(si)

func _pass_wall() -> void:
	# Greeks rebuilding the wall, camp behind it
	for i in range(14):
		var p := Vector3(rng.randf_range(-9, -4), 0, rng.randf_range(-6, 6))
		var nm: String = _pick(GREEKS)
		var an: String = ["carry", "kneelwork", "work", "push", "interact"][i % 5]
		spawn(nm, p, rng.randf() * TAU, an, -999, 99999, Vector3.ZERO, {"lo": i > 7})
	for i in range(6):
		var p := Vector3(-14.0 + i * 1.2, 0, -5.0 + rng.randf_range(-0.4, 0.4))
		spawn(_pick(GREEKS), p, PI * 0.5, "carry", -999, 99999, Vector3(0.0, 0, 0.9), {"wrap": 11.0})
	spawn("leonidas", Vector3(-4.2, 0, 2.6), -2.4, "point", -999, 99999, Vector3.ZERO, {"id": "leo", "crest": CREST})
	spawn("greek_man", Vector3(-5.6, 0, 3.6), 0.8, "talk")
	_phalanx(-11.0, PI * 0.5, 2, 6, "guard", "idle", -999, 99999, 1.1)
	for i in range(5):
		var p := Vector3(-22.0 - i * 4.0, 0, rng.randf_range(-4, 4)); p.y = hfn.call(p.x, p.z); _tent(p, rng.randf() * TAU, [Color(0.85, 0.78, 0.65), Color(0.7, 0.6, 0.45)][i % 2])
	_place("wooden_crate_01", _ground(Vector3(-8, 0, 3)), 1.0); _place("wooden_barrels_01", _ground(Vector3(-9, 0, -4)), 1.0)
	C(Vector3(4, 3.2, 9), Vector3(-6, 1.5, 0), Vector3(1, 2.8, 8), Vector3(-6, 1.5, -1), 40, 38)
	C(Vector3(-2.5, 2.2, 5.5), Vector3(-4.2, 1.8, 2.6), Vector3(-2.2, 2.1, 5.0), Vector3(-4.2, 1.8, 2.6), 34, 30)
	C(Vector3(30, 40, 30), Vector3(-5, 0, 0), Vector3(14, 30, 30), Vector3(-5, 0, 0), 44, 44)
	C(Vector3(-16, 4, -2), Vector3(-6, 2, 0), Vector3(-16, 4.5, 3), Vector3(-6, 2, 0), 40, 40)
	C(Vector3(-2, 60, 120), Vector3(-2, 30, -60), Vector3(-2, 50, 100), Vector3(-2, 60, -60), 48, 48)
	C(Vector3(-8, 2.0, -3), Vector3(-6, 2.2, 3), Vector3(-7, 2.0, -3), Vector3(-6, 2.2, 3), 40, 36)

func _pass_wait() -> void:
	# Spartans exercising / combing hair in front of the wall; Persian scout on horseback watching from afar
	for i in range(8):
		var p := Vector3(rng.randf_range(-4, 1), 0, rng.randf_range(-4, 4))
		var an: String = ["sit", "sittalk", "yes", "fold"][i % 4]
		var ex := {"crest": CREST}
		if an.begins_with("sit"): ex["dy"] = -0.05
		spawn(_pick(SPARTANS), p, rng.randf() * TAU, an, -999, 99999, Vector3.ZERO, ex)
	for i in range(6):
		spawn(_pick(SPARTANS), Vector3(-1.0 + i * 1.6, 0, 3.5), 0.0, ["combo", "attack", "block", "sword_idle"][i % 4], -999, 99999, Vector3.ZERO, {"sword": true})
	for i in range(4):
		var p := Vector3(-3.0 + i * 1.2, 0, -4.0)
		_place("boulder_01", _ground(p) - Vector3(0, 0.3, 0), 0.45, rng.randf() * TAU)
	spawn("leonidas", Vector3(0.5, 0, 0.5), PI * 0.5, "look", -999, 99999, Vector3.ZERO, {"id": "leo", "spear": true, "shield": SHIELD_SP[0], "crest": CREST, "speed": 0.8})
	_phalanx(-5.0, PI * 0.5, 2, 8, "guard", "idle", -999, 99999, 1.1)
	_persian(Vector3(28, 0, -2), -PI * 0.5, "look", {"id": "scout"})
	_far_army(Vector3(110, 0, 0), 70, 80, 900)
	C(Vector3(5, 2.4, 7), Vector3(-1, 1.2, 0), Vector3(3, 2.2, 6), Vector3(-1, 1.0, 1), 40, 36)
	C(Vector3(31, 2.0, 1.5), Vector3(0, 1.4, 0), Vector3(31.5, 2.0, 0.8), Vector3(0, 1.4, 0), 24, 18)
	C(Vector3(-3, 1.7, 6.5), Vector3(2, 1.2, 3.5), Vector3(-2, 1.7, 7), Vector3(3, 1.2, 3.5), 38, 36)
	C(Vector3(2.6, 2.2, 2.6), Vector3(0.5, 1.75, 0.5), Vector3(2.3, 2.0, 2.2), Vector3(0.5, 1.75, 0.5), 30, 28)
	C(Vector3(-12, 7, 10), Vector3(40, 2, 0), Vector3(-10, 8, 8), Vector3(60, 2, 0), 44, 40)

func _battle() -> void:
	# front of the phalanx at x=0 facing +x; persian waves charge from +x
	var front := []
	for c in range(9):
		var z := (c - 4) * 0.95
		front.append(_spartan(Vector3(0.0, 0, z), PI * 0.5, ["block", "attack", "shield", "block", "attack"][c % 5], {"speed": rng.randf_range(0.8, 1.1)}))
	for r in range(1, 6):
		for c in range(9):
			var z := (c - 4) * 0.95 + rng.randf_range(-0.05, 0.05)
			_spartan(Vector3(-r * 1.05, 0, z), PI * 0.5, "guard", {"lo": r > 2})
	spawn("leonidas", Vector3(-0.4, 0, 4.6), PI * 0.5, "attack", -999, 99999, Vector3.ZERO, {"id": "leo", "sword": true, "shield": SHIELD_SP[0], "crest": CREST})
	# waves: every 7 s a wave of 18 charges in, fights, many die and stay down; wraps for long segments
	for w in range(18):
		var t0 := w * 6.5
		for i in range(11):
			var z := rng.randf_range(-4.2, 4.2)
			var p := Vector3(rng.randf_range(26, 40), 0, z)
			var arrive := t0 + (p.x - 1.4) / 4.2
			var imm := w % 4 == 3
			var a := _persian(p, -PI * 0.5, "sprint" if rng.randf() < 0.5 else "run", {"start": t0, "end": t0 + 24.0, "vel": Vector3(-4.2, 0, 0), "immortal": imm, "lo": i > 4})
			ev(a, arrive, "attack" if rng.randf() < 0.5 else "combo", true, Vector3.ZERO)
			var die := arrive + rng.randf_range(0.8, 6.0)
			if rng.randf() < 0.75: ev(a, die, "death", false, Vector3.ZERO)
			else: ev(a, die, "run", true, Vector3(4.0, 0, 0), PI * 0.5)
	_far_army(Vector3(60, 0, 0), 60, 22, 600)
	_dust(90)
	C(Vector3(5.5, 2.2, 7.5), Vector3(1.0, 1.3, 0), Vector3(3.5, 2.0, 7.0), Vector3(0.5, 1.3, -1), 40, 36)
	C(Vector3(-8, 3.4, 2.0), Vector3(6, 1.2, 0), Vector3(-8, 3.4, -2.0), Vector3(6, 1.2, 0), 42, 40)
	C(Vector3(16, 16, 20), Vector3(2, 0, 0), Vector3(10, 12, 18), Vector3(2, 0, 0), 44, 42)
	C(Vector3(10, 2.8, 8.0), Vector3(0, 1.2, 0), Vector3(9, 2.6, 7.5), Vector3(0, 1.2, -0.5), 38, 34)
	C(Vector3(2.0, 1.8, 7.0), Vector3(-0.4, 1.6, 4.6), Vector3(1.6, 1.75, 6.6), Vector3(-0.4, 1.6, 4.6), 32, 28)
	C(Vector3(-12, 7, -5), Vector3(10, 0.5, 2), Vector3(-12, 6, 5), Vector3(10, 0.5, -2), 40, 40)
	C(Vector3(30, 3, 12), Vector3(0, 1.5, 0), Vector3(22, 2.5, 10), Vector3(0, 1.5, 0), 36, 32)

func _night_camp(council: bool) -> void:
	for fp in [Vector3(-12, 0, 0), Vector3(-17, 0, 4), Vector3(-17, 0, -4), Vector3(-23, 0, 1)]:
		var p := _ground(fp); _fire(p)
		for k in range(5):
			var a := k * TAU / 5.0 + rng.randf_range(-0.2, 0.2)
			var q := p + Vector3(cos(a), 0, sin(a)) * 1.6
			var sp := spawn(_pick(SPARTANS if rng.randf() < 0.6 else GREEKS), q, atan2(p.x - q.x, p.z - q.z), "sit" if rng.randf() < 0.6 else "sittalk", -999, 99999, Vector3.ZERO, {"dy": -0.05, "lo": fp != Vector3(-12, 0, 0)})
			_place("tree_stump_01", _ground(q) - Vector3(0, 0.05, 0), 0.9, rng.randf() * TAU)
	for i in range(6):
		var p := _ground(Vector3(-28.0 - i * 3.5, 0, rng.randf_range(-4, 4))); _tent(p, rng.randf() * TAU, Color(0.6, 0.52, 0.4))
	for i in range(4):
		spawn(_pick(SPARTANS), Vector3(-6.5, 0, -3.0 + i * 2.0), PI * 0.5, "torch", -999, 99999, Vector3.ZERO, {"torch": true, "crest": CREST})
	if council:
		spawn("leonidas", Vector3(-10.0, 0, 1.2), -1.8, "talk", -999, 99999, Vector3.ZERO, {"id": "leo", "crest": CREST})
		for k in range(6):
			var a := -0.9 + k * 0.36
			spawn(_pick(GREEKS + ["greek_man"]), Vector3(-10.0 - cos(a) * 3.0, 0, 1.2 + sin(a) * 3.0), atan2(cos(a), -sin(a)) + PI, ["look", "fold", "talk", "idle"][k % 4])
		_fire(_ground(Vector3(-11.6, 0, 1.4)), 0.7)
		var mess := spawn("greek_man", Vector3(4, 0, 0), -PI * 0.5, "sprint", 0.0, 4.0, Vector3(-3.4, 0, 0))
		C(Vector3(-6.0, 2.0, 3.5), Vector3(-10, 1.4, 1.2), Vector3(-6.5, 2.0, 2.5), Vector3(-10, 1.4, 1.2), 40, 36)
		C(Vector3(-8.6, 1.95, 2.0), Vector3(-10.0, 1.7, 1.2), Vector3(-8.8, 1.9, 1.7), Vector3(-10.0, 1.7, 1.2), 30, 26)
	else:
		spawn("leonidas", Vector3(-15.0, 0, -6.0), 0.4, "walk", -999, 99999, Vector3(0.0, 0, 0.75), {"id": "leo", "crest": CREST, "wrap": 14.0})
		C(Vector3(-15, 1.9, -8.5), Vector3(0, 1.6, 2.5), Vector3(-15, 1.9, -8.5), Vector3(0, 1.6, 2.5), 40, 40, {"track": "leo"})
	C(Vector3(-4, 4, 8), Vector3(-17, 1, 0), Vector3(-6, 3.5, 9), Vector3(-18, 1, 0), 44, 42)
	C(Vector3(-24, 2.2, -4), Vector3(300, 380, 900), Vector3(-24, 2.2, -4), Vector3(300, 300, 900), 55, 50)
	C(Vector3(-13.6, 1.3, 2.2), Vector3(-12, 0.8, 0), Vector3(-14.0, 1.2, 1.9), Vector3(-12, 0.8, 0), 40, 36)
	C(Vector3(10, 40, 40), Vector3(-15, 0, 0), Vector3(0, 30, 35), Vector3(-15, 0, 0), 44, 44)
	C(Vector3(-20.5, 1.5, 6.5), Vector3(-17, 0.9, 4), Vector3(-20, 1.5, 6.0), Vector3(-17, 0.9, 4), 38, 34)

func _last_stand() -> void:
	# open ground in front of the wall (x 6..14), Spartans in a tightening ring; later on the hillock behind the wall
	var hill := Vector3(-15, 0, 1)
	for i in range(26):
		var a := i * TAU / 26.0
		var p := hill + Vector3(cos(a), 0, sin(a)) * rng.randf_range(2.0, 3.2)
		var an: String = ["block", "attack", "combo", "sword_idle"][i % 4]
		var s := _spartan(p, atan2(cos(a), sin(a)), an, {"sword": true, "spear": null, "lo": i > 13})
		s.erase("spear")
		if rng.randf() < 0.5: ev(s, rng.randf_range(20, 70), "death", false)
	for i in range(70):
		var a := rng.randf() * TAU
		var p := hill + Vector3(cos(a), 0, sin(a)) * rng.randf_range(4.5, 9.0)
		var pa := _persian(p, atan2(-cos(a), -sin(a)), ["attack", "combo", "run", "block"][i % 4], {"lo": i > 20})
		if rng.randf() < 0.35: ev(pa, rng.randf_range(3, 50), "death", false)
	spawn("leonidas", hill + Vector3(0.4, 0, 0.2), PI * 0.5, "combo", -999, 99999, Vector3.ZERO, {"id": "leo", "sword": true, "shield": SHIELD_SP[0], "crest": CREST})
	# archers on the slope
	for i in range(30):
		var p := Vector3(rng.randf_range(10, 22), 0, rng.randf_range(-5, 5))
		spawn(_pick(PERSIANS), p, -PI * 0.5, "throw", -999, 99999, Vector3.ZERO, {"bow": true, "lo": true})
	_arrows(hill, Vector3(8, 2, 8), 420, Vector3(-16, 0, 0))
	_dust(110, Color(0.7, 0.6, 0.5, 0.06))
	_place("boulder_01", _ground(hill + Vector3(0, 0, -6)), 2.0)
	C(Vector3(-5, 3.6, 8), Vector3(-15, 2.4, 1), Vector3(-7, 3.8, 9), Vector3(-15, 2.4, 1), 40, 38)
	C(Vector3(-11.8, 3.2, 3.6), Vector3(-15, 2.8, 1.2), Vector3(-12.2, 3.2, 3.9), Vector3(-15, 2.8, 1.2), 34, 30)
	CO(hill + Vector3(0, 1.4, 0), 0.4, 1.6, 15, 11, 9, 6, 44, 1.2)
	C(Vector3(14, 2.2, 6), Vector3(-15, 7, 1), Vector3(12, 2.4, 5), Vector3(-15, 9, 1), 40, 44)
	C(Vector3(-15, 24, 14), Vector3(-15, 1, 1), Vector3(-15, 30, 18), Vector3(-15, 1, 1), 44, 44)
	C(Vector3(-9, 2.6, 4), Vector3(-15, 4, 0), Vector3(-9.5, 2.6, 3.5), Vector3(-15, 5, 0), 42, 46)

func _epitaph() -> void:
	var hill := Vector3(-15, 0, 1)
	var st := _box(Vector3(1.4, 2.2, 0.35), _ground(hill) + Vector3(0, 1.0, 0), _tmat("stone_wall", Color(0.95, 0.9, 0.82), 1.2))
	st.rotation.y = 0.3
	var lion := _box(Vector3(0.9, 0.7, 1.5), _ground(hill + Vector3(2.5, 0, 1.5)) + Vector3(0, 0.6, 0), _tmat("stone_wall", Color(0.9, 0.84, 0.75), 1.0))
	for i in range(12):
		var p := hill + Vector3(rng.randf_range(-6, 6), 0, rng.randf_range(-5, 5)); p.y = hfn.call(p.x, p.z)
		_place(["grass_medium_01", "shrub_01", "dry_branches_medium_01"][i % 3], p, rng.randf_range(0.7, 1.3), rng.randf() * TAU)
	# a traveller walks past and stops
	var a := spawn("greek_man", hill + Vector3(8, 0, 3), -2.2, "walk", -999, 99999, Vector3(-0.8, 0, -0.4))
	ev(a, 7.0, "look", true, Vector3.ZERO, -2.6)
	C(Vector3(-11.0, 3.0, 4.5), Vector3(-15, 2.5, 1), Vector3(-12.0, 2.9, 4.2), Vector3(-15, 2.6, 1), 38, 34)
	C(Vector3(-22, 4.5, 8), Vector3(-15, 2.4, 1), Vector3(-24, 5.5, 5), Vector3(-15, 2.4, 1), 40, 40)
	C(Vector3(-14, 3.6, 6), Vector3(40, 3, 30), Vector3(-16, 3.6, 6), Vector3(40, 6, 40), 44, 44)
	C(Vector3(-2, 60, 90), Vector3(-15, 0, 1), Vector3(-2, 80, 130), Vector3(-15, 0, 1), 44, 48)
	C(Vector3(-13.4, 3.1, 2.6), Vector3(-15, 2.7, 1), Vector3(-13.7, 3.1, 2.8), Vector3(-15, 2.8, 1), 32, 28)

# ======================================================= PERSIAN CAMP / THRONE
func _pcamp(throne: bool, night := false) -> void:
	if night:
		_night_sky(Color(0.01, 0.015, 0.05), Color(0.06, 0.07, 0.14)); env.ambient_light_energy = 0.3
		_fog(Color(0.06, 0.07, 0.12), 0.003, 0.4, 0.0); _grade(Vector3(0.92, 0.95, 1.05), 0.03, 1.0)
	else:
		_sky("drakensberg_solitary_mountain_puresky" if not throne else "qwantani_late_afternoon_puresky", 1.0, 30)
		sun.rotation_degrees = Vector3(-35, 140, 0); sun.light_color = Color(1.0, 0.88, 0.72); sun.light_energy = 1.5
		_fog(Color(0.85, 0.8, 0.7), 0.0012, 0.5); env.tonemap_exposure = 0.92
	var n := _noise(201, 0.01, 5)
	hfn = func(x: float, z: float) -> float:
		var edge: float = clampf((Vector2(x, z).length() - 180.0) / 300.0, 0.0, 1.0)
		var flat: float = clampf((Vector2(x, z).length() - 6.0) / 30.0, 0.0, 1.0)
		return n.get_noise_2d(x, z) * 2.0 * flat + edge * edge * 160.0
	world.add_child(Lib.terrain(1600.0, 260, hfn, _terrain_mat("dry_ground_01", "aerial_grass_rock", "rocky_terrain_02", "aerial_rocks_02", 150.0, 30.0, 0.0, Color(1.05, 0.95, 0.8))))
	var cols := [Color(0.85, 0.78, 0.6), Color(0.6, 0.3, 0.25), Color(0.3, 0.35, 0.5), Color(0.75, 0.6, 0.35)]
	for i in range(140):
		var a := rng.randf() * TAU; var r := rng.randf_range(16, 140)
		var p := Vector3(cos(a) * r, 0, sin(a) * r); p.y = hfn.call(p.x, p.z)
		_tent(p, rng.randf() * TAU, cols[i % 4], rng.randf_range(0.9, 1.4), i % 9 == 0)
	for i in range(12):
		var a := rng.randf() * TAU; var r := rng.randf_range(20, 90); _fire(_ground(Vector3(cos(a) * r, 0, sin(a) * r)), 0.8)
		_smoke(_ground(Vector3(cos(a) * r, 0, sin(a) * r)) + Vector3(0, 2, 0), 0.6, 20, Color(0.5, 0.48, 0.45, 0.25))
	# royal pavilion and throne on the knoll
	var top := _ground(Vector3(0, 0, 0))
	_box(Vector3(8, 0.3, 8), top + Vector3(0, 0.15, 0), _tmat("stone_wall", Color(0.95, 0.9, 0.82), 0.8))
	var gm := _m(Color(0.85, 0.65, 0.25), 0.8, 0.35)
	for cx in [-3.2, 3.2]:
		for cz in [-3.2, 3.2]:
			_cyl(0.12, 0.14, 4.2, top + Vector3(cx, 2.4, cz), gm)
	var can := _box(Vector3(7.6, 0.15, 7.6), top + Vector3(0, 4.5, 0), _m(Color(0.5, 0.16, 0.35), 0.0, 0.9))
	_box(Vector3(1.4, 2.2, 1.0), top + Vector3(0, 1.4, -1.6), gm)
	_box(Vector3(1.6, 0.6, 1.4), top + Vector3(0, 0.6, -1.3), gm)
	marks["throne"] = top + Vector3(0, 0.3, -1.2)
	if night:
		for cx in [-3.6, 3.6]:
			for cz in [-3.6, 3.6]: _fire(top + Vector3(cx, 0.3, cz), 0.6, false)
		for i in range(30):
			var a2 := rng.randf() * TAU; var r2 := rng.randf_range(15, 150); _fire(_ground(Vector3(cos(a2) * r2, 0, sin(a2) * r2)), 0.9)
	spawn("xerxes", Vector3(0, 0, -1.2), 0.0, "sit", -999, 99999, Vector3.ZERO, {"id": "xerxes", "dy": 0.58, "ground": true, "speed": 0.7, "noclip": true})
	for i in range(10):
		var a := -PI * 0.5 + (i - 4.5) * 0.18
		spawn(IMMORTALS[i % 2], Vector3(cos(a) * 5.0, 0, -sin(a) * 5.0 + 2.0), rng.randf_range(-0.2, 0.2), "guard", -999, 99999, Vector3.ZERO, {"spear": true, "wicker": true})
	spawn("immortal_a", Vector3(-1.5, 0, 1.0), PI, "talk", -999, 99999, Vector3.ZERO, {"id": "general"})
	if throne:
		spawn("ephialtes", Vector3(1.4, 0, 2.2), PI + 0.4, "talk", -999, 99999, Vector3.ZERO, {"id": "eph"})
		spawn("greek_man", Vector3(2.5, 0, 1.6), -2.4, "fold")   # Demaratus
	for i in range(60):
		var p := Vector3(rng.randf_range(-60, 60), 0, rng.randf_range(10, 70))
		var nm: String = _pick(PERSIANS)
		var an: String = ["idle", "talk", "walk", "sit", "carry", "look"][i % 6]
		var v := Vector3.ZERO
		if an == "walk" or an == "carry": v = Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized() * 1.1
		spawn(nm, p, atan2(v.x, v.z) if v != Vector3.ZERO else rng.randf() * TAU, an, -999, 99999, v, {"lo": true, "dy": -0.05 if an == "sit" else 0.0})
	C(Vector3(0, 3.0, 9), Vector3(0, 2.0, -1), Vector3(0, 2.6, 6.5), Vector3(0, 2.0, -1.2), 40, 34)
	C(Vector3(1.5, 2.6, 2.4), Vector3(0, 2.4, -1.2), Vector3(1.2, 2.5, 2.0), Vector3(0, 2.4, -1.2), 30, 26)
	C(Vector3(60, 40, 120), Vector3(0, 0, 0), Vector3(40, 30, 90), Vector3(0, 0, 0), 46, 44)
	C(Vector3(-4, 2.4, 4), Vector3(1.4, 1.6, 2.2), Vector3(-3.5, 2.3, 3.4), Vector3(1.4, 1.6, 2.2), 36, 32)
	C(Vector3(-30, 6, 60), Vector3(20, 2, 20), Vector3(10, 5, 60), Vector3(30, 2, 20), 42, 42)
	C(Vector3(-2.2, 2.4, -3.8), Vector3(0, 2.0, 6), Vector3(-1.5, 2.4, -3.6), Vector3(0, 2.0, 6), 38, 36)

# ======================================================= MARCH / HELLESPONT / PALACE
func _march() -> void:
	_sky("qwantani_mid_morning_puresky", 1.0, 80)
	sun.rotation_degrees = Vector3(-38, 150, 0); sun.light_color = Color(1.0, 0.9, 0.75); sun.light_energy = 1.5
	_fog(Color(0.85, 0.8, 0.72), 0.0013, 0.55)
	var n := _noise(301, 0.008, 5)
	hfn = func(x: float, z: float) -> float:
		var valley: float = clampf((absf(z) - 25.0) / 200.0, 0.0, 1.0)
		return n.get_noise_2d(x, z) * 3.0 + valley * valley * 120.0 + n.get_noise_2d(x * 3.0, z * 3.0) * 20.0 * valley
	world.add_child(Lib.terrain(1800.0, 260, hfn, _terrain_mat("dry_ground_01", "aerial_grass_rock", "rocky_terrain_02", "aerial_rocks_02", 160.0, 20.0, 0.0, Color(1.05, 0.92, 0.78))))
	# near column: 12 wide x 10 deep marching -x, wrapping
	for r in range(10):
		for c in range(12):
			var p := Vector3(10.0 + r * 1.5, 0, (c - 5.5) * 1.1)
			var imm := r < 3
			var a := _persian(p, -PI * 0.5, "march", {"vel": Vector3(-1.3, 0, 0), "immortal": imm, "lo": r > 2 or c < 2 or c > 9, "wrap": 46.0})
			a.from.x += 20.0
	spawn("xerxes", Vector3(40, 0, 18), -PI * 0.5, "walk", -999, 99999, Vector3(-1.1, 0, 0), {"wrap": 60.0, "id": "xerxes"})
	_far_army(Vector3(30, 0, 0), 600, 26, 2600)
	_dust(150, Color(0.8, 0.7, 0.55, 0.07))
	C(Vector3(-20, 5, 14), Vector3(20, 1.5, 0), Vector3(-14, 4, 13), Vector3(25, 1.5, 0), 40, 38)
	C(Vector3(-60, 60, 80), Vector3(120, 0, 0), Vector3(-40, 50, 70), Vector3(160, 0, 0), 46, 46)
	C(Vector3(5, 1.6, 8.5), Vector3(14, 1.5, 0), Vector3(3, 1.6, 8.5), Vector3(10, 1.5, 0), 36, 34)
	C(Vector3(-8, 1.2, 1.5), Vector3(20, 2, 0), Vector3(-9, 1.0, -1.5), Vector3(20, 2.5, 0), 44, 48)
	C(Vector3(200, 120, -200), Vector3(150, 0, 0), Vector3(150, 140, -260), Vector3(200, 0, 0), 50, 50)

func _hellespont() -> void:
	_sky("scythian_tombs_puresky", 1.0, 30)
	sun.rotation_degrees = Vector3(-14, 230, 0); sun.light_color = Color(1.0, 0.7, 0.45); sun.light_energy = 1.5
	_fog(Color(0.85, 0.72, 0.6), 0.001, 0.6); _grade(Vector3(1.02, 0.95, 0.86), 0.07)
	var n := _noise(401, 0.006, 5)
	hfn = func(x: float, z: float) -> float:
		var shore: float = absf(x) - 140.0
		return -6.0 + clampf(shore, -20.0, 200.0) * 0.35 + n.get_noise_2d(x, z) * 6.0 * clampf(shore / 20.0, 0.0, 1.0)
	world.add_child(Lib.terrain(2400.0, 220, hfn, _terrain_mat("coast_sand_rocks_02", "aerial_grass_rock", "rocky_terrain_02", "aerial_rocks_02", 200.0, 12.0)))
	_water(0.0, 6000.0)
	# pontoon bridge along x from -140 to 140 at z=0: boats side by side, plank deck
	for i in range(70):
		var x := -140.0 + i * 4.0
		_ship(Vector3(x, -0.2, 0), PI * 0.5, 0.55, Color(0.8, 0.75, 0.65), false, false)
	_box(Vector3(290, 0.2, 5.0), Vector3(0, 1.1, 0), _tmat("brown_planks_05", Color(0.75, 0.6, 0.45), 0.4))
	for i in range(140):
		var x := -140.0 + i * 2.0
		_cyl(0.05, 0.05, 1.2, Vector3(x, 1.7, 2.6), _m(Color(0.35, 0.25, 0.16)), null, 5); _cyl(0.05, 0.05, 1.2, Vector3(x, 1.7, -2.6), _m(Color(0.35, 0.25, 0.16)), null, 5)
	# army crossing on the deck (+x toward Europe)
	for r in range(14):
		for c in range(4):
			var p := Vector3(-30.0 + r * 1.6, 1.2, (c - 1.5) * 1.05)
			_persian(p, PI * 0.5, "march", {"vel": Vector3(1.2, 0, 0), "ground": false, "lo": r > 4, "wrap": 60.0, "start": -999.0})
	for i in range(18):
		_ship(Vector3(rng.randf_range(-200, 200), 0, rng.randf_range(40, 260)), rng.randf() * TAU, rng.randf_range(0.8, 1.1))
	# Xerxes on marble throne at Abydos (x=-150 hill)
	var hp := Vector3(-165, 0, -14); hp.y = hfn.call(hp.x, hp.z)
	_box(Vector3(2.4, 0.5, 2.4), hp + Vector3(0, 0.25, 0), _tmat("stone_wall", Color(0.98, 0.95, 0.9), 1.0))
	_box(Vector3(1.0, 0.55, 1.0), hp + Vector3(0, 0.75, 0), _m(Color(0.95, 0.93, 0.88), 0.0, 0.4))
	spawn("xerxes", Vector3(-165, 0, -14.0), PI * 0.4, "sit", -999, 99999, Vector3.ZERO, {"dy": 0.62, "speed": 0.6, "id": "xerxes", "noclip": true})
	spawn("immortal_a", Vector3(-163, 0, -12.6), PI * 0.4, "guard", -999, 99999, Vector3.ZERO, {"spear": true, "wicker": true})
	spawn("elder", Vector3(-166.5, 0, -12.6), PI * 0.3, "talk")
	C(Vector3(-60, 14, 40), Vector3(0, 1, 0), Vector3(-30, 12, 36), Vector3(20, 1, 0), 40, 40)
	C(Vector3(-12, 3.0, 8), Vector3(-20, 1.8, 0), Vector3(-6, 3.0, 8), Vector3(-12, 1.8, 0), 38, 36)
	C(Vector3(-161, hp.y + 2.0, -10), Vector3(-165, hp.y + 1.7, -14.2), Vector3(-161.5, hp.y + 1.9, -10.8), Vector3(-165, hp.y + 1.7, -14.2), 34, 30)
	C(Vector3(-170, hp.y + 3.0, -20), Vector3(0, 0, 0), Vector3(-170, hp.y + 3.2, -21), Vector3(40, 0, 0), 40, 36)
	C(Vector3(0, 70, -120), Vector3(0, 0, 0), Vector3(40, 60, -110), Vector3(0, 0, 0), 48, 46)
	C(Vector3(-163.5, hp.y + 1.8, -12.0), Vector3(-165, hp.y + 1.75, -14.2), Vector3(-163.6, hp.y + 1.8, -12.3), Vector3(-165, hp.y + 1.75, -14.2), 28, 24)

func _palace() -> void:
	env.background_mode = Environment.BG_COLOR; env.background_color = Color(0.1, 0.08, 0.06)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; env.ambient_light_color = Color(0.75, 0.65, 0.52); env.ambient_light_energy = 1.1
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC; env.glow_enabled = true; env.glow_intensity = 0.6
	sun.rotation_degrees = Vector3(-35, 150, 0); sun.light_color = Color(1.0, 0.85, 0.65); sun.light_energy = 1.3
	_fog(Color(0.5, 0.42, 0.32), 0.006, 0.3, 0.0)
	for i in range(8):
		var tl := OmniLight3D.new(); world.add_child(tl); tl.position = Vector3(-3.0 if i % 2 == 0 else 3.0, 3.0, -16 + (i / 2) * 8.0); tl.light_color = Color(1.0, 0.6, 0.3); tl.omni_range = 9; tl.light_energy = 1.6
		_fire(Vector3(-3.0 if i % 2 == 0 else 3.0, 2.2, -16 + (i / 2) * 8.0), 0.35, false)
		_cyl(0.08, 0.12, 2.2, Vector3(-3.0 if i % 2 == 0 else 3.0, 1.1, -16 + (i / 2) * 8.0), _m(Color(0.7, 0.55, 0.25), 0.8, 0.4))
	var fl := _tmat("stone_wall", Color(0.85, 0.78, 0.68), 0.25)
	_box(Vector3(60, 0.2, 80), Vector3(0, -0.1, 0), fl)
	var cm := _tmat("clay_plaster", Color(0.92, 0.85, 0.74), 0.6)
	for ix in range(-3, 4):
		for iz in range(-5, 5):
			if ix == 0: continue
			_column(Vector3(ix * 4.0, 0, iz * 4.0), 9.0, 0.45, cm)
	_box(Vector3(60, 1.2, 80), Vector3(0, 10.0, 0), _tmat("brown_planks_05", Color(0.45, 0.32, 0.22), 0.3))
	for s in [-1.0, 1.0]:
		_box(Vector3(0.6, 10, 80), Vector3(s * 15.0, 5, 0), cm)
	_box(Vector3(30, 10, 0.6), Vector3(0, 5, -21), cm)
	# shafts of light
	for i in range(5):
		var l := SpotLight3D.new(); world.add_child(l); l.position = Vector3(-10, 9.5, -16 + i * 8); l.rotation_degrees = Vector3(-60, -60, 0); l.spot_range = 30; l.spot_angle = 18; l.light_energy = 3.0; l.light_color = Color(1.0, 0.85, 0.6); l.shadow_enabled = i == 2
	var gm := _m(Color(0.85, 0.65, 0.25), 0.8, 0.35)
	_box(Vector3(6, 0.8, 4), Vector3(0, 0.4, -17), _tmat("stone_wall", Color(0.95, 0.9, 0.85), 0.8))
	_box(Vector3(1.6, 2.6, 1.0), Vector3(0, 2.1, -18), gm)
	spawn("xerxes", Vector3(0, 0, -17.6), 0.0, "sit", -999, 99999, Vector3.ZERO, {"id": "xerxes", "dy": 1.2, "ground": false, "speed": 0.6})
	spawn("elder", Vector3(-1.6, 0.8, -16.5), 0.4, "idle", -999, 99999, Vector3.ZERO, {"ground": false})
	for i in range(16):
		var side := -1.0 if i % 2 == 0 else 1.0
		spawn(IMMORTALS[i % 2], Vector3(side * 2.5, 0, -12.0 + (i / 2) * 2.6), -side * PI * 0.5, "guard", -999, 99999, Vector3.ZERO, {"spear": true, "wicker": true, "ground": false})
	for i in range(8):
		spawn(_pick(PERSIANS + ["elder"]), Vector3(rng.randf_range(-6, 6), 0, rng.randf_range(4, 14)), PI, ["idle", "fold", "look", "talk"][i % 4], -999, 99999, Vector3.ZERO, {"ground": false})
	C(Vector3(0, 2.4, 14), Vector3(0, 2.4, -17), Vector3(0, 2.4, 2), Vector3(0, 2.6, -17), 42, 38)
	C(Vector3(1.2, 2.5, -14.4), Vector3(0, 2.4, -17.6), Vector3(0.9, 2.5, -14.8), Vector3(0, 2.4, -17.6), 30, 26)
	C(Vector3(-9, 6, 8), Vector3(0, 2, -14), Vector3(-6, 5, 0), Vector3(0, 2, -14), 44, 42)
	C(Vector3(4.5, 1.7, -6), Vector3(-2.5, 1.6, -9), Vector3(4.5, 1.7, -2), Vector3(-2.5, 1.6, -6), 36, 36)

# ======================================================= SPARTA
func _sparta(which: String) -> void:
	_sky("qwantani_dawn_puresky" if which != "sparta_home" else "qwantani_dusk_2_puresky", 1.0, 60)
	sun.rotation_degrees = Vector3(-34, 120, 0); sun.light_color = Color(1.0, 0.86, 0.66); sun.light_energy = 1.5
	_fog(Color(0.86, 0.82, 0.75), 0.0012, 0.5); env.tonemap_exposure = 0.92
	var n := _noise(501, 0.006, 6); var n2 := _noise(502, 0.05, 3)
	hfn = func(x: float, z: float) -> float:
		var d: float = Vector2(x, z + 10.0).length()
		var flat: float = clampf((d - 70.0) / 160.0, 0.0, 1.0)
		var taygetus: float = clampf((-z - 120.0) / 300.0, 0.0, 1.0)
		return n.get_noise_2d(x, z) * 16.0 * flat + flat * flat * 50.0 + taygetus * taygetus * 380.0 + n2.get_noise_2d(x, z) * 0.3
	world.add_child(Lib.terrain(1600.0, 240, hfn, _terrain_mat("dry_ground_01", "aerial_grass_rock", "rocky_terrain_02", "snow_02", 260.0, 16.0, 0.0, Color(1.0, 0.95, 0.82))))
	var walls := [Color(1.0, 0.96, 0.9), Color(0.96, 0.9, 0.82), Color(0.98, 0.94, 0.86), Color(0.9, 0.85, 0.75)]
	var hp := [[-9, -6, 6, 5, 3.2, 0.1], [9, -5, 5.5, 5, 3.0, -0.1], [-10, 8, 6, 4.5, 3.2, 0.05], [10, 9, 5, 5, 3.0, 0.0], [-20, -2, 6, 5, 3.4, 0.2], [20, 2, 6, 5, 3.2, -0.2], [-14, -24, 7, 5, 3.6, 0.0], [8, 20, 5, 4.5, 3.0, 0.1], [-22, 14, 5, 5, 3.0, 0.4], [22, -12, 6, 5, 3.4, -0.3], [-30, -12, 5, 4, 3.0, 0.6], [30, 14, 5, 4, 3.0, -0.6]]
	for h in hp:
		var p := Vector3(h[0], 0, h[1]); p.y = hfn.call(p.x, p.z)
		_house(p, h[2], h[3], h[4], h[5] + (PI if h[1] < 0 else 0.0), walls[rng.randi() % 4])
	for i in range(40):
		var a := rng.randf() * TAU; var r := rng.randf_range(30, 110)
		_olive(_ground(Vector3(cos(a) * r, 0, sin(a) * r)), rng.randf_range(3, 5))
	for i in range(30):
		var a := rng.randf() * TAU; var r := rng.randf_range(40, 140)
		_conifer(_ground(Vector3(cos(a) * r, 0, sin(a) * r - 40)), rng.randf_range(6, 10))
	for i in range(30):
		var p := Vector3(rng.randf_range(-25, 25), 0, rng.randf_range(-20, 22)); if absf(p.x) < 4 and absf(p.z) < 4: continue
		_place(["shrub_01", "grass_medium_01", "rock_07", "antique_ceramic_vase_01", "wicker_basket_01", "jug_01"][i % 6], _ground(p), rng.randf_range(0.7, 1.2), rng.randf() * TAU, 0.03)
	# small temple at the end of the square
	_temple(_ground(Vector3(-28, 0, -36)), 0.4, 6, 4, 2.6, 5.5, _tmat("clay_plaster", Color(0.95, 0.92, 0.86), 0.5))
	# townsfolk everywhere
	for i in range(16):
		var p := Vector3(rng.randf_range(-16, 16), 0, rng.randf_range(-12, 14))
		var nm: String = ["woman_a", "woman_b", "greek_man", "elder", "boy", "girl", "villager_man"][i % 7]
		var an: String = ["idle", "talk", "walk", "carry", "look"][i % 5]
		var v := Vector3.ZERO
		if an == "walk" or an == "carry": v = Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized() * 1.0
		spawn(nm, p, atan2(v.x, v.z) if v != Vector3.ZERO else rng.randf() * TAU, an, -999, 99999, v, {"lo": i > 8, "wrap": 14.0} if v != Vector3.ZERO else {"lo": i > 8})
	match which:
		"sparta_city":
			# 300 marching out between the houses (toward +z), townsfolk watching
			for r in range(16):
				for c in range(4):
					var p := Vector3((c - 1.5) * 1.1, 0, -40.0 + r * 1.4)
					_spartan(p, 0.0, "march", {"vel": Vector3(0, 0, 1.2), "lo": r > 3, "wrap": 70.0})
			spawn("leonidas", Vector3(0, 0, -36.0), 0.0, "walk", -999, 99999, Vector3(0, 0, 1.2), {"id": "leo", "crest": CREST, "wrap": 70.0, "spear": true, "shield": SHIELD_SP[0]})
			for i in range(14):
				var side := -1.0 if i % 2 == 0 else 1.0
				spawn(["woman_a", "gorgo", "elder", "boy", "girl", "woman_b", "greek_man"][i % 7], Vector3(side * rng.randf_range(4.0, 5.5), 0, -6.0 + i * 1.3), -side * PI * 0.5, ["look", "idle", "fold"][i % 3])
			C(Vector3(6, 2.2, 10), Vector3(0, 1.5, -2), Vector3(5, 2.4, 6), Vector3(0, 1.5, -6), 40, 38)
			C(Vector3(-2.5, 1.8, 6), Vector3(0, 1.6, 0), Vector3(-2.5, 1.8, 6), Vector3(0, 1.6, 0), 40, 36, {"track": "leo"})
			C(Vector3(30, 30, 50), Vector3(0, 0, 0), Vector3(20, 25, 40), Vector3(0, 0, -5), 44, 42)
			C(Vector3(-5.5, 1.6, 1.0), Vector3(-4.8, 1.6, 4.0), Vector3(-5.5, 1.6, 1.4), Vector3(0, 1.6, 4.0), 34, 34)
			C(Vector3(0, 6, 40), Vector3(0, 30, -200), Vector3(0, 5, 34), Vector3(0, 40, -200), 44, 44)
		"envoy_well":
			var w := _ground(Vector3(0, 0, 2))
			_cyl(1.2, 1.25, 0.9, w + Vector3(0, 0.45, 0), _tmat("stone_wall", Color(0.9, 0.85, 0.78), 1.0), null, 18); _obst(w, 1.25, 1.25)
			var hole := _cyl(1.0, 1.0, 0.02, w + Vector3(0, 0.91, 0), _m(Color(0.02, 0.02, 0.02)), null, 18)
			marks["well"] = w
			for i in range(3):
				var e := spawn(PERSIANS[i], Vector3(-1.2 + i * 1.2, 0, 3.8), PI, "talk" if i == 1 else "fold")
			for i in range(8):
				var a := 0.4 + i * 0.3
				_spartan(Vector3(cos(a) * 4.5, 0, -sin(a) * 4.5 + 3.0), atan2(-cos(a), sin(a)), "guard" if i % 2 else "fold", {"spear": null, "shield": null})
			spawn("leonidas", Vector3(1.6, 0, 1.0), -0.6, "point", -999, 99999, Vector3.ZERO, {"id": "leo", "crest": CREST})
			C(Vector3(5, 2.4, 9), Vector3(0, 1.0, 2.5), Vector3(4, 2.2, 8), Vector3(0, 1.0, 2.5), 40, 36)
			C(Vector3(0.2, 3.8, 2.1), Vector3(0, 0, 2.0), Vector3(0.1, 3.5, 2.05), Vector3(0, -2, 2.0), 50, 44)
			C(Vector3(-1.5, 1.7, 7.0), Vector3(0, 1.5, 3.8), Vector3(-1.2, 1.7, 6.4), Vector3(0, 1.5, 3.8), 34, 32)
			C(Vector3(3.5, 1.8, -1.0), Vector3(1.6, 1.65, 1.0), Vector3(3.2, 1.8, -0.6), Vector3(1.6, 1.65, 1.0), 32, 28)
		"sparta_council":
			# ephors / elders seated on stone benches in a half circle; Leonidas standing
			for i in range(7):
				var a := -1.0 + i * 0.33
				var p := Vector3(sin(a) * 6.0, 0, -cos(a) * 6.0 - 4.0)
				_box(Vector3(1.4, 0.45, 0.6), _ground(p) + Vector3(0, 0.22, 0), _tmat("stone_wall", Color(0.95, 0.9, 0.82), 1.0), a)
				spawn("elder" if i % 2 == 0 else "greek_man", p, a + PI, "sittalk" if i == 3 else "sit", -999, 99999, Vector3.ZERO, {"dy": 0.0})
			spawn("leonidas", Vector3(0, 0, -0.5), PI, "talk", -999, 99999, Vector3.ZERO, {"id": "leo", "crest": CREST})
			for i in range(10):
				_spartan(Vector3((i - 4.5) * 1.0, 0, 3.0 + (i % 2) * 1.0), PI, "guard")
			C(Vector3(0, 2.2, 6), Vector3(0, 1.4, -6), Vector3(0, 2.0, 4), Vector3(0, 1.4, -6), 40, 38)
			C(Vector3(1.2, 1.85, -2.6), Vector3(0, 1.75, -0.5), Vector3(1.0, 1.8, -2.4), Vector3(0, 1.75, -0.5), 30, 28)
			C(Vector3(-3.0, 1.8, 0.5), Vector3(0, 1.2, -9), Vector3(-2.0, 1.8, 0.0), Vector3(1, 1.2, -9), 40, 40)
			C(Vector3(8, 3.0, 2), Vector3(0, 1.2, -3), Vector3(7, 3.0, -2), Vector3(0, 1.2, -3), 40, 40)
		"sparta_home":
			var court := _ground(Vector3(-4, 0, 27))
			_box(Vector3(8, 2.4, 0.4), court + Vector3(0, 1.2, -4), _tmat("clay_plaster", walls[0], 0.5)); _obst(court + Vector3(0, 0, -4), 4.0, 0.2)
			_box(Vector3(0.4, 2.4, 8), court + Vector3(-4, 1.2, 0), _tmat("clay_plaster", walls[0], 0.5)); _obst(court + Vector3(-4, 0, 0), 0.2, 4.0)
			_olive(court + Vector3(2.5, 0, -2.5), 3.0)
			_fire(court + Vector3(-1.5, 0, -1.5), 0.5)
			spawn("leonidas", Vector3(-3.6, 0, 27.4), PI + 0.7, "talk", -999, 99999, Vector3.ZERO, {"id": "leo"})
			spawn("gorgo", Vector3(-4.6, 0, 26.4), 0.7, "idle", -999, 99999, Vector3.ZERO, {"id": "gorgo"})
			spawn("boy", Vector3(-6.0, 0, 28.5), 1.2, "look")
			C(Vector3(-0.5, 1.9, 29.5), Vector3(-4.1, 1.5, 26.9), Vector3(-1.0, 1.8, 29.0), Vector3(-4.1, 1.5, 26.9), 36, 32)
			C(Vector3(-2.4, 1.75, 28.2), Vector3(-4.6, 1.6, 26.4), Vector3(-2.6, 1.72, 28.0), Vector3(-4.6, 1.6, 26.4), 30, 27)
			C(Vector3(-6.0, 1.7, 25.0), Vector3(-3.6, 1.65, 27.4), Vector3(-5.8, 1.7, 25.2), Vector3(-3.6, 1.65, 27.4), 30, 27)
			C(Vector3(-9.0, 2.5, 32.0), Vector3(-4.0, 1.4, 27.0), Vector3(-7.0, 2.5, 33.0), Vector3(-4.0, 1.4, 27.0), 40, 38)

func _agoge() -> void:
	_sky("qwantani_mid_morning_puresky", 1.0, 120)
	sun.rotation_degrees = Vector3(-30, 140, 0); sun.light_color = Color(1.0, 0.86, 0.66); sun.light_energy = 1.5
	_fog(Color(0.86, 0.82, 0.75), 0.0013, 0.5)
	var n := _noise(601, 0.007, 6)
	hfn = func(x: float, z: float) -> float:
		var d: float = Vector2(x, z).length()
		var flat: float = clampf((d - 50.0) / 160.0, 0.0, 1.0)
		return n.get_noise_2d(x, z) * 14.0 * flat + flat * flat * 70.0
	world.add_child(Lib.terrain(1400.0, 220, hfn, _terrain_mat("dry_ground_01", "aerial_grass_rock", "rocky_terrain_02", "snow_02", 260.0, 14.0, 0.0, Color(1.0, 0.92, 0.78))))
	for i in range(35):
		var a := rng.randf() * TAU; var r := rng.randf_range(30, 120); _olive(_ground(Vector3(cos(a) * r, 0, sin(a) * r)), rng.randf_range(3, 5))
	# boys running laps, wrestling pairs, spear practice line, instructor
	for i in range(10):
		var p := Vector3(-14.0 + i * 1.6, 0, 8.0)
		spawn("boy", p, PI * 0.5, "run", -999, 99999, Vector3(2.4, 0, 0), {"wrap": 14.0, "speed": 1.0})
	for i in range(4):
		var c := Vector3(-6.0 + i * 4.0, 0, 0.0)
		spawn("boy", c + Vector3(0.45, 0, 0), -PI * 0.5, ["combo", "attack", "block", "hit"][i % 4])
		spawn("boy", c - Vector3(0.45, 0, 0), PI * 0.5, ["block", "hit", "combo", "attack"][i % 4])
	for i in range(6):
		spawn("boy", Vector3(-5.0 + i * 2.0, 0, -6.0), PI, "throw", -999, 99999, Vector3.ZERO, {"spear": true, "spear_len": 1.8})
	spawn("spartan_b", Vector3(0, 0, -3.5), 0.0, "fold", -999, 99999, Vector3.ZERO, {"id": "trainer"})
	spawn("spartan_d", Vector3(-9, 0, -2.0), 0.6, "talk", -999, 99999, Vector3.ZERO, {"crest": CREST})
	_place("wooden_crate_01", _ground(Vector3(7, 0, -5)), 1.0); _place("wooden_barrels_01", _ground(Vector3(8.5, 0, -4)), 1.0)
	C(Vector3(10, 3, 14), Vector3(0, 1, 2), Vector3(6, 2.6, 13), Vector3(-2, 1, 2), 40, 38)
	C(Vector3(-4.0, 1.2, 2.5), Vector3(-6.0, 1.0, 0.0), Vector3(-4.6, 1.1, 2.2), Vector3(-6.0, 1.0, 0.0), 34, 30)
	C(Vector3(0, 1.0, 12.5), Vector3(-6, 1.0, 8), Vector3(0, 1.0, 12.5), Vector3(6, 1.0, 8), 40, 40)
	C(Vector3(1.6, 1.9, -1.2), Vector3(0, 1.7, -3.5), Vector3(1.4, 1.9, -1.4), Vector3(0, 1.7, -3.5), 30, 28)
	C(Vector3(-2, 1.5, -9.5), Vector3(0, 2.5, 5), Vector3(2, 1.5, -9.5), Vector3(0, 2.5, 5), 38, 38)

func _delphi() -> void:
	_sky("kloofendal_misty_morning_puresky", 1.0, 200)
	sun.rotation_degrees = Vector3(-22, 120, 0); sun.light_color = Color(1.0, 0.85, 0.65); sun.light_energy = 1.4
	_fog(Color(0.8, 0.82, 0.85), 0.0009, 0.5); _grade(Vector3(0.98, 0.97, 0.95), 0.04)
	var n := _noise(701, 0.01, 6)
	hfn = func(x: float, z: float) -> float:
		var up: float = maxf(0.0, -z - 8.0)
		var down: float = maxf(0.0, z - 12.0)
		return up * 1.4 + n.get_noise_2d(x, z) * minf(up, 20.0) * 1.2 - down * 0.8 + n.get_noise_2d(x * 0.5, z) * 2.0
	world.add_child(Lib.terrain(1400.0, 240, hfn, _terrain_mat("rocks_ground_05", "aerial_grass_rock", "cliff_side", "aerial_rocks_02", 300.0, 6.0)))
	_temple(_ground(Vector3(0, 0, 0)), 0.0, 6, 9, 2.6, 7.0, _tmat("clay_plaster", Color(0.97, 0.95, 0.9), 0.5))
	for i in range(18):
		var p := Vector3(rng.randf_range(-40, 40), 0, rng.randf_range(-30, -10)); _conifer(_ground(p), rng.randf_range(6, 12), Color(0.2, 0.3, 0.2))
	var t := _ground(Vector3(0, 0, 13.5))
	_cyl(0.35, 0.45, 0.9, t + Vector3(0, 0.45, 0), _m(Color(0.6, 0.45, 0.25), 0.8, 0.35))   # tripod/brazier
	_smoke(t + Vector3(0, 1.2, 0), 0.08, 30, Color(0.85, 0.85, 0.85, 0.18))
	_fire(t + Vector3(0, 0.9, 0), 0.4, false)
	spawn("priestess", Vector3(0, 0, 12.5), PI, "sittalk", -999, 99999, Vector3.ZERO, {"id": "pythia", "dy": 0.0})
	_box(Vector3(0.6, 0.5, 0.6), t + Vector3(0, 0.25, -1.0), _m(Color(0.9, 0.88, 0.82)))
	for i in range(3):
		_spartan(Vector3(-1.2 + i * 1.2, 0, 16.0), PI, "fold", {"spear": null, "shield": null})
	C(Vector3(18, 6, 40), Vector3(0, 5, 0), Vector3(12, 5, 32), Vector3(0, 5, 0), 40, 38)
	C(Vector3(1.5, 1.4, 10.6), Vector3(0, 1.1, 12.5), Vector3(1.2, 1.35, 10.9), Vector3(0, 1.1, 12.5), 32, 28)
	C(Vector3(0, 1.6, 20), Vector3(0, 1.4, 12.5), Vector3(0, 1.6, 18.5), Vector3(0, 1.4, 12.5), 38, 34)
	C(Vector3(-30, 30, 60), Vector3(0, 4, 0), Vector3(-20, 22, 50), Vector3(0, 4, 0), 44, 42)

func _greek_march() -> void:
	_sky("rocky_ridge_puresky", 1.0, 0)
	sun.rotation_degrees = Vector3(-35, 150, 0); sun.light_color = Color(1.0, 0.9, 0.75); sun.light_energy = 1.5
	_fog(Color(0.85, 0.85, 0.85), 0.0014, 0.55)
	var n := _noise(801, 0.008, 6)
	hfn = func(x: float, z: float) -> float:
		var v: float = clampf((absf(z - n.get_noise_1d(x) * 30.0) - 8.0) / 160.0, 0.0, 1.0)
		return n.get_noise_2d(x, z) * 2.0 + v * v * 160.0 + n.get_noise_2d(x * 3.0, z * 3.0) * 25.0 * v
	world.add_child(Lib.terrain(1600.0, 260, hfn, _terrain_mat("dry_ground_01", "aerial_grass_rock", "rocky_terrain_02", "aerial_rocks_02", 200.0, 16.0, 0.0, Color(1.0, 0.92, 0.8))))
	for i in range(50):
		var p := Vector3(rng.randf_range(-150, 150), 0, rng.randf_range(-80, 80)); if absf(p.z) < 10: continue
		if rng.randf() < 0.5: _olive(_ground(p), rng.randf_range(3, 5))
		else: _conifer(_ground(p), rng.randf_range(6, 10))
	for r in range(26):
		for c in range(4):
			var p := Vector3(30.0 - r * 1.4, 0, (c - 1.5) * 1.05)
			var sp := r < 12
			if sp: _spartan(p, -PI * 0.5 + PI, "march", {"vel": Vector3(1.25, 0, 0), "lo": r > 3, "wrap": 80.0})
			else: spawn(_pick(GREEKS), p, PI * 0.5, "march", -999, 99999, Vector3(1.25, 0, 0), {"spear": true, "shield": SHIELD_GR[rng.randi() % 4], "lo": true, "wrap": 80.0})
	spawn("leonidas", Vector3(32.5, 0, 0), PI * 0.5, "walk", -999, 99999, Vector3(1.25, 0, 0), {"id": "leo", "crest": CREST, "wrap": 80.0, "spear": true, "shield": SHIELD_SP[0]})
	_dust(100)
	C(Vector3(4, 3.0, -2.5), Vector3(0, 1.8, 0), Vector3(4, 3.0, -2.5), Vector3(0, 1.8, 0), 36, 34, {"track": "leo"})
	C(Vector3(80, 10, 18), Vector3(30, 1, 0), Vector3(70, 9, 16), Vector3(20, 1, 0), 40, 38)
	C(Vector3(-50, 70, -100), Vector3(30, 0, 0), Vector3(-30, 60, -90), Vector3(40, 0, 0), 46, 46)
	C(Vector3(-2.0, 1.6, 2.6), Vector3(1.5, 1.6, 0), Vector3(-2.0, 1.6, 2.6), Vector3(1.5, 1.6, 0), 34, 32, {"track": "leo"})
	C(Vector3(30, 1.2, 4), Vector3(0, 2, 0), Vector3(30, 1.3, -4), Vector3(0, 2, 0), 40, 40)

func _goat_path() -> void:
	_night_sky(Color(0.01, 0.015, 0.05), Color(0.05, 0.07, 0.14), 1.0)
	_fog(Color(0.06, 0.08, 0.14), 0.012, 0.4, 0.0); env.ambient_light_energy = 0.3; _grade(Vector3(0.92, 0.95, 1.05), 0.02, 1.0)
	var n := _noise(901, 0.03, 5)
	hfn = func(x: float, z: float) -> float:
		return x * 0.25 + n.get_noise_2d(x, z) * 2.5 + absf(z) * 0.3
	world.add_child(Lib.terrain(500.0, 200, hfn, _terrain_mat("forrest_ground_01", "rocks_ground_05", "cliff_side", "aerial_rocks_02", 300.0, 400.0)))
	for i in range(160):
		var p := Vector3(rng.randf_range(-90, 90), 0, rng.randf_range(-40, 40)); if absf(p.z) < 2.5: continue
		if rng.randf() < 0.7: _conifer(_ground(p), rng.randf_range(7, 13), Color(0.12, 0.18, 0.12))
		else: _olive(_ground(p), rng.randf_range(3, 4))
	for i in range(30):
		var p := Vector3(rng.randf_range(-60, 60), 0, rng.randf_range(-12, 12)); if absf(p.z) < 2.2: continue
		_place(["rock_07", "rock_09", "boulder_01", "dry_branches_medium_01"][i % 4], _ground(p), rng.randf_range(0.6, 1.4), rng.randf() * TAU, 0.2)
	# immortals single file with torches climbing +x, Ephialtes leading
	spawn("ephialtes", Vector3(-6, 0, 0.2), PI * 0.5, "walk", -999, 99999, Vector3(1.0, 0, 0), {"id": "eph", "wrap": 60.0, "torch": true})
	for i in range(30):
		var p := Vector3(-8.0 - i * 1.7, 0, rng.randf_range(-0.6, 0.6))
		_persian(p, PI * 0.5, "walk", {"immortal": true, "vel": Vector3(1.0, 0, 0), "wrap": 60.0, "torch": i % 3 == 0, "wicker": i % 3 != 0, "lo": i > 6})
	# phocian sentries on a knoll (they see / hear)
	for i in range(4):
		spawn(_pick(GREEKS), Vector3(30.0 + i * 1.3, 0, 8.0), -2.4, "torch" if i == 0 else "guard", -999, 99999, Vector3.ZERO, {"torch": i == 0, "spear": i != 0, "shield": SHIELD_GR[i % 4]})
	_fire(_ground(Vector3(31, 0, 10)), 0.6)
	C(Vector3(-2, 1.8, 3.2), Vector3(-6, 1.6, 0), Vector3(-2, 1.8, 3.2), Vector3(-6, 1.6, 0), 40, 38, {"track": "eph"})
	C(Vector3(-20, 9, 18), Vector3(-20, 0, 0), Vector3(-10, 8, 16), Vector3(-10, 0, 0), 42, 40)
	C(Vector3(32, 1.9, 11.5), Vector3(20, 3, 0), Vector3(32.5, 1.9, 11.0), Vector3(15, 4, 0), 36, 32)
	C(Vector3(-14, 0.8, -1.5), Vector3(-30, 3, 0), Vector3(-13, 0.8, -1.2), Vector3(-30, 6, 0), 44, 46)
	C(Vector3(0.6, 1.0, 1.6), Vector3(-3, 1.4, 0), Vector3(0.6, 1.0, 1.6), Vector3(-3, 1.4, 0), 34, 34, {"track": "eph"})

func _athens() -> void:
	_sky("belfast_sunset_puresky", 0.9, 300)
	sun.rotation_degrees = Vector3(-15, 250, 0); sun.light_color = Color(1.0, 0.55, 0.3); sun.light_energy = 1.0
	_fog(Color(0.45, 0.3, 0.22), 0.004, 0.5); env.tonemap_exposure = 0.9; _grade(Vector3(1.05, 0.88, 0.75), 0.1, 1.0)
	var n := _noise(1001, 0.008, 5)
	hfn = func(x: float, z: float) -> float:
		var hill: float = maxf(0.0, 22.0 - Vector2(x, z + 30.0).length() * 0.45)
		return n.get_noise_2d(x, z) * 3.0 + minf(hill, 16.0)
	world.add_child(Lib.terrain(1400.0, 240, hfn, _terrain_mat("dry_ground_01", "rocky_terrain_02", "cliff_side", "aerial_rocks_02", 300.0, 9.0, 0.0, Color(0.9, 0.8, 0.7))))
	_temple(_ground(Vector3(0, 0, -30)), 0.2, 8, 11, 2.4, 7.0, _tmat("clay_plaster", Color(0.95, 0.9, 0.82), 0.5), true)
	var walls := [Color(1.0, 0.95, 0.88), Color(0.95, 0.88, 0.8)]
	for i in range(40):
		var a := rng.randf() * TAU; var r := rng.randf_range(28, 70)
		var p := _ground(Vector3(cos(a) * r, 0, sin(a) * r - 30.0))
		_house(p, rng.randf_range(4, 6), rng.randf_range(4, 5), rng.randf_range(2.8, 3.4), rng.randf() * TAU, walls[i % 2])
		if i % 2 == 0:
			for k in range(3):
				_fire(p + Vector3(rng.randf_range(-1.5, 1.5), 2.6 + k * 0.6, rng.randf_range(-1.2, 1.2)), 3.0, false)
			_smoke(p + Vector3(0, 6, 0), 1.2, 40, Color(0.12, 0.1, 0.09, 0.6))
	_smoke(_ground(Vector3(0, 0, -30)) + Vector3(0, 10, 0), 2.0, 70, Color(0.1, 0.09, 0.08, 0.6))
	for i in range(12):
		var p := Vector3(rng.randf_range(-20, 20), 0, rng.randf_range(10, 30))
		_persian(p, PI + rng.randf_range(-0.6, 0.6), ["torch", "look", "walk"][i % 3], {"torch": i % 3 == 0, "vel": Vector3(0, 0, -0.8) if i % 3 == 2 else Vector3.ZERO})
	C(Vector3(40, 18, 60), Vector3(0, 10, -30), Vector3(30, 14, 50), Vector3(0, 10, -30), 42, 40)
	C(Vector3(-8, 2.0, 28), Vector3(0, 6, -10), Vector3(-6, 2.0, 24), Vector3(0, 8, -20), 44, 44)
	C(Vector3(10, 30, -80), Vector3(0, 10, -30), Vector3(-10, 28, -80), Vector3(0, 10, -30), 44, 44)
	C(Vector3(4, 1.8, 20), Vector3(0, 2, 30), Vector3(4, 1.8, 18), Vector3(-6, 2, 30), 38, 38)

func _salamis() -> void:
	_sky("kloofendal_48d_partly_cloudy_puresky", 1.0, 70)
	sun.rotation_degrees = Vector3(-35, 135, 0); sun.light_color = Color(1.0, 0.9, 0.78); sun.light_energy = 1.5
	_fog(Color(0.8, 0.85, 0.9), 0.0011, 0.6)
	var n := _noise(1101, 0.004, 6)
	hfn = func(x: float, z: float) -> float:
		var isl: float = maxf(-1.0, (absf(z) - 220.0) * 0.25)
		return -8.0 + isl * 1.0 + n.get_noise_2d(x, z) * 30.0 * clampf(isl / 30.0, 0.0, 1.0)
	world.add_child(Lib.terrain(3000.0, 220, hfn, _terrain_mat("coast_sand_rocks_02", "aerial_grass_rock", "rocky_terrain_02", "aerial_rocks_02", 300.0, 8.0)))
	_water(0.0, 8000.0)
	for i in range(26):
		_ship(Vector3(rng.randf_range(-140, 60), 0.0, rng.randf_range(-120, 100)), PI * 0.5 + rng.randf_range(-0.4, 0.4), 1.0, Color(0.85, 0.82, 0.75))
	for i in range(30):
		var s := _ship(Vector3(rng.randf_range(40, 220), 0.0, rng.randf_range(-120, 120)), -PI * 0.5 + rng.randf_range(-0.6, 0.6), 1.05, Color(0.6, 0.3, 0.25) if i % 2 else Color(0.35, 0.3, 0.45))
		if i % 4 == 0: _fire(s.position + Vector3(0, 2, 0), 1.8, false); _smoke(s.position + Vector3(0, 4, 0), 1.0, 30, Color(0.15, 0.13, 0.12, 0.55))
	# Xerxes watches from a hillside throne
	var hp := Vector3(60, 0, 240); hp.y = hfn.call(hp.x, hp.z)
	_box(Vector3(2.0, 0.5, 2.0), hp + Vector3(0, 0.25, 0), _m(Color(0.85, 0.65, 0.25), 0.8, 0.35))
	spawn("xerxes", hp + Vector3(0, 0, 0), PI, "sit", -999, 99999, Vector3.ZERO, {"dy": 0.95, "id": "xerxes", "speed": 0.5})
	C(Vector3(-30, 6, 40), Vector3(80, 2, 0), Vector3(-10, 5, 30), Vector3(100, 2, 0), 40, 38)
	C(Vector3(40, 60, -160), Vector3(40, 0, 0), Vector3(60, 50, -140), Vector3(40, 0, 0), 46, 46)
	C(Vector3(hp.x + 2.0, hp.y + 2.2, hp.z - 2.5), Vector3(hp.x, hp.y + 1.8, hp.z), Vector3(hp.x + 1.8, hp.y + 2.1, hp.z - 2.2), Vector3(hp.x, hp.y + 1.8, hp.z), 30, 26)
	C(Vector3(hp.x - 2, hp.y + 3, hp.z + 3), Vector3(60, 0, 0), Vector3(hp.x - 2, hp.y + 3, hp.z + 3), Vector3(100, 0, -20), 40, 36)

func _plataea() -> void:
	_sky("qwantani_sunrise_puresky", 1.0, 40)
	sun.rotation_degrees = Vector3(-25, 70, 0); sun.light_color = Color(1.0, 0.82, 0.62); sun.light_energy = 1.5
	_fog(Color(0.85, 0.78, 0.68), 0.0007, 0.5)
	var n := _noise(1201, 0.006, 5)
	hfn = func(x: float, z: float) -> float:
		var edge: float = clampf((Vector2(x, z).length() - 150.0) / 300.0, 0.0, 1.0)
		return n.get_noise_2d(x, z) * 4.0 + edge * edge * 140.0
	world.add_child(Lib.terrain(1600.0, 240, hfn, _terrain_mat("dry_ground_01", "aerial_grass_rock", "rocky_terrain_02", "aerial_rocks_02", 150.0, 30.0, 0.0, Color(1.0, 0.95, 0.75))))
	for r in range(5):
		for c in range(14):
			var p := Vector3(-30.0 - r * 1.1, 0, (c - 6.5) * 0.98)
			var a := _spartan(p, PI * 0.5, "march", {"vel": Vector3(1.4, 0, 0), "lo": r > 1})
			ev(a, 14.0 + rng.randf_range(0, 0.6), "attack" if r == 0 else "guard", true, Vector3.ZERO)
	var ar := spawn("spartan_c", Vector3(-28.5, 0, 2.0), PI * 0.5, "sprint", -999, 99999, Vector3(3.6, 0, 0), {"id": "aristo", "sword": true, "shield": SHIELD_SP[0], "crest": CREST})
	ev(ar, 9.0, "combo", true, Vector3.ZERO); ev(ar, 15.0, "death", false)
	for i in range(80):
		var p := Vector3(rng.randf_range(4, 30), 0, rng.randf_range(-10, 10))
		var pa := _persian(p, -PI * 0.5, ["guard", "attack", "block", "run"][i % 4], {"lo": i > 20})
		if rng.randf() < 0.3: ev(pa, rng.randf_range(10, 40), "death", false)
	_far_army(Vector3(40, 0, 0), 120, 90, 1200)
	_dust(60)
	C(Vector3(-30, 3, 14), Vector3(-18, 1.5, 0), Vector3(-22, 3, 14), Vector3(-8, 1.5, 0), 40, 38)
	C(Vector3(-34, 1.9, 5.0), Vector3(-28, 1.6, 0.0), Vector3(-30, 1.9, 5.5), Vector3(-22, 1.6, 0.0), 36, 34)
	C(Vector3(-18, 2.2, 6.0), Vector3(-26, 1.4, 1.0), Vector3(-15, 2.2, 6.0), Vector3(-20, 1.4, 1.0), 38, 36)
	C(Vector3(-20, 50, 80), Vector3(0, 0, 0), Vector3(0, 40, 70), Vector3(0, 0, 0), 46, 44)
	C(Vector3(10, 2.0, 12), Vector3(-15, 1.5, 0), Vector3(6, 2.0, 12), Vector3(-10, 1.5, 0), 38, 36)
