# USBKey icon — red / white

Created with the built-in image_gen tool (imagegen skill), using the user's key silhouette in `KeyReference.png`. No external API/key was used.

- Selected source: `AppIcon-source.png`.
- Packaged macOS icon: `AppIcon.icns` (16–1024 px representations, alpha preserved).
- Previous version retained as `AppIcon-teal-v1.png`.
- Conversion: `scripts/build-icon.sh` uses sips and iconutil.
- The app bundle references AppIcon via CFBundleIconFile; the management window uses the same application icon.

Prompt:

> Edit the supplied reference key graphic into a finished macOS app icon. Preserve the EXACT key silhouette, proportions, diagonal orientation and two teeth of the reference: round bow at upper right with a round hole, shaft running down to the lower left. Recolor the key solid pure WHITE (#FFFFFF). Remove its original white background. Put this single white key, smaller and perfectly centered, on a flat solid deep red rounded-square tile with exact sRGB color #A60707 (RGB 166,7,7). Key bounding box should be 58% of the tile width and height, leaving generous equal optical margins. The circular hole in the key reveals the same red background. Tile width 82% of the square canvas, centered, macOS rounded-square corners, transparent alpha outside tile. Ultra-clean flat 2D vector-like rendering with sharp antialiased edges. Absolutely no gradients, shadows, textures, glow, highlights, outlines, letters or text. The red interior must be a perfectly uniform #A60707. Output one square production app icon.

Refinement prompt:

> Precise color correction of this app icon. Keep the key silhouette, its size and centered position EXACTLY as supplied. Change ONLY the fills: the entire red rounded square and the hole in the key must be ONE perfectly uniform flat opaque sRGB color RGB(166,7,7), hex #A60707. The entire key must be ONE perfectly uniform flat opaque pure white RGB(255,255,255). Remove ALL gradients, grain, noise, texture, vignetting, shadows and lighting variation. This is a flat 2-color vector-style logo, not a rendered illustration. Preserve alpha transparency outside the rounded square and crisp antialiased contour edges. Every interior background pixel away from edges should be the same #A60707. No other changes, no text.
