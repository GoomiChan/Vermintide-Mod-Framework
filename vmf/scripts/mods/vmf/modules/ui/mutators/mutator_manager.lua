--[[ Add ability to turn mods into mutators --]]
local vmf = get_mod("VMF")

-- List of mods that are also mutators in order in which they should be enabled
-- This is populated via vmf.register_mod_as_mutator
local _MUTATORS = {}


-- This lists mutators and which ones should be enabled after them
-- This is populated via vmf.register_mod_as_mutator
local _MUTATORS_SEQUENCE = {
	--[[
	this_mutator = {
		"will be enabled",
		"before these ones"
	}
	]]--
}

-- So we don't sort after each one is added
local _MUTATORS_SORTED = false

-- So we don't have to check when player isn't hosting
local _ALL_MUTATORS_DISABLED = false

-- External modules
local _MUTATORS_VIEW
local _DICE_MANAGER
local _SET_LOBBY_DATA

local _MUTATORS_GUI

local _DEFAULT_CONFIG

-- List of enabled mutators in case VMF is reloaded in the middle of the game
local _ENABLED_MUTATORS = vmf:persistent_table("enabled_mutators")

-- ####################################################################################################################
-- ##### Local functions ##############################################################################################
-- ####################################################################################################################

local function get_index(tbl, o)
	for i, v in ipairs(tbl) do
		if o == v then
			return i
		end
	end
	return nil
end

-- Adds mutator names from enable_these_after to the list of mutators that should be enabled after the mutator_name
local function update_mutators_sequence(mutator_name, enable_these_after)
	if not _MUTATORS_SEQUENCE[mutator_name] then
		_MUTATORS_SEQUENCE[mutator_name] = {}
	end
	for _, other_mutator_name in ipairs(enable_these_after) do

		if _MUTATORS_SEQUENCE[other_mutator_name] and table.contains(_MUTATORS_SEQUENCE[other_mutator_name], mutator_name) then
			vmf:error("(mutators): Mutators '%s' and '%s' are both set to load after each other.", mutator_name, other_mutator_name)
		elseif not table.contains(_MUTATORS_SEQUENCE[mutator_name], other_mutator_name) then
			table.insert(_MUTATORS_SEQUENCE[mutator_name], other_mutator_name)
		end
	end
end

-- Checks if mutators are compatible both ways
local function is_compatible(mutator, other_mutator)
	local config = mutator:get_config()
	local name = mutator:get_name()
	local other_config = other_mutator:get_config()
	local other_name = other_mutator:get_name()

	local incompatible_specifically = (
		#config.incompatible_with > 0 and (
			table.contains(config.incompatible_with, other_name)
		) or
		#other_config.incompatible_with > 0 and (
			table.contains(other_config.incompatible_with, name)
		)
	)

	local compatible_specifically = (
		#config.compatible_with > 0 and (
			table.contains(config.compatible_with, other_name)
		) or
		#other_config.compatible_with > 0 and (
			table.contains(other_config.compatible_with, name)
		)
	)

	local compatible
	if incompatible_specifically then
		compatible = false
	elseif compatible_specifically then
		compatible = true
	elseif config.compatible_with_all or other_config.compatible_with_all then
		compatible = true
	elseif config.incompatible_with_all or other_config.incompatible_with_all then
		compatible = false
	else
		compatible = true
	end

	return compatible
end

-- Creates 'compatibility' entry for the mutator, checks compatibility of given mutator with all other mutators.
-- 'compatibility.mostly_compatible' is 'true' when mutator is not specifically set to be incompatible with
-- all other mutators. All the incompatible mutators will be added to 'compatibility.except'. And vice versa,
-- if 'mostly_compatible' is 'false', all the compatible mutators will be added to 'except'.
local function update_compatibility(mutator)

	-- Create default 'compatibility' entry
	local config = mutator:get_config()
	config.compatibility = {}
	local compatibility = config.compatibility
	compatibility.mostly_compatible = not config.incompatible_with_all
	compatibility.except = {}

	local mostly_compatible = compatibility.mostly_compatible
	local except = compatibility.except

	for _, other_mutator in ipairs(_MUTATORS) do

		local other_config = other_mutator:get_config()
		local other_mostly_compatible = other_config.compatibility.mostly_compatible
		local other_except = other_config.compatibility.except

		if is_compatible(mutator, other_mutator) then
			if not mostly_compatible then except[other_mutator] = true end
			if not other_mostly_compatible then other_except[mutator] = true end
		else
			if mostly_compatible then except[other_mutator] = true end
			if other_mostly_compatible then other_except[mutator] = true end
		end
	end
end

function vmf.temp_show_mutator_compatibility()

	print("MUTATORS COMPATIBILITY:")

	for _, mutator in ipairs(_MUTATORS) do
		local compatibility = mutator:get_config().compatibility

		print("\n" .. mutator:get_readable_name() .. (compatibility.mostly_compatible and "[+]" or "[-]") .. ":")

		local ident = compatibility.mostly_compatible and " - " or " + "

		for other_mutator in pairs(compatibility.except) do
			print(ident .. other_mutator:get_readable_name())
		end
	end
end

-- Called after mutator is enabled
local function on_enabled(mutator)
	local config = mutator:get_config()
	_DICE_MANAGER.addDice(config.dice)
	_SET_LOBBY_DATA()
	print("[MUTATORS] Enabled " .. mutator:get_name() .. " (" .. tostring(get_index(_MUTATORS, mutator)) .. ")")

	_ENABLED_MUTATORS[mutator:get_name()] = true
end

-- Called after mutator is disabled
local function on_disabled(mutator)
	local config = mutator:get_config()
	_DICE_MANAGER.removeDice(config.dice)
	_SET_LOBBY_DATA()
	print("[MUTATORS] Disabled " .. mutator:get_name() .. " (" .. tostring(get_index(_MUTATORS, mutator)) .. ")")

	_ENABLED_MUTATORS[mutator:get_name()] = nil
end

-- Checks if the player is server in a way that doesn't incorrectly return false during loading screens
local function player_is_server()
	local player = Managers.player
	local state = Managers.state
	return not player or player.is_server or not state or state.game_mode == nil
end

-- Sorts mutators in order they should be enabled
local function sort_mutators()

	if _MUTATORS_SORTED then return end

	--[[
	-- LOG --
	vmf:dump(_MUTATORS_SEQUENCE, "seq", 5)
	for i, v in ipairs(mutators) do
		print(i, v:get_name())
	end
	print("-----------")
	-- /LOG --
	--]]

	-- The idea is that all mutators before the current one are already in the right order
	-- Starting from second mutator
	local i = 2
	while i <= #_MUTATORS do
		local mutator = _MUTATORS[i]
		local mutator_name = mutator:get_name()
		local enable_these_after = _MUTATORS_SEQUENCE[mutator_name] or {}

		-- Going back from the previous mutator to the start of the list
		local j = i - 1
		while j > 0 do
			local other_mutator = _MUTATORS[j]

			-- Moving it after the current one if it is to be enabled after it
			if table.contains(enable_these_after, other_mutator:get_name()) then
				table.remove(_MUTATORS, j)
				table.insert(_MUTATORS, i, other_mutator)

				-- This will shift the current mutator back, so adjust the index
				i = i - 1
			end
			j = j - 1
		end

		i = i + 1
	end
	_MUTATORS_SORTED = true

	-- LOG --
	print("[MUTATORS] Sorted")
	for k, v in ipairs(_MUTATORS) do
		print("    ", k, v:get_name())
	end
	-- /LOG --
end

-- ####################################################################################################################
-- ##### VMF internal functions and variables #########################################################################
-- ####################################################################################################################

vmf.mutators = _MUTATORS

-- #########
-- # LOCAL #
-- #########

-- Checks current difficulty, map selection screen settings (optionally), incompatible mutators and whether player is server
-- to determine if a mutator can be enabled
function vmf.mutator_can_be_enabled(mutator)
	if #vmf.get_incompatible_mutators(mutator, true) > 0 then return false end
	return player_is_server() and vmf.mutator_supports_current_difficulty(mutator)
end

-- Appends, prepends and replaces the string with mutator titles
-- M, I
function vmf.add_mutator_titles_to_string(_mutators, str, separator, short)
	if #_mutators == 0 then return str end

	local before = nil
	local after = nil
	local replace = nil

	for _, mutator in ipairs(_mutators) do
		local config = mutator:get_config()
		local added_name = (short and config.short_title or mutator:get_readable_name())
		if config.title_placement == "before" then
			if before then
				before = added_name .. separator .. before
			else
				before = added_name
			end
		elseif config.title_placement == "replace" then
			if replace then
				replace = replace .. separator .. added_name
			else
				replace = added_name
			end
		else
			if after then
				after = after .. separator .. added_name
			else
				after = added_name
			end
		end
	end
	local new_str = replace or str
	if before then
		new_str = before .. (string.len(new_str) > 0 and separator or "") .. new_str
	end
	if after then
		new_str = new_str .. (string.len(new_str) > 0 and separator or "") .. after
	end
	return new_str
end

-- Returns a list of incompatible with self mutators, all or only enabled ones
-- M, G
function vmf.get_incompatible_mutators(mutator, enabled_only)
	local incompatible_mutators = {}
	for _, other_mutator in ipairs(_MUTATORS) do
		if (
			other_mutator ~= mutator and
			(not enabled_only or other_mutator:is_enabled()) and
			not is_compatible(mutator, other_mutator)
		) then
			table.insert(incompatible_mutators, other_mutator)
		end
	end
	return incompatible_mutators
end

-- Disables mutators that cannot be enabled right now
-- M, G
function vmf.disable_impossible_mutators(notify, everybody, reason)
	local disabled_mutators = {}
	for i = #_MUTATORS, 1, -1 do
		local mutator = _MUTATORS[i]
		if mutator:is_enabled() and not vmf.mutator_can_be_enabled(mutator) then
			vmf.mod_state_changed(mutator:get_name(), false)
			table.insert(disabled_mutators, mutator)
		end
	end
	if #disabled_mutators > 0 and notify then
		if not reason then reason = "" end
		local loc = everybody and "broadcast_disabled_mutators" or "local_disabled_mutators"
		local message = vmf:localize(loc) .. " " .. vmf:localize(reason) .. ":"
		message = message .. " " .. vmf.add_mutator_titles_to_string(disabled_mutators, "", ", ", false)
		if everybody then
			vmf:chat_broadcast(message)
		else
			vmf:echo(message)
		end
	end
	return disabled_mutators
end

-- Only checks difficulty
-- M, G
function vmf.mutator_supports_current_difficulty(mutator)
	local mutator_difficulty_levels = mutator:get_config().difficulty_levels
	local actual_difficulty = Managers.state and Managers.state.difficulty:get_difficulty()
	local right_difficulty = not actual_difficulty or table.contains(mutator_difficulty_levels, actual_difficulty)

	local map_view = _MUTATORS_VIEW.map_view
	local map_view_active = map_view and map_view.active
	local right_unapplied_difficulty = false

	if map_view_active then

		local difficulty_data = map_view.selected_level_index and map_view:get_difficulty_data(map_view.selected_level_index)
		local difficulty_layout = difficulty_data and difficulty_data[map_view.selected_difficulty_stepper_index]
		local difficulty_key = difficulty_layout and difficulty_layout.key
		right_unapplied_difficulty = difficulty_key and table.contains(mutator_difficulty_levels, difficulty_key)
	end

	return (map_view_active and right_unapplied_difficulty) or (not map_view_active and right_difficulty)
end

-- ##########
-- # GLOBAL #
-- ##########

-- Turns a mod into a mutator
function vmf.register_mod_as_mutator(mod, config)

	-- Form config
	config = config or {}
	local _config = table.clone(_DEFAULT_CONFIG)
	for k, _ in pairs(_config) do
		if config[k] ~= nil then
			_config[k] = config[k]
		end
	end
	if _config.short_title == "" then _config.short_title = nil end

	-- Save config inside the mod data
	mod._data.config = _config

	update_compatibility(mod)

	local mod_name = mod:get_name()

	-- @TODO: probably move these 2 blocks to the function of something like that
	if config.enable_before_these then
		update_mutators_sequence(mod_name, config.enable_before_these)
	end

	if config.enable_after_these then
		for _, other_mod_name in ipairs(config.enable_after_these) do
			update_mutators_sequence(other_mod_name, {mod_name})
		end
	end

	table.insert(_MUTATORS, mod)

	_MUTATORS_SORTED = false

	_MUTATORS_VIEW:update_mutator_list()
end

-- Enables/disables mutator while preserving the sequence in which they were enabled
function vmf.set_mutator_state(mutator, state, initial_call)

	-- Sort mutators if this is the first call
	if not _MUTATORS_SORTED then
		sort_mutators()
	end

	local disabled_mutators = {}
	local enable_these_after = _MUTATORS_SEQUENCE[mutator:get_name()]

	local i = get_index(_MUTATORS, mutator)
	-- Disable mutators that were and are required to be enabled after the current one
	-- This will be recursive so that if mutator2 requires mutator3 to be enabled after it, mutator3 will be disabled before mutator2
	-- Yeah this is super confusing
	if enable_these_after and #_MUTATORS > i then
		for j = #_MUTATORS, i + 1, -1 do
			if _MUTATORS[j]:is_enabled() and table.contains(enable_these_after, _MUTATORS[j]:get_name()) then
				--print("Disabled ", _MUTATORS[j]:get_name())
				vmf.set_mutator_state(_MUTATORS[j], false, false)
				table.insert(disabled_mutators, 1, _MUTATORS[j])
			end
		end
	end

	-- Enable/disable current mutator
	-- We're calling methods on the class object because we've overwritten them on the current one
	vmf.set_mod_state(mutator, state, initial_call)
	if state then
		_ALL_MUTATORS_DISABLED = false
		on_enabled(mutator)
	else
		on_disabled(mutator)
	end

	-- Re-enable disabled mutators
	-- This will be recursive
	if #disabled_mutators > 0 then
		for j = #disabled_mutators, 1, -1 do
			--print("Enabled ", disabled_mutators[j]:get_name())
			vmf.set_mutator_state(disabled_mutators[j], true, false)
		end
	end
end

-- Check if player is still hosting (on update)
function vmf.check_mutators_state()
	if not _ALL_MUTATORS_DISABLED and not player_is_server() then
		vmf.disable_impossible_mutators(true, false, "disabled_reason_not_server")
		_ALL_MUTATORS_DISABLED = true
	end
end

-- Called only after VMF reloading to check if some mutators were enabled before reloading
function vmf.is_mutator_enabled(mutator_name)
	return _ENABLED_MUTATORS[mutator_name]
end

-- ####################################################################################################################
-- ##### Hooks ########################################################################################################
-- ####################################################################################################################

vmf:hook("DifficultyManager.set_difficulty", function(func, self, difficulty)
	vmf.disable_impossible_mutators(true, true, "disabled_reason_difficulty_change")
	return func(self, difficulty)
end)

-- ####################################################################################################################
-- ##### Script #######################################################################################################
-- ####################################################################################################################

_DEFAULT_CONFIG = vmf:dofile("scripts/mods/vmf/modules/ui/mutators/mutator_default_config")

_MUTATORS_VIEW = vmf:dofile("scripts/mods/vmf/modules/ui/mutators/mutator_gui")
_DICE_MANAGER = vmf:dofile("scripts/mods/vmf/modules/ui/mutators/mutator_dice")
_SET_LOBBY_DATA = vmf:dofile("scripts/mods/vmf/modules/ui/mutators/mutator_info")

_MUTATORS_GUI = vmf:dofile("scripts/mods/vmf/modules/ui/mutators/mutators_gui")

-- Initialize mutators view when map_view has been initialized already
_MUTATORS_VIEW:init(_MUTATORS_VIEW:get_map_view())

-- Testing
--vmf:dofile("scripts/mods/vmf/modules/ui/mutators/test/mutator_test")
--vmf:dofile("scripts/mods/vmf/modules/ui/mutators/test/mutation")
--vmf:dofile("scripts/mods/vmf/modules/ui/mutators/test/deathwish")