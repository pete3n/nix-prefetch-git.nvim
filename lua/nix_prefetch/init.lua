---@module "nix_prefetch"
---@brief
--- Prefetch module provides primary nix-prefetch functions
local nix_prefetch = {}
local parse = require("nix_prefetch.parse")

if vim.fn.exists(":checkhealth") == 2 then
	require("nix_prefetch.health").check()
end

local cfg = require("nix_prefetch.config").values

---@private
---@param git_info GitTriplet
---@return string? url, string? err
local function _create_url(git_info)
	---@type string
	local protocol = "https://"
	---@type string
	local url = protocol .. git_info.forge .. "/" .. git_info.owner .. "/" .. git_info.repo

	return url, nil
end

---@private
---@param attrs_dict table<string, string>
---@param query_name string
---@return GitTriplet? git_info, string? err
local function _create_git_info(attrs_dict, query_name)
	---@type string, string
	local owner, repo
	---@type string, string
	for key, val in pairs(attrs_dict) do
		if key == "owner" then
			owner = val
		end
		if key == "repo" then
			repo = val
		end
	end

	if not owner or not repo then
		---@type string
		local err = "nix_prefetch._create_git_info(): error repo or owner attributes not found."
		if cfg.debug then
			vim.notify(err, vim.log.levels.ERROR)
		end
		return nil, err
	end

	---@type GitTriplet
	local git_info = {
		forge = cfg.query_metadata[query_name].forge,
		owner = owner,
		repo = repo,
	}

	return git_info, nil
end

---@private
--- Construct the archive tarball URL for a given git forge, used to compute
--- the correct SRI hash that matches fetchFromGitHub / fetchFromGitLab.
---@param git_info GitTriplet
---@param rev string
---@return string archive_url
local function _create_archive_url(git_info, rev)
	---@type string
	local base = "https://" .. git_info.forge .. "/" .. git_info.owner .. "/" .. git_info.repo
	return base .. "/archive/" .. rev .. ".tar.gz"
end

---@private
--- Compute the SRI hash for a fetchFromGitHub-compatible archive tarball.
--- Uses `nix store prefetch-file --unpack` which mirrors what fetchFromGitHub
--- does internally, producing a matching hash.
---@param archive_url string
---@param timeout integer
---@param callback fun(sri_hash: string?): nil
local function _prefetch_archive_hash(archive_url, timeout, callback)
	---@type string[]
	local cmd = {
		"nix", "store", "prefetch-file",
		"--json", "--hash-type", "sha256", "--unpack",
		archive_url,
	}

	vim.system(cmd, { text = true, timeout = timeout }, function(obj)
		vim.schedule(function()
			if obj.code ~= 0 then
				---@type string
				local err_msg = obj.stderr and vim.trim(obj.stderr) or "Unknown error"
				vim.notify(
					"nix store prefetch-file failed:\n" .. err_msg,
					vim.log.levels.ERROR
				)
				callback(nil)
				return
			end

			---@type boolean, table?
			local decode_ok, hash_result = pcall(vim.json.decode, obj.stdout)
			if not decode_ok or not hash_result.hash then
				vim.notify("Failed to parse nix store prefetch-file output", vim.log.levels.ERROR)
				callback(nil)
				return
			end

			callback(hash_result.hash)
		end)
	end)
end

---@private
-- Pull the current repo to check for updated rev and hash info
---@param git_info GitTriplet
---@param opts? NPUpdateOpts
---@param callback fun(result: table<string, any>?): nil
function nix_prefetch._prefetch_git(git_info, opts, callback)
	---@type NPUpdateOpts
	opts = opts or {}

	---@type string?
	local url, url_err = _create_url(git_info)
	if not url then
		---@type string
		local err = "nix_prefetch.prefetch_git() error: Could not create URL ... " .. tostring(url_err)
		if cfg.debug then
			vim.notify(err, vim.log.levels.ERROR)
		end
		return nil, err
	end

	---@type string[]
	local cmd = {
		"nix-prefetch-git",
	}

	if opts.deepClone == false then
		table.insert(cmd, "--no-deepClone")
	end
	if opts.fetchSubmodules ~= false then
		table.insert(cmd, "--fetch-submodules")
	end
	if opts.branch then
		table.insert(cmd, "--rev")
		table.insert(cmd, "refs/heads/" .. opts.branch)
	end
	if opts.rev then
		table.insert(cmd, "--rev")
		table.insert(cmd, opts.rev)
	end

	table.insert(cmd, url)

	vim.system(cmd, { text = true, timeout = cfg.timeout or 5000 }, function(obj)
		if obj.code ~= 0 then
			local err_msg = obj.stderr and vim.trim(obj.stderr) or "Unknown error"
			vim.notify("nix-prefetch-git failed for " .. url .. ":\n" .. err_msg, vim.log.levels.ERROR)
			callback(nil)
			return
		end

		---@type boolean, table?
		local ok, parsed = pcall(vim.json.decode, obj.stdout)
		if not ok then
			vim.notify("Failed to decode nix-prefetch-git output", vim.log.levels.ERROR)
			callback(nil)
			return
		end

		callback(parsed)
	end)
end

---@tag nix_prefetch.update()
---@brief Update a Nix src repository.
--- Uses nix-prefetch-git to resolve the target rev, then computes the
--- correct SRI hash via `nix store prefetch-file --unpack` using the
--- forge's archive tarball URL (matching fetchFromGitHub behavior).
---
---@param opts? NPUpdateOpts
---@return boolean updated, string? err
function nix_prefetch.update(opts)
	opts = opts or {}
	if opts.branch ~= nil and opts.rev ~= nil then
		error("NPUpdateOpts: 'branch' and 'rev' are mutually exclusive. Please specify only one.")
	end

	---@type NPNodePair?, string?
	local node_pair, np_err = parse.get_node_pair()
	if not node_pair then
		local err = "nix_prefetch.update() warning: Could not update ... " .. tostring(np_err)
		if cfg.debug then
			vim.notify(err, vim.log.levels.WARN)
		end
		return false, err
	end

	---@type integer
	local bufnr = node_pair.fetch_node.bufnr
	---@type GitTriplet?
	local git_info = _create_git_info(node_pair.attrs_dict, node_pair.fetch_node.query_name)

	if not git_info then
		---@type string
		local err = "nix_prefetch.update() error: Could not retrieve git info."
		if cfg.debug then
			vim.notify(err, vim.log.levels.ERROR)
		end
		return false, err
	end

	if opts.branch then
		vim.notify(
			"Fetching hash and rev for head of repo:\n"
			.. tostring(git_info.owner)
			.. "\\"
			.. tostring(git_info.repo)
			.. "\nbranch: "
			.. opts.branch,
			vim.log.levels.INFO
		)
	elseif opts.rev then
		vim.notify(
			"Fetching hash for repo:\n"
			.. tostring(git_info.owner)
			.. "\\"
			.. tostring(git_info.repo)
			.. "\nrev: "
			.. opts.rev,
			vim.log.levels.INFO
		)
	else
		vim.notify(
			"Fetching rev and hash for default branch of repo:\n"
			.. tostring(git_info.owner)
			.. "\\"
			.. tostring(git_info.repo),
			vim.log.levels.INFO
		)
	end

	nix_prefetch._prefetch_git(git_info, opts, function(result)
		vim.schedule(function()
			if not result then
				vim.notify("nix-prefetch-git failed to retrieve update info.", vim.log.levels.ERROR)
				return
			end

			if not vim.api.nvim_buf_is_valid(bufnr) then
				vim.notify("Buffer is no longer valid, cannot apply update.", vim.log.levels.WARN)
				return
			end

			---@type string
			local archive_url = _create_archive_url(git_info, result.rev)

			_prefetch_archive_hash(archive_url, cfg.timeout or 5000, function(sri_hash)
				if not sri_hash then
					vim.notify("Failed to compute SRI hash for archive.", vim.log.levels.ERROR)
					return
				end

				if not vim.api.nvim_buf_is_valid(bufnr) then
					vim.notify("Buffer is no longer valid, cannot apply update.", vim.log.levels.WARN)
					return
				end

				-- Replace the base32 sha256 with the correct SRI hash
				result.sha256 = sri_hash

				---@type TSNode
				local fetch_node = node_pair.fetch_node.node
				parse.update_buffer(bufnr, fetch_node, result)

				vim.notify(
					"Nix prefetch updated:\nrev=" .. result.rev .. "\nhash=" .. sri_hash,
					vim.log.levels.INFO
				)
			end)
		end)
	end)

	return true, nil
end

return nix_prefetch
