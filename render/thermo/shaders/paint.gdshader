shader_type canvas_item;
// painterly post: kuwahara-ish smoothing + warm grade + vignette + soft edge darkening
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform int radius = 2;
uniform float warmth = 0.06;
uniform float saturation = 1.12;
uniform float contrast = 1.06;
uniform float vignette = 0.35;
uniform float edge = 0.6;
uniform vec3 tint = vec3(1.0, 0.97, 0.9);
uniform float grain = 0.025;
uniform float time_s = 0.0;
float hash(vec2 p){ return fract(sin(dot(p, vec2(12.9898,78.233))) * 43758.5453); }
void fragment() {
	vec2 px = SCREEN_PIXEL_SIZE;
	vec2 uv = SCREEN_UV;
	vec3 m[4]; vec3 s[4];
	for (int k=0;k<4;k++){ m[k]=vec3(0.0); s[k]=vec3(0.0); }
	float n = float((radius+1)*(radius+1));
	for (int j=-radius;j<=0;j++) for (int i=-radius;i<=0;i++){
		vec3 c;
		c = texture(screen_tex, uv+vec2(float(i),float(j))*px).rgb; m[0]+=c; s[0]+=c*c;
		c = texture(screen_tex, uv+vec2(float(i+radius),float(j))*px).rgb; m[1]+=c; s[1]+=c*c;
		c = texture(screen_tex, uv+vec2(float(i),float(j+radius))*px).rgb; m[2]+=c; s[2]+=c*c;
		c = texture(screen_tex, uv+vec2(float(i+radius),float(j+radius))*px).rgb; m[3]+=c; s[3]+=c*c;
	}
	float best = 1e9; vec3 col = vec3(0.0);
	for (int k=0;k<4;k++){
		vec3 mu = m[k]/n; vec3 v = abs(s[k]/n - mu*mu);
		float sv = v.r+v.g+v.b;
		if (sv < best){ best = sv; col = mu; }
	}
	// edge darkening (ink-like) from luminance gradient
	float l = dot(texture(screen_tex, uv).rgb, vec3(0.3,0.59,0.11));
	float lx = dot(texture(screen_tex, uv+vec2(px.x*1.5,0)).rgb, vec3(0.3,0.59,0.11)) - l;
	float ly = dot(texture(screen_tex, uv+vec2(0,px.y*1.5)).rgb, vec3(0.3,0.59,0.11)) - l;
	float e = clamp(length(vec2(lx,ly))*6.0, 0.0, 1.0);
	col *= 1.0 - e*edge*0.35;
	// grade
	float g = dot(col, vec3(0.3,0.59,0.11));
	col = mix(vec3(g), col, saturation);
	col = (col-0.5)*contrast+0.5;
	col *= tint; col.r += warmth; col.b -= warmth*0.6;
	vec2 d = uv-0.5; col *= 1.0 - vignette*dot(d,d)*2.2;
	col += (hash(uv*1000.0+time_s)-0.5)*grain;
	COLOR = vec4(clamp(col,0.0,1.0),1.0);
}
