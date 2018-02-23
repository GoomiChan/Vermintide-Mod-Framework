--[[ Add ability to turn mods into mutators --]]

local manager = new_mod("vmf_mutator_manager")

manager:localization("localization/mutator_manager")

-- List of mods that are also mutators in order in which they should be enabled
-- This is populated via VMFMod.register_as_mutator
manager.mutators = {}
local mutators = manager.mutators

-- Table of mutators' configs by name
local mutators_config = {}
local default_config = manager:dofile("scripts/mods/vmf/modules/mutators/mutator_default_config")

-- This lists mutators and which ones should be enabled after them
-- This is populated via VMFMod.register_as_mutator
local mutators_sequence = {
	--[[
	this_mutator = {
		"will be enabled",
		"before these ones"
	}
	]]--
}

-- So we don't sort after each one is added
local mutators_sorted = false

-- So we don't have to check when player isn't hosting
local all_mutators_disabled = false


--[[
	PRIVATE METHODS
]]--

local mutators_view = manager:dofile("scripts/mods/vmf/modules/mutators/mutator_gui")
local dice_manager = manager:dofile("scripts/mods/vmf/modules/mutators/mutator_dice")
local set_lobby_data = manager:dofile("scripts/mods/vmf/modules/mutators/mutator_info")

-- Adds mutator names from enable_these_after to the list of mutators that should be enabled after the mutator_name
local function update_mutators_sequence(mutator_name, enable_these_after)
	if not mutators_sequence[mutator_name] then
		mutators_sequence[mutator_name] = {}
	end
	for _, other_mutator_name in ipairs(enable_these_after) do

		if mutators_sequence[other_mutator_name] and table.has_item(mutators_sequence[other_mutator_name], mutator_name) then
			manager:error("Mutators '" .. mutator_name .. "' and '" .. other_mutator_name .. "' are both set to load after the other one.")
		elseif not table.has_item(mutators_sequence[mutator_name], other_mutator_name) then
			table.insert(mutators_sequence[mutator_name], other_mutator_name)
		end

	end
	table.combine(mutators_sequence[mutator_name], enable_these_after)
end

-- Checks if mutators are compatible both ways
local function is_compatible(mutator, other_mutator)
	local config = mutator:get_config()
	local name = mutator:get_name()
	local other_config = other_mutator:get_config()
	local other_name = other_mutator:get_name()

	local incompatible_specifically = (
		#config.incompatible_with > 0 and (
			table.has_item(config.incompatible_with, other_name)
		) or
		#other_config.incompatible_with > 0 and (
			table.has_item(other_config.incompatible_with, name)
		)
	)

	local compatible_specifically = (
		#config.compatible_with > 0 and (
			table.has_item(config.compatible_with, other_name)
		) or
		#other_config.compatible_with > 0 and (
			table.has_item(other_config.compatible_with, name)
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

-- Called after mutator is enabled
local function on_enabled(mutator)
	local config = mutator:get_config()
	dice_manager.addDice(config.dice)
	set_lobby_data()
	print("[MUTATORS] Enabled " .. mutator:get_name() .. " (" .. tostring(table.index_of(mutators, mutator)) .. ")")
end

-- Called after mutator is disabled
local function on_disabled(mutator)
	local config = mutator:get_config()
	dice_manager.removeDice(config.dice)
	set_lobby_data()
	print("[MUTATORS] Disabled " .. mutator:get_name() .. " (" .. tostring(table.index_of(mutators, mutator)) .. ")")
end

-- Enables/disables mutator while preserving the sequence in which they were enabled
local function set_mutator_state(mutator, state)

	local i = table.index_of(mutators, mutator)
	if i == nil then
		mutator:error("Mutator isn't in the list")
		return
	end

	if state == mutator:is_enabled() then
		return
	end

	if state and (
		not mutator:can_be_enabled() or 
		Managers.state and Managers.state.game_mode and Managers.state.game_mode._game_mode_key ~= "inn"
	) then
		return
	end

	-- Sort mutators if this is the first call
	if not mutators_sorted then
		manager.sort_mutators()
	end

	local disabled_mutators = {}
	local enable_these_after = mutators_sequence[mutator:get_name()]

	-- Disable mutators that were and are required to be enabled after the current one
	-- This will be recursive so that if mutator2 requires mutator3 to be enabled after it, mutator3 will be disabled before mutator2
	-- Yeah this is super confusing
	if enable_these_after and #mutators > i then
		for j = #mutators, i + 1, -1 do
			if mutators[j]:is_enabled() and table.has_item(enable_these_after, mutators[j]:get_name()) then
				--print("Disabled ", mutators[j]:get_name())
				mutators[j]:disable()
				table.insert(disabled_mutators, 1, mutators[j])
			end
		end
	end

	-- Enable/disable current mutator
	-- We're calling methods on the class object because we've overwritten them on the current one
	if state then
		VMFMod.enable(mutator)
		on_enabled(mutator)
	else
		VMFMod.disable(mutator)
		on_disabled(mutator)
	end

	-- Re-enable disabled mutators
	-- This will be recursive
	if #disabled_mutators > 0 then
		for j = #disabled_mutators, 1, -1 do
			--print("Enabled ", disabled_mutators[j]:get_name())
			disabled_mutators[j]:enable()
		end
	end
end

-- Checks if the player is server in a way that doesn't incorrectly return false during loading screens
local function player_is_server()
	local player = Managers.player
	local state = Managers.state	
	return not player or player.is_server or not state or state.game_mode == nil
end

--[[
	PUBLIC METHODS
]]--

-- Sorts mutators in order they should be enabled
manager.sort_mutators = function()

	if mutators_sorted then return end

	--[[
	-- LOG --
	manager:dump(mutators_sequence, "seq", 5)
	for i, v in ipairs(mutators) do
		print(i, v:get_name())
	end
	print("-----------")
	-- /LOG --
	--]]

	-- Preventing endless loops (worst case is n*(n+1)/2 I believe)
	local maxIter = #mutators * (#mutators + 1)/2
	local numIter = 0

	-- The idea is that all mutators before the current one are already in the right order
	-- Starting from second mutator
	local i = 2
	while i <= #mutators do
		local mutator = mutators[i]
		local mutator_name = mutator:get_name()
		local enable_these_after = mutators_sequence[mutator_name] or {}

		-- Going back from the previous mutator to the start of the list
		local j = i - 1
		while j > 0 do
			local other_mutator = mutators[j]

			-- Moving it after the current one if it is to be enabled after it
			if table.has_item(enable_these_after, other_mutator:get_name()) then
				table.remove(mutators, j)
				table.insert(mutators, i, other_mutator)

				-- This will shift the current mutator back, so adjust the index
				i = i - 1
			end
			j = j - 1
		end

		i = i + 1

		numIter = numIter + 1
		if numIter > maxIter then
			manager:error("Mutators: too many iterations. Check for loops in 'enable_before_these'/'enable_after_these'.")
			return
		end
	end
	mutators_sorted = true

	-- LOG --
	print("[MUTATORS] Sorted")
	for k, v in ipairs(mutators) do
		print("    ", k, v:get_name())
	end
	-- /LOG --
end

-- Disables mutators that cannot be enabled right now
manager.disable_impossible_mutators = function(notify, everybody, reason)
	local disabled_mutators = {}
	for i = #mutators, 1, -1 do
		local mutator = mutators[i]
		if mutator:is_enabled() and not mutator:can_be_enabled() then
			mutator:disable()
			table.insert(disabled_mutators, mutator)
		end
	end
	if #disabled_mutators > 0 and notify then
		if not reason then reason = "" end
		local loc = everybody and "broadcast_disabled_mutators" or "local_disabled_mutators"
		local message = manager:localize(loc) .. " " .. manager:localize(reason) .. ":"
		message = message .. " " .. manager.add_mutator_titles_to_string(disabled_mutators, "", ", ", false)
		if everybody then
			manager:chat_broadcast(message)
		else
			manager:echo(message)
		end
	end
	return disabled_mutators
end

-- Appends, prepends and replaces the string with mutator titles
manager.add_mutator_titles_to_string = function(_mutators, str, separator, short)
	
	if #_mutators == 0 then return str end

	local before = nil
	local after = nil
	local replace = nil

	for _, mutator in ipairs(_mutators) do
		local config = mutator:get_config()
		local added_name = (short and config.short_title or config.title or mutator:get_name())
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

-- Check if player is still hosting
manager.update = function()
	if not all_mutators_disabled and not player_is_server() then
		manager.disable_impossible_mutators(true, false, "disabled_reason_not_server")
		all_mutators_disabled = true
	end
end


--[[
	MUTATOR'S OWN METHODS
]]--

-- Enables mutator
local function enable_mutator(self)
	set_mutator_state(self, true)
	all_mutators_disabled = false
end

-- Disables mutator
local function disable_mutator(self)
	set_mutator_state(self, false)
end

-- Checks current difficulty, map selection screen settings (optionally), incompatible mutators and whether player is server
-- to determine if a mutator can be enabled
local function can_be_enabled(self, ignore_map)
	if #self:get_incompatible_mutators(true) > 0 then return false end
	return player_is_server() and self:supports_current_difficulty(ignore_map)
end

-- Only checks difficulty
local function supports_current_difficulty(self, ignore_map)
	local mutator_difficulty_levels = self:get_config().difficulty_levels
	local actual_difficulty = Managers.state and Managers.state.difficulty:get_difficulty()
	local right_difficulty = not actual_difficulty or table.has_item(mutator_difficulty_levels, actual_difficulty)

	local map_view = not ignore_map and mutators_view.map_view
	local map_view_active = map_view and map_view.active
	local right_unapplied_difficulty = false

	if map_view_active then

		local difficulty_data = map_view.selected_level_index and map_view:get_difficulty_data(map_view.selected_level_index)
		local difficulty_layout = difficulty_data and difficulty_data[map_view.selected_difficulty_stepper_index]
		local difficulty_key = difficulty_layout and difficulty_layout.key
		right_unapplied_difficulty = difficulty_key and table.has_item(mutator_difficulty_levels, difficulty_key)
	end

	return (map_view_active and right_unapplied_difficulty) or (not map_view_active and right_difficulty)
end

-- Returns the config object for mutator from mutators_config
local function get_config(self)
	return mutators_config[self:get_name()]
end

-- Returns a list of incompatible with self mutators, all or only enabled ones
local function get_incompatible_mutators(self, enabled_only)
	local incompatible_mutators = {}
	for _, other_mutator in ipairs(mutators) do
		if (
			other_mutator ~= self and
			(not enabled_only or other_mutator:is_enabled()) and
			not is_compatible(self, other_mutator)
		) then
			table.insert(incompatible_mutators, other_mutator)
		end
	end
	return incompatible_mutators
end

-- Turns a mod into a mutator
VMFMod.register_as_mutator = function(self, config)
	if not config then config = {} end

	local mod_name = self:get_name()

	if table.has_item(mutators, self) then
		self:error("Mod is already registered as mutator")
		return
	end

	table.insert(mutators, self)

	-- Save config
	mutators_config[mod_name] = table.clone(default_config)
	local _config = mutators_config[mod_name]
	for k, _ in pairs(_config) do
		if config[k] ~= nil then
			_config[k] = config[k]
		end
	end
	if _config.short_title == "" then _config.short_title = nil end
	if _config.title == "" then _config.title = nil end

	if config.enable_before_these then
		update_mutators_sequence(mod_name, config.enable_before_these)
	end

	if config.enable_after_these then
		for _, other_mod_name in ipairs(config.enable_after_these) do
			update_mutators_sequence(other_mod_name, {mod_name})
		end
	end

	self.enable = enable_mutator
	self.disable = disable_mutator
	self.can_be_enabled = can_be_enabled
	self.supports_current_difficulty = supports_current_difficulty

	self.get_config = get_config
	self.get_incompatible_mutators = get_incompatible_mutators

	mutators_sorted = false

	-- Always init in the off state
	self:init_state(false)

	mutators_view:update_mutator_list()
end


--[[
	HOOKS
]]--
manager:hook("DifficultyManager.set_difficulty", function(func, self, difficulty)
	manager.disable_impossible_mutators(true, true, "disabled_reason_difficulty_change")
	return func(self, difficulty)
end)


--[[
	INITIALIZE
--]]

-- Initialize mutators view when map_view has been initialized already
mutators_view:init(mutators_view:get_map_view())

--[[
	Testing
--]]
-- manager:dofile("scripts/mods/vmf/modules/mutators/mutator_test")
-- manager:dofile("scripts/mods/vmf/modules/mutators/mutators/mutation")
-- manager:dofile("scripts/mods/vmf/modules/mutators/mutators/deathwish")
