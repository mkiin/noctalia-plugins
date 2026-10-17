--!strict

local PickerSession = {}
PickerSession.__index = PickerSession

function PickerSession.new()
	return setmetatable({
		tab = "images",
		showPalette = false,
		monitorIndex = 0,
		paletteQuery = "",
		paletteHover = nil :: string?,
	}, PickerSession)
end

function PickerSession:reset()
	self.tab = "images"
	self.showPalette = false
	self.paletteQuery = ""
	self.paletteHover = nil
end

function PickerSession:selectTab(tab: string)
	self.tab = tab
	self.showPalette = false
end

function PickerSession:togglePalette()
	self.showPalette = not self.showPalette
	self.paletteQuery = ""
	self.paletteHover = nil
end

function PickerSession:setPaletteQuery(query: string)
	self.paletteQuery = query
end

function PickerSession:setPaletteHover(key: string?)
	self.paletteHover = key
end

function PickerSession:selectMonitor(index: number)
	self.monitorIndex = index
end

function PickerSession:connector(): string?
	if self.monitorIndex <= 0 then
		return nil
	end
	local output = noctalia.outputs()[self.monitorIndex]
	return output and output.name or nil
end

return PickerSession
