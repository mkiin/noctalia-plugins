--!strict

type Job = { path: string, kind: string }

local ThumbnailCache = {}
ThumbnailCache.__index = ThumbnailCache

local function shellQuote(value: string): string
	return "'" .. value:gsub("'", "'\\''") .. "'"
end

function ThumbnailCache.new(onChange: () -> ())
	local base = noctalia.getenv("XDG_CACHE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.cache")
	local self = setmetatable({
		cacheDir = base .. "/noctalia/wallpaper-picker",
		ready = {} :: { [string]: string },
		pending = {} :: { [string]: boolean },
		queued = {} :: { [string]: boolean },
		failed = {} :: { [string]: boolean },
		queue = {} :: { Job },
		active = 0,
		lastRender = 0,
		onChange = onChange,
	}, ThumbnailCache)
	noctalia.mkdirAll(self.cacheDir)
	return self
end

function ThumbnailCache:cachePath(path: string): string
	return (self.cacheDir :: string) .. "/" .. path:gsub("[^%w]", "_") .. ".jpg"
end

function ThumbnailCache:get(path: string): string?
	local ready = self.ready[path]
	if ready then
		return ready
	end
	local cached = self:cachePath(path)
	if noctalia.fileExists(cached) then
		self.ready[path] = cached
		return cached
	end
	return nil
end

function ThumbnailCache:request(path: string, kind: string)
	if self:get(path) or self.pending[path] or self.queued[path] or self.failed[path] then
		return
	end
	self.queued[path] = true
	table.insert(self.queue, { path = path, kind = kind })
	self:pump()
end

function ThumbnailCache:pump()
	while self.active < 4 and #self.queue > 0 do
		local job = table.remove(self.queue, 1)
		if not job then
			break
		end
		local path = job.path
		self.queued[path] = nil
		self.pending[path] = true
		self.active += 1
		local dest: string = self:cachePath(path)
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
			self.pending[path] = nil
			if noctalia.fileExists(dest) then
				self.ready[path] = dest
			else
				self.failed[path] = true
			end
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
