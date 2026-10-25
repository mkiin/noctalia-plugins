--!strict

type Job = { path: string, kind: string }

local ThumbnailCache = {}
ThumbnailCache.__index = ThumbnailCache

local function shellQuote(value: string): string
	return "'" .. value:gsub("'", "'\\''") .. "'"
end

function ThumbnailCache.new(onChange: () -> ())
	local base = noctalia.getenv("XDG_CACHE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.cache")
	local dataDir = noctalia.pluginDataDir()
	local self = setmetatable({
		cacheDir = base .. "/noctalia/wallpaper-picker",
		videoDir = if dataDir then dataDir .. "/video-thumbnails" else nil,
		ready = {} :: { [string]: string },
		pending = {} :: { [string]: boolean },
		queued = {} :: { [string]: boolean },
		failed = {} :: { [string]: boolean },
		waiters = {} :: { [string]: { (string?) -> () } },
		queue = {} :: { Job },
		active = 0,
		lastRender = 0,
		onChange = onChange,
	}, ThumbnailCache)
	noctalia.mkdirAll(self.cacheDir)
	if self.videoDir and not noctalia.mkdirAll(self.videoDir) then
		self.videoDir = nil
	end
	return self
end

function ThumbnailCache:cachePath(path: string, kind: string): string
	if kind == "video" then
		local info = noctalia.fileInfo(path)
		local identity = path .. ":" .. tostring(info and info.size) .. ":" .. tostring(info and info.mtime)
		local hash = 5381
		for index = 1, #identity do
			hash = (hash * 33 + identity:byte(index)) % 4294967296
		end
		return (self.videoDir :: string) .. "/" .. string.format("%08x.jpg", hash)
	end
	return (self.cacheDir :: string) .. "/" .. path:gsub("[^%w]", "_") .. ".jpg"
end

function ThumbnailCache:get(path: string, kind: string): string?
	if kind == "video" and not self.videoDir then
		return nil
	end
	local cached = self:cachePath(path, kind)
	local ready = self.ready[cached]
	if ready then
		return ready
	end
	if noctalia.fileExists(cached) then
		self.ready[cached] = cached
		return cached
	end
	return nil
end

function ThumbnailCache:request(path: string, kind: string, onReady: ((string?) -> ())?)
	local key = kind .. ":" .. path
	local cached = self:get(path, kind)
	if cached then
		if onReady then
			onReady(cached)
		end
		return
	end
	if self.failed[key] or (kind == "video" and not self.videoDir) then
		if onReady then
			onReady(nil)
		end
		return
	end
	if onReady then
		self.waiters[key] = self.waiters[key] or {}
		table.insert(self.waiters[key], onReady)
	end
	if self.pending[key] or self.queued[key] then
		return
	end
	self.queued[key] = true
	table.insert(self.queue, { path = path, kind = kind })
	self:pump()
end

function ThumbnailCache:pump()
	while self.active < 4 and #self.queue > 0 do
		local job: Job? = table.remove(self.queue, 1)
		if not job then
			break
		end
		local path = job.path
		local key = job.kind .. ":" .. path
		self.queued[key] = nil
		self.pending[key] = true
		self.active += 1
		local dest: string = self:cachePath(path, job.kind)
		local command
		if job.kind == "video" then
			local temporary = dest .. ".d"
			command = "mkdir -p "
				.. shellQuote(temporary)
				.. " && mpv "
				.. shellQuote(path)
				.. " --no-config --no-terminal --really-quiet --frames=1 --start=10% --no-audio"
				.. " --vo=image --vo-image-format=jpg --vo-image-outdir="
				.. shellQuote(temporary)
				.. " && mv "
				.. shellQuote(temporary .. "/00000001.jpg")
				.. " "
				.. shellQuote(dest)
				.. "; rm -rf "
				.. shellQuote(temporary)
		else
			command = "ffmpeg -y -i " .. shellQuote(path) .. " -vf scale=520:-1 -q:v 4 " .. shellQuote(dest)
		end
		noctalia.runAsync(command, function()
			self.active -= 1
			self.pending[key] = nil
			if noctalia.fileExists(dest) then
				self.ready[dest] = dest
			else
				self.failed[key] = true
			end
			for _, callback in ipairs(self.waiters[key] or {}) do
				callback(self.ready[dest])
			end
			self.waiters[key] = nil
			self:pump()
			local now = noctalia.nowMs()
			if self.active == 0 and #self.queue == 0 or now - self.lastRender >= 150 then
				self.lastRender = now
				self.onChange()
			end
		end, 30000)
	end
end

return ThumbnailCache
