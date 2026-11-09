#!/bin/sh
# Regenerates the app icon from its design sources.
#
#   Design/AppIcon-Light.png (1024 × 1024, opaque, full bleed)  -> light appearance (default)
#   Design/AppIcon-Dark.png  (1024 × 1024, opaque, full bleed)  -> dark appearance
#     -> Apps/NimbusSync/AppIcon.icon  (Icon Composer document)
#     -> Apps/NimbusSync/Assets.xcassets/AppIconImage.imageset  (in-app icon, light + dark)
#
# Run from the repository root:  Scripts/make-app-icon.sh
#
# The artwork is a full-bleed square on purpose: macOS 26 and later mask app icons to their own
# rounded shape, and an icon that already carries a transparent margin and corners is shrunk into
# a grey tile instead.
#
# An asset-catalog app icon set cannot carry a dark variant on macOS, so the icon is an Icon
# Composer document: one layer whose image switches with the appearance, with Liquid Glass
# effects off so the artwork renders as drawn. actool also derives AppIcon.icns from the light
# rendering for macOS releases before 26, which have no dark app icons.
#
# NSApplication.applicationIconImage follows the system appearance, not the app's own Theme
# setting, so views inside the app draw AppIconImage instead: the same document rendered by
# ictool for each appearance, padded like the system icon (824 px artwork on a 1024 px canvas).
set -eu

light=Design/AppIcon-Light.png
dark=Design/AppIcon-Dark.png
icon=Apps/NimbusSync/AppIcon.icon

for source in "$light" "$dark"; do
    [ -f "$source" ] || { echo "error: $source is missing" >&2; exit 1; }
    width=$(sips -g pixelWidth "$source" | awk '/pixelWidth/ { print $2 }')
    height=$(sips -g pixelHeight "$source" | awk '/pixelHeight/ { print $2 }')
    [ "$width" = 1024 ] && [ "$height" = 1024 ] || { echo "error: $source must be 1024 × 1024 (is $width × $height)" >&2; exit 1; }
done

rm -rf "$icon"
mkdir -p "$icon/Assets"
sips -s format png "$light" --out "$icon/Assets/AppIcon-Light.png" >/dev/null
sips -s format png "$dark" --out "$icon/Assets/AppIcon-Dark.png" >/dev/null

cat > "$icon/icon.json" <<'JSON'
{
  "fill" : "automatic",
  "groups" : [
    {
      "layers" : [
        {
          "glass" : false,
          "image-name-specializations" : [
            { "value" : "AppIcon-Light.png" },
            { "appearance" : "dark", "value" : "AppIcon-Dark.png" }
          ],
          "name" : "Artwork"
        }
      ],
      "shadow" : { "kind" : "none", "opacity" : 0.5 },
      "specular" : false,
      "translucency" : { "enabled" : false, "value" : 0.5 }
    }
  ],
  "supported-platforms" : { "squares" : [ "macOS" ] }
}
JSON
echo "wrote $icon"

ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[ -x "$ictool" ] || { echo "error: ictool is missing (needs Xcode 26 or later): $ictool" >&2; exit 1; }
imageset=Apps/NimbusSync/Assets.xcassets/AppIconImage.imageset
rm -rf "$imageset"
mkdir -p "$imageset"
for rendition in Default Dark; do
    out="$imageset/AppIconImage-$rendition.png"
    "$ictool" "$icon" --export-image --output-file "$out" --platform macOS --rendition "$rendition" \
        --width 824 --height 824 --scale 1 >/dev/null
    sips --padToHeightWidth 1024 1024 "$out" --out "$out" >/dev/null
    echo "wrote $out"
done
cat > "$imageset/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "AppIconImage-Default.png", "idiom" : "universal" },
    {
      "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
      "filename" : "AppIconImage-Dark.png",
      "idiom" : "universal"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
echo "wrote $imageset/Contents.json"
