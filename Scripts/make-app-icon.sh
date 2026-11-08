#!/bin/sh
# Regenerates the app icon set from its design source.
#
#   Design/AppIcon.png (1024 × 1024, opaque, full bleed)
#     -> Apps/NimbusSync/Assets.xcassets/AppIcon.appiconset/
#
# Run from the repository root:  Scripts/make-app-icon.sh
#
# The artwork is a full-bleed square on purpose: macOS 26 and later mask app icons to their own
# rounded shape, and an icon that already carries a transparent margin and corners is shrunk into
# a grey tile instead.
set -eu

source=Design/AppIcon.png
set_dir=Apps/NimbusSync/Assets.xcassets/AppIcon.appiconset

[ -f "$source" ] || { echo "error: $source is missing" >&2; exit 1; }
width=$(sips -g pixelWidth "$source" | awk '/pixelWidth/ { print $2 }')
height=$(sips -g pixelHeight "$source" | awk '/pixelHeight/ { print $2 }')
[ "$width" = 1024 ] && [ "$height" = 1024 ] || { echo "error: $source must be 1024 × 1024 (is $width × $height)" >&2; exit 1; }

mkdir -p "$set_dir"
for points in 16 32 128 256 512; do
    for scale in 1 2; do
        pixels=$((points * scale))
        if [ "$scale" = 1 ]; then name="icon_${points}x${points}.png"; else name="icon_${points}x${points}@2x.png"; fi
        sips -s format png -z "$pixels" "$pixels" "$source" --out "$set_dir/$name" >/dev/null
        echo "wrote $set_dir/$name ($pixels px)"
    done
done

cat > "$set_dir/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
cat > "$(dirname "$set_dir")/Contents.json" <<'JSON'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
echo "wrote $set_dir/Contents.json"
