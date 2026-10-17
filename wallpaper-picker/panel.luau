--!nonstrict
-- Wallpaper Picker - picker panel.
--
-- Two tabs:
--   * Images - a Noctalia v4-style local picker: thumbnail grid, search, sort,
--     subfolder browsing, per-image favorites.
--   * Video  - the same grid + favorites driven through the headless mpvpaper
--     service, plus pause / resume / stop for the selected output.
--
-- Favorites snapshot the active theme palette at star time (4 accent dots), and
-- applying a favorited wallpaper restores that palette. The palette cards mirror
-- v4's Color Scheme "Predefined" grid.
--
-- Noctalia's plugin UI has no overlay / modal / tab primitives, so tiles compose
-- an image plus a small action row, and the palette chooser is a toggled content
-- view rather than a popup.

local builtinPalettes = require("./builtin_palettes.luau")

local PANEL_WIDTH = 1000
local PANEL_PADDING = 24
local GRID_COLUMNS = 4
local GRID_GAP = 12
local TILE_RADIUS = 12
-- Tiles flex to share the row, so no fixed tile width is needed. The image
-- height is derived from the expected slot width (content width / 4).
local CONTENT_WIDTH = PANEL_WIDTH - PANEL_PADDING * 2 - 16 -- slack for the scrollbar
local TILE_IMAGE_H = math.floor(((CONTENT_WIDTH - GRID_GAP * (GRID_COLUMNS - 1)) / GRID_COLUMNS) * 0.62)
local TILE_INNER_GAP = 4
local ACTION_H = 34
local NAME_H = 16
local VIEWPORT_ROWS = 2

-- Tile height is fixed so each row is deterministic and the viewport can be
-- sized to exactly VIEWPORT_ROWS rows (nothing beyond is shown).
local function tileHeight()
	local h = TILE_IMAGE_H + TILE_INNER_GAP + ACTION_H
	if noctalia.getConfig("show_names") ~= false then
		h = h + TILE_INNER_GAP + NAME_H
	end
	return h
end

local function viewportHeight()
	return tileHeight() * VIEWPORT_ROWS + GRID_GAP
end

local CACHE_DIR = (noctalia.getenv("XDG_CACHE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.cache"))
	.. "/noctalia/wallpaper-picker"
local DATA_DIR = noctalia.pluginDataDir()
local FAV_FILE = (DATA_DIR or CACHE_DIR) .. "/favorites.json"

local IMAGE_EXTENSIONS = { jpg = true, jpeg = true, png = true, webp = true, bmp = true, avif = true, gif = true }
local VIDEO_EXTENSIONS = { mp4 = true, webm = true, mkv = true, mov = true, gif = true }

local THUMB_MAX_CONCURRENT = 4

-- ── State ───────────────────────────────────────────────────────────────────

local tab = "images"
local showPalette = false
local query = ""
local sortMode = "name" -- name | name_desc | random
local monitorIndex = 0
local imageDir = nil
local browseDir = nil
local scanning = false
local isOpen = false

local imageEntries = {} -- { { path, name, isDir }, ... }
local videoEntries = {} -- { { path, name }, ... }

local thumbs = {} -- src path -> ready thumbnail path
local thumbPending = {} -- src path -> true while generating
local thumbQueue = {}
local thumbActive = 0
local lastThumbRender = 0 -- throttle re-renders while thumbnails trickle in

local favorites = { images = {}, videos = {} }

local paletteGroups = nil
local paletteSource = "builtin" -- builtin | community | custom
local currentSource = nil
local currentScheme = nil

local nonce = 0

local render -- forward declaration

-- ── Small helpers ───────────────────────────────────────────────────────────

local function shellQuote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function homeDir()
	return noctalia.getenv("HOME") or "/tmp"
end

local function stateDir()
	return noctalia.getenv("XDG_STATE_HOME") or (homeDir() .. "/.local/state")
end

local function configDir()
	return noctalia.getenv("XDG_CONFIG_HOME") or (homeDir() .. "/.config")
end

local function nextNonce()
	nonce += 1
	return nonce
end

local function outputs()
	return noctalia.outputs() or {}
end

local function monitorConnector()
	if monitorIndex <= 0 then
		return nil
	end
	local out = outputs()[monitorIndex]
	return out and out.name or nil
end

local function isDark()
	return noctalia.isDarkMode() == true
end

local function unique(list)
	local seen = {}
	local out = {}
	for _, v in ipairs(list) do
		if not seen[v] then
			seen[v] = true
			table.insert(out, v)
		end
	end
	return out
end

local function hasVideo()
	local assignments = noctalia.state.get("assignments") or {}
	if monitorIndex <= 0 then
		return next(assignments) ~= nil
	end
	local connector = monitorConnector()
	return assignments[connector] ~= nil or assignments["*"] ~= nil
end

local function isScopePaused()
	local paused = noctalia.state.get("paused") or {}
	if monitorIndex <= 0 then
		for _, v in pairs(paused) do
			if v then
				return true
			end
		end
		return false
	end
	local connector = monitorConnector()
	return paused[connector] == true or paused["*"] == true
end

-- ── Favorites ───────────────────────────────────────────────────────────────

local function loadFavorites()
	local content = noctalia.readFile(FAV_FILE)
	if type(content) == "string" and content ~= "" then
		local decoded = noctalia.json.decode(content)
		if type(decoded) == "table" then
			favorites.images = decoded.images or {}
			favorites.videos = decoded.videos or {}
		end
	end
end

local function saveFavorites()
	noctalia.writeFile(FAV_FILE, noctalia.json.encode(favorites) or '{ "images": {}, "videos": {} }')
end

local function snapshotPalette()
	return {
		noctalia.getColor("primary") or "#808080",
		noctalia.getColor("secondary") or "#808080",
		noctalia.getColor("tertiary") or "#808080",
		noctalia.getColor("error") or "#808080",
	}
end

local function toggleFavorite(kind, path)
	local store = favorites[kind]
	if store[path] then
		store[path] = nil
	else
		store[path] = {
			palette = snapshotPalette(),
			source = currentSource,
			scheme = currentScheme,
			mode = isDark() and "dark" or "light",
		}
	end
	saveFavorites()
	render()
end

-- ── Theme palette ───────────────────────────────────────────────────────────

local function refreshCurrentScheme()
	noctalia.runAsync("noctalia msg color-scheme-get", function(result)
		if type(result) == "table" and type(result.stdout) == "string" then
			local source, name = result.stdout:match("^(%S+)%s+(.+)$")
			if source and name then
				currentSource = source
				currentScheme = noctalia.string.trim(name)
				render()
			end
		end
	end)
end

local function applyPalette(source, name)
	if type(source) ~= "string" or type(name) ~= "string" then
		return
	end
	noctalia.runAsync("noctalia msg color-scheme-set " .. shellQuote(source) .. " " .. shellQuote(name))
	currentSource = source
	currentScheme = name
	render()
end

local function toggleThemeMode()
	noctalia.runAsync("noctalia msg theme-mode-toggle")
	noctalia.runAsync("sleep 0.3", function()
		paletteGroups = nil
		render()
	end)
end

-- Pull four accent colors and a surface color from a decoded palette table,
-- accepting the different key cases Noctalia writes across JSON sources.
local function modeFromTable(root, mode)
	if type(root) ~= "table" then
		return nil
	end
	local node = root[mode]
	if type(node) ~= "table" then
		node = root
	end

	local function pick(key)
		local capital = key:sub(1, 1):upper() .. key:sub(2)
		for _, candidate in ipairs({ key, capital, "m" .. capital }) do
			local value = node[candidate]
			if type(value) == "string" and value:sub(1, 1) == "#" then
				return value
			end
		end
		return nil
	end

	local surface = pick("surface")
	local colors = { pick("primary"), pick("secondary"), pick("tertiary"), pick("error") }
	if not colors[1] and not surface then
		return nil
	end
	return { colors = colors, surface = surface }
end

local function buildPaletteGroups()
	local mode = isDark() and "dark" or "light"
	local groups = {}

	local builtinItems = {}
	for _, p in ipairs(builtinPalettes) do
		local m = p[mode] or p.dark
		table.insert(builtinItems, {
			source = "builtin",
			name = p.name,
			colors = { m[1], m[2], m[3], m[4] },
			surface = m[5],
		})
	end
	table.insert(groups, { source = "builtin", title = noctalia.tr("palette.builtin"), items = builtinItems })

	-- Community: read the cached catalog (array, or { palettes = [...] }).
	local communityItems = {}
	local catalog = noctalia.readFile(stateDir() .. "/noctalia/community-palettes/.catalog/palettes.json")
	if type(catalog) == "string" and catalog ~= "" then
		local decoded = noctalia.json.decode(catalog)
		if type(decoded) == "table" then
			local entries = decoded.palettes or decoded
			if type(entries) == "table" then
				for _, item in ipairs(entries) do
					if type(item) == "table" and type(item.name) == "string" then
						local info = modeFromTable(item, mode)
						table.insert(communityItems, {
							source = "community",
							name = item.name,
							colors = (info and info.colors) or {},
							surface = info and info.surface or nil,
						})
					end
				end
			end
		end
	end
	if #communityItems > 0 then
		table.sort(communityItems, function(a, b)
			return a.name:lower() < b.name:lower()
		end)
		table.insert(groups, { source = "community", title = noctalia.tr("palette.community"), items = communityItems })
	end

	-- Custom: ~/.config/noctalia/palettes/*.json (one palette per file).
	local customItems = {}
	local dir = configDir() .. "/noctalia/palettes"
	local names = noctalia.listDir(dir)
	if type(names) == "table" then
		for _, file in ipairs(names) do
			if file:sub(-5) == ".json" then
				local info = nil
				local content = noctalia.readFile(dir .. "/" .. file)
				if type(content) == "string" and content ~= "" then
					info = modeFromTable(noctalia.json.decode(content), mode)
				end
				table.insert(customItems, {
					source = "custom",
					name = file:sub(1, -6),
					colors = (info and info.colors) or {},
					surface = info and info.surface or nil,
				})
			end
		end
	end
	if #customItems > 0 then
		table.sort(customItems, function(a, b)
			return a.name:lower() < b.name:lower()
		end)
		table.insert(groups, { source = "custom", title = noctalia.tr("palette.custom"), items = customItems })
	end

	paletteGroups = groups

	-- Keep the selected sub-tab on a source that actually has palettes.
	local valid = false
	for _, group in ipairs(groups) do
		if group.source == paletteSource and #group.items > 0 then
			valid = true
		end
	end
	if not valid then
		for _, group in ipairs(groups) do
			if #group.items > 0 then
				paletteSource = group.source
				break
			end
		end
	end
end

-- ── Thumbnails ──────────────────────────────────────────────────────────────

local function thumbCachePath(path)
	return CACHE_DIR .. "/" .. path:gsub("[^%w]", "_") .. ".jpg"
end

local function pumpThumbQueue()
	while thumbActive < THUMB_MAX_CONCURRENT and #thumbQueue > 0 do
		local job = table.remove(thumbQueue, 1)
		local src = job.path
		if thumbs[src] == nil and not thumbPending[src] then
			thumbPending[src] = true
			thumbActive += 1
			local dest = thumbCachePath(src)
			local cmd
			if job.kind == "video" then
				local tmpdir = dest .. ".d"
				cmd = "mkdir -p "
					.. shellQuote(tmpdir)
					.. " && mpv "
					.. shellQuote(src)
					.. " --no-config --no-terminal --really-quiet --frames=1 --start=10% --no-audio"
					.. " --vo=image --vo-image-format=jpg --vo-image-outdir="
					.. shellQuote(tmpdir)
					.. " && mv "
					.. shellQuote(tmpdir .. "/00000001.jpg")
					.. " "
					.. shellQuote(dest)
					.. "; rm -rf "
					.. shellQuote(tmpdir)
			else
				cmd = "ffmpeg -y -i " .. shellQuote(src) .. " -vf scale=520:-1 -q:v 4 " .. shellQuote(dest)
			end
			noctalia.runAsync(cmd, function()
				thumbActive -= 1
				thumbPending[src] = nil
				if noctalia.fileExists(dest) then
					thumbs[src] = dest
				end
				pumpThumbQueue()
				if thumbActive == 0 and #thumbQueue == 0 then
					render()
				else
					local now = noctalia.nowMs()
					if now - lastThumbRender >= 150 then
						lastThumbRender = now
						render()
					end
				end
			end, 30000)
		end
	end
end

local function queueThumb(path, kind)
	if thumbs[path] ~= nil or thumbPending[path] then
		return
	end
	local cached = thumbCachePath(path)
	if noctalia.fileExists(cached) then
		thumbs[path] = cached
		return
	end
	table.insert(thumbQueue, { path = path, kind = kind })
	pumpThumbQueue()
end

-- ── Scanning ────────────────────────────────────────────────────────────────

local function resolveImageDir()
	local configured = noctalia.getConfig("image_directory")
	if type(configured) == "string" and configured ~= "" then
		return noctalia.expandPath(configured)
	end
	return noctalia.wallpaperDirectory() or (homeDir() .. "/Pictures")
end

local function scanImages()
	scanning = true
	render()

	local dir = browseDir or imageDir
	local names = dir and noctalia.listDir(dir) or nil
	local items = {}
	if type(names) == "table" then
		for _, name in ipairs(names) do
			if name:sub(1, 1) ~= "." then
				local full = dir .. "/" .. name
				local info = noctalia.fileInfo(full)
				if type(info) == "table" then
					if info.isDir then
						table.insert(items, { path = full, name = name, isDir = true })
					else
						local ext = name:match("%.([%a%d]+)$")
						if ext and IMAGE_EXTENSIONS[ext:lower()] then
							table.insert(items, { path = full, name = name, isDir = false })
						end
					end
				end
			end
		end
	end

	imageEntries = items
	scanning = false

	noctalia.mkdirAll(CACHE_DIR)
	for _, item in ipairs(items) do
		if not item.isDir then
			queueThumb(item.path, "image")
		end
	end
	render()
end

local function scanVideos()
	local configured = noctalia.getConfig("video_directory")
	local dir
	if type(configured) == "string" and configured ~= "" then
		dir = noctalia.expandPath(configured)
	else
		dir = homeDir() .. "/Videos"
	end

	local names = noctalia.listDir(dir)
	local items = {}
	if type(names) == "table" then
		for _, name in ipairs(names) do
			if name:sub(1, 1) ~= "." then
				local ext = name:match("%.([%a%d]+)$")
				if ext and VIDEO_EXTENSIONS[ext:lower()] then
					table.insert(items, { path = dir .. "/" .. name, name = name })
				end
			end
		end
	end
	table.sort(items, function(a, b)
		return a.name:lower() < b.name:lower()
	end)
	videoEntries = items

	noctalia.mkdirAll(CACHE_DIR)
	for _, item in ipairs(items) do
		queueThumb(item.path, "video")
	end
	render()
end

local function visibleImages()
	local q = query:lower()
	local out = {}
	for _, item in ipairs(imageEntries) do
		if q == "" or item.name:lower():find(q, 1, true) then
			table.insert(out, item)
		end
	end
	if sortMode == "name" then
		table.sort(out, function(a, b)
			if a.isDir ~= b.isDir then
				return a.isDir
			end
			return a.name:lower() < b.name:lower()
		end)
	elseif sortMode == "name_desc" then
		table.sort(out, function(a, b)
			if a.isDir ~= b.isDir then
				return a.isDir
			end
			return a.name:lower() > b.name:lower()
		end)
	else
		for i = #out, 2, -1 do
			local j = math.random(i)
			out[i], out[j] = out[j], out[i]
		end
	end
	return out
end

local function visibleVideos()
	local q = query:lower()
	if q == "" then
		return videoEntries
	end
	local out = {}
	for _, item in ipairs(videoEntries) do
		if item.name:lower():find(q, 1, true) then
			table.insert(out, item)
		end
	end
	return out
end

-- ── Actions ─────────────────────────────────────────────────────────────────

local function applyImage(path)
	local connector = monitorConnector()
	noctalia.state.set("command", { action = "clear-all", nonce = nextNonce() })
	if connector then
		noctalia.setWallpaper(connector, path)
	else
		noctalia.setWallpaper(path)
	end
	local fav = favorites.images[path]
	if fav and fav.source and fav.scheme then
		applyPalette(fav.source, fav.scheme)
	end
end

local function applyVideo(path)
	local connector = monitorConnector() or "*"
	noctalia.state.set("command", { action = "set", connector = connector, path = path, nonce = nextNonce() })
	local fav = favorites.videos[path]
	if fav and fav.source and fav.scheme then
		applyPalette(fav.source, fav.scheme)
	end
end

local function pauseSelected()
	noctalia.state.set("command", {
		action = isScopePaused() and "thaw" or "freeze",
		connector = monitorConnector() or "",
		nonce = nextNonce(),
	})
	render()
end

local function stopSelected()
	local connector = monitorConnector()
	if connector then
		noctalia.state.set("command", { action = "clear", connector = connector, nonce = nextNonce() })
	else
		noctalia.state.set("command", { action = "clear-all", nonce = nextNonce() })
	end
	render()
end

-- ── UI building blocks ──────────────────────────────────────────────────────

local function paletteDots(colors, diameter)
	local dots = {}
	local list = colors or {}
	for i = 1, math.min(#list, 4) do
		if type(list[i]) == "string" then
			table.insert(
				dots,
				ui.box({
					width = diameter,
					height = diameter,
					radius = diameter * 0.5,
					fill = list[i],
				})
			)
		end
	end
	return ui.row({ gap = 4, align = "center" }, dots)
end

local function grid(items, columns, nodeFor)
	local rows = {}
	local row = {}
	for i = 1, #items do
		table.insert(row, nodeFor(items[i], i))
		if #row == columns or i == #items then
			for _ = #row + 1, columns do
				table.insert(row, ui.spacer({ flexGrow = 1 }))
			end
			table.insert(rows, ui.row({ gap = GRID_GAP, align = "stretch" }, row))
			row = {}
		end
	end
	return ui.column({ gap = GRID_GAP, align = "stretch" }, rows)
end

local function imageTile(item)
	if item.isDir then
		return ui.column(
			{ key = "dir:" .. item.path, flexGrow = 1, height = tileHeight(), gap = TILE_INNER_GAP, align = "stretch" },
			{
				ui.box({
					height = TILE_IMAGE_H,
					fill = "surface_variant",
					radius = TILE_RADIUS,
					border = "outline",
					borderWidth = 1,
					onClick = function()
						browseDir = item.path
						scanImages()
					end,
				}),
				ui.label({
					text = item.name,
					fontSize = 11,
					maxLines = 1,
					color = "on_surface_variant",
					textAlign = "center",
				}),
			}
		)
	end

	local fav = favorites.images[item.path]
	local children = {}
	local thumb = thumbs[item.path]
	if thumb then
		table.insert(
			children,
			ui.image({
				key = "img:" .. item.path,
				path = thumb,
				height = TILE_IMAGE_H,
				fit = "cover",
				radius = TILE_RADIUS,
				border = fav and "primary" or "outline",
				borderWidth = fav and 2 or 1,
				tooltip = item.name,
				onClick = function()
					applyImage(item.path)
				end,
			})
		)
	else
		-- Render a cheap placeholder until the thumbnail is ready. Never load the
		-- original here: decoding full-resolution wallpapers stalls the renderer.
		table.insert(
			children,
			ui.box({
				key = "ph:" .. item.path,
				height = TILE_IMAGE_H,
				fill = "surface_variant",
				radius = TILE_RADIUS,
				border = fav and "primary" or "outline",
				borderWidth = fav and 2 or 1,
				tooltip = item.name,
				onClick = function()
					applyImage(item.path)
				end,
			})
		)
	end
	table.insert(
		children,
		ui.row({ gap = 4, align = "center" }, {
			ui.button({
				key = "star:" .. item.path,
				glyph = fav and "star-filled" or "star",
				variant = "default",
				controlSize = "sm",
				tooltip = fav and noctalia.tr("favorite.remove") or noctalia.tr("favorite.add"),
				onClick = function()
					toggleFavorite("images", item.path)
				end,
			}),
			ui.spacer({ flexGrow = 1 }),
			paletteDots(fav and fav.palette or nil, 14),
		})
	)
	if noctalia.getConfig("show_names") ~= false then
		table.insert(
			children,
			ui.label({
				text = item.name,
				fontSize = 10,
				maxLines = 1,
				color = "on_surface_variant",
				textAlign = "center",
			})
		)
	end
	return ui.column(
		{ key = "tile:" .. item.path, flexGrow = 1, height = tileHeight(), gap = TILE_INNER_GAP, align = "stretch" },
		children
	)
end

local function videoTile(item)
	local fav = favorites.videos[item.path]
	local thumb = thumbs[item.path]
	local children = {}
	local action = function()
		applyVideo(item.path)
	end
	if thumb then
		table.insert(
			children,
			ui.image({
				key = "vimg:" .. item.path,
				path = thumb,
				height = TILE_IMAGE_H,
				fit = "cover",
				radius = TILE_RADIUS,
				border = fav and "primary" or "outline",
				borderWidth = fav and 2 or 1,
				tooltip = item.name,
				onClick = action,
			})
		)
	else
		table.insert(
			children,
			ui.box({
				key = "vbox:" .. item.path,
				height = TILE_IMAGE_H,
				fill = "surface_variant",
				radius = TILE_RADIUS,
				border = fav and "primary" or "outline",
				borderWidth = fav and 2 or 1,
				tooltip = item.name,
				onClick = action,
			})
		)
	end
	table.insert(
		children,
		ui.row({ gap = 4, align = "center" }, {
			ui.button({
				key = "vstar:" .. item.path,
				glyph = fav and "star-filled" or "star",
				variant = "default",
				controlSize = "sm",
				tooltip = fav and noctalia.tr("favorite.remove") or noctalia.tr("favorite.add"),
				onClick = function()
					toggleFavorite("videos", item.path)
				end,
			}),
			ui.spacer({ flexGrow = 1 }),
			paletteDots(fav and fav.palette or nil, 14),
		})
	)
	if noctalia.getConfig("show_names") ~= false then
		table.insert(
			children,
			ui.label({
				text = item.name,
				fontSize = 10,
				maxLines = 1,
				color = "on_surface_variant",
				textAlign = "center",
			})
		)
	end
	return ui.column(
		{ key = "vtile:" .. item.path, flexGrow = 1, height = tileHeight(), gap = TILE_INNER_GAP, align = "stretch" },
		children
	)
end

local function paletteCard(item)
	local selected = (currentSource == item.source and currentScheme == item.name)
	return ui.row({
		key = "pal:" .. item.source .. ":" .. item.name,
		flexGrow = 1,
		fill = item.surface or "surface_variant",
		radius = 10,
		padding = 10,
		gap = 8,
		align = "center",
		border = selected and "primary" or "outline",
		borderWidth = selected and 2 or 1,
		onClick = function()
			applyPalette(item.source, item.name)
		end,
	}, {
		ui.label({ text = item.name, fontSize = 12, flexGrow = 1, maxLines = 1, color = "on_surface" }),
		paletteDots(item.colors, 16),
	})
end

-- ── Render ──────────────────────────────────────────────────────────────────

local function header()
	local children = {
		ui.glyph({ name = "photo", size = 20, color = "primary" }),
		ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
		ui.button({
			glyph = isDark() and "moon" or "sun",
			variant = "default",
			tooltip = noctalia.tr("theme-mode"),
			onClick = toggleThemeMode,
		}),
		ui.button({
			glyph = "palette",
			variant = showPalette and "primary" or "default",
			tooltip = noctalia.tr("palette.title"),
			onClick = function()
				showPalette = not showPalette
				if showPalette and not paletteGroups then
					buildPaletteGroups()
				end
				render()
			end,
		}),
		ui.button({
			glyph = "refresh",
			variant = "default",
			tooltip = noctalia.tr("refresh"),
			onClick = function()
				paletteGroups = nil
				if tab == "video" then
					scanVideos()
				else
					scanImages()
				end
			end,
		}),
	}
	if noctalia.getSetting("shell.show_close_buttons") ~= false then
		table.insert(
			children,
			ui.button({
				glyph = "close",
				variant = "default",
				tooltip = noctalia.tr("close"),
				onClick = function()
					panel.close()
				end,
			})
		)
	end
	return ui.row({ gap = 8, align = "center" }, children)
end

local function tabBar()
	return ui.row({ gap = 8, align = "center" }, {
		ui.button({
			text = noctalia.tr("tab.images"),
			variant = tab == "images" and "primary" or "outline",
			onClick = function()
				tab = "images"
				showPalette = false
				render()
			end,
		}),
		ui.button({
			text = noctalia.tr("tab.video"),
			variant = tab == "video" and "primary" or "outline",
			onClick = function()
				tab = "video"
				showPalette = false
				if #videoEntries == 0 then
					scanVideos()
				else
					render()
				end
			end,
		}),
	})
end

local function monitorSelect()
	local labels = { noctalia.tr("all_outputs") }
	for _, out in ipairs(outputs()) do
		table.insert(labels, out.name)
	end
	return ui.select({
		key = "monitor",
		options = unique(labels),
		selectedIndex = monitorIndex,
		width = 200,
		onChange = function(index)
			monitorIndex = tonumber(index) or 0
			render()
		end,
	})
end

local function paletteTabs()
	local order = { "builtin", "community", "custom" }
	local children = {
		ui.button({
			glyph = "arrow-left",
			variant = "default",
			tooltip = noctalia.tr("back"),
			onClick = function()
				showPalette = false
				render()
			end,
		}),
		ui.label({ text = noctalia.tr("palette.title"), fontSize = 14, fontWeight = "bold", flexGrow = 1 }),
	}
	for _, source in ipairs(order) do
		local count = 0
		for _, group in ipairs(paletteGroups or {}) do
			if group.source == source then
				count = #group.items
			end
		end
		if count > 0 then
			table.insert(
				children,
				ui.button({
					text = noctalia.tr("palette." .. source),
					variant = paletteSource == source and "primary" or "outline",
					onClick = function()
						paletteSource = source
						render()
					end,
				})
			)
		end
	end
	return ui.row({ gap = 8, align = "center" }, children)
end

local function sourceControls()
	if showPalette then
		if not paletteGroups then
			buildPaletteGroups()
		end
		return paletteTabs()
	end

	local children = {
		ui.input({
			key = "search",
			value = query,
			placeholder = noctalia.tr("search"),
			flexGrow = 1,
			onChange = function(value)
				query = value
				render()
			end,
		}),
	}

	if tab == "images" then
		table.insert(
			children,
			ui.button({
				glyph = "arrow-left",
				variant = "default",
				enabled = browseDir ~= nil,
				tooltip = noctalia.tr("browse.up"),
				onClick = function()
					if browseDir then
						local parent = browseDir:match("^(.*)/[^/]+$")
						browseDir = (parent and parent ~= imageDir) and parent or nil
						scanImages()
					end
				end,
			})
		)
		table.insert(
			children,
			ui.button({
				glyph = sortMode == "name" and "sort-ascending"
					or (sortMode == "name_desc" and "sort-descending" or "arrows-shuffle"),
				variant = "default",
				tooltip = noctalia.tr("sort"),
				onClick = function()
					if sortMode == "name" then
						sortMode = "name_desc"
					elseif sortMode == "name_desc" then
						sortMode = "random"
					else
						sortMode = "name"
					end
					render()
				end,
			})
		)
	else
		table.insert(
			children,
			ui.button({
				glyph = isScopePaused() and "player-play" or "player-pause",
				variant = "default",
				enabled = hasVideo(),
				tooltip = isScopePaused() and noctalia.tr("resume") or noctalia.tr("pause"),
				onClick = pauseSelected,
			})
		)
		table.insert(
			children,
			ui.button({
				glyph = "player-stop",
				variant = "default",
				enabled = hasVideo(),
				tooltip = noctalia.tr("stop"),
				onClick = stopSelected,
			})
		)
	end

	table.insert(children, monitorSelect())
	return ui.row({ gap = 8, align = "center" }, children)
end

local function emptyState(glyphName, message)
	return ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
		ui.glyph({ name = glyphName, size = 40, color = "on_surface_variant" }),
		ui.label({ text = message, color = "on_surface_variant" }),
	})
end

-- A fixed-height column wrapping a flexing scroll: this both clips the content
-- to exactly VIEWPORT_ROWS rows and keeps the scroll gesture working (setting
-- `height` directly on the scroll disables scrolling).
local function viewport(children)
	return ui.column({ height = viewportHeight(), align = "stretch" }, {
		ui.scroll({ flexGrow = 1, gap = 12, align = "stretch" }, children),
	})
end

local function content()
	if showPalette then
		if not paletteGroups then
			buildPaletteGroups()
		end
		local children = {}
		for _, group in ipairs(paletteGroups or {}) do
			if group.source == paletteSource and #group.items > 0 then
				table.insert(children, grid(group.items, 2, paletteCard))
			end
		end
		if #children == 0 then
			return emptyState("palette", noctalia.tr("palette.empty"))
		end
		return viewport(children)
	end

	if tab == "video" then
		local items = visibleVideos()
		if #items == 0 then
			return emptyState("movie-off", query ~= "" and noctalia.tr("no_match") or noctalia.tr("video.empty"))
		end
		return viewport({ grid(items, GRID_COLUMNS, videoTile) })
	end

	if scanning and #imageEntries == 0 then
		return emptyState("loader-2", noctalia.tr("loading"))
	end

	local items = visibleImages()
	if #items == 0 then
		return emptyState("photo", query ~= "" and noctalia.tr("no_match") or noctalia.tr("image.empty"))
	end
	return viewport({ grid(items, GRID_COLUMNS, imageTile) })
end

render = function()
	if not isOpen then
		return
	end
	panel.render(ui.column({ flexGrow = 1, gap = 12, padding = PANEL_PADDING, align = "stretch" }, {
		header(),
		tabBar(),
		sourceControls(),
		content(),
	}))
end

-- ── Lifecycle ───────────────────────────────────────────────────────────────

function onOpen(_context)
	isOpen = true
	query = ""
	showPalette = false
	tab = "images"
	browseDir = nil

	if not imageDir then
		imageDir = resolveImageDir()
	end
	loadFavorites()
	refreshCurrentScheme()
	scanImages()
end

function onClose()
	isOpen = false
end

noctalia.state.watch("assignments", function(_)
	render()
end)

noctalia.state.watch("paused", function(_)
	render()
end)
