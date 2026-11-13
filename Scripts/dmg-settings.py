# dmgbuild settings for the NimbusSync installer DMG.
# Invoked by Scripts/make-dmg.sh with -D app=<path to .app> -D background=<path to background.png>.
# The background is 600x400 pt; dmgbuild picks up background@2x.png next to it for Retina.
import os.path

app = defines["app"]  # noqa: F821 (injected by dmgbuild)
app_name = os.path.basename(app)

format = "ULFO"  # lzfse, macOS 10.11+: faster and smaller than UDZO
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extension = [app_name]

background = defines["background"]  # noqa: F821
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

# Window content is 600x400 pt, matching the background; icons sit left/right of the arrow.
window_rect = ((200, 160), (600, 400))
default_view = "icon-view"
icon_size = 112
text_size = 13
arrange_by = None
icon_locations = {
    app_name: (150, 200),
    "Applications": (450, 200),
}
