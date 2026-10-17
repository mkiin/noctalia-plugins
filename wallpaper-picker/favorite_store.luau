--!strict

export type Favorite = { palette: { string }, source: string?, scheme: string?, mode: string }
type FavoriteMap = { [string]: Favorite }
type FavoriteData = { images: FavoriteMap, videos: FavoriteMap }

local FavoriteStore = {}
FavoriteStore.__index = FavoriteStore

local function dataDirectory(): string
	local fallback = noctalia.getenv("XDG_CACHE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.cache")
	return noctalia.pluginDataDir() or (fallback .. "/noctalia/wallpaper-picker")
end

function FavoriteStore.new()
	local directory = dataDirectory()
	noctalia.mkdirAll(directory)
	return setmetatable({
		file = directory .. "/favorites.json",
		data = { images = {} :: FavoriteMap, videos = {} :: FavoriteMap } :: FavoriteData,
	}, FavoriteStore)
end

function FavoriteStore:load()
	local content = noctalia.readFile(self.file)
	if type(content) ~= "string" or content == "" then
		return
	end
	local decoded = noctalia.json.decode(content)
	if type(decoded) == "table" then
		self.data.images = if type(decoded.images) == "table" then decoded.images else {}
		self.data.videos = if type(decoded.videos) == "table" then decoded.videos else {}
	end
end

function FavoriteStore:get(kind: string, path: string): Favorite?
	local collection: FavoriteMap = self.data.images
	if kind == "video" then
		collection = self.data.videos
	end
	return collection[path]
end

function FavoriteStore:toggle(kind: string, path: string, source: string?, scheme: string?): boolean
	local collection: FavoriteMap = self.data.images
	if kind == "video" then
		collection = self.data.videos
	end
	local selected = collection[path] == nil
	if selected then
		collection[path] = {
			palette = {
				noctalia.getColor("primary") or "#808080",
				noctalia.getColor("secondary") or "#808080",
				noctalia.getColor("tertiary") or "#808080",
				noctalia.getColor("error") or "#808080",
			},
			source = source,
			scheme = scheme,
			mode = if noctalia.isDarkMode() then "dark" else "light",
		}
	else
		collection[path] = nil
	end
	noctalia.writeFile(self.file, noctalia.json.encode(self.data) or '{ "images": {}, "videos": {} }')
	return selected
end

return FavoriteStore
