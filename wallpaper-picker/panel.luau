--!strict

local PickerCoordinator = require("./picker_coordinator.luau")
local MediaBrowser = require("./media_browser.luau")
local PaletteManager = require("./palette_manager.luau")

type ImageEntry = MediaBrowser.ImageEntry
type VideoEntry = MediaBrowser.VideoEntry
type PaletteItem = PaletteManager.PaletteItem

local PANEL_WIDTH = 1000
local PANEL_PADDING = 24
local GRID_COLUMNS = 4
local GRID_GAP = 12
local TILE_RADIUS = 12
local CONTENT_WIDTH = PANEL_WIDTH - PANEL_PADDING * 2 - 16
local TILE_IMAGE_H = math.floor(((CONTENT_WIDTH - GRID_GAP * (GRID_COLUMNS - 1)) / GRID_COLUMNS) * 0.72)
local TILE_INNER_GAP = 6
local NAME_H = 22
local VIEWPORT_ROWS = 2

local function tileHeight(): number
	return TILE_IMAGE_H + TILE_INNER_GAP + NAME_H
end

local function viewportHeight(): number
	return tileHeight() * VIEWPORT_ROWS + GRID_GAP
end

local function activeVariant(selected: boolean): "primary" | "outline"
	return if selected then "primary" else "outline"
end

local function toolbarVariant(selected: boolean): "primary" | "default"
	return if selected then "primary" else "default"
end

local function paletteDots(colors: { string? }?, diameter: number): UiNode
	local dots = {}
	for _, color in ipairs(colors or {}) do
		if type(color) == "string" then
			table.insert(dots, ui.box({ width = diameter, height = diameter, radius = diameter * 0.5, fill = color }))
		end
	end
	return ui.row({ gap = 4, align = "center" }, dots)
end

local function grid<T>(items: { T }, columns: number, nodeFor: (T) -> UiNode): UiNode
	local rows = {}
	local row = {}
	for index, item in ipairs(items) do
		table.insert(row, nodeFor(item))
		if #row == columns or index == #items then
			for _ = #row + 1, columns do
				table.insert(row, ui.spacer({ flexGrow = 1 }))
			end
			table.insert(rows, ui.row({ gap = GRID_GAP, align = "stretch" }, row))
			row = {}
		end
	end
	return ui.column({ gap = GRID_GAP, align = "stretch" }, rows)
end

local function emptyState(glyph: string, message: string): UiNode
	return ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
		ui.glyph({ name = glyph, size = 40, color = "on_surface_variant" }),
		ui.label({ text = message, color = "on_surface_variant" }),
	})
end

local function viewport(children: { UiNode }): UiNode
	return ui.column({ height = viewportHeight(), align = "stretch" }, {
		ui.scroll({ flexGrow = 1, gap = 12, align = "stretch" }, children),
	})
end

local PickerPanel = {}
PickerPanel.__index = PickerPanel

function PickerPanel.new()
	local self = setmetatable({ isOpen = false, view = nil :: any }, PickerPanel)
	local onChange = function()
		self:render()
	end
	self.coordinator = PickerCoordinator.new(onChange)
	return self
end

function PickerPanel:header(): UiNode
	return ui.row({ gap = 8, align = "center" }, {
		ui.glyph({ name = "photo", size = 20, color = "primary" }),
		ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold" }),
	})
end

function PickerPanel:tabBar(): UiNode
	local view = self.view
	local isFavorite = view.isFavorite
	local children = {
		ui.button({
			text = noctalia.tr("tab.images"),
			variant = activeVariant(view.tab == "images"),
			onClick = function()
				self.coordinator:dispatch("select-tab", "images")
			end,
		}),
		ui.button({
			text = noctalia.tr("tab.video"),
			variant = activeVariant(view.tab == "video"),
			onClick = function()
				self.coordinator:dispatch("select-tab", "video")
			end,
		}),
		ui.spacer({ flexGrow = 1 }),
		ui.button({
			key = "favorite-wallpaper",
			glyph = if isFavorite then "star-filled" else "star",
			variant = if isFavorite then "primary" else "default",
			enabled = view.hasWallpaper,
			tooltip = if not view.hasWallpaper
				then noctalia.tr("favorite.unavailable")
				else if isFavorite then noctalia.tr("favorite.remove") else noctalia.tr("favorite.add"),
			onClick = function()
				self.coordinator:dispatch("toggle-favorite")
			end,
		}),
		ui.button({
			glyph = if view.isDark then "moon" else "sun",
			variant = "default",
			tooltip = noctalia.tr("theme-mode"),
			onClick = function()
				self.coordinator:dispatch("toggle-theme")
			end,
		}),
		ui.button({
			glyph = "palette",
			variant = toolbarVariant(view.showPalette),
			tooltip = noctalia.tr("palette.title"),
			onClick = function()
				self.coordinator:dispatch("toggle-palette")
			end,
		}),
		ui.button({
			glyph = "refresh",
			variant = "default",
			tooltip = noctalia.tr("refresh"),
			onClick = function()
				self.coordinator:dispatch("refresh")
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

function PickerPanel:monitorSelect(): UiNode
	return ui.select({
		key = "monitor",
		options = self.view.outputs,
		selectedIndex = self.view.monitorIndex,
		width = 200,
		onChange = function(index)
			self.coordinator:dispatch("select-monitor", tostring(index))
		end,
	})
end

function PickerPanel:paletteTabs(): UiNode
	local children = {
		ui.button({
			glyph = "arrow-left",
			variant = "default",
			tooltip = noctalia.tr("back"),
			onClick = function()
				self.coordinator:dispatch("back-from-palette")
			end,
		}),
		ui.label({ text = noctalia.tr("palette.title"), fontSize = 14, fontWeight = "bold", flexGrow = 1 }),
	}
	for _, group in ipairs(self.view.paletteGroups) do
		if #group.items > 0 then
			local source = group.source
			table.insert(
				children,
				ui.button({
					text = group.title,
					variant = activeVariant(self.view.paletteSource == source),
					onClick = function()
						self.coordinator:dispatch("palette-source", source)
					end,
				})
			)
		end
	end
	return ui.row({ gap = 8, align = "center" }, children)
end

function PickerPanel:sourceControls(): UiNode
	if self.view.showPalette then
		return self:paletteTabs()
	end
	local children = {
		ui.input({
			key = "search",
			value = self.view.query,
			placeholder = noctalia.tr("search"),
			flexGrow = 1,
			onChange = function(value)
				self.coordinator:dispatch("search", value)
			end,
		}),
	}
	if self.view.tab == "images" then
		if self.view.inSubfolder then
			table.insert(
				children,
				ui.button({
					glyph = "arrow-up",
					text = noctalia.tr("browse.up"),
					variant = "default",
					tooltip = self.view.folder,
					onClick = function()
						self.coordinator:dispatch("up-folder")
					end,
				})
			)
		end
		local mode = self.view.sortMode
		local sortLabel = if mode == "name"
			then noctalia.tr("sort.name")
			else if mode == "name_desc" then noctalia.tr("sort.name_desc") else noctalia.tr("sort.random")
		table.insert(
			children,
			ui.button({
				glyph = if mode == "name"
					then "sort-ascending"
					else if mode == "name_desc" then "sort-descending" else "arrows-shuffle",
				text = sortLabel,
				variant = "default",
				tooltip = noctalia.tr("sort.change"),
				onClick = function()
					self.coordinator:dispatch("sort")
				end,
			})
		)
	else
		table.insert(
			children,
			ui.button({
				glyph = if self.view.paused then "player-play" else "player-pause",
				variant = "default",
				enabled = self.view.hasVideo,
				tooltip = if self.view.paused then noctalia.tr("resume") else noctalia.tr("pause"),
				onClick = function()
					self.coordinator:dispatch("pause-or-resume")
				end,
			})
		)
		table.insert(
			children,
			ui.button({
				glyph = "player-stop",
				variant = "default",
				enabled = self.view.hasVideo,
				tooltip = noctalia.tr("stop"),
				onClick = function()
					self.coordinator:dispatch("stop")
				end,
			})
		)
	end
	table.insert(children, self:monitorSelect())
	return ui.row({ gap = 8, align = "center" }, children)
end

function PickerPanel:imageTile(item: ImageEntry): UiNode
	if item.isDir then
		local directory = ui.column({
			height = TILE_IMAGE_H,
			fill = "surface_variant",
			radius = TILE_RADIUS,
			border = "outline",
			borderWidth = 1,
			align = "center",
			justify = "center",
			tooltip = item.path,
			onClick = function()
				self.coordinator:dispatch("enter-folder", item.path)
			end,
		}, { ui.glyph({ name = "folder", size = 44, color = "primary" }) })
		local children = { directory }
		if self.view.showNames then
			table.insert(children, ui.label({ text = item.name, fontSize = 12, color = "on_surface", maxLines = 1 }))
		end
		return ui.column(
			{ key = "dir:" .. item.path, flexGrow = 1, height = tileHeight(), gap = TILE_INNER_GAP },
			children
		)
	end
	return self:mediaTile("images", item.path, item.name)
end

function PickerPanel:videoTile(item: VideoEntry): UiNode
	return self:mediaTile("video", item.path, item.name)
end

function PickerPanel:mediaTile(kind: string, path: string, name: string): UiNode
	local selected = self.view.selectedKind == kind and self.view.selectedPath == path
	local favorite = self.coordinator:favorite(kind, path)
	local preview = self.coordinator:thumbnail(path)
	local border = if selected then "primary" else if favorite then "tertiary" else "outline"
	local action = function()
		self.coordinator:dispatch(if kind == "video" then "apply-video" else "apply-image", path)
	end
	local image: UiNode
	if preview then
		image = ui.image({
			key = "preview:" .. path .. ":" .. border,
			path = preview,
			height = TILE_IMAGE_H,
			fit = "cover",
			radius = TILE_RADIUS,
			border = border,
			borderWidth = if selected or favorite then 2 else 1,
			tooltip = name,
			onClick = action,
		})
	else
		image = ui.column({
			key = "placeholder:" .. path .. ":" .. border,
			height = TILE_IMAGE_H,
			fill = "surface_variant",
			radius = TILE_RADIUS,
			border = border,
			borderWidth = if selected or favorite then 2 else 1,
			align = "center",
			justify = "center",
			tooltip = name,
			onClick = action,
		}, {
			ui.glyph({
				name = if kind == "video" then "movie" else "photo",
				size = 32,
				color = "on_surface_variant",
			}),
		})
	end
	local children = { image }
	if self.view.showNames or favorite then
		local labels = {}
		if self.view.showNames then
			table.insert(
				labels,
				ui.label({ text = name, fontSize = 12, maxLines = 1, flexGrow = 1, color = "on_surface" })
			)
		else
			table.insert(labels, ui.spacer({ flexGrow = 1 }))
		end
		if favorite then
			table.insert(labels, paletteDots(favorite.palette, 12))
		end
		table.insert(children, ui.row({ gap = 6, align = "center" }, labels))
	end
	return ui.column({ key = "tile:" .. path, flexGrow = 1, height = tileHeight(), gap = TILE_INNER_GAP }, children)
end

function PickerPanel:paletteCard(item: PaletteItem): UiNode
	local selected = self.view.currentSource == item.source and self.view.currentScheme == item.name
	return ui.row({
		key = "pal:" .. item.source .. ":" .. item.name,
		flexGrow = 1,
		fill = item.surface or "surface_variant",
		radius = 10,
		padding = 10,
		gap = 8,
		align = "center",
		border = if selected then "primary" else "outline",
		borderWidth = if selected then 2 else 1,
		onClick = function()
			self.coordinator:dispatch("palette-apply", item.source, item.name)
		end,
	}, {
		ui.label({ text = item.name, fontSize = 12, flexGrow = 1, maxLines = 1, color = "on_surface" }),
		paletteDots(item.colors, 16),
	})
end

function PickerPanel:content(): UiNode
	if self.view.showPalette then
		for _, group in ipairs(self.view.paletteGroups) do
			if group.source == self.view.paletteSource then
				return viewport({ grid(group.items, 2, function(item)
					return self:paletteCard(item)
				end) })
			end
		end
		return emptyState("palette", noctalia.tr("palette.empty"))
	end
	local query = self.view.query
	if self.view.tab == "video" then
		local items = self.view.videos
		if #items == 0 then
			return emptyState("movie-off", if query ~= "" then noctalia.tr("no_match") else noctalia.tr("video.empty"))
		end
		return viewport({ grid(items, GRID_COLUMNS, function(item)
			return self:videoTile(item)
		end) })
	end
	local items = self.view.images
	if self.view.scanning and #items == 0 then
		return emptyState("loader-2", noctalia.tr("loading"))
	end
	if #items == 0 then
		return emptyState("photo", if query ~= "" then noctalia.tr("no_match") else noctalia.tr("image.empty"))
	end
	return viewport({ grid(items, GRID_COLUMNS, function(item)
		return self:imageTile(item)
	end) })
end

function PickerPanel.render(self: any)
	if not self.isOpen then
		return
	end
	self.view = self.coordinator:snapshot()
	panel.render(ui.column({ flexGrow = 1, gap = 12, padding = PANEL_PADDING, align = "stretch" }, {
		self:header(),
		self:tabBar(),
		self:sourceControls(),
		self:content(),
	}))
end

function PickerPanel.open(self: any)
	self.isOpen = true
	self.coordinator:open()
end

function PickerPanel:close()
	self.isOpen = false
end

local picker: any = PickerPanel.new()

function onOpen(_context)
	picker:open()
end

function onClose()
	picker:close()
end

noctalia.state.watch("assignments", function()
	picker.coordinator:assignmentsChanged()
end)

noctalia.state.watch("paused", function()
	picker.coordinator:pausedChanged()
end)
