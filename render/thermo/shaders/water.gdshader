shader_type spatial;
render_mode cull_disabled;
uniform vec3 deep = vec3(0.05, 0.18, 0.26);
uniform vec3 shallow = vec3(0.14, 0.38, 0.42);
uniform vec3 sky_col = vec3(0.75, 0.82, 0.9);
uniform float t = 0.0;
uniform float wave = 1.0;
varying vec3 wp;
float h(vec2 p){ return sin(p.x*0.21+t*0.9)*0.5+sin(p.y*0.17+t*0.7+p.x*0.05)*0.5+sin((p.x+p.y)*0.53+t*1.7)*0.18+sin((p.x-p.y)*1.1+t*2.3)*0.07; }
void vertex(){ wp = (MODEL_MATRIX*vec4(VERTEX,1.0)).xyz; }
void fragment(){
	vec2 p = wp.xz; float e = 0.25; float fade = clamp(1.0 - length(CAMERA_POSITION_WORLD.xz - p) / 400.0, 0.15, 1.0);
	vec3 n = normalize(vec3(-(h(p+vec2(e,0))-h(p-vec2(e,0)))*wave*0.22*fade, 1.0, -(h(p+vec2(0,e))-h(p-vec2(0,e)))*wave*0.22*fade));
	NORMAL = (VIEW_MATRIX*vec4(n,0.0)).xyz;
	float fr = pow(1.0 - clamp(dot(normalize(CAMERA_POSITION_WORLD - wp), n), 0.0, 1.0), 3.0);
	ALBEDO = mix(deep, sky_col*0.35, fr*0.35);
	ROUGHNESS = 0.18; METALLIC = 0.0; SPECULAR = 0.25;
}
