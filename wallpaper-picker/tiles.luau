--!strict

local MediaBrowser = require("./media_browser.luau")

type ImageEntry = MediaBrowser.ImageEntry
type VideoEntry = MediaBrowser.VideoEntry

local TILE_WIDTH = 245
local TILE_IMAGE_H = math.floor(TILE_WIDTH * 0.72)
local TILE_INNER_GAP = 6
local NAME_H = 22
local TILE_RADIUS = 12
local TILE_BORDER_WIDTH = 1

local function tileHeight(): number
	return TILE_IMAGE_H + TILE_INNER_GAP + NAME_H
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

local Tiles = {}

function Tiles.imageTile(panel: any, item: ImageEntry): UiNode
	if item.isDir then
		local directory = ui.column({
			width = TILE_WIDTH,
			height = TILE_IMAGE_H,
			fill = "surface_variant",
			radius = TILE_RADIUS,
			border = "outline",
			borderWidth = TILE_BORDER_WIDTH,
			align = "center",
			justify = "center",
			tooltip = item.path,
			onClick = function()
				panel.coordinator:dispatch("enter-folder", item.path)
			end,
		}, { ui.glyph({ name = "folder", size = 44, color = "primary" }) })
		local children = { directory }
		if panel.view.showNames then
			table.insert(children, ui.label({ text = item.name, fontSize = 12, color = "on_surface", maxLines = 1 }))
		end
		return ui.column(
			{ key = "dir:" .. item.path, width = TILE_WIDTH, height = tileHeight(), gap = TILE_INNER_GAP },
			children
		)
	end
	return Tiles.mediaTile(panel, "images", item.path, item.name)
end

function Tiles.videoTile(panel: any, item: VideoEntry): UiNode
	return Tiles.mediaTile(panel, "video", item.path, item.name)
end

function Tiles.mediaTile(panel: any, kind: string, path: string, name: string): UiNode
	local view = panel.view
	local selected = view.selectedKind == kind and view.selectedPath == path
	local favorite = panel.coordinator:favorite(kind, path)
	local preview = panel.coordinator:thumbnail(path)
	local border = if selected then "primary" else if favorite then "tertiary" else "outline"
	local action = function()
		panel.coordinator:dispatch(if kind == "video" then "apply-video" else "apply-image", path)
	end
	local image: UiNode
	if preview then
		image = ui.image({
			key = "preview:" .. path .. ":" .. border,
			path = preview,
			width = TILE_WIDTH,
			height = TILE_IMAGE_H,
			fit = "cover",
			radius = TILE_RADIUS,
			border = border,
			borderWidth = TILE_BORDER_WIDTH,
			tooltip = name,
			onClick = action,
		})
	else
		image = ui.column({
			key = "placeholder:" .. path .. ":" .. border,
			width = TILE_WIDTH,
			height = TILE_IMAGE_H,
			fill = "surface_variant",
			radius = TILE_RADIUS,
			border = border,
			borderWidth = TILE_BORDER_WIDTH,
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
	if view.showNames or favorite then
		local labels = {}
		if view.showNames then
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
	return ui.column(
		{ key = "tile:" .. path, width = TILE_WIDTH, height = tileHeight(), gap = TILE_INNER_GAP },
		children
	)
end

return Tiles
