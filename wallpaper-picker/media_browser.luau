--!strict

export type ImageEntry = { path: string, name: string, isDir: boolean }
export type VideoEntry = { path: string, name: string }

local IMAGE_EXTENSIONS = { jpg = true, jpeg = true, png = true, webp = true, bmp = true, avif = true, gif = true }
local VIDEO_EXTENSIONS = { mp4 = true, webm = true, mkv = true, mov = true, gif = true }

local MediaBrowser = {}
MediaBrowser.__index = MediaBrowser

local function homeDir(): string
	return noctalia.getenv("HOME") or "/tmp"
end

local function imageDirectory(): string
	local configured = noctalia.getConfig("image_directory")
	if type(configured) == "string" and configured ~= "" then
		return noctalia.expandPath(configured)
	end
	return noctalia.wallpaperDirectory() or (homeDir() .. "/Pictures")
end

local function videoDirectory(): string
	local configured = noctalia.getConfig("video_directory")
	if type(configured) == "string" and configured ~= "" then
		return noctalia.expandPath(configured)
	end
	return homeDir() .. "/Videos"
end

function MediaBrowser.new(thumbnails: any, onChange: () -> ())
	local directory = imageDirectory()
	return setmetatable({
		thumbnails = thumbnails,
		onChange = onChange,
		imageDir = directory,
		browseDir = directory,
		query = "",
		sortMode = "name",
		randomOrder = {} :: { [string]: number },
		imageEntries = {} :: { ImageEntry },
		videoEntries = {} :: { VideoEntry },
		videoScanned = false,
		scanning = false,
	}, MediaBrowser)
end

function MediaBrowser:reset()
	self.imageDir = imageDirectory()
	self.browseDir = self.imageDir
	self.query = ""
	self:scanImages()
end

function MediaBrowser:setQuery(value: string)
	self.query = value
	self.onChange()
end

function MediaBrowser:getQuery(): string
	return self.query
end

function MediaBrowser:getSortMode(): string
	return self.sortMode
end

function MediaBrowser:cycleSort()
	if self.sortMode == "name" then
		self.sortMode = "name_desc"
	elseif self.sortMode == "name_desc" then
		self.sortMode = "random"
		self.randomOrder = {}
		for _, item in ipairs(self.imageEntries) do
			self.randomOrder[item.path] = math.random()
		end
	else
		self.sortMode = "name"
	end
	self.onChange()
end

function MediaBrowser:isInSubfolder(): boolean
	return self.browseDir ~= self.imageDir
end

function MediaBrowser:currentFolder(): string
	return self.browseDir
end

function MediaBrowser:enterFolder(path: string)
	self.browseDir = path
	self:scanImages()
end

function MediaBrowser:goUp()
	local dir = self.browseDir
	if dir == self.imageDir then
		return
	end
	local parent = dir:match("^(.*)/[^/]+$")
	if parent and parent ~= self.imageDir then
		self.browseDir = parent
	else
		self.browseDir = self.imageDir
	end
	self:scanImages()
end

function MediaBrowser:scanImages()
	self.scanning = true
	self.onChange()
	local dir = self:currentFolder()
	local names = noctalia.listDir(dir)
	local items: { ImageEntry } = {}
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
	self.imageEntries = items
	self.scanning = false
	if self.sortMode == "random" then
		for _, item in ipairs(items) do
			if not self.randomOrder[item.path] then
				self.randomOrder[item.path] = math.random()
			end
		end
	end
	for _, item in ipairs(items) do
		if not item.isDir then
			self.thumbnails:request(item.path, "image")
		end
	end
	self.onChange()
end

function MediaBrowser:scanVideos()
	local dir = videoDirectory()
	local names = noctalia.listDir(dir)
	local items: { VideoEntry } = {}
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
	self.videoEntries = items
	self.videoScanned = true
	for _, item in ipairs(items) do
		self.thumbnails:request(item.path, "video")
	end
	self.onChange()
end

function MediaBrowser:ensureVideos()
	if not self.videoScanned then
		self:scanVideos()
	end
end

function MediaBrowser:refresh(tab: string)
	if tab == "video" then
		self:scanVideos()
	else
		self:scanImages()
	end
end

function MediaBrowser:isScanning(): boolean
	return self.scanning
end

function MediaBrowser:visibleImages(): { ImageEntry }
	local q = self.query:lower()
	local out: { ImageEntry } = {}
	for _, item in ipairs(self.imageEntries) do
		if q == "" or item.name:lower():find(q, 1, true) then
			table.insert(out, item)
		end
	end
	if self.sortMode == "name" then
		table.sort(out, function(a, b)
			if a.isDir ~= b.isDir then
				return a.isDir
			end
			return a.name:lower() < b.name:lower()
		end)
	elseif self.sortMode == "name_desc" then
		table.sort(out, function(a, b)
			if a.isDir ~= b.isDir then
				return a.isDir
			end
			return a.name:lower() > b.name:lower()
		end)
	else
		table.sort(out, function(a, b)
			return (self.randomOrder[a.path] or 0) < (self.randomOrder[b.path] or 0)
		end)
	end
	return out
end

function MediaBrowser:visibleVideos(): { VideoEntry }
	local q = self.query:lower()
	if q == "" then
		return self.videoEntries
	end
	local out: { VideoEntry } = {}
	for _, item in ipairs(self.videoEntries) do
		if item.name:lower():find(q, 1, true) then
			table.insert(out, item)
		end
	end
	return out
end

return MediaBrowser
