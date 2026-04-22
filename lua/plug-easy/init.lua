-- NOTE:
-- TODO: first install fails!!!!
-- NOTE:

local M = {}
local config_table = {}

local plug_root_path = vim.fn.stdpath("data") .. "/lapuglisi"

local function gh(r)
	return "https://github.com/" .. r
end

M._threads = {}

M._done = {}

M._pre_check = function()
	if not vim.fn.executable("git") then
		error("git is not installed")
		return false
	end

	return true
end

local function get_git_refs(repo)
	local git_cmd = {
		"git",
		"ls-remote",
		repo,
	}

	local ret_lines = {}
	local out = vim.fn.system(git_cmd)

	if vim.v.shell_error ~= 0 then
		error("Could not get repo tags: " .. out)
		return { "master", "main" }
	end

	local lines = vim.split(out, "\n", { trimempty = true })

	for _, line in ipairs(lines) do
		local branch = line:match("^.+%s+refs/heads/(.+)$") or line:match(".+%s+refs/tags/(.+)$")
		if branch ~= nil then
			table.insert(ret_lines, branch)
		end
	end

	return ret_lines
end

local function get_plugin_name(name, source)
	local source = source or ""
	local name_from_source = source:match("^.+/(.+)$")

	name_from_source = name_from_source:match("(.+)%.nvim$") or name_from_source

	return name or name_from_source
end

local function get_dir_name(plugin)
	local path = plugin and plugin.src

	return path:match("^.+/(.+)$")
end

local function plug_clone_repo(spec)
	local repo = spec.src
	local version = spec.version or "main"
	local version_t = type(version)

	local plug_version = version
	local plug_repo = gh(repo)
	local repo_name = repo:match("^.+/(.+)$")
	local plug_path = plug_root_path .. "/" .. repo_name

	spec.path = plug_path

	if vim.uv.fs_stat(plug_path) then
		return true
	end

	-- Check if we have a range for version
	if version_t == "table" then
		local versions = get_git_refs(plug_repo)

		for _, v in pairs(versions) do
			if version:has(v) then
				plug_version = v
				break
			end
		end
	else
		plug_version = version
	end

	local git_cmd = {
		"git",
		"clone",
		"-b",
		plug_version,
		"--filter=blob:none",
		plug_repo,
		plug_path,
	}

	print("[plug-easy] cloning repo '" .. plug_repo .. "'")
	local out = vim.fn.system(git_cmd)
	if vim.v.shell_error ~= 0 then
		error("[plug-easy] Error while cloning '" .. plug_repo .. "': " .. out)
		return false
	end

	return true
end

local function build_plugin(plugin)
	local path = plugin.path
	local cwd = vim.fn.getcwd(0, 0)

	print("[plug-easy] building", vim.inspect(plugin))

	if vim.fn.isdirectory(path) then
		vim.api.nvim_set_current_dir(path)
	end

	local build_cmd = type(plugin.build) == "table" and table.concat(plugin.build, " ") or plugin.build

	vim.api.nvim_set_current_dir(cwd)
end

M.has_plugin = function(spec)
	if spec == nil then
		return true
	end

	local done_name = ""
	local spec_name = get_plugin_name(spec.name, spec.src)
	local found = false
	for i, v in ipairs(M._done) do
		done_name = get_plugin_name(v.name, v.src)
		if done_name == spec_name then
			found = true
			break
		end
	end

	if found then
		-- print("### has_plugin: dependency", spec_name, "is installed")
	else
		-- print("### has_plugin: dependency", spec_name, "not found")
	end

	return found
end

local function setup_plugin(spec)
	local name = spec.name
	local event = spec.event
	local event_t = type(event)
	local config_t = type(spec.config)
	local opts = spec.opts or nil
	-- local repo_name = get_dir_name(spec)

	vim.opt.rtp:append(spec.path)

	repeat
		local done = true
		for _, dep in pairs(spec.dependencies or {}) do
			if not M.has_plugin(dep) then
				print("dependency", dep.name, "for", name, "is not installed")
				done = false
				break
			end
		end

		if not done then
			coroutine.yield()
		end
	until done

	if event_t == "string" or event_t == "table" then
		vim.api.nvim_create_autocmd(event, {
			callback = function()
				require(name).setup(opts)
			end,
		})
	else
		if config_t == "function" then
			spec.config()
		end

		if opts ~= nil then
			local ok, plugin = pcall(require, name)
			if ok and type(plugin.setup) == "function" then
				plugin.setup(opts)
			end
		end
	end

	local keys = spec.keys or {}
	for _, key in ipairs(keys) do
		local mode = key.mode or { "n" }
		local desc = key.desc
		local map = key[1]
		local cmd = key[2]

		local key_opts = desc and { desc = desc } or {}

		if mode and map and cmd then
			vim.keymap.set(mode, map, cmd, key_opts)
		end
	end

	--[[
	if spec.build ~= nil then
		vim.schedule(function()
			build_plugin(spec)
		end)
	end
	]]
	--

	table.insert(M._done, spec)

	return true
end

local function setup_plugins()
	repeat
		local done = true
		for index, thread in pairs(M._threads) do
			local co = thread.thread

			if co ~= nil then
				local res = coroutine.resume(co)
				if not res then
					M._threads[index] = { thread = nil, plugin = nil }
				else
					done = false
				end
			end
		end
	until done
end

local function co_callback(spec)
	spec.name = get_plugin_name(spec.name, spec[1] or spec.src)
	setup_plugin(spec)
end

local function setup_spec(spec)
	if type(spec) == "string" then
		spec = { src = spec }
	else
		spec.src = spec.src or spec[1]
	end

	local co = coroutine.create(function(plugin)
		if plug_clone_repo(plugin) then
			co_callback(plugin)
		end
	end)

	coroutine.resume(co, spec)

	M._threads[#M._threads + 1] = {
		thread = co,
	}
end

M.setup = function(specs)
	if not M._pre_check() then
		error("plug-easy: pre-check failed")
		return nil
	end

	local specs = specs or {}

	for _, spec in pairs(specs) do
		local deps = spec.dependencies or {}
		for _, dep in ipairs(deps) do
			setup_spec(dep)
		end

		setup_spec(spec)
	end

	setup_plugins()
end

return M
