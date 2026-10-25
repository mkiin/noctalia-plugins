"""Run: nix shell nixpkgs#luau nixpkgs#python3 --command python3 tests/wallpaper_transition.py"""

import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1] / "wallpaper-picker"
script = """
local commands = {}
local timers = {}
local previews = {}
local settings = { ["wallpaper.transition_duration"] = 800 }
local wallpapers = {}
local noctalia = {
    getSetting = function(key) return settings[key] end,
    runAsync = function(command, callback)
        if callback then
            table.insert(timers, { command = command, callback = callback })
        else
            table.insert(commands, command)
        end
        return true
    end,
    nowMs = function() return 0 end,
    state = { set = function() end },
    setWallpaper = function(first, second)
        table.insert(wallpapers, if second then first .. "=" .. second else first)
    end,
}
-- Palette listing is outside these scheduling tests.
local require = function() return {} end
"""
for module, filename in (
    ("PaletteManager", "palette_manager.luau"),
    ("WallpaperController", "wallpaper_controller.luau"),
):
    script += f"local {module} = (function()\n{(root / filename).read_text()}\nend)()\n"

script += """
local palettes = PaletteManager.new(function() end)
local favorites = {
    get = function(_, _, path)
        if path == "plain" then return nil end
        return { source = "community", scheme = path }
    end,
}
local thumbnails = {
    request = function(_, path, kind, callback)
        assert(kind == "video")
        previews[path] = callback
    end,
}
local selectedOutput = nil
local controller = WallpaperController.new(
    { connector = function() return selectedOutput end }, palettes, favorites, thumbnails, function() end
)
local function reset()
    table.clear(commands)
    table.clear(timers)
end
local function finishTimers()
    local pending = table.clone(timers)
    table.clear(timers)
    for _, timer in ipairs(pending) do timer.callback({}) end
end
local function expectScheme(name)
    assert(#commands == 1, "expected exactly one palette application")
    assert(commands[1] == "noctalia msg color-scheme-set 'community' '" .. name .. "'")
end

controller:applyImage("first")
assert(wallpapers[1] == "first", "wallpaper must change immediately")
assert(#commands == 0, "palette must wait")
assert(timers[2].command[1] == "sleep" and timers[2].command[2] == "1")
assert(palettes:current() == nil, "pending palette must not become current early")
finishTimers()
expectScheme("first")

reset()
controller:applyImage("first")
controller:applyImage("last")
finishTimers()
expectScheme("last")

for _, interrupt in ipairs({
    function() controller:applyImage("plain") end,
    function() controller:applyVideo("plain") end,
    function() controller:stop() end,
}) do
    reset()
    controller:applyImage("stale")
    interrupt()
    finishTimers()
    assert(#commands == 0, "interrupted palette must not apply")
end

for _, interrupt in ipairs({
    function() palettes:apply("community", "manual") end,
    function() controller:applyVideo("manual") end,
}) do
    reset()
    controller:applyImage("stale")
    interrupt()
    finishTimers()
    expectScheme("manual")
end

reset()
controller:applyImage("stale")
palettes:toggleMode()
finishTimers()
assert(#commands == 1 and commands[1] == "noctalia msg theme-mode-toggle")

-- Consult live settings: the cached selection may be stale or an IPC may have failed.
for source, key in pairs({
    builtin = "builtin", community = "community_palette",
    custom = "custom_palette", wallpaper = "wallpaper_scheme",
}) do
    reset()
    settings["theme.source"] = source
    settings["theme." .. key] = "active"
    palettes:apply(source, "active")
    assert(#commands == 0, "active palette must not be reapplied")
    local actualSource, actualName = palettes:current()
    assert(actualSource == source and actualName == "active")
end

reset()
settings["wallpaper.transition_duration"] = 1200
controller:applyImage("changed-duration")
assert(timers[2].command[2] == "1.4", "delay must follow host settings")
settings["theme.source"] = "community"
settings["theme.community_palette"] = "changed-duration"
finishTimers()
assert(#commands == 0, "recheck the active palette after the delay")

reset()
palettes:apply("community", "retry")
palettes:apply("community", "retry")
assert(#commands == 2, "an unconfirmed application must remain retryable")

table.clear(wallpapers)
controller:applyVideo("video")
previews.video("/persistent/video.jpg")
assert(wallpapers[1] == "/persistent/video.jpg", "video preview must become the host wallpaper")

table.clear(wallpapers)
controller:applyVideo("old")
controller:applyVideo("new")
previews.old("/persistent/old.jpg")
previews.new("/persistent/new.jpg")
assert(#wallpapers == 1 and wallpapers[1] == "/persistent/new.jpg", "stale preview must not replace the selection")

table.clear(wallpapers)
controller:applyVideo("stopped")
controller:stop()
previews.stopped("/persistent/stopped.jpg")
assert(#wallpapers == 0, "stopped video must not replace the host wallpaper")

table.clear(wallpapers)
selectedOutput = "DP-1"
controller:applyVideo("left")
selectedOutput = "HDMI-A-1"
controller:applyVideo("right")
previews.left("/persistent/left.jpg")
previews.right("/persistent/right.jpg")
assert(wallpapers[1] == "DP-1=/persistent/left.jpg")
assert(wallpapers[2] == "HDMI-A-1=/persistent/right.jpg")
print("wallpaper transition checks passed")
"""

with tempfile.NamedTemporaryFile(mode="w", suffix=".luau") as test:
    test.write(script)
    test.flush()
    subprocess.run(["luau", test.name], check=True)
