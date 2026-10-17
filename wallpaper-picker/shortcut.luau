--!strict

local function render()
	shortcut.setLabel(noctalia.tr("title"))
	shortcut.setIcon("photo")
end

function onClick()
	noctalia.togglePanel("mkiin/wallpaper-picker:picker")
end

render()
