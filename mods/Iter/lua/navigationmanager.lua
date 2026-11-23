local key = ModPath .. '	' .. RequiredScript
if _G[key] then
	return
else
	_G[key] = true
end

dofile(Iter._path .. 'lua/_navdatapatches.lua')
local Geometry = assert(blt.vm.loadfile(Iter._path .. 'lua/_navgeometry.lua'))()
assert(type(Geometry) == 'table' and type(Geometry.new) == 'function', 'Iter: navigation geometry failed to load')

local mvec3_ang = mvector3.angle
local mvec3_dis = mvector3.distance
local mvec3_set = mvector3.set
local mvec3_sub = mvector3.subtract
local mvec3_z = mvector3.z
local math_abs = math.abs
local math_max = math.max
local table_insert = table.insert
local table_remove = table.remove

local EMPTY = {}
local tmp_vec1 = Vector3()

local function itr_seg_id(all_nav_segments, nav_seg_id)
	if nav_seg_id == nil or all_nav_segments[nav_seg_id] then
		return nav_seg_id
	end
	local string_id = tostring(nav_seg_id)
	return all_nav_segments[string_id] and string_id or nav_seg_id
end

local function itr_navlink_element(navlink)
	local script_data = navlink:script_data()
	return script_data and script_data.element
end

local function itr_release_navlink(element)
	local action = element.itr_reserved_by_action
	if action and action.itr_reserved_navlink_element == element then
		action.itr_reserved_navlink_element = nil
	end
	element.itr_reserved_by_action = nil
	element.itr_reserved_by_unit = nil
	element.itr_navlink_queue_frame_t = nil
	element.itr_navlink_queue_oldest_t = nil
	element.itr_navlink_queue_previous_oldest_t = nil
	element.itr_navlink_queue_length_in_progress = nil
	element.itr_navlink_queue_length = nil
end

local function itr_reset_navigation(self)
	self.itr_nav = nil
	self.itr_nav_failed = nil
	self.itr_coarse_cache = {}
	self.itr_navlink_planned_use = {}
end

local ENTRANCE_LEVELS = { gallery = true, framing_frame_1 = true }
local function itr_gallery_entrance_blocked(self, from, to, portal)
	if not (from == '13' and to == '1' or from == '1' and to == '13') then
		return false
	end
	if math_abs(portal.x - 2325) >= 1 or math_abs(portal.y) >= 300 then
		return false
	end
	local hit = self:raycast({
		pos_from = Vector3(2500, portal.y, portal.z),
		pos_to = Vector3(2250, portal.y, portal.z),
		allow_entry = false,
	})
	return hit and true or false
end

function NavigationManager:itr_make_neighbours_list(navseg_id)
	local geo = self.itr_nav
	if not geo then
		return
	end
	local all_nav_segments = self._nav_segments
	navseg_id = itr_seg_id(all_nav_segments, navseg_id)
	local list = {}
	for neighbour_seg_id in pairs(geo.links[navseg_id] or EMPTY) do
		local neighbour_seg = all_nav_segments[neighbour_seg_id]
		if neighbour_seg and not neighbour_seg.disabled then
			table_insert(list, neighbour_seg_id)
		end
	end
	geo.enabled[navseg_id] = list
end

-- Resyncs private views of changed directed pairs from the native graph; hints follow static door changes.
local function itr_sync_pairs(self, changed_pairs)
	local geo = self.itr_nav
	if not geo then
		return false
	end
	local all_nav_segments = self._nav_segments
	local dirty, any_change
	for _, pair in ipairs(changed_pairs) do
		local from, to = itr_seg_id(all_nav_segments, pair[1]), itr_seg_id(all_nav_segments, pair[2])
		local segment = all_nav_segments[from]
		if segment then
			local doors_changed, entries_changed = geo:set_pair(from, to, segment.neighbours[to])
			if doors_changed then
				dirty = dirty or {}
				dirty[from] = true
				dirty[to] = true
			end
			any_change = any_change or entries_changed
			self:itr_make_neighbours_list(from)
		end
	end
	if dirty then
		geo:refresh(dirty)
	end
	return any_change
end

local function itr_refresh_gallery_entrance(self)
	local geo = self.itr_nav
	if geo and geo.blocked and itr_sync_pairs(self, { { '13', '1' }, { '1', '13' } }) then
		self.itr_coarse_cache = {}
	end
end

local function itr_on_graph_changed(self, changed_pairs)
	self.itr_coarse_cache = {}
	local geo = self.itr_nav
	if geo then
		geo.free_points = {}
		itr_sync_pairs(self, changed_pairs)
	end
end

local itr_original_navigationmanager_registercoverunits = NavigationManager.register_cover_units
function NavigationManager:register_cover_units()
	local _debug = self._debug
	self._debug = true
	itr_original_navigationmanager_registercoverunits(self)
	local covers = {}
	for i = #self._covers, 1, -1 do
		local cover = self._covers[i]
		local nav_tracker = cover[3]
		if mvector3.distance(cover[1], nav_tracker:position()) < 60 then
			table.insert(covers, nav_tracker:position())
		else
			table.remove(self._covers, i)
			local location_script_data = self._quad_field:get_script_data(nav_tracker)
			table.delete(location_script_data.covers, cover)
			self._quad_field:destroy_nav_tracker(nav_tracker)
		end
	end
	self._debug = _debug
end

local itr_original_navigationmanager_registeranimnavlink = NavigationManager.register_anim_nav_link
function NavigationManager:register_anim_nav_link(element)
	local values = element._values
	if not values.itr_from_navseg then
		local intervals = {
			e_nl_fwd_2m = 0,
			e_nl_fwd_4m = 1,
		}

		local so_action = values.so_action
		if type(so_action) == 'string' then
			local interval = math.max(values.interval or 1000, 0)
			if intervals[so_action] then
				values.interval = math.min(interval, intervals[so_action])
			elseif so_action:find('rappel') or so_action:find('rapel') then
				values.interval = math.min(interval, 2)
			elseif so_action:find('jump') then
				values.interval = math.min(interval, 1)
			elseif so_action:find('ladder') then
				values.interval = math.min(interval, 1)
			elseif so_action:find('_clim') then -- climb/climd
				values.interval = math.min(interval, 2)
			elseif so_action:find('e_nl_down_') then
				values.interval = math.min(interval, 1.5)
			elseif so_action:find('e_nl_over_') then
				values.interval = math.min(interval, 1)
			elseif so_action:find('e_nl_up_') then
				values.interval = math.min(interval, 2)
			elseif so_action:find('through') then
				values.interval = math.min(interval, 1)
			end
		end

		values.itr_interval = values.interval or 0
	end
	values.interval = Iter.settings.streamline_path and 0 or values.itr_interval

	itr_original_navigationmanager_registeranimnavlink(self, element)

	local nav_link = element:nav_link()
	if nav_link then
		values.itr_from_navseg = nav_link:start_nav_segment()
		values.itr_to_navseg = nav_link:end_nav_segment()
		itr_on_graph_changed(self, { { values.itr_from_navseg, values.itr_to_navseg } })
	end
end

local itr_original_navigationmanager_unregisteranimnavlink = NavigationManager.unregister_anim_nav_link
function NavigationManager:unregister_anim_nav_link(element)
	local nav_link = element:nav_link()
	if nav_link then
		local link_key = nav_link:key()
		local from, to = nav_link:start_nav_segment(), nav_link:end_nav_segment()
		nav_link:set_delay_time(604800)
		itr_original_navigationmanager_unregisteranimnavlink(self, element)
		itr_release_navlink(element)
		if self.itr_navlink_planned_use then
			self.itr_navlink_planned_use[link_key] = nil
		end
		itr_on_graph_changed(self, { { from, to } })
	end
end

local itr_original_navigationmanager_clbknavfield = NavigationManager.clbk_navfield
function NavigationManager:clbk_navfield(event_name, args, args2, args3)
	local fuckery
	if event_name == 'add_nav_seg_neighbours' then
		for nav_seg_id in pairs(args) do
			local nav_seg = self._nav_segments[nav_seg_id]
			if nav_seg and not nav_seg.disabled_neighbours then
				nav_seg.disabled_neighbours = {}
				fuckery = true
			end
		end
	end

	itr_original_navigationmanager_clbknavfield(self, event_name, args, args2, args3)

	if fuckery then
		for nav_seg_id in pairs(args) do
			local nav_seg = self._nav_segments[nav_seg_id]
			if nav_seg and nav_seg.disabled_neighbours and not next(nav_seg.disabled_neighbours) then
				nav_seg.disabled_neighbours = nil
			end
		end
	end

	if event_name == 'add_nav_seg_neighbours' or event_name == 'remove_nav_seg_neighbours' then
		local changed_pairs = {}
		for nav_seg_id, neighbours in pairs(args) do
			for _, neighbour_seg_id in ipairs(neighbours) do
				table_insert(changed_pairs, { nav_seg_id, neighbour_seg_id })
			end
		end
		itr_on_graph_changed(self, changed_pairs)
	elseif event_name == 'obstruct_nav_link' or event_name == 'unobstruct_nav_link' then
		itr_on_graph_changed(self, { { args, args2 } })
	end
end

local itr_original_navigationmanager_setnavsegmentstate = NavigationManager.set_nav_segment_state
function NavigationManager:set_nav_segment_state(id, ...)
	itr_original_navigationmanager_setnavsegmentstate(self, id, ...)
	self.itr_coarse_cache = {}
	local geo = self.itr_nav
	if not geo then
		return
	end
	id = itr_seg_id(self._nav_segments, id)
	for segment_id, links in pairs(geo.links) do
		if segment_id == id or links[id] then
			self:itr_make_neighbours_list(segment_id)
		end
	end
end

for _, name in ipairs({ 'add_obstacle', 'remove_obstacle' }) do
	local itr_original = NavigationManager[name]
	NavigationManager[name] = function(self, ...)
		local result = itr_original(self, ...)
		itr_on_graph_changed(self, EMPTY)
		return result
	end
end

local itr_original_navigationmanager_clear = NavigationManager._clear
function NavigationManager:_clear(...)
	itr_reset_navigation(self)
	return itr_original_navigationmanager_clear(self, ...)
end

function NavigationManager:itr_get_neighbour_door_list(segment_id, neighbour_seg_id)
	local all_nav_segments = self._nav_segments
	segment_id = itr_seg_id(all_nav_segments, segment_id)
	neighbour_seg_id = itr_seg_id(all_nav_segments, neighbour_seg_id)
	local destination = all_nav_segments[neighbour_seg_id]
	if not destination or destination.disabled then
		return
	end
	local geo = self.itr_nav
	if geo then
		local links = geo.links[segment_id]
		return links and links[neighbour_seg_id]
	end
	local segment = all_nav_segments[segment_id]
	return segment and segment.neighbours[neighbour_seg_id]
end

local function itr_navlink_usable(navlink, access_pos, access_neg)
	return alive(navlink)
		and not navlink:is_obstructed()
		and (not access_pos or navlink:check_access(access_pos, access_neg or 0))
		and itr_navlink_element(navlink)
end

local function itr_log_navlink_usage(self, navlink, t)
	local planned_use = self.itr_navlink_planned_use
	if not planned_use then
		planned_use = {}
		self.itr_navlink_planned_use = planned_use
	end
	local link_key = navlink:key()
	local navlink_usage = planned_use[link_key]
	if not navlink_usage then
		navlink_usage = {}
		planned_use[link_key] = navlink_usage
	end
	local last_entry = navlink_usage[#navlink_usage]
	if not last_entry or t > last_entry then -- 1 coarse path per frame, no need to stack multiple attempts from the same NPC
		table_insert(navlink_usage, t)
	end
end

local function itr_get_navlink_usage(self, navlink, element, t)
	local navlink_usage = self.itr_navlink_planned_use and self.itr_navlink_planned_use[navlink:key()]
	if not navlink_usage then
		return 0
	end

	local nu = navlink_usage[1]
	local threshold = t - (element._values.itr_interval or 0)
	while nu and nu < threshold do
		table_remove(navlink_usage, 1)
		nu = navlink_usage[1]
	end
	return #navlink_usage
end

local function itr_get_congestion_risk(self, navlink, element, t)
	local nav_link_delay = element._values.itr_interval or 0
	if nav_link_delay <= 0 then
		return 0
	end
	local user = element.itr_reserved_by_unit
	return math_max(0, navlink:delay_time() - t)
		+ (
				(alive(user) and user:id() ~= -1 and 0 or 1)
				+ (element.itr_navlink_queue_length or 0)
				+ itr_get_navlink_usage(self, navlink, element, t)
			)
			* nav_link_delay
end

local function itr_pos_obstructed(quad_field, pos)
	local nav_tracker = quad_field:create_nav_tracker(pos, true)
	local obstructed = nav_tracker:obstructed()
	quad_field:destroy_nav_tracker(nav_tracker)
	return obstructed
end

local function itr_get_free_door_point(self, geo, door_id)
	local free = geo.free_points[door_id]
	local points = geo.door_points[door_id]
	if free == nil then
		free = false
		for i, door_pos in ipairs(points) do
			if not itr_pos_obstructed(self._quad_field, door_pos) then
				free = i
				break
			end
		end
		geo.free_points[door_id] = free
	end
	return free and points[free]
end

local function itr_static_door_pos(self, geo, i_door)
	if type(i_door) == 'number' then
		return geo and itr_get_free_door_point(self, geo, i_door) or nil
	elseif i_door.x and not itr_pos_obstructed(self._quad_field, i_door) then
		return i_door
	end
end

local function itr_pair_open(self, geo, door_list)
	for i = #door_list, 1, -1 do
		if itr_static_door_pos(self, geo, door_list[i]) then
			return true
		end
	end
	return false
end

function NavigationManager:itr_get_closest_door_to_pos(
	_,
	door_list,
	pos_from,
	pos_to,
	access_pos,
	navlink_accounting,
	access_neg
)
	if not door_list or not pos_to then
		return
	end
	local geo = self.itr_nav
	local best_pos, best_pos_with_delay, t, min_congestion_risk
	local best_dis = 1000000000
	local is_direct, through_navlink, through_navlink_with_delay

	for i = #door_list, 1, -1 do
		local i_door = door_list[i]
		if type(i_door) == 'number' then
			local door_pos = geo and itr_get_free_door_point(self, geo, i_door)
			if door_pos then
				local dis = (pos_from and mvec3_dis(pos_from, door_pos) or 0) + mvec3_dis(door_pos, pos_to)
				if dis <= best_dis then
					best_pos = door_pos
					best_dis = dis
					is_direct = true
				end
			end
		elseif i_door.x then
			-- r203: raw portals are probed too; only matched doors have cached probe points.
			if not itr_pos_obstructed(self._quad_field, i_door) then
				local dis = (pos_from and mvec3_dis(pos_from, i_door) or 0) + mvec3_dis(i_door, pos_to)
				if dis <= best_dis then
					best_pos = i_door
					best_dis = dis
					is_direct = true
				end
			end
		elseif not is_direct and itr_navlink_usable(i_door, access_pos, access_neg) then
			local element = itr_navlink_element(i_door)
			local start_pos = element:value('position')
			local end_pos = element:nav_link_end_pos()
			local dis = (pos_from and mvec3_dis(pos_from, start_pos) or 0)
				+ mvec3_dis(start_pos, end_pos)
				+ mvec3_dis(end_pos, pos_to)
			t = t or TimerManager:game():time()
			local congestion_risk = itr_get_congestion_risk(self, i_door, element, t)
			if congestion_risk == 0 then
				if dis * 1.4 < best_dis then
					is_direct = false
					best_pos = end_pos
					best_dis = dis * 1.4
					through_navlink = i_door
				end
			elseif not min_congestion_risk or congestion_risk < min_congestion_risk then
				min_congestion_risk = congestion_risk
				best_pos_with_delay = end_pos
				through_navlink_with_delay = i_door
			end
		end
	end

	if is_direct then
		through_navlink = nil
	else
		through_navlink = through_navlink or through_navlink_with_delay
		if through_navlink and navlink_accounting then
			itr_log_navlink_usage(self, through_navlink, t or TimerManager:game():time())
		end
	end

	return best_pos or best_pos_with_delay, through_navlink
end

function NavigationManager:itr_get_door_between(segment1_id, segment2_id, near_pos, access_pos, access_neg)
	local door_list = self:itr_get_neighbour_door_list(segment1_id, segment2_id)
	if door_list then
		return self:itr_get_closest_door_to_pos(nil, door_list, nil, near_pos, access_pos, true, access_neg)
	end
end

function NavigationManager:itr_find_best_navlink(
	segment1_id,
	segment2_id,
	access_pos,
	near_pos,
	current_navlink_element,
	access_neg
)
	local door_list = self:itr_get_neighbour_door_list(segment1_id, segment2_id)
	if not door_list then
		return
	end

	local best_time_to_wait = 100000000000
	local best_navlink, best_navlink_element
	for i = #door_list, 1, -1 do
		local navlink = door_list[i]
		if type(navlink) ~= 'number' and not navlink.x and itr_navlink_usable(navlink, access_pos, access_neg) then
			local navlink_element = itr_navlink_element(navlink)

			local interval = navlink_element._values.itr_interval or 0
			local extra_time_to_go = math_max(0, 1.5 - interval)
			local navpos = navlink_element:value('position')

			local queue_length = navlink_element.itr_navlink_queue_length or 0
			if navlink_element == current_navlink_element then
				queue_length = queue_length - 1
			end

			local time_to_wait = queue_length * (interval + extra_time_to_go)

			if near_pos then
				local my_time_to_go = mvec3_dis(near_pos, navpos) / (self.itr_navlink_coef * 0.7)
				time_to_wait = time_to_wait - extra_time_to_go + math_max(0, my_time_to_go - interval)
			end

			local user = navlink_element.itr_reserved_by_unit
			if alive(user) and user:id() ~= -1 then
				time_to_wait = time_to_wait
					+ interval
					+ math_max(0, mvec3_dis(user:position(), navpos) / self.itr_navlink_coef - interval)
			end

			if time_to_wait < best_time_to_wait then
				best_time_to_wait = time_to_wait
				best_navlink = navlink
				best_navlink_element = navlink_element
			end
		end
	end

	return best_navlink, best_navlink_element
end

-- Congestion cost of crossing a pair: 0 with a walkable static entry, nil when no entry is usable. Native delay
-- is a hard gate only for searches that ignore congestion; congestion-aware searches price Iter's own queue delay.
local function itr_get_accessibility(self, door_list, access_pos, access_neg, honor_delay)
	if not door_list then
		return
	end
	local best_cost, t
	for i = #door_list, 1, -1 do
		local i_door = door_list[i]
		if type(i_door) == 'number' or i_door.x then
			if itr_static_door_pos(self, self.itr_nav, i_door) then
				return 0
			end
		elseif itr_navlink_usable(i_door, access_pos, access_neg) then
			t = t or TimerManager:game():time()
			if not honor_delay or t > i_door:delay_time() then
				local element = itr_navlink_element(i_door)
				local cost = itr_get_congestion_risk(self, i_door, element, t)
				if cost == 0 then
					cost = (element._values.itr_interval or 0) > 0 and 0.1 or 0.01
				end
				if not best_cost or cost < best_cost then
					best_cost = cost
				end
			end
		end
	end
	return best_cost
end

function NavigationManager:itr_get_accessibility(door_list, access_pos, access_neg)
	return itr_get_accessibility(self, door_list, access_pos, access_neg, false)
end

NavigationManager.itr_navlink_coef = 350

if not Iter.settings.streamline_path then
	return
end

local itr_original_navigationmanager_setloaddata = NavigationManager.set_load_data
function NavigationManager:set_load_data(...)
	if not next(self._nav_segments) then
		itr_reset_navigation(self)
	end
	return itr_original_navigationmanager_setloaddata(self, ...)
end

-- Captures the converted v6 navfield the engine receives; v5 assets arrive here through the native converter.
local itr_original_navigationmanager_sendnavfieldtoengine = NavigationManager._send_nav_field_to_engine
function NavigationManager:_send_nav_field_to_engine(load_data, ...)
	local result = itr_original_navigationmanager_sendnavfieldtoengine(self, load_data, ...)
	if load_data and load_data.segments and not self.itr_nav_failed then
		local geo = self.itr_nav or Geometry.new()
		local ok, err = pcall(geo.capture, geo, load_data, self._grid_size)
		if ok then
			self.itr_nav = geo
		else
			self.itr_nav = nil
			self.itr_nav_failed = true
			log('[Iter] navigation geometry disabled for this level: ' .. tostring(err))
		end
	end
	return result
end

local function itr_reconcile_live_graph(self, geo)
	local started = os.clock()
	geo:clear_links()
	local all_nav_segments = self._nav_segments
	local level_id = Iter:get_level_id()
	geo.blocked = ENTRANCE_LEVELS[level_id]
		and Iter.settings['map_change_' .. level_id]
		and all_nav_segments['13']
		and all_nav_segments['1']
		and function(from, to, portal)
			return itr_gallery_entrance_blocked(self, from, to, portal)
		end
	local matched, links = 0, 0
	for segment_id, segment in pairs(all_nav_segments) do
		geo:ensure_segment(segment_id)
		for neighbour_seg_id, entries in pairs(segment.neighbours) do
			geo:set_pair(segment_id, neighbour_seg_id, entries)
			matched = matched + #(geo._nav_segments[segment_id].neighbours[neighbour_seg_id] or EMPTY)
			links = links + #(geo.links[segment_id][neighbour_seg_id] or EMPTY)
		end
	end
	geo:prepare_all()
	for segment_id in pairs(all_nav_segments) do
		self:itr_make_neighbours_list(segment_id)
	end
	self.itr_coarse_cache = {}
	log(
		('[Iter] navigation geometry: rooms=%d doors=%d matched=%d ambiguous=%d unmatched=%d other_entries=%d ms=%.1f'):format(
			#geo._rooms,
			#geo._room_doors,
			matched,
			geo.ambiguous,
			geo.unmatched,
			links - matched - geo.ambiguous - geo.unmatched,
			(os.clock() - started) * 1000
		)
	)
end

local itr_original_navigationmanager_resolvesegmentneighbours = NavigationManager._resolve_segment_neighbours
function NavigationManager:_resolve_segment_neighbours(...)
	local result = itr_original_navigationmanager_resolvesegmentneighbours(self, ...)
	local geo = self.itr_nav
	if geo then
		local ok, err = pcall(itr_reconcile_live_graph, self, geo)
		if not ok then
			self.itr_nav = nil
			self.itr_nav_failed = true
			log('[Iter] navigation geometry disabled for this level: ' .. tostring(err))
		end
	end
	return result
end

local axis = Vector3()
local function itr_get_door_in_alignment(self, geo, door_list, from, to)
	if not from or not to then
		return
	end
	local best_pos, best_angle
	mvec3_set(axis, to)
	mvec3_sub(axis, from)
	for i = #door_list, 1, -1 do
		local door_pos = itr_static_door_pos(self, geo, door_list[i])
		if door_pos then
			mvec3_set(tmp_vec1, door_pos)
			mvec3_sub(tmp_vec1, from)
			local angle = mvec3_ang(axis, tmp_vec1)
			if not best_angle or angle < best_angle then
				best_angle = angle
				best_pos = door_pos
			end
		end
	end
	return best_pos
end

local function itr_get_hints(geo, segment_id, neighbour_seg_id)
	local hints = geo and geo._nav_segments[segment_id]
	return hints and hints.neighbours[neighbour_seg_id] and hints
end

function NavigationManager:itr_get_coarse_pos_between(segment1_id, segment2_id, near_pos, access_pos, access_neg)
	local doors = self:itr_get_neighbour_door_list(segment1_id, segment2_id)
	if not doors then
		return false
	end

	local geo = self.itr_nav
	local hints = itr_get_hints(geo, segment1_id, segment2_id)
	if hints and itr_pair_open(self, geo, doors) then
		local best_pos = hints.choke_point_proxies[segment2_id]
			or hints.out_proxies[segment2_id]
			or hints.in_proxies[segment2_id]
		if best_pos then
			return best_pos
		end
	end

	return self:itr_get_closest_door_to_pos(nil, doors, nil, near_pos, access_pos, false, access_neg)
end

function NavigationManager:itr_path_has_navlinks(path)
	local geo = self.itr_nav
	for i = 1, #path - 1 do
		local door_list = self:itr_get_neighbour_door_list(path[i][1], path[i + 1][1])
		if door_list and not itr_pair_open(self, geo, door_list) then
			return true
		end
	end
	return false
end

-- Without geometry (capture failed) native portal lists are streamlined by alignment alone, like r203.
function NavigationManager:itr_streamline(path, access_pos, access_neg)
	local geo = self.itr_nav
	access_neg = access_neg or path.itr_access_neg
	local all_segs = self._nav_segments
	local hint_segs = geo and geo._nav_segments or EMPTY
	local path_nr = #path
	local step1 = path[1]
	local step2

	if not step1 then
		return false
	end
	for _, step in ipairs(path) do
		step[1] = itr_seg_id(all_segs, step[1])
	end

	local segment1 = all_segs[step1[1]]
	if not segment1 then
		return false
	end

	if not step1[2] then
		step1[2] = segment1.pos
	end

	for i = 2, path_nr do
		step2 = path[i]
		local segment2_id = step2[1]
		local segment2 = all_segs[segment2_id]

		if
			not segment2
			or segment2.disabled
			or access_pos and self._quad_field:is_nav_segment_blocked(segment2_id, access_pos)
		then
			return false
		end

		local door_list = self:itr_get_neighbour_door_list(step1[1], segment2_id)
		if door_list then
			local navlink
			local step3 = path[i + 1]
			local segment3 = step3 and all_segs[step3[1]]
			local hints1 = itr_get_hints(geo, step1[1], segment2_id)
			local hints2 = hint_segs[segment2_id] or EMPTY
			local hints3 = step3 and hint_segs[step3[1]] or EMPTY

			local best_pos = hints1 and hints1.choke_point_proxies[segment2_id]
			if best_pos and not itr_pair_open(self, geo, door_list) then
				best_pos = nil
			end

			if not best_pos then
				local out_proxy = step3
					and (
						hints3.choke_points and hints3.choke_points[segment2_id]
						or hints2.out_proxies and hints2.out_proxies[step3[1]]
					)
				local in_proxy = hints2.in_proxies and hints2.in_proxies[step1[1]] or segment3 and segment3.pos
				best_pos = itr_get_door_in_alignment(self, geo, door_list, step1[2], out_proxy or in_proxy)
			end

			if not best_pos then
				local proxy = step3 and hints2.in_proxies and hints2.in_proxies[step3[1]]
					or path[path_nr][2]
					or segment2.pos
				best_pos, navlink =
					self:itr_get_closest_door_to_pos(nil, door_list, step1[2], proxy, access_pos, true, access_neg)
				if not best_pos then
					return false
				end
			end

			step2[2] = best_pos
			step2[3] = navlink
			if navlink then
				path.has_navlinks = true -- callers must not treat a chosen link crossing as walkable
			end
		elseif step1[1] ~= segment2_id then
			return false
		end

		step1 = step2
	end

	path[1][2] = nil
	if path_nr > 1 and path[path_nr - 1][1] ~= path[path_nr][1] then
		path[path_nr + 1] = { path[path_nr][1] }
		path[path_nr][1] = path[path_nr - 1][1]
	end
	return path
end

local function path_copy(path)
	local result =
		{ has_navlinks = path.has_navlinks, coarse_dis = path.coarse_dis, itr_access_neg = path.itr_access_neg }
	for i = 1, #path do
		local step_src = path[i]
		table_insert(result, { step_src[1], step_src[2] })
	end
	return result
end

local function shallow_copy(t)
	local result = {}
	for k, v in pairs(t) do
		result[k] = v
	end
	return result
end

local function append(list, value)
	local result = { unpack(list) }
	result[#result + 1] = value
	return result
end

local function get_coarse_dis(p1, p2, ps)
	local dis = mvec3_dis(p1, p2)
	if ps then
		local ps_z = mvec3_z(ps)
		dis = dis + (math_abs(mvec3_z(p1) - ps_z) + math_abs(mvec3_z(p2) - ps_z)) * 2
	end
	return dis
end

-- Cache nodes keyed by the exact native values: masks and segment ids are never stringified or joined.
local NIL_KEY = {}
local function cache_node(node, value)
	if value == nil then
		value = NIL_KEY
	end
	local child = node[value]
	if not child then
		child = {}
		node[value] = child
	end
	return child
end

NavigationManager.itr_coarse_cache_lifetime = 2
NavigationManager.itr_coarse_fail_retry_t = 3

-- The native method name is misspelled (coarce); search_coarse and _commence_coarce_searches dispatch here.
local itr_original_navigationmanager_executecoarcesearch = NavigationManager._execute_coarce_search
assert(itr_original_navigationmanager_executecoarcesearch, 'Iter: native _execute_coarce_search missing')
function NavigationManager:_execute_coarce_search(search_data)
	local geo = self.itr_nav
	local all_nav_segments = self._nav_segments
	local next_seg_id = search_data.start_i_seg
	local end_i_seg = search_data.end_i_seg
	if not geo or not all_nav_segments[next_seg_id] or not all_nav_segments[end_i_seg] then
		return itr_original_navigationmanager_executecoarcesearch(self, search_data)
	end

	itr_refresh_gallery_entrance(self)

	local t = TimerManager:game():time()
	local access_pos = search_data.access_pos
	local access_neg = search_data.access_neg
	local verify_clbk = search_data.verify_clbk

	local bypass_congestion = search_data.bypass_congestion
	if not bypass_congestion then
		if type(search_data.id) ~= 'string' then
			bypass_congestion = true
		else
			local fc = search_data.id:sub(1, 1)
			bypass_congestion = not (fc == 'T' or fc == 'C')
		end
	end

	local coarse_cache = self.itr_coarse_cache
	if not coarse_cache then
		coarse_cache = {}
		self.itr_coarse_cache = coarse_cache
	end
	local use_cache = not bypass_congestion and not verify_clbk
	local cache_ends = use_cache
		and cache_node(cache_node(cache_node(coarse_cache, access_pos), access_neg), next_seg_id)

	local cached_result = use_cache and cache_ends[end_i_seg]
	if type(cached_result) == 'number' then
		if t - cached_result < self.itr_coarse_fail_retry_t then
			return false
		end
	elseif cached_result and t - cached_result.t < self.itr_coarse_cache_lifetime then
		local result = path_copy(cached_result)
		result[#result][2] = search_data.to_pos
		return search_data.results_callback and result or self:itr_streamline(result, access_pos, access_neg)
	end

	if
		all_nav_segments[end_i_seg].disabled
		or access_pos and self._quad_field:is_nav_segment_blocked(end_i_seg, access_pos)
	then
		if use_cache then
			cache_ends[end_i_seg] = t
		end
		return false
	end

	local navlink_coef = self.itr_navlink_coef
	local links = geo.links
	local enabled = geo.enabled

	local potential_paths = {}
	local seg_to_search = {}
	local discovered_seg = {
		[next_seg_id] = {
			path = { next_seg_id },
			delay = 0,
			steps_nr = 0,
			coarse_dis = 0,
			pos = search_data.from_pos or all_nav_segments[next_seg_id].pos,
		},
	}

	local candidate
	repeat
		local navseg = all_nav_segments[next_seg_id]
		local neighbours = links[next_seg_id]
		if neighbours then
			local consider_neighbours = true
			local from = discovered_seg[next_seg_id]
			local door_list = neighbours[end_i_seg]
			if door_list then
				local access_cost = itr_get_accessibility(self, door_list, access_pos, access_neg, bypass_congestion)
				if access_cost then
					if bypass_congestion then
						access_cost = 0
					end
					local through_pos =
						self:itr_get_coarse_pos_between(next_seg_id, end_i_seg, from.pos, access_pos, access_neg)
					consider_neighbours = access_cost > 0 or not through_pos
					if through_pos then
						local tmp = shallow_copy(from)
						tmp.delay = tmp.delay + access_cost
						tmp.coarse_dis = tmp.coarse_dis
							+ get_coarse_dis(tmp.pos, through_pos, navseg.pos)
							+ mvec3_dis(through_pos, search_data.to_pos or all_nav_segments[end_i_seg].pos)
						table_insert(potential_paths, tmp)

						if not candidate or tmp.coarse_dis < candidate.coarse_dis then
							if tmp.delay < 0.2 then
								candidate = tmp
							end
						end
					end
				end
			end

			if consider_neighbours then
				local enabled_neighbours = enabled[next_seg_id] or EMPTY
				for i = #enabled_neighbours, 1, -1 do
					local neighbour_seg_id = enabled_neighbours[i]
					if
						not (verify_clbk and not verify_clbk(neighbour_seg_id))
						and not (access_pos and self._quad_field:is_nav_segment_blocked(neighbour_seg_id, access_pos))
					then
						local access_cost = itr_get_accessibility(
							self,
							neighbours[neighbour_seg_id],
							access_pos,
							access_neg,
							bypass_congestion
						)
						if access_cost then
							if bypass_congestion then
								access_cost = 0
							end
							local through_pos = self:itr_get_coarse_pos_between(
								next_seg_id,
								neighbour_seg_id,
								from.pos,
								access_pos,
								access_neg
							)
							if through_pos then
								local delay = from.delay + access_cost
								local coarse_dis = from.coarse_dis + get_coarse_dis(from.pos, through_pos, navseg.pos)
								local discovered = discovered_seg[neighbour_seg_id]
								if not discovered then
									if
										not candidate
										or coarse_dis + delay * navlink_coef
											< candidate.coarse_dis + candidate.delay * navlink_coef
									then
										table_insert(seg_to_search, neighbour_seg_id)
										discovered = {
											path = append(from.path, neighbour_seg_id),
											delay = delay,
											steps_nr = from.steps_nr + 1,
											coarse_dis = coarse_dis,
											pos = through_pos,
										}
										discovered_seg[neighbour_seg_id] = discovered
									end
								elseif
									coarse_dis + delay * navlink_coef
									< discovered.coarse_dis + discovered.delay * navlink_coef
								then
									table_insert(seg_to_search, neighbour_seg_id)
									discovered.path = append(from.path, neighbour_seg_id)
									discovered.delay = delay
									discovered.steps_nr = from.steps_nr + 1
									discovered.coarse_dis = coarse_dis
									discovered.pos = through_pos
								end
							end
						end
					end
				end
			end
		end

		next_seg_id = table_remove(seg_to_search, 1)
	until not next_seg_id

	local best_score = 100000000
	local best_path
	for _, ppath in ipairs(potential_paths) do
		local score = ppath.coarse_dis + ppath.delay * navlink_coef
		if score < best_score then
			best_score = score
			best_path = ppath
		end
	end

	if not best_path then
		if use_cache then
			cache_ends[end_i_seg] = t
		end
		return false
	end

	local result = {}
	for i, seg_id in ipairs(best_path.path) do
		result[i] = { seg_id }
	end
	result[#result + 1] = {
		end_i_seg,
		search_data.to_pos,
	}
	-- From the chosen pairs, not delay: bypass searches price every usable link at 0.
	result.has_navlinks = self:itr_path_has_navlinks(result)
	result.coarse_dis = best_path.coarse_dis
	result.itr_access_neg = access_neg

	if use_cache and best_path.delay == 0 then
		local cache_result = path_copy(result)
		cache_result.t = t
		cache_ends[end_i_seg] = cache_result
	end

	return search_data.results_callback and result or self:itr_streamline(result, access_pos, access_neg)
end
