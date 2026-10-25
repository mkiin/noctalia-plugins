# Wallpaper Picker

A unified image + video wallpaper picker that recreates Noctalia v4's local
wallpaper panel. The **Images** tab browses a folder of wallpapers with a
thumbnail grid, search, sort, subfolder navigation and favorites; the
**Video** tab drives [`mpvpaper`](https://github.com/GhostNaN/mpvpaper) through a
headless service with the same grid, favorites, and pause / resume / stop.

The single star in the header favorites the wallpaper currently applied to the
selected output. Favorites snapshot the active theme palette, show a distinct
thumbnail border and four accent dots below the thumbnail. Applying a favorited
wallpaper restores both the wallpaper and its saved palette. Image favorites
apply their palette after the configured transition duration plus 200 ms.
Selecting another wallpaper, manually changing the palette or theme mode, or
stopping video cancels the pending palette change. Already active palettes are
not reapplied.

## Plugin

| Field | Value |
| --- | --- |
| ID | `mkiin/wallpaper-picker` |
| Entries | Bar widget: `wallpaper`; panel: `picker`; service: `service`; shortcut: `shortcut` |

## Requirements

Install `mpvpaper` and `mpv` (used both for playback and to generate video
thumbnails). `ffmpeg` is used to generate image thumbnails; without it the
original images are shown directly.

## Usage

- Add the **Wallpaper Picker** bar widget, or the control-center shortcut, and
  click it to open the panel.
- Or toggle it over IPC:

  ```sh
  noctalia msg panel-toggle mkiin/wallpaper-picker:picker
  ```

- **Images** tab: click a thumbnail to set it as the wallpaper. Click a folder
  to drill in; the labeled up button appears inside a subfolder. Use the header
  star to favorite the current wallpaper.
- **Video** tab: click a thumbnail to start it on the selected output. Pause /
  resume / stop act on the selected output (or all outputs).
- The palette button switches to a grid of built-in, community and custom
  color schemes; the theme button toggles light / dark.
- Selecting a video also saves its generated still thumbnail as Noctalia's
  wallpaper for the selected output(s), so the lock screen and Control Center
  can display it while `mpvpaper` plays the video on the desktop.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `image_directory` | `folder` | `""` | Folder scanned for images; defaults to the Noctalia wallpaper directory. |
| `video_directory` | `folder` | `""` | Folder scanned for videos; defaults to `~/Videos`. |
| `show_names` | `bool` | `true` | Show file names under each thumbnail. |
| `mute` | `bool` | `true` | Mute video audio. |
| `hardware_decode` | `bool` | `true` | Use GPU video decoding (`hwdec=auto`). |
| `auto_pause` | `select` | `full` | Pause the video while a window covers the wallpaper. |
| `mpv_options` | `string` | `""` | Extra space-separated mpv options. |
| `run_as_systemd` | `bool` | `false` | Run mpvpaper in a systemd transient scope. |
| `cpu_quota`, `allowed_cpus`, `memory_max`, `cpu_weight`, `nice` | | | Resource limits, applied when `run_as_systemd` is on. |

## Notes

- Stop reveals the video's saved still thumbnail on that output. Select an image
  to replace it.
- Favorites are stored in the plugin's data directory (`favorites.json`).
- Image thumbnails are cached under `$XDG_CACHE_HOME/noctalia/wallpaper-picker`.
  Video thumbnails are kept in the plugin's data directory because Noctalia
  uses them as persisted wallpapers.
