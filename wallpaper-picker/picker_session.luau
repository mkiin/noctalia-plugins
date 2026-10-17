--!strict

local PickerSession = {}
PickerSession.__index = PickerSession

function PickerSession.new()
	return setmetatable({
		tab = "images",
		showPalette = false,
		monitorIndex = 0,
	}, PickerSession)
end

function PickerSession:reset()
	self.tab = "images"
	self.showPalette = false
end

function PickerSession:selectTab(tab: string)
	self.tab = tab
	self.showPalette = false
end

function PickerSession:togglePalette()
	self.showPalette = not self.showPalette
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
