--!strict

local PickerSession = require("./picker_session.luau")
local ThumbnailCache = require("./thumbnail_cache.luau")
local MediaBrowser = require("./media_browser.luau")
local FavoriteStore = require("./favorite_store.luau")
local PaletteManager = require("./palette_manager.luau")
local WallpaperController = require("./wallpaper_controller.luau")

local PickerCoordinator = {}
PickerCoordinator.__index = PickerCoordinator

function PickerCoordinator.new(onChange: () -> ())
	local session = PickerSession.new()
	local thumbnails = ThumbnailCache.new(onChange)
	local browser = MediaBrowser.new(thumbnails, onChange)
	local favorites = FavoriteStore.new()
	local palettes = PaletteManager.new(onChange)
	local wallpapers = WallpaperController.new(session, palettes, favorites, onChange)
	return setmetatable({
		session = session,
		thumbnails = thumbnails,
		browser = browser,
		favorites = favorites,
		palettes = palettes,
		wallpapers = wallpapers,
		onChange = onChange,
	}, PickerCoordinator)
end

function PickerCoordinator:open()
	self.session:reset()
	self.favorites:load()
	self.palettes:refreshCurrent()
	self.browser:reset()
	self.onChange()
end

function PickerCoordinator:assignmentsChanged()
	self.onChange()
end

function PickerCoordinator:pausedChanged()
	self.onChange()
end

function PickerCoordinator:thumbnail(path: string): string?
	return self.thumbnails:get(path)
end

function PickerCoordinator:favorite(kind: string, path: string): FavoriteStore.Favorite?
	return self.favorites:get(kind, path)
end

function PickerCoordinator:snapshot()
	local kind, path = self.wallpapers:selection()
	local currentSource, currentScheme = self.palettes:current()
	local names = { noctalia.tr("all_outputs") }
	for _, output in ipairs(noctalia.outputs()) do
		table.insert(names, output.name)
	end
	return {
		tab = self.session.tab,
		showPalette = self.session.showPalette,
		monitorIndex = self.session.monitorIndex,
		outputs = names,
		query = self.browser:getQuery(),
		sortMode = self.browser:getSortMode(),
		inSubfolder = self.browser:isInSubfolder(),
		folder = self.browser:currentFolder(),
		images = self.browser:visibleImages(),
		videos = self.browser:visibleVideos(),
		scanning = self.browser:isScanning(),
		paletteGroups = if self.session.showPalette then self.palettes:getGroups() else {},
		paletteSource = self.palettes:selectedSource(),
		paletteQuery = self.session.paletteQuery,
		paletteHover = self.session.paletteHover,
		currentSource = currentSource,
		currentScheme = currentScheme,
		selectedKind = kind,
		selectedPath = path,
		hasWallpaper = kind ~= nil and path ~= nil,
		isFavorite = kind ~= nil and path ~= nil and self.favorites:get(kind, path) ~= nil,
		hasVideo = self.wallpapers:hasVideo(),
		paused = self.wallpapers:isPaused(),
		isDark = noctalia.isDarkMode(),
		showNames = noctalia.getConfig("show_names") ~= false,
	}
end

function PickerCoordinator:dispatch(action: string, value: string?, extra: string?)
	if action == "select-tab" and value then
		self.session:selectTab(value)
		if value == "video" then
			self.browser:ensureVideos()
		end
	elseif action == "select-monitor" and value then
		self.session:selectMonitor(tonumber(value) or 0)
	elseif action == "toggle-palette" then
		self.session:togglePalette()
		if self.session.showPalette then
			self.palettes:getGroups()
		end
	elseif action == "back-from-palette" then
		if self.session.showPalette then
			self.session:togglePalette()
		end
	elseif action == "palette-source" and value then
		self.palettes:selectSource(value)
	elseif action == "palette-search" then
		self.session:setPaletteQuery(value or "")
	elseif action == "palette-hover" then
		self.session:setPaletteHover(if value == nil or value == "" then nil else value)
	elseif action == "palette-apply" and value and extra then
		self.palettes:apply(value, extra)
	elseif action == "toggle-theme" then
		self.palettes:toggleMode()
	elseif action == "refresh" then
		self.palettes:refresh()
		self.browser:refresh(self.session.tab)
	elseif action == "search" and value then
		self.browser:setQuery(value)
	elseif action == "up-folder" then
		self.browser:goUp()
	elseif action == "sort" then
		self.browser:cycleSort()
	elseif action == "enter-folder" and value then
		self.browser:enterFolder(value)
	elseif action == "apply-image" and value then
		self.wallpapers:applyImage(value)
	elseif action == "apply-video" and value then
		self.wallpapers:applyVideo(value)
	elseif action == "toggle-favorite" then
		self.wallpapers:toggleFavorite()
	elseif action == "pause-or-resume" then
		self.wallpapers:pauseOrResume()
	elseif action == "stop" then
		self.wallpapers:stop()
	end
	self.onChange()
end

return PickerCoordinator
