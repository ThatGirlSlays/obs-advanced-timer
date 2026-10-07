--[[
Advanced Timer for OBS Studio
Version: 1.0.5
Author: ThatGirlSlays

Runs one or more independent timers. Each timer counts up or down on its own
text source, has its own display format and activation mode, and runs its
own set of actions when it completes: change scene, hide/show sources, press
an OBS hotkey, change what the timer text shows, and mute/unmute audio
sources (each with its own delay or early offset).
]]

obs = obslua
local bit = require("bit")

-- Bump with every revision
local SCRIPT_VERSION = "1.0.5"
local SCRIPT_AUTHOR = "ThatGirlSlays"

local MAX_TIMERS = 10

-- Text source types this script can write to (unversioned ids)
local TEXT_SOURCE_IDS = {
	text_gdiplus = true,     -- Windows: Text (GDI+)
	text_ft2_source = true,  -- macOS/Linux: Text (FreeType 2)
}

local MODE_DOWN = "down"
local MODE_UP = "up"

local ACTIVATION_MANUAL = "manual"
local ACTIVATION_RESTART_LIVE = "restart_live"
local ACTIVATION_WHILE_LIVE = "while_live"
local ACTIVATION_STREAM = "stream"
local ACTIVATION_RECORD = "record"

local FORMAT_AUTO = "auto"
local FORMAT_CUSTOM = "custom"

local END_KEEP = "keep"
local END_HIDE = "hide"
local END_TEXT = "text"
local END_RESET = "reset"

local AUDIO_NONE = ""
local AUDIO_MUTE = "mute"
local AUDIO_UNMUTE = "unmute"

-- Interaction modifier flags (fall back to libobs values if not exported)
local MOD_SHIFT = obs.INTERACT_SHIFT_KEY or 2
local MOD_CONTROL = obs.INTERACT_CONTROL_KEY or 4
local MOD_ALT = obs.INTERACT_ALT_KEY or 8
local MOD_COMMAND = obs.INTERACT_COMMAND_KEY or 128

-- Settings keys. Each timer's settings end in "_<timer number>".
local function key(name, i) return name .. "_" .. i end
local function audio_key_action(i, source) return "audio_action_" .. i .. ":" .. source end
local function audio_key_offset(i, source) return "audio_offset_" .. i .. ":" .. source end

local script_settings = nil
local timer_count = 1
local timers = {}

local function new_timer(i)
	return {
		index = i,
		cfg = {
			text_source = "",
			mode = MODE_DOWN,
			duration_ms = 0,
			activation = ACTIVATION_MANUAL,
			format_mode = FORMAT_AUTO,
			format = "",
			prefix = "",
			suffix = "",
			hide_zero_groups = false,
			hide_single_zero = false,
			show_ms = false,
			end_action = END_KEEP,
			end_text = "",
			end_scene = "",
			end_hide_source = "",
			end_show_source = "",
			end_hotkey = "",
		},
		running = false,
		completed = false,
		elapsed_ms = 0,
		last_ns = nil,
		last_text = nil,
		was_live = false,     -- text source was in the program output last tick
		timer_hidden = false, -- the text source was hidden by the "hide" end action
		audio_events = {},    -- scheduled mute/unmute actions for this run
		hotkey_start_id = nil,
		hotkey_reset_id = nil,
	}
end

for i = 1, MAX_TIMERS do
	timers[i] = new_timer(i)
end

local function active_timers()
	local list = {}
	for i = 1, timer_count do
		table.insert(list, timers[i])
	end
	return list
end

----------------------------------------------------------------------------
-- Time parsing and formatting

-- Parses "hh:mm:ss", "mm:ss" or "ss" (seconds may have decimals) into
-- milliseconds. Returns nil when the text can't be read.
function parse_duration(str)
	str = (str or ""):gsub("%s", "")
	if str == "" then
		return 0
	end

	local parts = {}
	for part in (str .. ":"):gmatch("([^:]*):") do
		table.insert(parts, part)
	end
	if #parts > 3 then
		return nil
	end

	local total = 0
	for _, part in ipairs(parts) do
		local n = tonumber(part == "" and "0" or part)
		if n == nil or n < 0 then
			return nil
		end
		total = total * 60 + n
	end
	return math.floor(total * 1000 + 0.5)
end

local UNIT_MS = { d = 86400000, h = 3600000, m = 60000, s = 1000 }
local FRACTION_MS = { 100, 10, 1 } -- %f, %ff, %fff

-- Splits a custom format such as "%hh:%mm:%ss.%ff" into literal text and
-- {unit, width} tokens. "%%" is a literal percent sign.
local format_cache = {}
function parse_format(fmt)
	if format_cache[fmt] then
		return format_cache[fmt]
	end

	local tokens = {}
	local has = {}
	local literal = {}
	local function flush()
		if #literal > 0 then
			table.insert(tokens, table.concat(literal))
			literal = {}
		end
	end

	local i, n = 1, #fmt
	while i <= n do
		local c = fmt:sub(i, i)
		local unit = fmt:sub(i + 1, i + 1)
		if c == "%" and unit == "%" then
			table.insert(literal, "%")
			i = i + 2
		elseif c == "%" and unit:match("^[dhmsf]$") then
			local j = i + 1
			while j <= n and j - i <= 3 and fmt:sub(j, j) == unit do
				j = j + 1
			end
			flush()
			table.insert(tokens, { unit = unit, width = j - i - 1 })
			has[unit] = math.max(has[unit] or 0, j - i - 1)
			i = j
		else
			table.insert(literal, c)
			i = i + 1
		end
	end
	flush()

	-- Smallest unit shown decides how the time is rounded
	local step = 1000
	if has.f then
		step = FRACTION_MS[math.min(has.f, 3)]
	elseif has.s then
		step = 1000
	elseif has.m then
		step = UNIT_MS.m
	elseif has.h then
		step = UNIT_MS.h
	elseif has.d then
		step = UNIT_MS.d
	end

	local parsed = { tokens = tokens, has = has, step = step }
	format_cache[fmt] = parsed
	return parsed
end

local function round_to(ms, step, round_up)
	local units
	if round_up then
		units = math.ceil(ms / step - 1e-9)
	else
		units = math.floor(ms / step + 1e-9)
	end
	return math.max(units, 0) * step
end

-- Formats with a custom format. The largest unit in the format takes up the
-- whole remaining time, so "%mm:%ss" shows 1 hour 5 minutes as 65:00.
function format_custom(ms, fmt, round_up)
	local parsed = parse_format(fmt)
	local rest = round_to(ms, parsed.step, round_up)

	local values = {}
	for _, unit in ipairs({ "d", "h", "m", "s" }) do
		if parsed.has[unit] then
			values[unit] = math.floor(rest / UNIT_MS[unit])
			rest = rest % UNIT_MS[unit]
		end
	end

	local out = {}
	for _, token in ipairs(parsed.tokens) do
		if type(token) == "string" then
			table.insert(out, token)
		elseif token.unit == "f" then
			local width = math.min(token.width, 3)
			local value = math.floor(rest / FRACTION_MS[width])
			table.insert(out, string.format("%0" .. width .. "d", value))
		else
			table.insert(out, string.format("%0" .. token.width .. "d", values[token.unit]))
		end
	end
	return table.concat(out)
end

-- Formats with the checkbox display options
function format_auto(ms, c, round_up)
	local rest = round_to(ms, c.show_ms and 10 or 1000, round_up)
	local total_seconds = math.floor(rest / 1000)
	local hundredths = math.floor((rest % 1000) / 10)

	local hours = math.floor(total_seconds / 3600)
	local minutes = math.floor(total_seconds / 60) % 60
	local seconds = total_seconds % 60

	-- Hiding leading 00 drops each empty group in front, down to the seconds
	local text
	if c.hide_zero_groups and hours == 0 and minutes == 0 then
		text = string.format("%02d", seconds)
	elseif c.hide_zero_groups and hours == 0 then
		text = string.format("%02d:%02d", minutes, seconds)
	else
		text = string.format("%02d:%02d:%02d", hours, minutes, seconds)
	end
	if c.hide_single_zero then
		text = (text:gsub("^0(%d)", "%1"))
	end
	if c.show_ms then
		text = text .. string.format(".%02d", hundredths)
	end
	return text
end

-- Countdowns round up so the display shows the full starting value and only
-- reaches zero at the end.
local function format_time(t, ms)
	local round_up = t.cfg.mode == MODE_DOWN
	if t.cfg.format_mode == FORMAT_CUSTOM and t.cfg.format ~= "" then
		return format_custom(ms, t.cfg.format, round_up)
	end
	return format_auto(ms, t.cfg, round_up)
end

-- Milliseconds the display should show right now
local function display_ms(t)
	local c = t.cfg
	if c.mode == MODE_DOWN then
		return math.max(c.duration_ms - t.elapsed_ms, 0)
	end
	if c.duration_ms > 0 then
		return math.min(t.elapsed_ms, c.duration_ms)
	end
	return t.elapsed_ms
end

local function start_ms(t)
	if t.cfg.mode == MODE_DOWN then
		return t.cfg.duration_ms
	end
	return 0
end

local function display_text(t)
	local c = t.cfg
	if t.completed then
		if c.end_action == END_TEXT then
			return c.end_text
		elseif c.end_action == END_RESET then
			return c.prefix .. format_time(t, start_ms(t)) .. c.suffix
		end
	end
	return c.prefix .. format_time(t, display_ms(t)) .. c.suffix
end

----------------------------------------------------------------------------
-- OBS helpers

local function set_source_text(source_name, text)
	if source_name == "" then
		return
	end
	local source = obs.obs_get_source_by_name(source_name)
	if source ~= nil then
		local settings = obs.obs_data_create()
		obs.obs_data_set_string(settings, "text", text)
		obs.obs_source_update(source, settings)
		obs.obs_data_release(settings)
		obs.obs_source_release(source)
	end
end

local function visit_scene_items(scene, source_name, fn)
	local items = obs.obs_scene_enum_items(scene)
	if items == nil then
		return
	end
	for _, item in ipairs(items) do
		local source = obs.obs_sceneitem_get_source(item)
		if obs.obs_source_get_name(source) == source_name then
			fn(item)
		end
		if obs.obs_sceneitem_is_group(item) then
			visit_scene_items(obs.obs_sceneitem_group_get_scene(item), source_name, fn)
		end
	end
	obs.sceneitem_list_release(items)
end

-- Shows or hides a source everywhere it appears, in every scene and group
local function set_source_visible(source_name, visible)
	if source_name == nil or source_name == "" then
		return
	end
	local scenes = obs.obs_frontend_get_scenes()
	if scenes == nil then
		return
	end
	for _, scene_source in ipairs(scenes) do
		local scene = obs.obs_scene_from_source(scene_source)
		visit_scene_items(scene, source_name, function(item)
			obs.obs_sceneitem_set_visible(item, visible)
		end)
	end
	obs.source_list_release(scenes)
end

local function change_scene(scene_name)
	if scene_name == "" then
		return
	end
	local scene = obs.obs_get_source_by_name(scene_name)
	if scene ~= nil then
		obs.obs_frontend_set_current_scene(scene)
		obs.obs_source_release(scene)
	end
end

local function set_muted(source_name, muted)
	local source = obs.obs_get_source_by_name(source_name)
	if source ~= nil then
		obs.obs_source_set_muted(source, muted)
		obs.obs_source_release(source)
	end
end

local function is_text_source(source)
	return TEXT_SOURCE_IDS[obs.obs_source_get_unversioned_id(source)] == true
end

local function is_audio_source(source)
	local flags = obs.obs_source_get_output_flags(source)
	return bit.band(flags, obs.OBS_SOURCE_AUDIO) ~= 0
end

-- Names of all input sources matching filter, sorted
local function source_names(filter)
	local names = {}
	local sources = obs.obs_enum_sources()
	if sources ~= nil then
		for _, source in ipairs(sources) do
			if filter == nil or filter(source) then
				table.insert(names, obs.obs_source_get_name(source))
			end
		end
		obs.source_list_release(sources)
	end
	table.sort(names, function(a, b) return a:lower() < b:lower() end)
	return names
end

local function scene_names()
	local names = {}
	local scenes = obs.obs_frontend_get_scenes()
	if scenes ~= nil then
		for _, scene in ipairs(scenes) do
			table.insert(names, obs.obs_source_get_name(scene))
		end
		obs.source_list_release(scenes)
	end
	return names
end

----------------------------------------------------------------------------
-- Hotkey completion action
--
-- Lua scripts can't send keystrokes to the operating system, so the combo is
-- injected into OBS's own hotkey system instead. Whatever is bound to that
-- combo in Settings > Hotkeys runs, exactly as if it had been pressed.

local MODIFIER_NAMES = {
	shift = MOD_SHIFT,
	ctrl = MOD_CONTROL, control = MOD_CONTROL,
	alt = MOD_ALT, option = MOD_ALT, opt = MOD_ALT,
	cmd = MOD_COMMAND, command = MOD_COMMAND, win = MOD_COMMAND,
	windows = MOD_COMMAND, super = MOD_COMMAND, meta = MOD_COMMAND,
}

local KEY_ALIASES = {
	esc = "ESCAPE", escape = "ESCAPE",
	enter = "RETURN", ["return"] = "RETURN",
	space = "SPACE", spacebar = "SPACE", tab = "TAB", backspace = "BACKSPACE",
	del = "DELETE", delete = "DELETE", ins = "INSERT", insert = "INSERT",
	home = "HOME", ["end"] = "END",
	pgup = "PAGEUP", pageup = "PAGEUP", pgdn = "PAGEDOWN", pagedown = "PAGEDOWN",
	up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT",
	["-"] = "MINUS", minus = "MINUS", ["="] = "EQUAL", equal = "EQUAL",
	[","] = "COMMA", comma = "COMMA", ["."] = "PERIOD", period = "PERIOD",
	["/"] = "SLASH", slash = "SLASH", [";"] = "SEMICOLON", semicolon = "SEMICOLON",
	["'"] = "APOSTROPHE", ["["] = "BRACKETLEFT", ["]"] = "BRACKETRIGHT",
	["\\"] = "BACKSLASH", ["`"] = "QUOTELEFT",
	["num*"] = "NUMASTERISK", ["num+"] = "NUMPLUS", ["num-"] = "NUMMINUS",
	["num."] = "NUMPERIOD", ["num/"] = "NUMSLASH",
}

-- Turns "Ctrl+Shift+F5" into (modifiers, "OBS_KEY_F5"). Returns nil and an
-- error message when it can't be read.
function parse_hotkey(spec)
	spec = (spec or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if spec == "" then
		return nil, "no hotkey set"
	end

	local modifiers = 0
	local key_name = nil
	-- "+" on its own (e.g. "Ctrl++") is the plus key
	local tokens = {}
	for token in (spec .. "+"):gmatch("([^+]*)%+") do
		table.insert(tokens, token)
	end
	if spec:sub(-2) == "++" then
		tokens[#tokens] = "+"
	end

	for _, raw in ipairs(tokens) do
		local token = raw:gsub("%s", "")
		local lower = token:lower()
		if token == "" then
			-- skip empty pieces from stray "+"
		elseif MODIFIER_NAMES[lower] ~= nil then
			modifiers = bit.bor(modifiers, MODIFIER_NAMES[lower])
		elseif key_name ~= nil then
			return nil, "more than one non-modifier key in \"" .. spec .. "\""
		elseif token:upper():sub(1, 8) == "OBS_KEY_" then
			key_name = token:upper()
		elseif token == "+" then
			key_name = "OBS_KEY_PLUS"
		elseif KEY_ALIASES[lower] ~= nil then
			key_name = "OBS_KEY_" .. KEY_ALIASES[lower]
		else
			key_name = "OBS_KEY_" .. token:upper()
		end
	end

	if key_name == nil then
		return nil, "no key in \"" .. spec .. "\" besides modifiers"
	end
	return modifiers, key_name
end

local function press_hotkey(spec)
	local modifiers, key_name = parse_hotkey(spec)
	if modifiers == nil then
		obs.script_log(obs.LOG_WARNING, "Hotkey not pressed: " .. key_name)
		return
	end

	local key_code = obs.obs_key_from_name(key_name)
	if key_code == nil or key_code == 0 or key_code == obs.OBS_KEY_NONE then
		obs.script_log(obs.LOG_WARNING, "Hotkey not pressed: unknown key \"" .. key_name .. "\"")
		return
	end

	local ok, err = pcall(function()
		local combo = obs.obs_key_combination()
		combo.modifiers = modifiers
		combo.key = key_code
		obs.obs_hotkey_inject_event(combo, false)
		obs.obs_hotkey_inject_event(combo, true)
		obs.obs_hotkey_inject_event(combo, false)
	end)
	if not ok then
		obs.script_log(obs.LOG_WARNING, "Hotkey not pressed: " .. tostring(err))
	end
end

----------------------------------------------------------------------------
-- Timer control

local function render(t, force)
	if t.cfg.text_source == "" then
		return
	end
	local text = display_text(t)
	if force or text ~= t.last_text then
		set_source_text(t.cfg.text_source, text)
		t.last_text = text
	end
end

-- Schedules each audio rule relative to the start of the run
local function build_audio_events(t)
	t.audio_events = {}
	if script_settings == nil or t.cfg.duration_ms <= 0 then
		return
	end
	for _, name in ipairs(source_names(is_audio_source)) do
		local action = obs.obs_data_get_string(script_settings, audio_key_action(t.index, name))
		if action == AUDIO_MUTE or action == AUDIO_UNMUTE then
			local offset = obs.obs_data_get_int(script_settings, audio_key_offset(t.index, name))
			table.insert(t.audio_events, {
				at_ms = math.max(t.cfg.duration_ms + offset, 0),
				source = name,
				mute = action == AUDIO_MUTE,
				fired = false,
			})
		end
	end
end

local function fire_due_audio_events(t)
	for _, event in ipairs(t.audio_events) do
		if not event.fired and t.elapsed_ms >= event.at_ms then
			event.fired = true
			set_muted(event.source, event.mute)
		end
	end
end

local function has_pending_audio_events(t)
	for _, event in ipairs(t.audio_events) do
		if not event.fired then
			return true
		end
	end
	return false
end

local function complete(t)
	local c = t.cfg
	t.completed = true

	if c.end_action == END_HIDE then
		set_source_visible(c.text_source, false)
		t.timer_hidden = true
	end
	render(t, true)

	change_scene(c.end_scene)
	set_source_visible(c.end_hide_source, false)
	set_source_visible(c.end_show_source, true)
	if c.end_hotkey ~= "" then
		press_hotkey(c.end_hotkey)
	end
end

local function timer_reset(t)
	t.running = false
	t.completed = false
	t.elapsed_ms = 0
	t.last_ns = nil
	t.audio_events = {}
	if t.timer_hidden then
		set_source_visible(t.cfg.text_source, true)
		t.timer_hidden = false
	end
	render(t, true)
end

local function timer_start(t)
	if t.completed then
		timer_reset(t)
	end
	if t.running then
		return
	end
	if t.elapsed_ms == 0 then
		build_audio_events(t)
	end
	t.running = true
	t.last_ns = obs.os_gettime_ns()
end

local function timer_pause(t)
	t.running = false
	t.last_ns = nil
end

local function timer_toggle(t)
	if t.running and not t.completed then
		timer_pause(t)
	else
		timer_start(t)
	end
end

local function timer_restart(t)
	timer_reset(t)
	timer_start(t)
end

local function tick_timer(t, now)
	if not t.running then
		return
	end

	if t.last_ns ~= nil then
		t.elapsed_ms = t.elapsed_ms + (now - t.last_ns) / 1000000
	end
	t.last_ns = now

	if not t.completed and t.cfg.duration_ms > 0 and t.elapsed_ms >= t.cfg.duration_ms then
		complete(t)
	end
	fire_due_audio_events(t)

	-- After completion, keep the clock going only for delayed audio actions
	if t.completed and not has_pending_audio_events(t) then
		t.running = false
		t.last_ns = nil
	end

	render(t, false)
end

----------------------------------------------------------------------------
-- Activation
--
-- Activation is checked by polling in script_tick rather than with signal or
-- frontend event callbacks. A completion action that changes scene waits for
-- the OBS window to switch, and the switch itself fires those callbacks; a
-- callback into this script at that point waits on the tick that is waiting
-- on the switch, and OBS freezes.

local streaming_was_active = false
local recording_was_active = false

local function is_source_live(source_name)
	if source_name == "" then
		return false
	end
	local source = obs.obs_get_source_by_name(source_name)
	if source == nil then
		return false
	end
	local live = obs.obs_source_active(source)
	obs.obs_source_release(source)
	return live
end

local function check_activation(t, stream_started, record_started)
	local activation = t.cfg.activation
	if activation == ACTIVATION_RESTART_LIVE or activation == ACTIVATION_WHILE_LIVE then
		local live = is_source_live(t.cfg.text_source)
		if live ~= t.was_live then
			t.was_live = live
			if activation == ACTIVATION_RESTART_LIVE then
				if live then
					timer_restart(t)
				end
			elseif live then
				timer_start(t)
			else
				timer_pause(t)
			end
		end
	elseif activation == ACTIVATION_STREAM and stream_started then
		timer_restart(t)
	elseif activation == ACTIVATION_RECORD and record_started then
		timer_restart(t)
	end
end

local function check_all_activation()
	local streaming = obs.obs_frontend_streaming_active()
	local recording = obs.obs_frontend_recording_active()
	local stream_started = streaming and not streaming_was_active
	local record_started = recording and not recording_was_active
	streaming_was_active = streaming
	recording_was_active = recording

	for _, t in ipairs(active_timers()) do
		check_activation(t, stream_started, record_started)
	end
end

-- Advances the timers once per rendered frame
function script_tick(_)
	check_all_activation()
	local now = obs.os_gettime_ns()
	for _, t in ipairs(active_timers()) do
		tick_timer(t, now)
	end
end

----------------------------------------------------------------------------
-- Hotkeys for each timer (registered as timers are added)

local function hotkey_label(i, action)
	return "Advanced Timer " .. i .. ": " .. action
end

local function load_hotkey(id, saved_key)
	if script_settings == nil then
		return
	end
	local saved = obs.obs_data_get_array(script_settings, saved_key)
	obs.obs_hotkey_load(id, saved)
	obs.obs_data_array_release(saved)
end

local function register_hotkeys(count)
	for i = 1, count do
		local t = timers[i]
		if t.hotkey_start_id == nil then
			t.hotkey_start_id = obs.obs_hotkey_register_frontend(
				"advanced_timer_start_pause_" .. i, hotkey_label(i, "Start / Pause"),
				function(pressed)
					if pressed then
						timer_toggle(t)
					end
				end)
			t.hotkey_reset_id = obs.obs_hotkey_register_frontend(
				"advanced_timer_reset_" .. i, hotkey_label(i, "Reset"),
				function(pressed)
					if pressed then
						timer_reset(t)
					end
				end)
			load_hotkey(t.hotkey_start_id, key("hotkey_start_pause", i))
			load_hotkey(t.hotkey_reset_id, key("hotkey_reset", i))
		end
	end
end

----------------------------------------------------------------------------
-- Properties

local function fill_text_sources(prop, show_all)
	obs.obs_property_list_clear(prop)
	obs.obs_property_list_add_string(prop, "-- Select a text source --", "")
	for _, name in ipairs(source_names(is_text_source)) do
		if show_all or name:lower():find("timer", 1, true) then
			obs.obs_property_list_add_string(prop, name, name)
		end
	end
end

local function fill_scenes(prop)
	obs.obs_property_list_clear(prop)
	obs.obs_property_list_add_string(prop, "-- Do not change scene --", "")
	for _, name in ipairs(scene_names()) do
		obs.obs_property_list_add_string(prop, name, name)
	end
end

local function fill_sources(prop, empty_label)
	obs.obs_property_list_clear(prop)
	obs.obs_property_list_add_string(prop, empty_label, "")
	for _, name in ipairs(source_names(nil)) do
		obs.obs_property_list_add_string(prop, name, name)
	end
end

local function timer_title(i, settings)
	local source = settings and obs.obs_data_get_string(settings, key("text_source", i)) or ""
	if source ~= "" then
		return "Timer " .. i .. " (" .. source .. ")"
	end
	return "Timer " .. i
end

local function fill_edit_list(props, settings)
	local prop = obs.obs_properties_get(props, "edit_timer")
	local count = obs.obs_data_get_int(settings, "timer_count")
	obs.obs_property_list_clear(prop)
	for i = 1, count do
		obs.obs_property_list_add_int(prop, timer_title(i, settings), i)
	end
end

local function fill_all_lists(props, settings)
	for i = 1, MAX_TIMERS do
		fill_text_sources(obs.obs_properties_get(props, key("text_source", i)),
			obs.obs_data_get_bool(settings, key("show_all_text", i)))
		fill_scenes(obs.obs_properties_get(props, key("end_scene", i)))
		fill_sources(obs.obs_properties_get(props, key("end_hide_source", i)), "-- Do not hide a source --")
		fill_sources(obs.obs_properties_get(props, key("end_show_source", i)), "-- Do not show a source --")
	end
	fill_edit_list(props, settings)
end

local function set_visible(props, name, visible)
	local prop = obs.obs_properties_get(props, name)
	if prop ~= nil then
		obs.obs_property_set_visible(prop, visible)
	end
end

-- Shows only the timer being edited, and only the options that apply to it
local function update_visibility(props, settings)
	local count = obs.obs_data_get_int(settings, "timer_count")
	local edit = obs.obs_data_get_int(settings, "edit_timer")
	if edit < 1 or edit > count then
		edit = 1
		obs.obs_data_set_int(settings, "edit_timer", edit)
	end

	for i = 1, MAX_TIMERS do
		set_visible(props, key("group_timer", i), i == edit)
		local custom = obs.obs_data_get_string(settings, key("format_mode", i)) == FORMAT_CUSTOM
		set_visible(props, key("format", i), custom)
		set_visible(props, key("hide_zero_groups", i), not custom)
		set_visible(props, key("hide_single_zero", i), not custom)
		set_visible(props, key("show_ms", i), not custom)
		set_visible(props, key("end_text", i),
			obs.obs_data_get_string(settings, key("end_action", i)) == END_TEXT)
	end
end

local function refresh_view(props, p, settings)
	update_visibility(props, settings)
	return true
end

local function timer_count_modified(props, p, settings)
	fill_edit_list(props, settings)
	update_visibility(props, settings)
	return true
end

local function text_source_modified(props, p, settings)
	fill_edit_list(props, settings)
	return true
end

local function refresh_clicked(props, p)
	if script_settings ~= nil then
		fill_all_lists(props, script_settings)
	end
	return true
end

local function add_section_label(props, name, label)
	if obs.OBS_TEXT_INFO ~= nil then
		obs.obs_properties_add_text(props, name, label, obs.OBS_TEXT_INFO)
	end
end

local function add_timer_properties(props, i, audio_sources)
	local t = timers[i]
	local group = obs.obs_properties_create()

	-- Timer
	local text_source = obs.obs_properties_add_list(group, key("text_source", i), "Text source",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_set_modified_callback(text_source, text_source_modified)
	local show_all = obs.obs_properties_add_bool(group, key("show_all_text", i),
		"List all text sources (not only ones with \"Timer\" in the name)")
	obs.obs_property_set_modified_callback(show_all, function(ps, p, settings)
		fill_text_sources(obs.obs_properties_get(ps, key("text_source", i)),
			obs.obs_data_get_bool(settings, key("show_all_text", i)))
		return true
	end)

	local mode = obs.obs_properties_add_list(group, key("mode", i), "Timer type",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(mode, "Count down", MODE_DOWN)
	obs.obs_property_list_add_string(mode, "Count up", MODE_UP)

	local duration = obs.obs_properties_add_text(group, key("duration", i), "Duration (hh:mm:ss)",
		obs.OBS_TEXT_DEFAULT)
	obs.obs_property_set_long_description(duration,
		"Count down starts here and ends at 00:00:00. Count up starts at 00:00:00 and stops here. " ..
		"Leave at 00:00:00 for a count up that never ends.")

	local activation = obs.obs_properties_add_list(group, key("activation", i), "Activation mode",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(activation, "Manual (buttons and hotkeys only)", ACTIVATION_MANUAL)
	obs.obs_property_list_add_string(activation, "Restart when the text source goes live", ACTIVATION_RESTART_LIVE)
	obs.obs_property_list_add_string(activation, "Run only while the text source is live", ACTIVATION_WHILE_LIVE)
	obs.obs_property_list_add_string(activation, "Restart when streaming starts", ACTIVATION_STREAM)
	obs.obs_property_list_add_string(activation, "Restart when recording starts", ACTIVATION_RECORD)
	obs.obs_property_set_long_description(activation,
		"\"Live\" means the text source is showing in the program (on stream), not just in the preview.")

	-- Display
	add_section_label(group, key("label_display", i), "Display")
	local format_mode = obs.obs_properties_add_list(group, key("format_mode", i), "Format",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(format_mode, "Standard (use the options below)", FORMAT_AUTO)
	obs.obs_property_list_add_string(format_mode, "Custom format", FORMAT_CUSTOM)
	obs.obs_property_set_modified_callback(format_mode, refresh_view)

	local format = obs.obs_properties_add_text(group, key("format", i), "Custom format",
		obs.OBS_TEXT_DEFAULT)
	obs.obs_property_set_long_description(format,
		"%d days, %h hours, %m minutes, %s seconds. Double a letter for 2 digits (%hh, %mm, %ss). " ..
		"%f tenths, %ff hundredths, %fff milliseconds. The largest unit used holds the rest of the time, " ..
		"so %mm:%ss shows 1 hour 5 minutes as 65:00. Example: %h:%mm:%ss.%ff")
	obs.obs_properties_add_bool(group, key("hide_zero_groups", i),
		"Hide leading 00 (00:08:30 shows as 08:30, 00:00:08 as 08)")
	obs.obs_properties_add_bool(group, key("hide_single_zero", i),
		"Hide leading single 0 (08:30 shows as 8:30)")
	obs.obs_properties_add_bool(group, key("show_ms", i),
		"Show hundredths of a second (07:48.19)")
	obs.obs_properties_add_text(group, key("prefix", i), "Text before the time", obs.OBS_TEXT_DEFAULT)
	obs.obs_properties_add_text(group, key("suffix", i), "Text after the time", obs.OBS_TEXT_DEFAULT)

	-- Controls
	add_section_label(group, key("label_controls", i), "Controls")
	obs.obs_properties_add_button(group, key("start_pause_button", i), "Start / Pause", function()
		timer_toggle(t)
		return false
	end)
	obs.obs_properties_add_button(group, key("reset_button", i), "Reset", function()
		timer_reset(t)
		return false
	end)

	-- Completion actions
	add_section_label(group, key("label_finish", i), "When the timer completes")
	local end_action = obs.obs_properties_add_list(group, key("end_action", i), "Timer text",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(end_action, "Keep the final value", END_KEEP)
	obs.obs_property_list_add_string(end_action, "Hide the text source", END_HIDE)
	obs.obs_property_list_add_string(end_action, "Change the text", END_TEXT)
	obs.obs_property_list_add_string(end_action, "Reset to the starting value", END_RESET)
	obs.obs_property_set_modified_callback(end_action, refresh_view)
	obs.obs_properties_add_text(group, key("end_text", i), "New text", obs.OBS_TEXT_DEFAULT)

	obs.obs_properties_add_list(group, key("end_scene", i), "Change scene",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_properties_add_list(group, key("end_hide_source", i), "Hide a source",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_properties_add_list(group, key("end_show_source", i), "Show a source",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)

	local hotkey = obs.obs_properties_add_text(group, key("end_hotkey", i), "Press hotkey",
		obs.OBS_TEXT_DEFAULT)
	obs.obs_property_set_long_description(hotkey,
		"A key combo bound in OBS Settings > Hotkeys, e.g. Ctrl+Shift+F5. Leave empty for none.")
	obs.obs_properties_add_button(group, key("test_hotkey_button", i), "Test hotkey", function()
		press_hotkey(t.cfg.end_hotkey)
		return false
	end)

	-- Audio
	add_section_label(group, key("label_audio", i), "Audio when the timer completes")
	for _, name in ipairs(audio_sources) do
		local action = obs.obs_properties_add_list(group, audio_key_action(i, name), name,
			obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
		obs.obs_property_list_add_string(action, "Leave as is", AUDIO_NONE)
		obs.obs_property_list_add_string(action, "Mute", AUDIO_MUTE)
		obs.obs_property_list_add_string(action, "Unmute", AUDIO_UNMUTE)
		local offset = obs.obs_properties_add_int(group, audio_key_offset(i, name),
			name .. " delay / offset (ms)", -86400000, 86400000, 100)
		obs.obs_property_set_long_description(offset,
			"Positive: run this long after the timer completes (1000 = 1 second later). " ..
			"Negative: run this long before it completes (-10000 = 10 seconds early).")
	end

	obs.obs_properties_add_group(props, key("group_timer", i), timer_title(i, script_settings),
		obs.OBS_GROUP_NORMAL, group)
end

function script_properties()
	local props = obs.obs_properties_create()

	local count = obs.obs_properties_add_int(props, "timer_count", "Number of timers", 1, MAX_TIMERS, 1)
	obs.obs_property_set_modified_callback(count, timer_count_modified)
	local edit = obs.obs_properties_add_list(props, "edit_timer", "Edit timer",
		obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
	obs.obs_property_set_modified_callback(edit, refresh_view)
	obs.obs_properties_add_button(props, "refresh_button", "Refresh source and scene lists",
		refresh_clicked)

	local audio_sources = source_names(is_audio_source)
	for i = 1, MAX_TIMERS do
		add_timer_properties(props, i, audio_sources)
	end

	if script_settings ~= nil then
		fill_all_lists(props, script_settings)
		update_visibility(props, script_settings)
	end

	return props
end

function script_description()
	return [[<h2 style="color:#f0b429;margin-bottom:0">ADVANCED TIMER</h2>
<p style="margin-top:4px"><b>Ver ]] .. SCRIPT_VERSION .. [[</b> &nbsp; by ]] .. SCRIPT_AUTHOR .. [[</p>
<p style="color:#7ed957">Sets text sources to act as timers with advanced options. Hotkeys can be set for
starting/pausing and resetting each timer.</p>
<p>Set how many timers you need, then pick one under "Edit timer" to change its settings.
Tip: put "Timer" in your text source's name so it shows in the list.</p>]]
end

function script_defaults(settings)
	obs.obs_data_set_default_int(settings, "timer_count", 1)
	obs.obs_data_set_default_int(settings, "edit_timer", 1)
	for i = 1, MAX_TIMERS do
		obs.obs_data_set_default_string(settings, key("mode", i), MODE_DOWN)
		obs.obs_data_set_default_string(settings, key("duration", i), "00:05:00")
		obs.obs_data_set_default_string(settings, key("activation", i), ACTIVATION_MANUAL)
		obs.obs_data_set_default_string(settings, key("format_mode", i), FORMAT_AUTO)
		obs.obs_data_set_default_string(settings, key("format", i), "%hh:%mm:%ss")
		obs.obs_data_set_default_string(settings, key("end_action", i), END_KEEP)
	end
end

local function read_timer_settings(t, settings)
	local i = t.index
	local c = t.cfg
	local previous_source = c.text_source

	c.text_source = obs.obs_data_get_string(settings, key("text_source", i))
	c.mode = obs.obs_data_get_string(settings, key("mode", i))
	c.activation = obs.obs_data_get_string(settings, key("activation", i))
	c.format_mode = obs.obs_data_get_string(settings, key("format_mode", i))
	c.format = obs.obs_data_get_string(settings, key("format", i))
	c.prefix = obs.obs_data_get_string(settings, key("prefix", i))
	c.suffix = obs.obs_data_get_string(settings, key("suffix", i))
	c.hide_zero_groups = obs.obs_data_get_bool(settings, key("hide_zero_groups", i))
	c.hide_single_zero = obs.obs_data_get_bool(settings, key("hide_single_zero", i))
	c.show_ms = obs.obs_data_get_bool(settings, key("show_ms", i))
	c.end_action = obs.obs_data_get_string(settings, key("end_action", i))
	c.end_text = obs.obs_data_get_string(settings, key("end_text", i))
	c.end_scene = obs.obs_data_get_string(settings, key("end_scene", i))
	c.end_hide_source = obs.obs_data_get_string(settings, key("end_hide_source", i))
	c.end_show_source = obs.obs_data_get_string(settings, key("end_show_source", i))
	c.end_hotkey = obs.obs_data_get_string(settings, key("end_hotkey", i))

	local duration_text = obs.obs_data_get_string(settings, key("duration", i))
	local duration_ms = parse_duration(duration_text)
	if duration_ms == nil then
		obs.script_log(obs.LOG_WARNING, "Timer " .. i .. ": can't read duration \"" ..
			duration_text .. "\", expected hh:mm:ss")
	else
		c.duration_ms = duration_ms
	end

	if c.text_source ~= previous_source then
		t.last_text = nil
		t.was_live = false
	end
end

function script_update(settings)
	script_settings = settings
	timer_count = math.max(1, math.min(obs.obs_data_get_int(settings, "timer_count"), MAX_TIMERS))

	for i = 1, MAX_TIMERS do
		read_timer_settings(timers[i], settings)
	end
	for i = timer_count + 1, MAX_TIMERS do
		timer_pause(timers[i])
	end
	register_hotkeys(timer_count)

	for _, t in ipairs(active_timers()) do
		render(t, false)
	end
end

function script_save(settings)
	for i = 1, MAX_TIMERS do
		local t = timers[i]
		if t.hotkey_start_id ~= nil then
			local start_hotkey = obs.obs_hotkey_save(t.hotkey_start_id)
			obs.obs_data_set_array(settings, key("hotkey_start_pause", i), start_hotkey)
			obs.obs_data_array_release(start_hotkey)

			local reset_hotkey = obs.obs_hotkey_save(t.hotkey_reset_id)
			obs.obs_data_set_array(settings, key("hotkey_reset", i), reset_hotkey)
			obs.obs_data_array_release(reset_hotkey)
		end
	end
end

function script_load(settings)
	script_settings = settings
	timer_count = math.max(1, math.min(obs.obs_data_get_int(settings, "timer_count"), MAX_TIMERS))
	register_hotkeys(timer_count)

	-- Don't restart timers for a stream or recording already running at load
	streaming_was_active = obs.obs_frontend_streaming_active()
	recording_was_active = obs.obs_frontend_recording_active()
end
