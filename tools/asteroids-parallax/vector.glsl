#version 120

#ifdef VERTEX
attribute vec4 VertexCoord;
attribute vec2 TexCoord;
uniform mat4 MVPMatrix;
varying vec2 tex;

void main()
{
    gl_Position = MVPMatrix * VertexCoord;
    tex = TexCoord;
}
#endif

#ifdef FRAGMENT
uniform sampler2D Texture;
uniform vec2 TextureSize;
varying vec2 tex;

float light_at(vec2 point)
{
    return dot(texture2D(Texture, point).rgb, vec3(0.299, 0.587, 0.114));
}

void main()
{
    vec2 step_size = 1.0 / TextureSize;
    float glow = light_at(tex + vec2(step_size.x, 0.0))
               + light_at(tex - vec2(step_size.x, 0.0))
               + light_at(tex + vec2(0.0, step_size.y))
               + light_at(tex - vec2(0.0, step_size.y));
    float light = min(1.0, light_at(tex) + 0.16 * glow);
    gl_FragColor = vec4(light * vec3(0.15, 0.95, 1.0), 1.0);
}
#endif
