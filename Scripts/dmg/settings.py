import os

# Inputs passed via environment so no paths are hard-coded.
application = os.environ["APP_PATH"]
appname = os.path.basename(application)

format = "UDZO"                      # compressed, read-only
size = None                          # auto-size to contents

files = [application]
symlinks = {"Applications": "/Applications"}

background = os.environ["BG_TIFF"]    # HiDPI TIFF (640x400 pt, @2x)

# Clean, chromeless window.
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

window_rect = ((280, 220), (640, 400))
default_view = "icon-view"
icon_size = 128
text_size = 13

icon_locations = {
    appname: (170, 195),
    "Applications": (470, 195),
}
