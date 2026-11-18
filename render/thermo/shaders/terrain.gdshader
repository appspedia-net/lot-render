shader_type spatial;
uniform sampler2D tex_low : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_mid : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_rock : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_snow : source_color, filter_linear_mipmap, repeat_enable;
uniform float scale = 0.12;
uniform float snow_h = 30.0;
uniform float mid_h = 8.0;
uniform float snow_amount = 0.0;
uniform vec3 low_tint = vec3(1.0);
varying vec3 wpos; varying vec3 wnor;
void vertex(){ wpos = (MODEL_MATRIX*vec4(VERTEX,1.0)).xyz; wnor = normalize((MODEL_MATRIX*vec4(NORMAL,0.0)).xyz); }
vec3 tri(sampler2D t, vec3 p, vec3 n){
	vec3 b = pow(abs(n), vec3(4.0)); b /= (b.x+b.y+b.z);
	return texture(t, p.zy*scale).rgb*b.x + texture(t, p.xz*scale).rgb*b.y + texture(t, p.xy*scale).rgb*b.z;
}
void fragment(){
	float slope = 1.0 - clamp(wnor.y, 0.0, 1.0);
	vec3 low = tri(tex_low, wpos, wnor)*low_tint;
	vec3 mid = tri(tex_mid, wpos*0.7, wnor);
	vec3 rock = tri(tex_rock, wpos*0.5, wnor);
	vec3 snow = tri(tex_snow, wpos*0.4, wnor);
	float nz = texture(tex_mid, wpos.xz*0.013).r;
	float tm = smoothstep(mid_h-3.0, mid_h+3.0, wpos.y + nz*6.0);
	vec3 c = mix(low, mid, tm);
	c = mix(c, rock, smoothstep(0.35, 0.6, slope));
	float ts = max(smoothstep(snow_h-4.0, snow_h+4.0, wpos.y + nz*8.0), snow_amount) * (1.0 - smoothstep(0.55, 0.8, slope));
	c = mix(c, snow, ts);
	ALBEDO = c;
	ROUGHNESS = mix(0.95, 0.6, ts);
}
