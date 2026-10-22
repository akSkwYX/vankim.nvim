local Fields = require("vankim.field")
local ankiconnect = require("vankim.ankiconnect")

--------------------------------------------------------------------------------
-- Buffer management -----------------------------------------------------------
--------------------------------------------------------------------------------

local M = {}

-- Fill buffer
---@param buf integer
---@param model string
---@param deck string
---@param fields table
---@param values table|nil
---@return integer buf_index
function M.fill_buffer(buf, model, deck, fields, values)
  local lines = {}
  table.insert(lines, "Model: " .. (model or ""))
  table.insert(lines, "Deck: " .. (deck or ""))
  table.insert(lines, "")
  table.insert(lines, "")
  for i, fname in ipairs(fields) do
    table.insert(lines, fname .. ":")
    local val = values and values[i] or ""
    if val == nil or val == "" then
      table.insert(lines, "")
      table.insert(lines, "")
      table.insert(lines, "")
    else
      -- split on \n and insert lines
      for s in (val .. "\n"):gmatch("(.-)\n") do
        table.insert(lines, s)
      end
    end
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "filetype", "anki")
  require("vankim.embedded").attach(buf)
  Fields.set_fields_names(fields)
  return buf
end

-- Create a scratch buffer prefilled with headers and fields
---@param model string
---@param deck string
---@param fields table
---@return integer buf_index
function M.open_card_buffer(model, deck, fields)
  local buf

  for buffer = 1, vim.fn.bufnr("$") do
    if vim.fn.bufexists(buffer) and vim.api.nvim_buf_get_name(buffer):match("^" .. vim.pesc(vim.g.vankim_bufname)) then
      buf = buffer
      break
    end
  end
  if not buf then
    buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, vim.g.vankim_bufname)
  end

  M.fill_buffer(buf, model, deck, fields, nil)

  -- show the buffer in current window
  local w = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(w, buf)
  vim.api.nvim_set_option_value("filetype", "vankim", {buf = buf})

  return buf
end

-- Parse the current buffer into { model = ..., deck = ..., fields = { fieldName = value, ... } }
---@return table buffer_content
function M.parse_current_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local model, deck
  local fields = {}
  local i = 1
  -- read headers
  while i <= #lines do
    local l = lines[i]
    if l:match("^%s*$") then i = i + 1; break end
    local m = l:match("^%s*Model:%s*(.+)%s*$")
    local d = l:match("^%s*Deck:%s*(.+)%s*$")
    if m then model = m end
    if d then deck = d end
    i = i + 1
  end

  while i <= #lines do
    local l = lines[i]
    local fname, rest = l:match("^%s*([^:]+):%s*(.*)$")
    if fname and Fields.is_a_field(fname) then
      -- gather subsequent non-field lines as continuation until next field or EOF
      local value_lines = {}
      if rest and rest ~= "" then table.insert(value_lines, rest) end
      i = i + 1
      while i <= #lines do
        local nxt = lines[i]
        local nxt_fname = nxt:match("^%s*([^:]+):%s*(.*)$")
        if nxt_fname and Fields.is_a_field(nxt_fname) then break end
        table.insert(value_lines, nxt)
        i = i + 1
      end
      fields[fname] = table.concat(value_lines, "\n")
    else
      i = i + 1
    end
  end

  return { model = model, deck = deck, fields = fields }
end

return M
