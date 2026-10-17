--!strict

local WallpaperController = {}
WallpaperController.__index = WallpaperController

function WallpaperController.new(session: any, palettes: any, favorites: any, onChange: () -> ())
	return setmetatable({
		session = session,
		palettes = palettes,
		favorites = favorites,
		onChange = onChange,
		nonce = 0,
		pendingKind = "",
		pendingPath = "",
		pendingConnector = "",
		pendingUntil = 0,
	}, WallpaperController)
end

function WallpaperController:nextNonce(): number
	self.nonce = (self.nonce :: number) + 1
	return self.nonce
end

function WallpaperController:selection(): (string?, string?)
	local connector = self.session:connector() or noctalia.focusedOutputName()
	local assignments = noctalia.state.get("assignments") or {}
	local video = assignments[connector] or assignments["*"]
	local kind: string?
	local path: string?
	if type(video) == "string" and video ~= "" then
		kind, path = "video", video
	else
		local output = connector or (noctalia.outputs()[1] and noctalia.outputs()[1].name)
		local image = output and noctalia.wallpaperPath(output)
		if type(image) == "string" and image ~= "" then
			kind, path = "images", image
		end
	end
	if self.pendingPath ~= "" then
		if kind == self.pendingKind and path == self.pendingPath then
			self.pendingPath = ""
		elseif
			noctalia.nowMs() < self.pendingUntil
			and (self.pendingConnector == "*" or self.pendingConnector == connector)
		then
			return self.pendingKind, self.pendingPath
		else
			self.pendingPath = ""
		end
	end
	return kind, path
end

function WallpaperController:expectSelection(kind: string, path: string, connector: string?)
	self.pendingKind = kind
	self.pendingPath = path
	self.pendingConnector = connector or "*"
	self.pendingUntil = noctalia.nowMs() + 3000
	noctalia.runAsync("sleep 3", function()
		self.onChange()
	end)
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
	self:expectSelection("images", path, connector)
	local hadVideo = self:hasVideo()
	local ticket = self:nextNonce()
	if connector then
		noctalia.setWallpaper(connector, path)
	else
		noctalia.setWallpaper(path)
	end
	if hadVideo then
		if connector then
			noctalia.setWallpaperEnabled(connector, true)
		else
			for _, output in ipairs(noctalia.outputs()) do
				noctalia.setWallpaperEnabled(output.name, true)
			end
		end
		noctalia.runAsync("sleep 0.3", function()
			if self.nonce == ticket then
				noctalia.state.set("command", { action = "clear-all", nonce = ticket })
			end
		end)
	end
	local favorite = self.favorites:get("images", path)
	if favorite and favorite.source and favorite.scheme then
		self.palettes:apply(favorite.source, favorite.scheme)
	end
	self.onChange()
end

function WallpaperController:applyVideo(path: string)
	local connector = self.session:connector() or "*"
	self:expectSelection("video", path, connector)
	noctalia.state.set("command", { action = "set", connector = connector, path = path, nonce = self:nextNonce() })
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

function WallpaperController:pauseOrResume()
	noctalia.state.set("command", {
		action = if self:isPaused() then "thaw" else "freeze",
		connector = self.session:connector() or "",
		nonce = self:nextNonce(),
	})
	self.onChange()
end

function WallpaperController:stop()
	self.pendingPath = ""
	local connector = self.session:connector()
	if connector then
		noctalia.state.set("command", { action = "clear", connector = connector, nonce = self:nextNonce() })
	else
		noctalia.state.set("command", { action = "clear-all", nonce = self:nextNonce() })
	end
	self.onChange()
end

return WallpaperController
