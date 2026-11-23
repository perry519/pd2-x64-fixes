local key = ModPath .. '	' .. RequiredScript
if _G[key] then
	return
else
	_G[key] = true
end

if not Iter.settings.streamline_path then return end

local mvec3_eq = mvector3.equal
local mvec3_z = mvector3.z
local math_abs = math.abs
local table_remove = table.remove

local function remove_duplicates(run)
	for i = #run, 2, -1 do
		if mvec3_eq(run[i], run[i - 1]) then table_remove(run, i - 1) end
	end
end

-- run holds Vector3 points only; its first and last points are kept
local function optimize_run(run, allow_out_of_graph)
	remove_duplicates(run)
	local run_nr = #run
	if run_nr <= 2 then return run end

	local navman = managers.navigation
	local z = {}
	for i = 1, run_nr do
		z[i] = mvec3_z(run[i])
	end

	local opt_run = { run[1] }
	local i = 1
	while i < run_nr do
		local pos_i = run[i]
		local next_index = i + 1
		for j = i + 2, run_nr do
			if math_abs(z[j] - z[i]) < 100 then
				local blocked
				if allow_out_of_graph then
					blocked = CopActionWalk._chk_shortcut_pos_to_pos(pos_i, run[j])
				else
					blocked = navman:raycast({
						pos_from = pos_i,
						pos_to = run[j],
					})
				end
				if not blocked then next_index = j end
			end
		end

		opt_run[#opt_run + 1] = run[next_index]
		i = next_index
	end

	remove_duplicates(opt_run)

	return opt_run
end

-- detailed path results mix Vector3 points with NavLink userdata; vector math only ever sees vector runs
function CivilianLogicTravel.itr_optimize_path(path, allow_out_of_graph)
	if #path <= 2 then return path end

	local opt_path = {}
	local run = {}
	local function flush_run()
		for _, pos in ipairs(optimize_run(run, allow_out_of_graph)) do
			opt_path[#opt_path + 1] = pos
		end
		run = {}
	end

	for _, nav_point in ipairs(path) do
		if nav_point.x then
			run[#run + 1] = nav_point
		else
			flush_run()
			opt_path[#opt_path + 1] = nav_point
		end
	end
	flush_run()

	return opt_path
end
