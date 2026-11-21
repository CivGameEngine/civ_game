// UV и PBR импортированных материалов, включая упакованный roughness glTF.
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D roughness_texture : filter_linear_mipmap, repeat_enable;
uniform bool has_texture = false;
uniform bool has_normal = false;
uniform bool has_roughness = false;
uniform vec4 base_color : source_color = vec4(1.0);
uniform float material_roughness = 0.9;
uniform float normal_scale = 1.0;
uniform int roughness_channel = 0;

vec3 landscape_albedo(vec2 uv) {
	return base_color.rgb * (has_texture ? texture(albedo_texture, uv).rgb : vec3(1.0));
}

float landscape_roughness(vec2 uv) {
	if (!has_roughness) { return material_roughness; }
	vec4 channels = texture(roughness_texture, uv);
	float value = channels.r;
	if (roughness_channel == 1) { value = channels.g; }
	else if (roughness_channel == 2) { value = channels.b; }
	else if (roughness_channel == 3) { value = channels.a; }
	else if (roughness_channel == 4) { value = dot(channels.rgb, vec3(0.333333)); }
	return material_roughness * value;
}
