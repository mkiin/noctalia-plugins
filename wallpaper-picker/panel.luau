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
local PALETTE_CARD_WIDTH = 460
local PALETTE_CARD_HEIGHT = 380
local PALETTE_ROW_H = 34

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

function PickerPanel:paletteRow(item: PaletteItem): UiNode
	local selected = self.view.currentSource == item.source and self.view.currentScheme == item.name
	local key = "pal:" .. item.source .. ":" .. item.name
	local hovered = self.view.paletteHover == key
	local fill = if selected then "primary/0.16" else if hovered then "hover" else "#00000000"
	local color = if hovered then "on_hover" else "on_surface"
	return ui.row({
		key = key,
		height = PALETTE_ROW_H,
		fill = fill,
		border = if selected then "primary" else "outline",
		borderWidth = if selected then 2 else 1,
		radius = 8,
		paddingH = 10,
		gap = 10,
		align = "center",
		onClick = function()
			self.coordinator:dispatch("palette-apply", item.source, item.name)
		end,
		onHover = function(state: string)
			self.coordinator:dispatch("palette-hover", if state == "true" then key else "")
		end,
	}, {
		paletteDots(item.colors, 12),
		ui.label({ text = item.name, fontSize = 13, flexGrow = 1, maxLines = 1, color = color }),
	})
end

function PickerPanel:palettePopup(): UiNode
	local view = self.view
	local group = nil :: PaletteManager.PaletteGroup?
	for _, candidate in ipairs(view.paletteGroups) do
		if candidate.source == view.paletteSource then
			group = candidate
			break
		end
	end
	local title = if group then group.title else noctalia.tr("palette.title")

	local sourceButtons = {}
	for _, candidate in ipairs(view.paletteGroups) do
		if #candidate.items > 0 then
			local source = candidate.source
			table.insert(
				sourceButtons,
				ui.button({
					key = "palette-src:" .. source,
					text = candidate.title,
					variant = activeVariant(view.paletteSource == source),
					onClick = function()
						self.coordinator:dispatch("palette-source", source)
					end,
				})
			)
		end
	end

	local query = (view.paletteQuery or ""):lower()
	local rows = {}
	if group then
		for _, item in ipairs(group.items) do
			if query == "" or item.name:lower():find(query, 1, true) then
				table.insert(rows, self:paletteRow(item))
			end
		end
	end
	local list: UiNode
	if #rows == 0 then
		list = ui.column({ flexGrow = 1, align = "center", justify = "center" }, {
			ui.label({ text = noctalia.tr("palette.empty"), color = "on_surface_variant" }),
		})
	else
		list = ui.scroll({ flexGrow = 1, gap = 4, align = "stretch" }, rows)
	end

	local card = ui.column({
		key = "palette-card",
		width = PALETTE_CARD_WIDTH,
		height = PALETTE_CARD_HEIGHT,
		fill = "surface",
		border = "outline",
		borderWidth = 1,
		radius = 12,
		padding = 12,
		gap = 12,
		align = "stretch",
	}, {
		ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = title, fontSize = 14, fontWeight = "bold", flexGrow = 1, color = "on_surface" }),
			ui.button({
				glyph = "close",
				variant = "default",
				tooltip = noctalia.tr("close"),
				onClick = function()
					self.coordinator:dispatch("back-from-palette")
				end,
			}),
		}),
		ui.row({ gap = 8, align = "center" }, sourceButtons),
		ui.input({
			key = "palette-search",
			value = view.paletteQuery,
			placeholder = noctalia.tr("palette.search"),
			onChange = function(value)
				self.coordinator:dispatch("palette-search", value)
			end,
		}),
		list,
	})
	return ui.row({ flexGrow = 1, justify = "end", align = "start" }, { card })
end

function PickerPanel:sourceControls(): UiNode
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

function PickerPanel:content(): UiNode
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
	local children
	if self.view.showPalette then
		children = { self:header(), self:tabBar(), self:palettePopup() }
	else
		children = { self:header(), self:tabBar(), self:sourceControls(), self:content() }
	end
	panel.render(ui.column({ flexGrow = 1, gap = 12, padding = PANEL_PADDING, align = "stretch" }, children))
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
