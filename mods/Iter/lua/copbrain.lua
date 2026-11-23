local key = ModPath .. '	' .. RequiredScript
if _G[key] then
	return
else
	_G[key] = true
end

if not Iter.settings.streamline_path then return end

function CopBrain:search_for_coarse_path(search_id, to_seg, verify_clbk, access_neg)
	local to_pos
	local objective = self._logic_data.objective
	if objective then
		to_pos = objective.pos
		if not to_pos and alive(objective.follow_unit) then
			to_pos = objective.follow_unit:movement():nav_tracker():field_position()
		end
	end

	local params = {
		from_tracker = self._unit:movement():nav_tracker(),
		to_seg = to_seg,
		access = { 'walk' },
		id = search_id,
		results_clbk = callback(self, self, 'clbk_coarse_pathing_results', search_id),
		verify_clbk = verify_clbk,
		access_pos = self._logic_data.char_tweak.access,
		access_neg = access_neg,
		to_pos = to_pos,
	}
	self._logic_data.active_searches[search_id] = 2

	local navigation = managers.navigation
	local queued_nr = #navigation._coarse_searches
	navigation:search_coarse(params)

	-- only the search queued by this call; same-segment and invalid searches queue nothing
	local queued_search = navigation._coarse_searches[queued_nr + 1]
	if queued_search and queued_search.id == search_id then queued_search.from_pos = self._logic_data.m_pos end

	return true
end

local itr_original_copbrain_clbkcoarsepathingresults = CopBrain.clbk_coarse_pathing_results
function CopBrain:clbk_coarse_pathing_results(search_id, path)
	if path then
		local data = self._logic_data
		local my_data = data.internal_data
		local objective = data.objective

		path.coarse_dis = nil
		local navigation = managers.navigation
		if path.has_navlinks == nil and navigation.itr_path_has_navlinks then
			path.has_navlinks = navigation:itr_path_has_navlinks(path)
		end
		my_data.itr_direct_to_pos = path.has_navlinks == false
				and objective
				and objective.pos
				and managers.groupai:state():whisper_mode()
				and objective.pos
			or nil

		if not my_data.itr_direct_to_pos then
			path[1][2] = data.m_pos

			if objective and alive(objective.follow_unit) then path[#path][2] = objective.follow_unit:position() end

			path = navigation:itr_streamline(path, self._SO_access)
		end
	end

	itr_original_copbrain_clbkcoarsepathingresults(self, search_id, path)
end

local itr_original_copbrain_clbkpathingresults = CopBrain.clbk_pathing_results
function CopBrain:clbk_pathing_results(search_id, path)
	itr_original_copbrain_clbkpathingresults(self, search_id, path)

	local data = self._logic_data
	local my_data = data.internal_data
	if search_id ~= my_data.advance_path_search_id then return end

	local walk_action = my_data.advancing
	if not walk_action or not walk_action.itr_path_ahead_from then return end

	local results = data.pathing_results
	local accepted = path and results and results[search_id] == path
	if not accepted or not my_data.processing_advance_path or not my_data.coarse_path then
		walk_action.itr_path_ahead_from = nil
		return
	end

	if not walk_action:itr_append_next_step(path) then return end

	results[search_id] = nil
	my_data.processing_advance_path = nil

	if my_data.coarse_path_index >= #my_data.coarse_path - 2 then
		local end_rot = data.objective and data.objective.rot
		if end_rot then walk_action._end_rot = end_rot end
	end
end
