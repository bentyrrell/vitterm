#include <metal_stdlib>
using namespace metal;

// Keep in sync with Uniforms in Renderer.swift.
struct Uniforms {
    float2 viewport;   // drawable size in pixels
    float2 cellSize;   // cell size in pixels
    float  textGamma;  // coverage exponent (<1 thickens)
    float  pad0, pad1, pad2;
};

// Rect kinds.
// RECT_SOLID = 0 is the default kind.
constant uint RECT_CURLY   = 1;
constant uint RECT_DOTTED  = 2;
constant uint RECT_DASHED  = 3;
constant uint RECT_HOLLOW  = 4;

struct RectInstance {
    float2 origin;
    float2 size;
    uchar4 color;      // straight alpha RGBA
    uint   kind;
    float  thickness;
    float  pad;
};

struct GlyphInstance {
    float2 origin;
    float2 size;
    float2 uv;         // atlas pixel origin
    uchar4 color;      // straight alpha RGBA
    uint   flags;      // bit 0: color glyph
};

struct ImageInstance {
    float2 origin;
    float2 size;
    float4 uv;         // normalized (u0, v0, u1, v1)
    float  alpha;
    float  pad0, pad1, pad2;
};

struct RectOut {
    float4 position [[position]];
    float2 local;
    float2 size;
    float4 color;
    uint   kind [[flat]];
    float  thickness;
};

struct GlyphOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    uint   flags [[flat]];
};

struct ImageOut {
    float4 position [[position]];
    float2 uv;
    float  alpha;
};

static float4 toNDC(float2 px, float2 viewport) {
    return float4(px.x / viewport.x * 2.0 - 1.0, 1.0 - px.y / viewport.y * 2.0, 0.0, 1.0);
}

constant float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };

vertex RectOut rect_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device RectInstance *rects [[buffer(0)]],
                           constant Uniforms &u [[buffer(1)]]) {
    RectInstance r = rects[iid];
    float2 c = corners[vid];
    RectOut o;
    o.position = toNDC(r.origin + c * r.size, u.viewport);
    o.local = c * r.size;
    o.size = r.size;
    o.color = float4(r.color) / 255.0;
    o.kind = r.kind;
    o.thickness = r.thickness;
    return o;
}

fragment float4 rect_fragment(RectOut in [[stage_in]]) {
    float a = 1.0;
    float t = max(in.thickness, 1.0);
    if (in.kind == RECT_CURLY) {
        // Sine wave through the rect, one period per ~cell width.
        float amp = max((in.size.y - t) * 0.5, 0.5);
        float period = max(in.size.y * 2.6, 6.0);
        float phase = in.local.x / period * 2.0 * M_PI_F;
        float y = in.size.y * 0.5 - amp * sin(phase);
        // Distance to the curve, corrected for slope.
        float slope = amp * 2.0 * M_PI_F / period * cos(phase);
        float d = abs(in.local.y - y) / sqrt(1.0 + slope * slope);
        a = clamp(t * 0.5 + 0.5 - d, 0.0, 1.0);
    } else if (in.kind == RECT_DOTTED) {
        float p = fmod(in.local.x, t * 2.0);
        a = p < t ? 1.0 : 0.0;
    } else if (in.kind == RECT_DASHED) {
        float dash = max(t * 3.0, 3.0);
        float p = fmod(in.local.x, dash * 2.0);
        a = p < dash ? 1.0 : 0.0;
    } else if (in.kind == RECT_HOLLOW) {
        float2 l = in.local;
        bool edge = l.x < t || l.y < t || l.x > in.size.x - t || l.y > in.size.y - t;
        a = edge ? 1.0 : 0.0;
    }
    float alpha = in.color.a * a;
    return float4(in.color.rgb * alpha, alpha);
}

vertex GlyphOut glyph_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             const device GlyphInstance *glyphs [[buffer(0)]],
                             constant Uniforms &u [[buffer(1)]]) {
    GlyphInstance g = glyphs[iid];
    float2 c = corners[vid];
    GlyphOut o;
    o.position = toNDC(g.origin + c * g.size, u.viewport);
    o.uv = g.uv + c * g.size;
    o.color = float4(g.color) / 255.0;
    o.flags = g.flags;
    return o;
}

fragment float4 glyph_fragment(GlyphOut in [[stage_in]],
                               texture2d<float> grayAtlas [[texture(0)]],
                               texture2d<float> colorAtlas [[texture(1)]],
                               constant Uniforms &u [[buffer(1)]]) {
    constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);
    if (in.flags & 1u) {
        // Premultiplied BGRA emoji; color.a carries faint/opacity.
        float4 c = colorAtlas.sample(s, in.uv);
        return c * in.color.a;
    }
    float cov = grayAtlas.sample(s, in.uv).r;
    cov = pow(cov, u.textGamma);
    float alpha = in.color.a * cov;
    return float4(in.color.rgb * alpha, alpha);
}

vertex ImageOut image_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             const device ImageInstance *imgs [[buffer(0)]],
                             constant Uniforms &u [[buffer(1)]]) {
    ImageInstance im = imgs[iid];
    float2 c = corners[vid];
    ImageOut o;
    o.position = toNDC(im.origin + c * im.size, u.viewport);
    o.uv = mix(im.uv.xy, im.uv.zw, c);
    o.alpha = im.alpha;
    return o;
}

fragment float4 image_fragment(ImageOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv) * in.alpha; // texture is premultiplied RGBA
}

// Cursor trail: a convex polygon (triangulated on the CPU) in a single color.
vertex float4 trail_vertex(uint vid [[vertex_id]],
                           const device float2 *pts [[buffer(0)]],
                           constant Uniforms &u [[buffer(1)]]) {
    return toNDC(pts[vid], u.viewport);
}

fragment float4 trail_fragment(constant float4 &color [[buffer(0)]]) {
    return float4(color.rgb * color.a, color.a);
}
