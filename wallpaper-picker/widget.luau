--!nonstrict
-- Bar widget that opens the wallpaper picker.

local glyph = noctalia.getConfig("glyph") or "photo"

local function render()
	barWidget.setGlyph(glyph)
	barWidget.setTooltip(noctalia.tr("title"))
end

function update()
	render()
end

function onClick()
	noctalia.togglePanel("mkiin/wallpaper-picker:picker")
end

render()
