--!strict

noctalia.setUpdateInterval(1000)

local STATE_DIR = (noctalia.getenv("XDG_STATE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.local/state"))
	.. "/noctalia/wallpaper-picker"
local STATE_FILE = STATE_DIR .. "/assignments.json"

local assignments = {}
local lastAssignments = {}
local launchedAsSystemd = {}
local lastPresent = {}
local isPaused = {}
local generation = {}
local transitionEpoch = 0
local available = false
local mpvpaperSupportsAutoMode = false

local function cfg(key)
	return noctalia.getConfig(key)
end

local function shellQuote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function unitNameFor(connector: string)
	if connector == "*" then
		return "mpvpaper.scope"
	end
	return "mpvpaper-" .. connector:gsub("[^%w%-]", "_") .. ".scope"
end

local function nextGeneration(connector: string): number
	local value = (generation[connector] or 0) + 1
	generation[connector] = value
	return value
end

local function pkillPattern(connector: string)
	local escaped = connector:gsub("([%.%*%+%?%(%)%[%]%^%$|\\{}])", "\\%1")
	return shellQuote("(^|/)mpvpaper .* " .. escaped .. " ")
end

local function forEachOutput(connector, fn)
	if connector == "*" then
		for _, output in ipairs(noctalia.outputs()) do
			fn(output.name)
		end
	else
		fn(connector)
	end
end

local function persist()
	noctalia.runAsync("mkdir -p " .. shellQuote(STATE_DIR))
	noctalia.writeFile(STATE_FILE, noctalia.json.encode({
		assignments = assignments,
		lastAssignments = lastAssignments,
		launchedAsSystemd = launchedAsSystemd,
	}) or "")
end

local function loadAssignments()
	local content = noctalia.readFile(STATE_FILE)
	if type(content) == "string" and content ~= "" then
		local decoded = noctalia.json.decode(content)
		if type(decoded) == "table" then
			if decoded.assignments then
				assignments = decoded.assignments
				lastAssignments = decoded.lastAssignments or {}
				launchedAsSystemd = decoded.launchedAsSystemd or {}
			else
				assignments = decoded
			end
		end
	end
end

local function publish()
	noctalia.state.set("assignments", assignments)
	noctalia.state.set("available", available)
	noctalia.state.set("paused", isPaused)
end

local function mpvOptions()
	local parts = { "loop-file=inf", "panscan=1.0" }
	if cfg("mute") then
		table.insert(parts, "no-audio")
	end
	table.insert(parts, "hwdec=" .. (cfg("hardware_decode") and "auto" or "no"))

	local extra = cfg("mpv_options")
	if type(extra) == "string" and extra ~= "" then
		table.insert(parts, extra)
	end
	return table.concat(parts, " ")
end

local function probeAutoModeSupport(callback)
	noctalia.runAsync("mpvpaper --help", function(result)
		mpvpaperSupportsAutoMode = type(result) == "table"
			and type(result.stdout) == "string"
			and result.stdout:find("--auto%-mode") ~= nil
		if callback then
			callback()
		end
	end)
end

local function normalizedAutoPauseMode()
	local mode = cfg("auto_pause")
	if mode == true then
		return "full"
	end
	if mode == false then
		return "off"
	end
	if type(mode) == "string" then
		return mode
	end
	return "off"
end

local function autoPauseFlag()
	local mode = normalizedAutoPauseMode()
	if mode == "off" then
		return ""
	end
	if mpvpaperSupportsAutoMode then
		if mode == "max" then
			return "--auto-pause --auto-mode MAX"
		end
		if mode == "full" then
			return "--auto-pause --auto-mode FULL"
		end
	end
	return "--auto-pause"
end

local function systemdProperties()
	local props = {}
	local cpu_quota = cfg("cpu_quota")
	if type(cpu_quota) == "number" and cpu_quota > 0 then
		table.insert(props, "CPUQuota=" .. tostring(cpu_quota) .. "%")
	end

	local allowed_cpus = cfg("allowed_cpus")
	if type(allowed_cpus) == "string" and allowed_cpus ~= "" then
		table.insert(props, "AllowedCPUs=" .. allowed_cpus)
	end

	local memory_max = cfg("memory_max")
	if type(memory_max) == "string" and memory_max ~= "" then
		table.insert(props, "MemoryMax=" .. memory_max)
	end

	local cpu_weight = cfg("cpu_weight")
	if type(cpu_weight) == "number" and cpu_weight > 0 then
		table.insert(props, "CPUWeight=" .. tostring(cpu_weight))
	end

	return props
end

local function killMpvpaper(connector: string, callback: ((CommandResult) -> ())?, signal: number?)
	local sig = (type(signal) == "number" and signal > 0) and signal or 15
	local killCmd
	local pattern = pkillPattern(connector)
	if launchedAsSystemd[connector] then
		local unitName = unitNameFor(connector)
		if isPaused[connector] then
			killCmd = "systemctl --user thaw "
				.. shellQuote(unitName)
				.. " ; systemctl --user stop "
				.. shellQuote(unitName)
		else
			killCmd = "systemctl --user stop " .. shellQuote(unitName)
		end
	elseif isPaused[connector] then
		killCmd = "pkill -CONT -f -- " .. pattern .. " ; pkill -" .. sig .. " -f -- " .. pattern
	else
		killCmd = "pkill -" .. sig .. " -f -- " .. pattern
	end
	if not launchedAsSystemd[connector] then
		killCmd = killCmd
			.. " ; if pgrep -A -f -- "
			.. pattern
			.. " >/dev/null 2>&1; then timeout 2s pidwait -A -f -- "
			.. pattern
			.. " >/dev/null 2>&1 || { pkill -KILL -f -- "
			.. pattern
			.. " 2>/dev/null; timeout 1s pidwait -A -f -- "
			.. pattern
			.. " >/dev/null 2>&1 || true; }; fi"
	end

	isPaused[connector] = false

	if callback then
		noctalia.runAsync(killCmd, callback)
	else
		noctalia.runAsync(killCmd)
	end
end

local function startMpvpaper(connector, path)
	local ticket = nextGeneration(connector)
	killMpvpaper(connector, function()
		if generation[connector] ~= ticket or assignments[connector] ~= path then
			return
		end
		launchedAsSystemd[connector] = cfg("run_as_systemd")
		persist()

		local flags = autoPauseFlag()
		local cmd = "mpvpaper "
		if flags ~= "" then
			cmd = cmd .. flags .. " "
		end
		cmd = cmd .. "-o " .. shellQuote(mpvOptions()) .. " " .. shellQuote(connector) .. " " .. shellQuote(path)

		local nice = cfg("nice")
		if type(nice) == "number" and nice ~= 0 then
			cmd = "nice -n " .. tostring(nice) .. " " .. cmd
		end

		if launchedAsSystemd[connector] then
			local unitName = unitNameFor(connector)
			local propsCmd = ""
			for _, prop in ipairs(systemdProperties()) do
				propsCmd = propsCmd .. "--property=" .. shellQuote(prop) .. " "
			end
			cmd = "systemd-run --user --scope " .. propsCmd .. "--unit=" .. shellQuote(unitName) .. " " .. cmd
		end

		forEachOutput(connector, function(name)
			noctalia.setWallpaperEnabled(name, false)
		end)
		noctalia.runAsync("exec " .. cmd .. " >/dev/null 2>&1 &", function() end)
	end)
end

local function freezeMpvpaper(connector)
	isPaused[connector] = true
	if cfg("run_as_systemd") then
		noctalia.runAsync("systemctl --user freeze " .. shellQuote(unitNameFor(connector)))
	else
		noctalia.runAsync("pkill -STOP -f -- " .. pkillPattern(connector))
	end
end

local function thawMpvpaper(connector)
	isPaused[connector] = false
	if cfg("run_as_systemd") then
		noctalia.runAsync("systemctl --user thaw " .. shellQuote(unitNameFor(connector)))
	else
		noctalia.runAsync("pkill -CONT -f -- " .. pkillPattern(connector))
	end
end

local function toggleMpvpaper(connector)
	if isPaused[connector] then
		thawMpvpaper(connector)
	else
		freezeMpvpaper(connector)
	end
end

local function snapshotAssignments()
	if next(assignments) == nil then
		return
	end
	lastAssignments = {}
	for k, v in pairs(assignments) do
		lastAssignments[k] = v
	end
end

local function clearVideo(connector)
	if type(connector) ~= "string" or connector == "" then
		return
	end

	snapshotAssignments()
	assignments[connector] = nil
	local ticket = nextGeneration(connector)
	persist()

	killMpvpaper(connector, function()
		if generation[connector] ~= ticket then
			return
		end
		forEachOutput(connector, function(name)
			if not assignments["*"] and not assignments[name] then
				noctalia.setWallpaperEnabled(name, true)
			end
		end)
	end)

	publish()
end

local function clearAll(afterKill: (() -> ())?)
	transitionEpoch += 1
	local epoch = transitionEpoch
	snapshotAssignments()
	local targets = {}
	for connector in pairs(assignments) do
		targets[connector] = true
	end
	for connector in pairs(lastAssignments) do
		targets[connector] = true
	end
	for connector in pairs(generation) do
		targets[connector] = true
	end
	assignments = {}
	persist()
	publish()
	local remaining = 0
	for _ in pairs(targets) do
		remaining += 1
	end
	local function finish()
		if epoch ~= transitionEpoch then
			return
		end
		if afterKill then
			afterKill()
		else
			for _, output in ipairs(noctalia.outputs()) do
				noctalia.setWallpaperEnabled(output.name, true)
			end
		end
	end
	if remaining == 0 then
		finish()
		return
	end
	for connector in pairs(targets) do
		nextGeneration(connector)
		killMpvpaper(connector, function()
			remaining -= 1
			if remaining == 0 then
				finish()
			end
		end)
	end
end

local function applyImage(path, connector)
	if type(path) ~= "string" or path == "" then
		return
	end
	clearAll(function()
		if type(connector) == "string" and connector ~= "" and connector ~= "*" then
			noctalia.setWallpaper(connector, path)
		else
			noctalia.setWallpaper(path)
		end
		for _, output in ipairs(noctalia.outputs()) do
			noctalia.setWallpaperEnabled(output.name, true)
		end
	end)
end

local function setVideo(connector, path)
	if not available or type(connector) ~= "string" or connector == "" or type(path) ~= "string" or path == "" then
		return
	end
	transitionEpoch += 1

	if connector == "*" then
		for conn in pairs(assignments) do
			if conn ~= "*" then
				clearVideo(conn)
			end
		end
	else
		if assignments["*"] then
			clearVideo("*")
		end
	end

	assignments[connector] = path
	persist()

	startMpvpaper(connector, path)
	publish()
end

local function presentOutputs()
	local present = {}
	for _, output in ipairs(noctalia.outputs()) do
		present[output.name] = true
	end
	return present
end

local function applyAll()
	for connector, path in pairs(assignments) do
		startMpvpaper(connector, path)
	end
end

function update() end

function onOutputsChanged()
	if not available then
		return
	end
	local present = presentOutputs()

	local newMonitor = false
	for conn in pairs(present) do
		if not lastPresent[conn] then
			newMonitor = true
		end
	end

	if newMonitor and assignments["*"] then
		startMpvpaper("*", assignments["*"])
	end

	for connector, path in pairs(assignments) do
		if connector ~= "*" then
			if present[connector] and not lastPresent[connector] then
				startMpvpaper(connector, path)
			end
		end
	end

	lastPresent = present
end

function onExit(signal)
	for connector in pairs(assignments) do
		killMpvpaper(connector, nil, signal)
	end
end

function onConfigChanged(_key, _value)
	applyAll()
end

function onIpc(event, payload)
	if event == "clear-all" then
		clearAll()
	elseif event == "clear" then
		clearVideo(payload)
	elseif event == "reapply" then
		if not available then
			noctalia.log("wallpaper-picker: reapply requested but mpvpaper is not installed")
			return
		end
		if next(assignments) == nil then
			assignments = {}
			for k, v in pairs(lastAssignments) do
				assignments[k] = v
			end
			persist()
		end
		applyAll()
		publish()
	elseif event == "pause" or event == "freeze" then
		if type(payload) == "string" and payload ~= "" then
			freezeMpvpaper(payload)
		else
			for conn in pairs(assignments) do
				freezeMpvpaper(conn)
			end
		end
		publish()
	elseif event == "resume" or event == "thaw" then
		if type(payload) == "string" and payload ~= "" then
			thawMpvpaper(payload)
		else
			for conn in pairs(assignments) do
				thawMpvpaper(conn)
			end
		end
		publish()
	elseif event == "toggle" then
		if type(payload) == "string" and payload ~= "" then
			toggleMpvpaper(payload)
		else
			for conn in pairs(assignments) do
				toggleMpvpaper(conn)
			end
		end
		publish()
	end
end

noctalia.state.watch("command", function(cmd)
	if type(cmd) ~= "table" then
		return
	end
	if cmd.action == "set" then
		setVideo(cmd.connector, cmd.path)
	elseif cmd.action == "apply-image" then
		applyImage(cmd.path, cmd.connector)
	elseif cmd.action == "clear" then
		clearVideo(cmd.connector)
	elseif cmd.action == "clear-all" then
		clearAll()
	elseif cmd.action == "freeze" then
		onIpc("freeze", cmd.connector)
	elseif cmd.action == "thaw" then
		onIpc("thaw", cmd.connector)
	elseif cmd.action == "toggle" then
		onIpc("toggle", cmd.connector)
	end
end)

noctalia.runAsync("mkdir -p " .. shellQuote(STATE_DIR))
loadAssignments()

available = noctalia.commandExists("mpvpaper")
if available then
	probeAutoModeSupport(function()
		lastPresent = presentOutputs()
		applyAll()
	end)
else
	noctalia.notifyError("Wallpaper Picker", "mpvpaper is not installed")
end

publish()
