# mpvExtended English Learning Pack

English-learning setup for mpvExtended / mpv NAS Player.

## Screenshots
<img src="screenshots/landscape_view.png" width="800">

<img src="screenshots/portrait_view.png" width="400">


## Preparing mpvExtended

Download and install mpvExtended from the link below:
https://github.com/marlboro-advance/mpvEx/releases

arm64-v8a: Modern 64-bit ARM devices (recommended for most users)
universal: Works on all devices (larger size)


### Recommended settings for mpvExtended

* Screen Orientation Settings  
  * [Preferences][Player] Orientation : Free


## Files

```text
mpvExtended_english_learning_pack_lua_config/
├─ README.md
├─ README_ja.md
├─ mpv.conf
└─ english-subs-android.lua
```

## Install

Copy:

```text
english-subs-android.lua
```

to:

```text
/storage/emulated/0/Android/media/app.marlboroadvance.mpvex/english-subs-android.lua
```

Then paste the included `mpv.conf` into mpvExtended's mpv.conf editor.

Important line:

```ini
script=/sdcard/Android/media/app.marlboroadvance.mpvex/english-subs-android.lua
```

## User settings

Edit the top of the Lua file:

```lua
local o = {
    landscape_panel_ratio = 0.60,
    portrait_panel_ratio = 0.60,

    prev_count = 2,
    next_count = 2,

    font_size = 52,
    current_font_size = 52,

    line_gap = 14,
    block_gap = 22,

    margin_x = 28,
    margin_y = 28,

    current_marker = "",

    -- Wrapping width correction.
    -- 1.00 = conservative/default estimate
    -- 1.15-1.25 = use more of the panel width
    wrap_width_scale = 1.20,
}
```

This package does not depend on the Custom Lua Import UI.
