---@module "nix_prefetch.parse"
---@brief
--- Parsing functions for nix_prefetch

---@type NPConfig
local cfg = require("nix_prefetch.config").values
local ts = vim.treesitter

local parse = {}

---@private
--- Parse all fetch queries and return them as a table
---@return table<string, vim.treesitter.Query>?, string?
local function _get_fetch_queries()
	---@type table<string, vim.treesitter.Query>
	local queries = {}

	---@type string, string
	for name, query_str in pairs(cfg.queries.fetch or {}) do
		local query, parse_err = vim.treesitter.query.parse("nix", query_str)
		if not query then
			---@type string
			local err = "nix_prefetch.parse._get_fetch_queries() warning: Failed to parse fetch query for "
				.. name
				.. ": "
				.. tostring(parse_err)
			if cfg.debug then
				vim.notify(err, vim.log.levels.WARN)
			end
		else
			queries[name] = query
		end
	end

	if vim.tbl_isempty(queries) then
		---@type string
		local err = "nix_prefetch.parse._get_fetch_queries() error: No valid fetch queries parsed."
		if cfg.debug then
			vim.notify(err, vim.log.levels.ERROR)
		end
		return nil, err
	end

	return queries, nil
end

---@private
--- Get the treesitter node at the cursor position
---@return NPFetchNode? fetch_node, string? err
local function _get_node_at_cursor()
	---@type boolean, integer?
	local bufnr_ok, cur_bufnr = pcall(vim.api.nvim_get_current_buf)
	if not bufnr_ok then
		---@type string
		local err = "nix_prefetch.parse._get_node_at_cursor() error: Could not retrieve current bufnr ... "
			.. tostring(cur_bufnr)
		if cfg.debug then
			vim.notify(err, vim.log.levels.ERROR)
		end
		return nil, err
	end
	---@cast cur_bufnr integer

	---@type boolean, integer[]?
	local cursor_ok, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
	if not cursor_ok then
		---@type string
		local err = "nix_prefetch.parse._get_node_at_cursor() error: "
			.. "Could not retrieve cursor position for current window ... "
			.. tostring(cursor)
		if cfg.debug then
			vim.notify(err, vim.log.levels.ERROR)
		end
		return nil, err
	end
	---@cast cursor integer[]

	---@type integer
	local cur_row = cursor[1] - 1 -- convert to 0-indexed
	---@type integer
	local cur_col = cursor[2]

	---@type table<string, vim.treesitter.Query>?
	local queries, fetch_err = _get_fetch_queries()
	if not queries then
		return nil, fetch_err
	end

	---@type vim.treesitter.LanguageTree?, string? parse_err
	local parser, parse_err = vim.treesitter.get_parser(cur_bufnr, "nix")
	if not parser then
		---@type string
		local err = "prefetch.parse.get_node_at_cursor() error: No parser available for nix ... " .. tostring(parse_err)
		if cfg.debug then
			vim.notify(err, vim.log.levels.ERROR)
		end
		return nil, err
	end
	---@cast parser vim.treesitter.LanguageTree

	---@type TSTree?
	local tree = parser:parse()[1]
	if not tree then
		---@type string
		local err = "nix_prefetch.get_node_at_cursor() error: Could not parse first language tree."
		if cfg.debug then
			vim.notify(err, vim.log.levels.ERROR)
		end
		return nil, err
	end
	---@cast tree TSTree
	---@type TSNode
	local root = tree:root()

	---@type string, vim.treesitter.Query
	for query_name, query in pairs(queries) do
		---@type integer, TSNode
		for id, node, _ in query:iter_captures(root, cur_bufnr, 0, -1) do
			if query.captures[id] == "fetchBlock" then
				---@type integer
				local s_row, s_col, e_row, e_col = node:range()
				if
					(cur_row > s_row or (cur_row == s_row and cur_col >= s_col))
					and (cur_row < e_row or (cur_row == e_row and cur_col <= e_col))
				then
					return {
						bufnr = cur_bufnr,
						node = node,
						range = { s_row = s_row, s_col = s_col, e_row = e_row, e_col = e_col },
						query_name = query_name,
					},
						nil
				end
			end
		end
	end

	---@type string
	local err = "prefetch.parse.get_node_at_cursor() warning: No fetch block found at cursor."
	if cfg.debug then
		vim.notify(err, vim.log.levels.WARN)
	end

	return nil
end

---@private
---Get a dictionary of attribute values from a fetch node.
---@param fetch_node TSNode -- The outer `{ ... }` table node containing a `binding_set`.
---@param bufnr integer -- The buffer number containing the node.
---@return table<string, string>? attrs_dict, string? err
local function _get_attrs_dict(fetch_node, bufnr)
	---@type table<string, string>
	local attrs_dict = {}

	---@type vim.treesitter.Query?
	local attrs_query = vim.treesitter.query.parse("nix", cfg.queries.attrs.all)
	if not attrs_query then
		local err = "nix_prefetch.parse._get_attrs_dict() warning: Could not parse attributes."
		if cfg.debug then
			vim.notify(err, vim.log.levels.WARN)
		end
		return nil, err
	end

	for i = 0, fetch_node:child_count() - 1 do
		---@type TSNode?
		local child = fetch_node:child(i)

		if not child then
			goto continue
		end
		---@cast child TSNode

		local child_type = child:type()
		--local child_text = ts.get_node_text(child, bufnr)
		-- vim.notify(string.format("  [%d] type = %s, text = %s", i, child_type, child_text), vim.log.levels.INFO)

		if child_type == "binding_set" then
			---@type table<integer, TSNode[]>
			for _, match, _ in attrs_query:iter_matches(child, bufnr, 0, -1) do
				---@type TSNode|nil
				local key_node = nil
				---@type TSNode|nil
				local value_node = nil

				for id, nodes in pairs(match) do
					---@type TSNode
					local node = nodes[1]
					---@type string
					local name = attrs_query.captures[id]

					-- local node_text = ts.get_node_text(node, bufnr)
					if name == "key" then
						key_node = node
					elseif name == "value" then
						value_node = node
					end
				end

				if key_node and value_node then
					local key_text = ts.get_node_text(key_node, bufnr)
					local value_text = ts.get_node_text(value_node, bufnr)
					value_text = value_text:match('^"(.-)"$') or value_text
					attrs_dict[key_text] = value_text
				end
			end
		end

		::continue::
	end

	if next(attrs_dict) then
		return attrs_dict, nil
	else
		local err = "nix_prefetch.parse._get_attrs_dict() warning: No valid git attributes found."
		if cfg.debug then
			vim.notify(err, vim.log.levels.WARN)
		end
		return nil, err
	end
end

---@param bufnr integer
---@param fetch_node TSNode
---@param new_info table<string, string> must contain "rev" and "hash"
function parse.update_buffer(bufnr, fetch_node, new_info)
	---@type vim.treesitter.Query?, string?
	local query, qry_err = vim.treesitter.query.parse("nix", cfg.queries.attrs.all)
	if not query then
		---@type string
		local err = "prefetch.parse.update_buffer() warning: Failed to parse repo ... " .. tostring(qry_err)
		if cfg.debug then
			vim.notify(err, vim.log.levels.WARN)
		end
		return nil, err
	end

	---@type table<integer, TSNode[]>
	for _, match, _ in query:iter_matches(fetch_node, bufnr, 0, -1) do
		---@type TSNode?
		local key_node
		---@type TSNode?
		local value_node

		---@type integer, TSNode
		for id, nodes in pairs(match) do
			---@type TSNode
			local node = nodes[1]
			---@type string
			local name = query.captures[id]
			if name == "key" then
				key_node = node
			elseif name == "value" then
				value_node = node
			end
		end

		if key_node and value_node then
			---@type string
			local key_text = ts.get_node_text(key_node, bufnr)
			if key_text == "rev" or key_text == "hash" then
				---@type string, string
				local lookup = key_text == "hash" and "sha256" or key_text
				local new_val = new_info[lookup]
				if new_val then
					new_val = '"' .. new_val .. '"'
					---@type integer
					local s_row, s_col, e_row, e_col = value_node:range()
					vim.api.nvim_buf_set_text(bufnr, s_row, s_col, e_row, e_col, { new_val })
				end
			end
		end
	end
end

---@tag parse.get_node_pair()
---@brief
--- Get the attribute set as a Lua dictionary
---
---@return NPNodePair? node_pair, string? err
function parse.get_node_pair()
	---@type NPFetchNode?, string?
	local fetch_node, get_nr_err = _get_node_at_cursor()

	if not fetch_node then
		---@type string
		local err = "nix_prefetch.parse.get_node_pair() warning: No fetch node found." .. tostring(get_nr_err)
		if cfg.debug then
			vim.notify(err, vim.log.levels.WARN)
		end
		return nil, err
	end
	---@cast fetch_node NPFetchNode

	---@type table<string, string>?
	local attrs_dict = _get_attrs_dict(fetch_node.node, fetch_node.bufnr)
	if not attrs_dict or attrs_dict == {} then
		---@type string
		local err = "nix_prefetch.parse.get_node_pair() warning: No attribute sets found."
		if cfg.debug then
			vim.notify(err, vim.log.levels.WARN)
		end
	end
	---@cast attrs_dict table<string, string>

	---@type NPNodePair
	local node_pair = {
		fetch_node = fetch_node,
		attrs_dict = attrs_dict,
	}

	return node_pair
end

return parse
