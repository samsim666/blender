
uniform sampler2D gpFillTexture;
uniform sampler2D gpStrokeTexture;
uniform sampler2D gpSceneDepthTexture;
uniform vec3 gpNormal;

in vec4 finalColorMul;
in vec4 finalColorAdd;
in vec3 finalPos;
in vec2 finalUvs;
noperspective in float strokeThickness;
flat in vec2 strokePt1;
flat in vec2 strokePt2;
flat in int matFlag;
flat in float depth;

layout(location = 0) out vec4 fragColor;
layout(location = 1) out vec4 revealColor;

float length_squared(vec2 v)
{
  return dot(v, v);
}
float length_squared(vec3 v)
{
  return dot(v, v);
}

vec3 gpencil_lighting(void)
{
  vec3 light_accum = vec3(0.0);
  for (int i = 0; i < GPENCIL_LIGHT_BUFFER_LEN; i++) {
    if (lights[i].color_type.x == -1.0) {
      break;
    }
    vec3 L = lights[i].position.xyz - finalPos;
    float vis = 1.0;
    /* Spot Attenuation. */
    if (lights[i].color_type.w == GP_LIGHT_TYPE_SPOT) {
      mat3 rot_scale = mat3(lights[i].right.xyz, lights[i].up.xyz, lights[i].forward.xyz);
      vec3 local_L = rot_scale * L;
      local_L /= abs(local_L.z);
      float ellipse = inversesqrt(length_squared(local_L));
      vis *= smoothstep(0.0, 1.0, (ellipse - lights[i].spot_size) / lights[i].spot_blend);
      /* Also mask +Z cone. */
      vis *= step(0.0, local_L.z);
    }
    /* Inverse square decay. Skip for suns. */
    float L_len_sqr = length_squared(L);
    if (lights[i].color_type.w < GP_LIGHT_TYPE_SUN) {
      vis /= L_len_sqr;
    }
    else {
      L = lights[i].forward.xyz;
      L_len_sqr = 1.0;
    }
    /* Lambertian falloff */
    if (lights[i].color_type.w != GP_LIGHT_TYPE_AMBIENT) {
      L /= sqrt(L_len_sqr);
      vis *= clamp(dot(gpNormal, L), 0.0, 1.0);
    }
    light_accum += vis * lights[i].color_type.rgb;
  }
  /* Clamp to avoid NaNs. */
  return clamp(light_accum, 0.0, 1e10);
}

float stroke_round_cap_mask()
{
  /* We create our own uv space to avoid issues with triangulation and linear
   * interpolation artifacts. */
  vec2 line = strokePt2.xy - strokePt1.xy;
  vec2 pos = gl_FragCoord.xy - strokePt1.xy;
  float line_len = sqrt(length_squared(line));
  float half_line_len = line_len * 0.5;
  /* Normalize */
  line = (line_len > 0.0) ? (line / line_len) : vec2(1.0, 0.0);
  /* Create a uv space that englobe the whole segment into a capsule. */
  vec2 uv_end;
  uv_end.x = max(abs(dot(line, pos) - half_line_len) - half_line_len, 0.0);
  uv_end.y = dot(vec2(-line.y, line.x), pos);
  /* Divide by stroke radius. */
  uv_end /= strokeThickness;

  return (length_squared(uv_end) > 0.25) ? 0.0 : 1.0;
}

void main()
{
  vec4 col;
  if (GP_FLAG_TEST(matFlag, GP_STROKE_TEXTURE_USE)) {
    bool premul = GP_FLAG_TEST(matFlag, GP_STROKE_TEXTURE_PREMUL);
    col = texture_read_as_linearrgb(gpStrokeTexture, premul, finalUvs);
  }
  else if (GP_FLAG_TEST(matFlag, GP_FILL_TEXTURE_USE)) {
    bool use_clip = GP_FLAG_TEST(matFlag, GP_FILL_TEXTURE_CLIP);
    vec2 uvs = (use_clip) ? clamp(finalUvs, 0.0, 1.0) : finalUvs;
    bool premul = GP_FLAG_TEST(matFlag, GP_FILL_TEXTURE_PREMUL);
    col = texture_read_as_linearrgb(gpFillTexture, premul, uvs);
  }
  else /* SOLID */ {
    col = vec4(1.0);
  }
  col.rgb *= col.a;

  /* Composite all other colors on top of texture color.
   * Everything is premult by col.a to have the stencil effect. */
  fragColor = col * finalColorMul + col.a * finalColorAdd;

  fragColor.rgb *= gpencil_lighting();

  fragColor *= stroke_round_cap_mask();

  if (GP_FLAG_TEST(matFlag, GP_STROKE_DOTS)) {
    const float rad_sqr_inv = 1.0 / 0.25;
    float dist = 1.0 - rad_sqr_inv * length_squared(finalUvs - 0.5);
    fragColor *= clamp(dist, 0.0, 1.0);
  }

  /* For compatibility with colored alpha buffer.
   * Note that we are limited to mono-chromatic alpha blending here
   * because of the blend equation and the limit of 1 color target
   * when using custom color blending. */
  revealColor = vec4(0.0, 0.0, 0.0, fragColor.a);

  if (fragColor.a < 0.001) {
    discard;
  }

  /* Manual depth test */
  vec2 uvs = gl_FragCoord.xy / vec2(textureSize(gpSceneDepthTexture, 0).xy);
  float scene_depth = texture(gpSceneDepthTexture, uvs).r;
  if (gl_FragCoord.z > scene_depth) {
    discard;
  }

  /* We override the fragment depth using the fragment shader to ensure a constant value.
   * This has a cost as the depth test cannot happen early.
   * We could do this in the vertex shader but then perspective interpolation of uvs and
   * fragment clipping gets really complicated. */
  if (depth >= 0.0) {
    gl_FragDepth = depth;
  }
  else {
    gl_FragDepth = gl_FragCoord.z;
  }
}