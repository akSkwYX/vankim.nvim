--------------------------------------------------------------------------------
-- Field management tools ------------------------------------------------------
--------------------------------------------------------------------------------

local M = {}

-- Fields names
---@param names table
function M.set_fields_names(names)
  local fields_names = {}
  for _, name in ipairs(names) do
    fields_names[name] = true
  end
  vim.g.vankim_fields_names = fields_names
end

---@param name string
---@return boolean 
function M.is_a_field(name)
  while name:sub(1,1) == " " do name = name:sub(2,#name) end
  while name:sub(#name,#name) == " " or name:sub(#name,#name) == ":" do name = name:sub(1,#name-1) end
  return vim.g.vankim_fields_names[name] ~= nil
end

-- Get field positions in the current buffer
---@return table
function M.get_field_positions()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local fields = {}
  local i = 1
  -- Skip Model and Deck headers
  while i <= #lines and (lines[i]:match("^%s*$") or lines[i]:match("Model:") or lines[i]:match("Deck:")) do
    i = i + 1
  end
  while i <= #lines do
    local l = lines[i]
    -- detect header lines of the form "FieldName:" optionally with trailing spaces
    local name = l:match("^%s*([^:]+):%s*$")
    if name and is_a_field(name) then
      local header = i
      local start = header + 1
      while start <= #lines and lines[start]:match("^%s*$") do start = start + 1 end
      -- handle empty field case
      if start > #lines or (lines[start]:match("^%s*[^:]+:%s*$") and is_a_field(lines[start]:match("^%s*([^:]+):%s*$"))) then
        table.insert(fields, { name = name, header = header, start = header, ending = header })
        i = start
      else
        local j = start
        while j <= #lines and not (lines[j]:match("^%s*([^:]+):%s*$") and is_a_field(lines[j]:match("^%s*([^:]+):%s*$"))) do
          j = j + 1
        end
        local end_line = j - 1
        while end_line > start and lines[end_line]:match("^%s*$") do end_line = end_line - 1 end
        table.insert(fields, { name = name, header = header, start = start, ending = end_line })
        i = j
      end
    else
      i = i + 1
    end
  end
  return fields
end

-- Set the i-th field value in buf. Replaces the lines that were the previous value.
---@param field_index integer
---@param text string
---@return boolean success
---@return string|nil error_msg
local function set_field_value(field_index, text)
  local function split_into_lines(s)
    if not s or s == "" then return { "" } end
    local out = {}
    for line in (s .. "\n"):gmatch("(.-)\n") do table.insert(out, line) end
    return out
  end

  local buf = vim.api.nvim_get_current_buf()
  local fields = M.get_field_positions()
  local f = fields[field_index]
  if not f then return false, "field index out of range" end
  local new_lines = split_into_lines(text)
  -- replace existing value region [start, end] (1-based lines -> 0-based indexes)
  local start0 = f.start - 1
  local end0 = f.ending
  vim.api.nvim_buf_set_lines(buf, start0, end0, false, new_lines)
  return true
end

return M
