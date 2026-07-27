-- 纯过滤模式元数据与路径匹配

local M = {}

M.MODES = { 'fuzzy', 'glob', 'regex' }

local MODE_DISPLAY = {
  fuzzy = { icon = '', label = 'Fuzzy', hl = 'VVExplorerFilterModeFuzzy' },
  glob = { icon = '', label = 'Glob', hl = 'VVExplorerFilterModeGlob' },
  regex = { icon = '󰑑', label = 'Regex', hl = 'VVExplorerFilterModeRegex' },
}

---@param mode string
---@return {icon:string, label:string, hl:string}
function M.display(mode)
  return MODE_DISPLAY[mode] or { icon = '?', label = mode or '?', hl = 'Comment' }
end

---@param mode string
---@return string
function M.next_mode(mode)
  for index, current in ipairs(M.MODES) do
    if current == mode then return M.MODES[(index % #M.MODES) + 1] end
  end
  return M.MODES[1]
end

---@param index string[]
---@param cwd string
---@return string[]
function M.build_rels(index, cwd)
  local rels = {}
  local prefix_length = #cwd + 2
  for position, path in ipairs(index) do
    rels[position] = path:sub(prefix_length)
  end
  return rels
end

---@param rels string[]
---@param query string
---@return string[]
local function fast_prefilter(rels, query)
  local lower_query = query:lower()
  local query_characters = {}
  for index = 1, #lower_query do
    query_characters[index] = lower_query:sub(index, index)
  end

  local result = {}
  for _, rel in ipairs(rels) do
    local lower_rel = rel:lower()
    local position = 1
    local matches = true
    for _, character in ipairs(query_characters) do
      local found = lower_rel:find(character, position, true)
      if not found then
        matches = false
        break
      end
      position = found + 1
    end
    if matches then result[#result + 1] = rel end
  end
  return result
end

---@param rels string[]
---@param query string
---@return {matched:string[], positions:integer[][]}
local function match_fuzzy_basename(rels, query)
  local candidate_names = {}
  local candidate_offsets = {}
  local candidate_rels = {}
  local lower_query = query:lower()
  local query_characters = {}
  for index = 1, #lower_query do
    query_characters[index] = lower_query:sub(index, index)
  end

  for _, rel in ipairs(rels) do
    local slash = rel:find('/[^/]*$')
    local basename = slash and rel:sub(slash + 1) or rel
    local offset = slash or 0
    local lower_basename = basename:lower()
    local position = 1
    local matches = true
    for _, character in ipairs(query_characters) do
      local found = lower_basename:find(character, position, true)
      if not found then
        matches = false
        break
      end
      position = found + 1
    end
    if matches then
      candidate_names[#candidate_names + 1] = basename
      candidate_offsets[#candidate_offsets + 1] = offset
      candidate_rels[#candidate_rels + 1] = rel
    end
  end

  if #candidate_names == 0 then return { matched = {}, positions = {} } end

  local ok, result = pcall(vim.fn.matchfuzzypos, candidate_names, query)
  if not ok or type(result) ~= 'table' then
    return { matched = {}, positions = {} }
  end

  local matched_names = result[1] or {}
  local raw_positions = result[2] or {}
  local queues = {}
  for index, basename in ipairs(candidate_names) do
    if not queues[basename] then queues[basename] = {} end
    queues[basename][#queues[basename] + 1] = {
      rel = candidate_rels[index],
      offset = candidate_offsets[index],
    }
  end

  local matched = {}
  local positions = {}
  for index, basename in ipairs(matched_names) do
    local queue = queues[basename]
    if queue and #queue > 0 then
      local entry = table.remove(queue, 1)
      matched[#matched + 1] = entry.rel
      local adjusted = {}
      for _, position in ipairs(raw_positions[index] or {}) do
        adjusted[#adjusted + 1] = position + entry.offset
      end
      positions[#positions + 1] = adjusted
    end
  end

  return { matched = matched, positions = positions }
end

---@param rels string[]
---@param query string
---@return {matched:string[], positions:integer[][]}
local function match_fuzzy(rels, query)
  if not query:find('/', 1, true) then
    return match_fuzzy_basename(rels, query)
  end

  local candidates = fast_prefilter(rels, query)
  local ok, result = pcall(vim.fn.matchfuzzypos, candidates, query)
  if not ok or type(result) ~= 'table' then
    return { matched = {}, positions = {} }
  end

  local raw_matched = result[1] or {}
  local raw_positions = result[2] or {}
  local basename_matched = {}
  local basename_positions = {}
  local path_matched = {}
  local path_positions = {}

  for index, rel in ipairs(raw_matched) do
    local slash = rel:find('/[^/]*$')
    local basename_start = slash or 0
    local positions = raw_positions[index] or {}
    local inside_basename = true
    for _, position in ipairs(positions) do
      if position < basename_start then
        inside_basename = false
        break
      end
    end
    if inside_basename then
      basename_matched[#basename_matched + 1] = rel
      basename_positions[#basename_positions + 1] = positions
    else
      path_matched[#path_matched + 1] = rel
      path_positions[#path_positions + 1] = positions
    end
  end

  local matched = {}
  local positions = {}
  for index = 1, #basename_matched do
    matched[index] = basename_matched[index]
    positions[index] = basename_positions[index]
  end
  local offset = #basename_matched
  for index = 1, #path_matched do
    matched[offset + index] = path_matched[index]
    positions[offset + index] = path_positions[index]
  end

  return { matched = matched, positions = positions }
end

---@param rels string[]
---@param query string
---@return {matched:string[], positions:integer[][]}
local function match_glob(rels, query)
  local pattern = query
  local has_wildcard = pattern:find('[%*%?%[]') ~= nil
  local has_slash = pattern:find('/') ~= nil
  if not has_slash then
    pattern = has_wildcard and ('**/' .. pattern) or ('**/*' .. pattern .. '*')
  end

  local ok, lpeg_pattern = pcall(vim.glob.to_lpeg, pattern)
  if not ok then return { matched = {}, positions = {} } end

  local matched = {}
  for _, rel in ipairs(rels) do
    if vim.lpeg and vim.lpeg.match(lpeg_pattern, rel) then
      matched[#matched + 1] = rel
    end
  end
  table.sort(matched)

  local positions = {}
  for index = 1, #matched do positions[index] = {} end
  return { matched = matched, positions = positions }
end

---@param rels string[]
---@param query string
---@return {matched:string[], positions:integer[][]}
local function match_regex(rels, query)
  local ok, regex = pcall(vim.regex, query)
  if not ok or not regex then return { matched = {}, positions = {} } end

  local matched = {}
  for _, rel in ipairs(rels) do
    if regex:match_str(rel) then matched[#matched + 1] = rel end
  end
  table.sort(matched)

  local positions = {}
  for index = 1, #matched do positions[index] = {} end
  return { matched = matched, positions = positions }
end

---@param index string[]
---@param rels string[]
---@param cwd string
---@param query string
---@param mode? 'fuzzy'|'glob'|'regex'
---@param max_results? integer
---@return {abs:string[], rels:string[], positions:integer[][], total_count:integer}
function M.match(index, rels, cwd, query, mode, max_results)
  if query == '' or #index == 0 then
    return { abs = {}, rels = {}, positions = {}, total_count = 0 }
  end

  local result
  if mode == 'glob' then
    result = match_glob(rels, query)
  elseif mode == 'regex' then
    result = match_regex(rels, query)
  else
    result = match_fuzzy(rels, query)
  end

  local total = #result.matched
  if total == 0 then
    return { abs = {}, rels = {}, positions = {}, total_count = 0 }
  end

  local limit = max_results or 1000
  if total > limit then
    local matched = {}
    local positions = {}
    for index_position = 1, limit do
      matched[index_position] = result.matched[index_position]
      positions[index_position] = result.positions[index_position]
    end
    result.matched = matched
    result.positions = positions
  end

  local absolute = {}
  for index_position, rel in ipairs(result.matched) do
    absolute[index_position] = cwd .. '/' .. rel
  end
  return {
    abs = absolute,
    rels = result.matched,
    positions = result.positions,
    total_count = total,
  }
end

---@param matched_abs string[]
---@param cwd string
---@return table<string, boolean>, table<string, boolean>
function M.visible_set(matched_abs, cwd)
  local visible = {}
  local is_dir_map = {}
  for _, absolute in ipairs(matched_abs) do
    local path = absolute
    while true do
      visible[path] = true
      local parent = vim.fs.dirname(path)
      if parent == path or parent == cwd or #parent <= #cwd then break end
      is_dir_map[parent] = true
      path = parent
    end
  end
  return visible, is_dir_map
end

return M
