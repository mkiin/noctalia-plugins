--!strict

local builtinPalettes = require("./builtin_palettes.luau")

export type PaletteItem = { source: string, name: string, colors: { string? }, surface: string? }
export type PaletteGroup = { source: string, title: string, items: { PaletteItem } }

local PaletteManager = {}
PaletteManager.__index = PaletteManager

local function shellQuote(value: string): string
	return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function homeDir(): string
	return noctalia.getenv("HOME") or "/tmp"
end

local function stateDir(): string
	return noctalia.getenv("XDG_STATE_HOME") or (homeDir() .. "/.local/state")
end

local function configDir(): string
	return noctalia.getenv("XDG_CONFIG_HOME") or (homeDir() .. "/.config")
end

local function modeFromTable(root: any, mode: string): { colors: { string? }, surface: string? }?
	if type(root) ~= "table" then
		return nil
	end
	local node = root[mode]
	if type(node) ~= "table" then
		node = root
	end
	local function pick(key: string): string?
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

function PaletteManager.new(onChange: () -> ())
	return setmetatable({
		groups = nil :: { PaletteGroup }?,
		source = "builtin",
		currentSource = nil :: string?,
		currentScheme = nil :: string?,
		applyRevision = 0,
		onChange = onChange,
	}, PaletteManager)
end

function PaletteManager:current(): (string?, string?)
	return self.currentSource, self.currentScheme
end

function PaletteManager:selectedSource(): string
	return self.source
end

function PaletteManager:isSelected(item: PaletteItem): boolean
	return self.currentSource == item.source and self.currentScheme == item.name
end

function PaletteManager:refreshCurrent()
	noctalia.runAsync("noctalia msg color-scheme-get", function(result)
		if type(result.stdout) ~= "string" then
			return
		end
		local source, name = result.stdout:match("^(%S+)%s+(.+)$")
		if source and name then
			self.currentSource = source
			self.currentScheme = noctalia.string.trim(name)
			self.onChange()
		end
	end)
end

function PaletteManager:cancelPendingApply()
	self.applyRevision = (self.applyRevision :: number) + 1
end

function PaletteManager:apply(source: string?, name: string?, delayMs: number?)
	self:cancelPendingApply()
	if not source or not name then
		return
	end
	local revision = self.applyRevision
	local function apply()
		if revision ~= self.applyRevision then
			return
		end
		local setting = if source == "wallpaper"
			then "wallpaper_scheme"
			elseif source == "builtin" then "builtin"
			else source .. "_palette"
		if noctalia.getSetting("theme.source") ~= source or noctalia.getSetting("theme." .. setting) ~= name then
			noctalia.runAsync("noctalia msg color-scheme-set " .. shellQuote(source) .. " " .. shellQuote(name))
		end
		self.currentSource = source
		self.currentScheme = name
		self.onChange()
	end
	if delayMs and delayMs > 0 then
		noctalia.runAsync({ "sleep", tostring(delayMs / 1000) }, apply)
	else
		apply()
	end
end

function PaletteManager:toggleMode()
	self:cancelPendingApply()
	noctalia.runAsync("noctalia msg theme-mode-toggle")
	noctalia.runAsync("sleep 0.3", function()
		self.groups = nil
		self.onChange()
	end)
end

function PaletteManager:refresh()
	self.groups = nil
	self.onChange()
end

function PaletteManager:getGroups(): { PaletteGroup }
	if self.groups then
		return self.groups
	end
	local mode = if noctalia.isDarkMode() then "dark" else "light"
	local groups: { PaletteGroup } = {}
	local builtinItems: { PaletteItem } = {}
	for _, palette in ipairs(builtinPalettes) do
		local colors = palette[mode] or palette.dark
		table.insert(builtinItems, {
			source = "builtin",
			name = palette.name,
			colors = { colors[1], colors[2], colors[3], colors[4] },
			surface = colors[5],
		})
	end
	table.insert(groups, { source = "builtin", title = noctalia.tr("palette.builtin"), items = builtinItems })

	local communityItems: { PaletteItem } = {}
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

	local customItems: { PaletteItem } = {}
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

	self.groups = groups
	local valid = false
	for _, group in ipairs(groups) do
		if group.source == self.source and #group.items > 0 then
			valid = true
		end
	end
	if not valid then
		for _, group in ipairs(groups) do
			if #group.items > 0 then
				self.source = group.source
				break
			end
		end
	end
	return groups
end

function PaletteManager:selectSource(source: string)
	for _, group in ipairs(self:getGroups()) do
		if group.source == source and #group.items > 0 then
			self.source = source
			self.onChange()
			return
		end
	end
end

return PaletteManager
