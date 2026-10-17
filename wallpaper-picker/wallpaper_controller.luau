--!strict

local WallpaperController = {}
WallpaperController.__index = WallpaperController

function WallpaperController.new(session: any, palettes: any, favorites: any, onChange: () -> ())
	return setmetatable({
		session = session,
		palettes = palettes,
		favorites = favorites,
		onChange = onChange,
		selectedKind = "",
		selectedPath = "",
		nonce = 0,
	}, WallpaperController)
end

function WallpaperController:nextNonce(): number
	self.nonce = (self.nonce :: number) + 1
	return self.nonce
end

function WallpaperController:selection(): (string?, string?)
	if self.selectedPath == "" then
		return nil, nil
	end
	return self.selectedKind, self.selectedPath
end

function WallpaperController:isSelected(kind: string, path: string): boolean
	return self.selectedKind == kind and self.selectedPath == path
end

function WallpaperController:syncSelection()
	local connector = self.session:connector() or noctalia.focusedOutputName()
	local assignments = noctalia.state.get("assignments") or {}
	local video = assignments[connector] or assignments["*"]
	if type(video) == "string" and video ~= "" then
		self.selectedKind = "video"
		self.selectedPath = video
	else
		local output = connector or (noctalia.outputs()[1] and noctalia.outputs()[1].name)
		local image = output and noctalia.wallpaperPath(output)
		self.selectedKind = if image then "images" else ""
		self.selectedPath = image or ""
	end
	self.onChange()
end

function WallpaperController:hasVideo(): boolean
	local assignments = noctalia.state.get("assignments") or {}
	if self.session.monitorIndex <= 0 then
		return next(assignments) ~= nil
	end
	local connector = self.session:connector()
	return assignments[connector] ~= nil or assignments["*"] ~= nil
end

function WallpaperController:isPaused(): boolean
	local paused = noctalia.state.get("paused") or {}
	if self.session.monitorIndex <= 0 then
		for _, value in pairs(paused) do
			if value then
				return true
			end
		end
		return false
	end
	local connector = self.session:connector()
	return paused[connector] == true or paused["*"] == true
end

function WallpaperController:applyImage(path: string)
	local connector = self.session:connector()
	noctalia.state.set("command", { action = "clear-all", nonce = self:nextNonce() })
	if connector then
		noctalia.setWallpaper(connector, path)
	else
		noctalia.setWallpaper(path)
	end
	self.selectedKind = "images"
	self.selectedPath = path
	local favorite = self.favorites:get("images", path)
	if favorite and favorite.source and favorite.scheme then
		self.palettes:apply(favorite.source, favorite.scheme)
	end
	self.onChange()
end

function WallpaperController:applyVideo(path: string)
	local connector = self.session:connector() or "*"
	noctalia.state.set("command", { action = "set", connector = connector, path = path, nonce = self:nextNonce() })
	self.selectedKind = "video"
	self.selectedPath = path
	local favorite = self.favorites:get("video", path)
	if favorite and favorite.source and favorite.scheme then
		self.palettes:apply(favorite.source, favorite.scheme)
	end
	self.onChange()
end

function WallpaperController:toggleFavorite(): boolean?
	local kind, path = self:selection()
	if not kind or not path then
		return nil
	end
	local source, scheme = self.palettes:current()
	local selected = self.favorites:toggle(kind, path, source, scheme)
	self.onChange()
	return selected
end

function WallpaperController:isFavorite(): boolean
	local kind, path = self:selection()
	return kind ~= nil and path ~= nil and self.favorites:get(kind, path) ~= nil
end

function WallpaperController:pauseOrResume()
	noctalia.state.set("command", {
		action = if self:isPaused() then "thaw" else "freeze",
		connector = self.session:connector() or "",
		nonce = self:nextNonce(),
	})
	self.onChange()
end

function WallpaperController:stop()
	local connector = self.session:connector()
	if connector then
		noctalia.state.set("command", { action = "clear", connector = connector, nonce = self:nextNonce() })
	else
		noctalia.state.set("command", { action = "clear-all", nonce = self:nextNonce() })
	end
	self.onChange()
end

return WallpaperController
