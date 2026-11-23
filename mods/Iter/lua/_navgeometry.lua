local mvec3_add = mvector3.add
local mvec3_dis_sq = mvector3.distance_sq
local mvec3_div = mvector3.divide
local mvec3_lerp = mvector3.lerp
local mvec3_set = mvector3.set
local math_max = math.max
local math_min = math.min
local table_insert = table.insert

local EMPTY = {}
local MATCH_DIS_SQ = 0.01

local Geometry = {}
Geometry.__index = Geometry

function Geometry.new()
	return setmetatable({
		_rooms = {}, -- quad id -> { borders, height }, world units
		_room_doors = {}, -- door id -> { pos, pos1, center, rooms = { quad, quad } }
		_nav_segments = {}, -- native segment id -> private hints, neighbours = { [other] = { door ids } }
		door_points = {}, -- door id -> { center, pos, pos1 }, r200 obstruction probe order
		room_seg = {}, -- quad id -> native segment id
		internal_doors = {}, -- segment id -> { [door id] = door } with both quads inside
		pair_doors = {}, -- segment id -> other id -> { crossing door ids }
		links = {}, -- segment id -> other id -> private route entries: door id, unmatched Vector3, NavLink
		enabled = {}, -- segment id -> { enabled neighbour ids }
		mirrored = {}, -- segment id -> other id -> true when choke_point_proxies[other] came from other
		free_points = {}, -- door id -> index into door_points of first unobstructed point, or false
		ambiguous = 0,
		unmatched = 0,
	}, Geometry)
end

local function count(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

local function number_array(t, n, name)
	assert(type(t) == 'table' and #t == n, 'Iter: navfield ' .. name .. ' length mismatch')
	return t
end

function Geometry:ensure_segment(id)
	local segment = self._nav_segments[id]
	if not segment then
		segment = { neighbours = {}, choke_points = {}, choke_point_proxies = {}, in_proxies = {}, out_proxies = {} }
		self._nav_segments[id] = segment
		self.internal_doors[id] = {}
		self.pair_doors[id] = {}
	end
	return segment
end

-- Appends one converted v6 navfield. Raises on malformed data; the caller drops the whole geometry.
function Geometry:capture(data, grid)
	assert(type(data) == 'table' and data.version == 6, 'Iter: v6 navfield required')
	assert(type(grid) == 'number' and grid > 0, 'Iter: navfield grid size required')
	assert(
		type(data.segments) == 'table' and type(data.visibility_groups) == 'table',
		'Iter: navfield segments missing'
	)
	local quad_offset, door_offset = #self._rooms, #self._room_doors
	local nq = #(data.quad_borders_x_pos or EMPTY)
	local x_pos = number_array(data.quad_borders_x_pos, nq, 'quad_borders_x_pos')
	local x_neg = number_array(data.quad_borders_x_neg, nq, 'quad_borders_x_neg')
	local y_pos = number_array(data.quad_borders_y_pos, nq, 'quad_borders_y_pos')
	local y_neg = number_array(data.quad_borders_y_neg, nq, 'quad_borders_y_neg')
	local h_pp = number_array(data.quad_heights_xp_yp, nq, 'quad_heights_xp_yp')
	local h_nn = number_array(data.quad_heights_xn_yn, nq, 'quad_heights_xn_yn')
	local nd = #(data.door_low_pos or EMPTY)
	local low_pos = number_array(data.door_low_pos, nd, 'door_low_pos')
	local high_pos = number_array(data.door_high_pos, nd, 'door_high_pos')
	local low_quads = number_array(data.door_low_quads, nd, 'door_low_quads')
	local high_quads = number_array(data.door_high_quads, nd, 'door_high_quads')

	local room_seg = self.room_seg
	for _, segment in ipairs(data.segments) do
		local id = tostring(segment.id)
		self:ensure_segment(id)
		for _, i_group in ipairs(segment.vis_groups or EMPTY) do
			local group = data.visibility_groups[i_group]
			assert(type(group) == 'table' and type(group.quads) == 'table', 'Iter: navfield visibility group missing')
			for _, quad in ipairs(group.quads) do
				assert(type(quad) == 'number' and quad >= 1 and quad <= nq, 'Iter: navfield quad out of range')
				local q = quad + quad_offset
				assert(not room_seg[q] or room_seg[q] == id, 'Iter: navfield quad belongs to two segments')
				room_seg[q] = id
			end
		end
	end

	for quad = 1, nq do
		self._rooms[quad + quad_offset] = {
			borders = {
				x_pos = x_pos[quad] * grid,
				x_neg = x_neg[quad] * grid,
				y_pos = y_pos[quad] * grid,
				y_neg = y_neg[quad] * grid,
			},
			height = { xp_yp = h_pp[quad], xn_yn = h_nn[quad] },
		}
	end

	for i = 1, nd do
		local low, high = low_pos[i], high_pos[i]
		local a, b = low_quads[i] + quad_offset, high_quads[i] + quad_offset
		assert(self._rooms[a] and self._rooms[b], 'Iter: navfield door references missing quad')
		local pos = Vector3(low.x * grid, low.y * grid, low.z)
		local pos1 = Vector3(high.x * grid, high.y * grid, high.z)
		local center = Vector3()
		mvec3_lerp(center, pos, pos1, 0.5)
		local id = i + door_offset
		local door = { pos = pos, pos1 = pos1, center = center, rooms = { a, b } }
		self._room_doors[id] = door
		self.door_points[id] = { center, pos, pos1 }
		local sa, sb = room_seg[a], room_seg[b]
		-- Quads outside every segment cannot carry a route; keep them only as flood rooms.
		if sa and sa == sb then
			self.internal_doors[sa][id] = door
		elseif sa and sb then
			for _, pair in ipairs({ { sa, sb }, { sb, sa } }) do
				local by_other = self.pair_doors[pair[1]]
				local candidates = by_other[pair[2]]
				if not candidates then
					candidates = {}
					by_other[pair[2]] = candidates
				end
				candidates[#candidates + 1] = id
			end
		end
	end
end

function Geometry:clear_links()
	self.links, self.enabled, self.mirrored, self.free_points = {}, {}, {}, {}
	self.ambiguous, self.unmatched = 0, 0
	for _, segment in pairs(self._nav_segments) do
		segment.neighbours = {}
	end
end

function Geometry:match_portal(from, to, portal)
	local by_other = self.pair_doors[from]
	local found, n = nil, 0
	for _, id in ipairs(by_other and by_other[to] or EMPTY) do
		if mvec3_dis_sq(self._room_doors[id].center, portal) <= MATCH_DIS_SQ then
			found, n = id, n + 1
		end
	end
	if n == 1 then
		return found
	end
	if n > 1 then
		self.ambiguous = self.ambiguous + 1
	else
		self.unmatched = self.unmatched + 1
	end
end

local function same_array(a, b)
	if a == b then
		return true
	end
	if not a or not b or #a ~= #b then
		return false
	end
	for i = 1, #a do
		if not rawequal(a[i], b[i]) then
			return false
		end
	end
	return true
end

-- Rebuilds the private view of one directed live pair. Native entries stay untouched; matched portals
-- become door ids, other portals stay usable vectors without hints, animated links follow all portals.
-- Returns doors_changed, entries_changed.
function Geometry:set_pair(from, to, entries)
	local segment = self:ensure_segment(from)
	local list, doors, used, links = {}, {}, {}, nil
	for _, entry in ipairs(entries or EMPTY) do
		if not entry.x then
			links = links or {}
			links[#links + 1] = entry
		elseif not (self.blocked and self.blocked(from, to, entry)) then
			local id = self:match_portal(from, to, entry)
			if id and not used[id] then
				used[id] = true
				doors[#doors + 1] = id
				list[#list + 1] = id
			else
				list[#list + 1] = entry
			end
		end
	end
	for _, link in ipairs(links or EMPTY) do
		list[#list + 1] = link
	end
	list = list[1] and list or nil
	doors = doors[1] and doors or nil
	local by_other = self.links[from]
	if not by_other then
		by_other = {}
		self.links[from] = by_other
	end
	local old_list, old_doors = by_other[to], segment.neighbours[to]
	by_other[to] = list
	segment.neighbours[to] = doors
	return not same_array(old_doors, doors), not same_array(old_list, list)
end

-- r200 flood/proxy algorithms below; inputs are private door ids of live directed boundaries.

function Geometry:get_nav_seg_from_i_room(i_room)
	return self.room_seg[i_room]
end

function Geometry:itr_get_all_doors_of_segment(segment_id)
	local all_seg_doors, room_neighbours = {}, {}
	for door_id, door in pairs(self.internal_doors[segment_id] or EMPTY) do
		all_seg_doors[door_id] = door
	end
	local segment = self._nav_segments[segment_id]
	for _, door_list in pairs(segment and segment.neighbours or EMPTY) do
		for _, door_id in ipairs(door_list) do
			local door = self._room_doors[door_id]
			all_seg_doors[door_id] = door
			local r1, r2 = door.rooms[1], door.rooms[2]
			room_neighbours[self.room_seg[r1] == segment_id and r2 or r1] = true
		end
	end
	return all_seg_doors, room_neighbours
end

function Geometry:itr_get_room_to_doors(segment_id, all_seg_doors)
	local result = {}
	for door_id, door in pairs(all_seg_doors) do
		for _, room_id in ipairs(door.rooms) do
			if segment_id == self:get_nav_seg_from_i_room(room_id) then
				local ri = result[room_id]
				if not ri then
					ri = {}
					result[room_id] = ri
				end
				table_insert(ri, door_id)
			end
		end
	end
	return result
end

function Geometry:itr_is_contiguous(level, door_flood_levels, room_to_doors)
	local all_doors = self._room_doors
	local level_doors = {}
	local room_pool = {}
	for door_id, door_level in pairs(door_flood_levels) do
		if door_level == level then
			level_doors[door_id] = true
			for _, room_id in ipairs(all_doors[door_id].rooms) do
				if room_to_doors[room_id] then
					room_pool[room_id] = true
				end
			end
		end
	end

	local start = next(room_pool)
	if not start then
		return false
	end
	local to_process = { [start] = true }
	local stop
	repeat
		stop = true
		local old_to_process = to_process
		to_process = {}
		for base_room_id in pairs(old_to_process) do
			room_pool[base_room_id] = nil
			for _, door_id in pairs(room_to_doors[base_room_id]) do
				for _, room_id in ipairs(all_doors[door_id].rooms) do
					if room_pool[room_id] then
						to_process[room_id] = true
						stop = false
					end
				end
				level_doors[door_id] = nil
			end
		end
	until stop

	return not next(level_doors)
end

function Geometry:itr_flood(from_doors, room_to_doors)
	local door_flood_levels = {}
	local to_process = {}
	local level = 1
	for _, door_id in pairs(from_doors) do
		door_flood_levels[door_id] = level
		to_process[door_id] = true
	end

	local all_doors = self._room_doors
	local door_level_counts = { #from_doors }
	local stop
	repeat
		stop = true
		level = level + 1
		local old_to_process = to_process
		to_process = {}
		for base_door_id in pairs(old_to_process) do
			for _, room_id in ipairs(all_doors[base_door_id].rooms) do
				local next_doors = room_to_doors[room_id]
				if next_doors then
					for _, door_id in ipairs(next_doors) do
						if not door_flood_levels[door_id] and not to_process[door_id] then
							to_process[door_id] = true
							door_flood_levels[door_id] = level
							door_level_counts[level] = (door_level_counts[level] or 0) + 1
							stop = false
						end
					end
				end
			end
		end
	until stop

	local room_flood_levels = {}
	for door_id, door_level in pairs(door_flood_levels) do
		for _, room_id in ipairs(all_doors[door_id].rooms) do
			if room_to_doors[room_id] then -- to filter rooms of this segment
				local room_level = room_flood_levels[room_id]
				room_flood_levels[room_id] = room_level and math_min(room_level, door_level) or door_level
			end
		end
	end

	return room_flood_levels, door_flood_levels, door_level_counts
end

function Geometry:itr_find_choke_point(
	room_flood_levels,
	room_level_counts,
	room_to_doors,
	door_flood_levels,
	important_rooms
)
	local lower_levels_contiguity = true
	local level_max = #room_level_counts
	local threshold = math_max(4, level_max / 2)
	for level, n in pairs(room_level_counts) do
		if level > threshold or level == level_max then
			break
		end
		if lower_levels_contiguity then
			lower_levels_contiguity = self:itr_is_contiguous(level, door_flood_levels, room_to_doors)
		end
		if n == 1 then -- choke point exists
			for room_id, room_level in pairs(room_flood_levels) do
				if room_level == level and important_rooms[room_id] then
					local room_data = self._rooms[room_id]
					local r_borders = room_data.borders
					local r_height = room_data.height
					return Vector3(
						(r_borders.x_pos + r_borders.x_neg) / 2,
						(r_borders.y_pos + r_borders.y_neg) / 2,
						(r_height.xp_yp + r_height.xn_yn) / 2
					),
						lower_levels_contiguity
				end
			end
			break
		end
	end
end

local tmp_vec = Vector3()
local function itr_add_door_pos_to(sum_pos, all_doors, i_door)
	local door = all_doors[i_door]
	mvec3_lerp(tmp_vec, door.pos, door.pos1, 0.5)
	mvec3_add(sum_pos, tmp_vec)
end

local function itr_get_rooms_having_access_to_next_level(all_doors, room_to_doors, room_flood_levels, room_neighbours)
	local result = {}
	for room_id, room_level in pairs(room_flood_levels) do
		for _, door_id in ipairs(room_to_doors[room_id]) do
			local rooms = all_doors[door_id].rooms
			local other_room_id = rooms[1] == room_id and rooms[2] or rooms[1]
			local other_room_level = room_flood_levels[other_room_id]
			-- next level OR other navseg
			if
				other_room_level and other_room_level > room_level
				or not other_room_level and room_level ~= 1 and room_neighbours[other_room_id]
			then
				result[room_id] = room_level
				break
			end
		end
	end
	return result
end

function Geometry:itr_find_proxies(segment_id)
	local choke_points, choke_point_proxies = {}, {}
	local in_proxies = {}
	local out_proxies = {}
	local all_doors = self._room_doors
	local all_nav_segments = self._nav_segments
	local segment = all_nav_segments[segment_id]
	local all_seg_doors, room_neighbours = self:itr_get_all_doors_of_segment(segment_id)
	local room_to_doors = self:itr_get_room_to_doors(segment_id, all_seg_doors)
	local seg_door_nr = count(all_seg_doors)

	for neighbour_seg_id, door_list in pairs(segment.neighbours) do
		local best_level
		local min_count = 1000
		local level1_contiguous
		local room_flood_levels, door_flood_levels, door_level_counts = self:itr_flood(door_list, room_to_doors)

		local important_rooms =
			itr_get_rooms_having_access_to_next_level(all_doors, room_to_doors, room_flood_levels, room_neighbours)
		local important_doors = {}
		local room_level_counts = {}
		for room_id, level in pairs(important_rooms) do
			room_level_counts[level] = (room_level_counts[level] or 0) + 1
			if level == 1 then
				for _, door_id in ipairs(room_to_doors[room_id]) do
					if door_flood_levels[door_id] == 1 then
						table_insert(important_doors, door_id)
					end
				end
			end
		end

		for level, n in pairs(door_level_counts) do
			if not self:itr_is_contiguous(level, door_flood_levels, room_to_doors) then
				break
			end
			if n <= min_count then
				best_level = level
				min_count = n
			end
			if level == 1 then
				level1_contiguous = true
			elseif level > 4 then
				break
			end
		end

		if best_level and seg_door_nr > 20 then
			local cnt = 0
			local pos = Vector3(0, 0, 0)
			for door_id, level in pairs(door_flood_levels) do
				if level == best_level then
					itr_add_door_pos_to(pos, all_doors, door_id)
					cnt = cnt + 1
				end
			end
			if cnt > 0 and cnt < 5 then
				mvec3_div(pos, cnt)
				out_proxies[neighbour_seg_id] = pos
			end
		end

		local neighbour_segment = all_nav_segments[neighbour_seg_id]
		local neighbour_in_proxies = neighbour_segment and neighbour_segment.in_proxies
		local already_done = neighbour_in_proxies and neighbour_in_proxies[segment_id]
		if already_done ~= nil then
			in_proxies[neighbour_seg_id] = already_done
		elseif level1_contiguous then
			local cnt = 0
			local frontier_center = Vector3(0, 0, 0)
			for _, door_id in ipairs(important_doors) do
				itr_add_door_pos_to(frontier_center, all_doors, door_id)
				cnt = cnt + 1
			end
			if cnt > 2 then
				mvec3_div(frontier_center, cnt)
				local metawidth = 0
				for _, door_id in ipairs(important_doors) do
					local door = all_doors[door_id]
					mvec3_lerp(tmp_vec, door.pos, door.pos1, 0.5)
					local dis = mvec3_dis_sq(frontier_center, tmp_vec)
					if dis > metawidth then
						metawidth = dis
					end
				end
				in_proxies[neighbour_seg_id] = metawidth < (150 * 150) and frontier_center or nil
			end
		end

		if #door_list > 1 then
			local choke_point_pos, lower_levels_contiguity = self:itr_find_choke_point(
				room_flood_levels,
				room_level_counts,
				room_to_doors,
				door_flood_levels,
				important_rooms
			)
			if choke_point_pos then
				choke_points[neighbour_seg_id] = choke_point_pos

				if lower_levels_contiguity then
					-- pick the closest important door
					local best_pos = Vector3()
					local min_dis = 1000000000
					for _, door_id in ipairs(important_doors) do
						local door = all_doors[door_id]
						if mvec3_dis_sq(door.pos, door.pos1) > 2500 then
							mvec3_lerp(tmp_vec, door.pos, door.pos1, 0.5)
							local dis = mvec3_dis_sq(tmp_vec, choke_point_pos)
							if dis < min_dis then
								min_dis = dis
								mvec3_set(best_pos, tmp_vec)
							end
						else
							for _, pos in ipairs({ door.pos, door.pos1 }) do
								local dis = mvec3_dis_sq(pos, choke_point_pos)
								if dis < min_dis then
									min_dis = dis
									mvec3_set(best_pos, pos)
								end
							end
						end
					end
					choke_point_proxies[neighbour_seg_id] = best_pos
				end
			end
		end
	end

	return choke_points, choke_point_proxies, in_proxies, out_proxies
end

function Geometry:mirror_choke_proxy(segment_id, neighbour_seg_id)
	local choke_point_proxy = self._nav_segments[segment_id].choke_point_proxies[neighbour_seg_id]
	local neighbour = self._nav_segments[neighbour_seg_id]
	if choke_point_proxy and neighbour and not neighbour.choke_point_proxies[segment_id] then
		neighbour.choke_point_proxies[segment_id] = choke_point_proxy
		local mirrored = self.mirrored[neighbour_seg_id]
		if not mirrored then
			mirrored = {}
			self.mirrored[neighbour_seg_id] = mirrored
		end
		mirrored[segment_id] = true
	end
end

function Geometry:prepare_all()
	local segments = self._nav_segments
	for _, segment in pairs(segments) do
		segment.in_proxies = nil
	end
	for segment_id, segment in pairs(segments) do
		segment.choke_points, segment.choke_point_proxies, segment.in_proxies, segment.out_proxies =
			self:itr_find_proxies(segment_id)
	end

	self.mirrored = {}
	for segment_id, segment in pairs(segments) do
		for neighbour_seg_id in pairs(segment.neighbours) do
			self:mirror_choke_proxy(segment_id, neighbour_seg_id)
		end
	end
end

-- Recomputes hints of segments whose static boundary changed, plus neighbours that reused their in-proxies.
function Geometry:refresh(dirty)
	local segments = self._nav_segments
	for segment_id in pairs(dirty) do
		if not segments[segment_id] then
			dirty[segment_id] = nil
		end
	end
	local reused = {}
	for segment_id in pairs(dirty) do
		for other_id, pos in pairs(segments[segment_id].in_proxies or EMPTY) do
			local other = segments[other_id]
			if not dirty[other_id] and other and rawequal(other.in_proxies[segment_id], pos) then
				reused[other_id] = true
			end
		end
	end
	for segment_id in pairs(reused) do
		dirty[segment_id] = true
	end

	for segment_id, from in pairs(self.mirrored) do
		for other_id in pairs(from) do
			if dirty[segment_id] or dirty[other_id] then
				if not dirty[segment_id] then
					segments[segment_id].choke_point_proxies[other_id] = nil
				end
				from[other_id] = nil
			end
		end
	end

	for segment_id in pairs(dirty) do
		segments[segment_id].in_proxies = nil
	end
	for segment_id in pairs(dirty) do
		local segment = segments[segment_id]
		segment.choke_points, segment.choke_point_proxies, segment.in_proxies, segment.out_proxies =
			self:itr_find_proxies(segment_id)
	end
	for segment_id in pairs(dirty) do
		for neighbour_seg_id in pairs(segments[segment_id].neighbours) do
			self:mirror_choke_proxy(segment_id, neighbour_seg_id)
		end
		for other_id, other in pairs(segments) do
			if not dirty[other_id] and other.neighbours[segment_id] then
				self:mirror_choke_proxy(other_id, segment_id)
			end
		end
	end
	return dirty
end

return Geometry
