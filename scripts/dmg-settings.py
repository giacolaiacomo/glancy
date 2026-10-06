# dmgbuild settings for Glancy's DMG window (used by scripts/make-dmg.sh).
# -D app=<path to Glancy.app> -D background=<background.png; background@2x.png beside it>
import os.path

app = defines["app"]
format = "UDZO"
compression_level = 9
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {os.path.basename(app): (170, 236), "Applications": (470, 236)}
background = defines["background"]
window_rect = ((200, 160), (640, 420))
icon_size = 128
text_size = 13
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
show_icon_preview = False
arrange_by = None
hide_extensions = [os.path.basename(app)]
