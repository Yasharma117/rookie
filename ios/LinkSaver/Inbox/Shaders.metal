#include <metal_stdlib>
using namespace metal;

#include <SwiftUI/SwiftUI_Metal.h>

// Fluid ripple distortion.
//
// Generates multiple concentric radial wavefronts emanating from `center`.
// The visible "rings" the user sees are the pixel deformation produced by the
// Gaussian-windowed wavefronts — they are an emergent property of the distortion.
//
// Parameters:
//   position  — pixel position in source coordinates
//   center    — tap origin in source coordinates
//   time      — animation progress 0..1
//   amplitude — peak pixel displacement at the wavefront crest
[[ stitchable ]] float2 fluidRipple(
    float2 position,
    float2 center,
    float time,
    float amplitude
) {
    float2 delta = position - center;
    float distance = length(delta);
    if (distance < 0.5) {
        return position;
    }

    float totalDisplacement = 0.0;
    float thickness = 50.0;

    // Three concentric wavefronts, staggered by 0.15 time units
    // Each subsequent ring is weaker (0.7x, 0.45x, 0.25x)
    float ringSpeeds[3] = {280.0, 220.0, 160.0};
    float ringStrengths[3] = {1.0, 0.7, 0.45};

    for (int i = 0; i < 3; i++) {
        float ringTime = time - float(i) * 0.12;
        if (ringTime <= 0.0) continue;

        float wavefront = ringTime * ringSpeeds[i];
        float ring = exp(-pow(distance - wavefront, 2.0) / (thickness * thickness));

        // Envelope: decays as time progresses and per ring index
        float envelope = (1.0 - ringTime) * amplitude * ringStrengths[i];
        if (envelope > 0.0) {
            totalDisplacement += ring * envelope;
        }
    }

    return position + normalize(delta) * totalDisplacement;
}
