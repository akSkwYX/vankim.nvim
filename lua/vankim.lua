-- lua/vankim.lua
-- Minimal Neovim helper to create Anki cards using AnkiConnect (via curl + JSON).
-- Usage:
--   :AnkiNew [CardType] [DeckName]
--   :AnkiSend [true|false]
--   :AnkiJump [next|previous|beginning|end]
--   :AnkiDeck
--   :AnkiModel

local M = {}

-- Configuration
M.url = "http://127.0.0.1:8765"
M.api_version = 5
M.bufname_prefix = "AnkiNew:"

-- Helper
-- Parse raw command args preserving quoted strings (supports "..." and '...')
local function split_args(raw)
  if not raw or raw == "" then return {} end
  local args = {}
  local i = 1
  local len = #raw
  while i <= len do
    -- skip whitespace
    while i <= len and raw:sub(i,i):match("%s") do i = i + 1 end
    if i > len then break end
    local c = raw:sub(i,i)
    if c == '"' or c == "'" then
      local quote = c
      i = i + 1
      local j = i
      while j <= len do
        local ch = raw:sub(j,j)
        if ch == "\\" then j = j + 2 -- skip escaped char
        elseif ch == quote then break
        else j = j + 1 end
      end
      local token = raw:sub(i, j-1)
      token = token:gsub("\\"..quote, quote)
      table.insert(args, token)
      i = j + 1
    else
      local j = i
      while j <= len and not raw:sub(j,j):match("%s") do j = j + 1 end
      table.insert(args, raw:sub(i, j-1))
      i = j
    end
  end
  return args
end

-- highlight namespace and default links (uses user's colorscheme groups)
local ns = vim.api.nvim_create_namespace('anki_highlight')
vim.cmd('highlight default link AnkiFieldName Identifier')
vim.cmd('highlight default link AnkiHeader Type')

local function update_highlights(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  for i, l in ipairs(lines) do
    -- detect "Name: ..." style lines (fields and headers)
    local pre, name = l:match('^(%s*)([^:]+):')
    if name then
      local start_col = #pre
      local end_col = start_col + #name
      -- Use different groups for CardType/Deck vs other fields
      if l:match('^%s*CardType:') or l:match('^%s*Deck:') then
        vim.api.nvim_buf_add_highlight(buf, ns, 'AnkiHeader', i-1, start_col, end_col)
      else
        vim.api.nvim_buf_add_highlight(buf, ns, 'AnkiFieldName', i-1, start_col, end_col)
      end
    end
  end
end

-- Simple sync POST via curl. Returns decoded JSON table or nil, err
local function ankiconnect_request(payload)
  local json = vim.fn.json_encode(payload)
  local cmd = { "curl", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-d", json, M.url }
  local ok_res = vim.fn.system(cmd)
  if ok_res == nil or ok_res == '' then
    return nil, "empty response (is Anki running with AnkiConnect?)"
  end
  local ok, decoded = pcall(vim.fn.json_decode, ok_res)
  if not ok then
    return nil, "failed to parse JSON response: " .. tostring(decoded)
  end
  if decoded.error ~= vim.NIL and decoded.error ~= nil then
    return nil, decoded.error
  end
  return decoded.result, nil
end

-- Helpers to store last-used model/deck in vim.g
local function set_last(model, deck)
  if model then vim.g.anki_last_model = model end
  if deck  then vim.g.anki_last_deck  = deck  end
end
local function get_last()
  return vim.g.anki_last_model, vim.g.anki_last_deck
end

-- Fetch model field names (returns array of strings) or nil + err
local function get_model_fields(model_name)
  local payload = { action = "modelFieldNames", version = M.api_version, params = { modelName = model_name } }
  return ankiconnect_request(payload)
end

-- Create a scratch buffer prefilled with headers and fields
local function open_card_buffer(model, deck, fields)
  -- Prepare lines
  local lines = {}
  table.insert(lines, "CardType: " .. (model or ""))
  table.insert(lines, "Deck: " .. (deck or ""))
  table.insert(lines, "")
  table.insert(lines, "")
  for _, f in ipairs(fields) do
    table.insert(lines, f .. ": ")
    table.insert(lines, "")
    table.insert(lines, "")
    table.insert(lines, "")
  end

  local curbuf = vim.api.nvim_get_current_buf()
  local curname = vim.api.nvim_buf_get_name(curbuf) or ""
  local buf

  if curname:match("^" .. vim.pesc(M.bufname_prefix)) then
    -- Reuse current buffer if it already is an Anki buffer
    buf = curbuf
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  else
    buf = vim.api.nvim_create_buf(false, true) -- listed=false, scratch=true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_name(buf, M.bufname_prefix .. (model or "untitled"))
  end

  vim.api.nvim_buf_set_option(buf, "filetype", "anki")

  -- initial highlight pass
  update_highlights(buf)

  -- show the buffer in current window
  local w = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(w, buf)

  return buf
end

-- Public command: AnkiNew [CardType] [DeckName]
-- Simple parser for user-command args (handles the three common shapes)
local function parse_opts_to_fargs(opts)
  -- 1) prefer raw string (supports quotes) when provided
  if type(opts) == "table" and opts.args and opts.args ~= "" then
    return split_args(opts.args)
  end

  -- 2) fallback to nvim's split (simple single-word cases)
  if type(opts) == "table" and opts.fargs and #opts.fargs > 0 then
    return opts.fargs
  end

  -- 3) fallback to numeric tokens inside opts (recombine simple quoted fragments)
  if type(opts) == "table" then
    local raw = {}
    for i, v in ipairs(opts) do table.insert(raw, v) end
    if #raw > 0 then
      local out = {}
      local i = 1
      while i <= #raw do
        local tok = raw[i]
        local first = tok:sub(1,1)
        if (first == '"' or first == "'") and not tok:match(first .. "$") then
          local quote = first
          local parts = { tok:sub(2) } -- without leading quote
          i = i + 1
          while i <= #raw and not raw[i]:match(quote .. "$") do
            table.insert(parts, raw[i]); i = i + 1
          end
          if i <= #raw then
            table.insert(parts, raw[i]:sub(1, -2)) -- without trailing quote
            i = i + 1
          end
          table.insert(out, table.concat(parts, " "))
        else
          -- strip surrounding quotes if both present
          if #tok > 1 and ((tok:sub(1,1) == '"' and tok:sub(-1,-1) == '"') or (tok:sub(1,1) == "'" and tok:sub(-1,-1) == "'")) then
            table.insert(out, tok:sub(2, -2))
          else
            table.insert(out, tok)
          end
          i = i + 1
        end
      end
      return out
    end
  end

  -- 4) if called programmatically with a string
  if type(opts) == "string" and opts ~= "" then
    return split_args(opts)
  end

  return {}
end

local function split_into_lines(s)
  if not s or s == "" then return { "" } end
  local out = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do table.insert(out, line) end
  return out
end

local function get_field_positions(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local fields = {}
  local i = 3
  while i <= #lines do
    local l = lines[i]
    -- detect header lines of the form "FieldName:" optionally with trailing spaces
    local name = l:match("^%s*([^:]+):%s*$")
    if name then
      local header = i
      local start = header + 1
      while start <= #lines and lines[start]:match("^%s*$") do start = start + 1 end
      if start > #lines or lines[start]:match("^%s*[^:]+:%s*$") then
        -- next line is another header: empty field
        table.insert(fields, { name = name, header = header, start = start-2, ending = start-2 })
        i = start
      else
        local j = start
        while j <= #lines and not lines[j]:match("^%s*[^:]+:%s*$") do j = j + 1 end
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

-- Set the i-th field (1-based) value in buf. Replaces the lines that were the previous value.
local function set_field_value(buf, field_index, text)
  buf = buf or vim.api.nvim_get_current_buf()
  local fields = get_field_positions(buf)
  local f = fields[field_index]
  if not f then return false, "field index out of range" end
  local new_lines = split_into_lines(text)
  -- replace existing value region [start, end] (1-based lines -> 0-based indexes)
  local start0 = f.start - 1
  local end0 = f.ending
  vim.api.nvim_buf_set_lines(buf, start0, end0, false, new_lines)
  update_highlights(buf)
  return true
end

function M.AnkiNew(opts)
  local fargs = parse_opts_to_fargs(opts)

  local model = nil
  local deck = nil
  if fargs and #fargs >= 1 and fargs[1] ~= "" then model = fargs[1] end
  if fargs and #fargs >= 2 and fargs[2] ~= "" then deck = fargs[2] end

  local last_model, last_deck = get_last()
  model = model or last_model or ""
  deck = deck or last_deck or ""

  local sel_text = nil
  if type(opts) == "table" and opts.range and opts.line1 and opts.line2 then
    local buf = vim.api.nvim_get_current_buf()
    local start_line = tonumber(opts.line1)
    local end_line = tonumber(opts.line2)
    if start_line and end_line and end_line >= start_line then
      local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
      sel_text = table.concat(lines, "\n")
    end
  else
    local sel_start = vim.fn.getpos("'<")[2] or 0
    local sel_end = vim.fn.getpos("'>")[2] or 0
    if sel_start > 0 and sel_end >= sel_start then
      local curbuf = vim.api.nvim_get_current_buf()
      local lines = vim.api.nvim_buf_get_lines(curbuf, sel_start-1, sel_end, false)
      sel_text = table.concat(lines, "\n")
    end
  end

  -- If selection exists but no model is known, error out
  if sel_text and (not model or model == "") then
    vim.notify("Anki: cannot use visual selection as first field — no model specified or last model available.", vim.log.levels.ERROR)
    return
  end

  local fields = {}
  if model and model ~= "" then
    local loc_fields, err = get_model_fields(model)
    if not fields then
      vim.notify("Anki: failed to fetch model fields for '"..model.."': "..tostring(err), vim.log.levels.ERROR)
      return
    end
    fields = loc_fields
  end

  set_last(model, deck)
  local buf = open_card_buffer(model, deck, fields)

  -- If we captured a visual selection, set it as the first field's value
  if sel_text and sel_text ~= "" then
    local ok, msg = set_field_value(buf, 1, sel_text)
    if not ok then
      vim.notify("Anki: failed to set selection into first field: " .. tostring(msg), vim.log.levels.WARN)
    end
  end

  vim.notify("Anki: opened editor for model '"..model.."' (deck: "..deck..")", vim.log.levels.INFO)
end

-- Parse the current buffer into { model = ..., deck = ..., fields = { fieldName = value, ... } }
local function parse_current_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local model, deck
  local fields = {}
  local i = 1
  -- read headers
  while i <= #lines do
    local l = lines[i]
    if l:match("^%s*$") then i = i + 1; break end
    local m = l:match("^%s*CardType:%s*(.+)%s*$")
    local d = l:match("^%s*Deck:%s*(.+)%s*$")
    if m then model = m end
    if d then deck = d end
    i = i + 1
  end

  -- read fields: expect pattern "FieldName: <content possibly on same line>"
  while i <= #lines do
    local l = lines[i]
    local fname, rest = l:match("^%s*([^:]+):%s*(.*)$")
    if fname then
      -- gather subsequent non-field lines as continuation until next field or EOF
      local value_lines = {}
      if rest and rest ~= "" then table.insert(value_lines, rest) end
      i = i + 1
      while i <= #lines do
        local nxt = lines[i]
        local nxt_fname = nxt:match("^%s*([^:]+):%s*(.*)$")
        if nxt_fname then break end
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

-- Rebuild current Anki buffer content for a model, deck and a list of values aligned with fields.
-- fields_list: array of field names (in order)
-- values: array of strings (may be multi-line) aligned with fields_list
local function rebuild_buffer_with_values(buf, model, deck, fields_list, values)
  buf = buf or vim.api.nvim_get_current_buf()
  local lines = {}
  table.insert(lines, "CardType: " .. (model or ""))
  table.insert(lines, "Deck: " .. (deck or ""))
  table.insert(lines, "")
  table.insert(lines, "")

  for i, fname in ipairs(fields_list) do
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
  update_highlights(buf)
  return buf
end

-- Public command: AnkiSend
function M.AnkiSend(arg)
  local reset = false
  if arg and arg.args == "true" then reset = true end

  local parsed = parse_current_buffer()
  if not parsed.model then
    vim.notify("Anki: CardType not set in buffer (line 'CardType: ...')", vim.log.levels.ERROR)
    return
  end
  if not parsed.deck then
    vim.notify("Anki: Deck not set in buffer (line 'Deck: ...')", vim.log.levels.ERROR)
    return
  end

  -- Build the addNote payload
  local note = {
    deckName = parsed.deck,
    modelName = parsed.model,
    fields = parsed.fields,
    tags = {}  -- could parse tags from buffer later
  }
  local payload = { action = "addNote", version = M.api_version, params = { note = note } }
  local res, err = ankiconnect_request(payload)
  if not res then
    vim.notify("Anki: addNote failed: "..tostring(err), vim.log.levels.ERROR)
    return
  end
  set_last(parsed.model, parsed.deck)
  if not reset then vim.notify("Anki: note added (id: "..tostring(res)..")", vim.log.levels.INFO) end

  if reset then
    local buf = vim.api.nvim_get_current_buf()
    local model = parsed.model
    local deck = parsed.deck
    local fields, err = get_model_fields(model)
    if not fields then
      vim.notify("Anki: failed to fetch model fields for '"..model.."': "..tostring(err), vim.log.levels.ERROR)
      return
    end

    rebuild_buffer_with_values(buf, model, deck, fields, nil)
    -- vim.notify("Anki: reset editor for model '"..model.."' (deck: "..deck..")", vim.log.levels.INFO)
  end
end


-- Jump to the next / previous field's value. Accepts opts (user command table) or a string.
function M.AnkiJump(opts)
  local arg = nil
  if type(opts) == "table" and opts.args then arg = opts.args:lower() elseif type(opts) == "string" then arg = opts:lower() end
  local direction = 0
  if arg == "precedent" or arg == "prev" or arg == "p" or arg == "previous" then 
    direction = -1
  elseif arg == "next" or arg == "n" then
    direction = 1
  end

  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local fields = get_field_positions(buf)
  if #fields == 0 then vim.notify("Anki: no fields found", vim.log.levels.WARN); return end

  local target = nil
  local current_field = 1
  while current_field <= #fields and fields[current_field].header < row do
    current_field = current_field + 1
  end
  current_field = current_field - 1
  target = fields[((current_field-1+direction) % #fields) + 1]

  local position = { target.start, 0 }
  if arg == "ending" or arg == "end" or arg == "e" then 
    position = { target.ending, #(vim.api.nvim_get_current_line()) - 1 } 
  end
  vim.api.nvim_win_set_cursor(0, position)
end

-- Add Telescope-based selectors for deck and card type
local function ensure_telescope()
  local ok, _ = pcall(require, "telescope")
  return ok
end

local function set_header_in_buffer(buf, header, value)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, l in ipairs(lines) do
    if l:match("^%s*" .. vim.pesc(header) .. "%s*:") then
      lines[i] = header .. ": " .. value
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      return true
    end
  end
  -- if header missing, insert at top
  table.insert(lines, 1, header .. ": " .. value)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return true
end


function M.AnkiDeck()
  if not pcall(require, "telescope") then
    vim.notify("Anki: telescope not found (install telescope.nvim to use :AnkiDeck)", vim.log.levels.WARN)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local decks, err = ankiconnect_request({ action = "deckNames", version = M.api_version })
  if not decks then vim.notify("Anki: failed to fetch decks: " .. tostring(err), vim.log.levels.ERROR); return end

  pickers.new({}, {
    prompt_title = "Anki decks",
    finder = finders.new_table { results = decks },
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        local chosen = selection[1]
        local buf = vim.api.nvim_get_current_buf()
        -- update only the Deck: header line, preserve buffer text
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local updated = false
        for i, l in ipairs(lines) do
          if l:match("^%s*Deck:%s*") then
            lines[i] = "Deck: " .. chosen
            updated = true
            break
          end
        end
        if not updated then
          table.insert(lines, 2, "Deck: " .. chosen) -- insert after CardType
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        set_last(nil, chosen)
        update_highlights(buf)
        vim.notify("Anki: deck set to " .. chosen, vim.log.levels.INFO)
      end)
      return true
    end,
  }):find()
end

function M.AnkiModel()
  if not pcall(require, "telescope") then
    vim.notify("Anki: telescope not found (install telescope.nvim to use :AnkiModel)", vim.log.levels.WARN)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local models, err = ankiconnect_request({ action = "modelNames", version = M.api_version })
  if not models then vim.notify("Anki: failed to fetch models: " .. tostring(err), vim.log.levels.ERROR); return end

  pickers.new({}, {
    prompt_title = "Anki models (card types)",
    finder = finders.new_table { results = models },
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        local new_model = selection[1]

        -- parse current buffer content
        local buf = vim.api.nvim_get_current_buf()
        local parsed = parse_current_buffer()
        local old_fields_map = parsed.fields or {}
        -- get names in order from current buffer using positions
        local old_pos = get_field_positions(buf)
        local old_order = {}
        for _, f in ipairs(old_pos) do table.insert(old_order, f.name) end

        local deck = parsed.deck or vim.g.anki_last_deck or ""

        -- fetch new model field names
        local new_fields, ferr = get_model_fields(new_model)
        if not new_fields then
          vim.notify("Anki: failed to fetch fields for model '" .. new_model .. "': " .. tostring(ferr), vim.log.levels.ERROR)
          return
        end

        -- Build new values aligned with new_fields:
        -- 1) fill from old_fields_map by exact name match
        -- 2) for remaining new positions, fill from old_order by index if not yet consumed
        local used_old = {}
        local values = {}

        -- step 1: name matches
        for i, nf in ipairs(new_fields) do
          if old_fields_map[nf] then
            values[i] = old_fields_map[nf]
            used_old[nf] = true
          end
        end

        -- step 2: index-preserve for remaining fields
        local old_idx = 1
        for i = 1, #new_fields do
          if values[i] == nil then
            -- advance old_idx to next not-used old field
            while old_idx <= #old_order and used_old[ old_order[old_idx] ] do old_idx = old_idx + 1 end
            if old_idx <= #old_order then
              local name_at_idx = old_order[old_idx]
              values[i] = old_fields_map[name_at_idx] or ""
              used_old[name_at_idx] = true
              old_idx = old_idx + 1
            else
              values[i] = ""
            end
          end
        end

        -- persist last used and rebuild buffer with preserved values
        set_last(new_model, deck)
        rebuild_buffer_with_values(buf, new_model, deck, new_fields, values)
        vim.notify("Anki: changed model to " .. new_model, vim.log.levels.INFO)
      end)
      return true
    end,
  }):find()
end



-- Setup: create user commands
-- Completion for :AnkiNew that wraps suggestions in quotes but still filters on partial input.
local function escape_for_quote(s, quote)
  if quote == '"' then
    return s:gsub('"', '\\"')
  elseif quote == "'" then
    return s:gsub("'", "\\'")
  end
  return s
end

local function quote_candidate(s, preferred_quote)
  if preferred_quote == '"' then
    return '"' .. escape_for_quote(s, '"') .. '"'
  elseif preferred_quote == "'" then
    return "'" .. escape_for_quote(s, "'") .. "'"
  else
    -- choose a quote that doesn't appear in s if possible
    if s:find('"') and not s:find("'") then
      return "'" .. escape_for_quote(s, "'") .. "'"
    else
      return '"' .. escape_for_quote(s, '"') .. '"'
    end
  end
end

local function anki_new_complete(arg_lead, cmd_line, cursor_pos)
  local before_cursor = cmd_line
  if cursor_pos and type(cursor_pos) == "number" and cursor_pos <= #cmd_line then
    before_cursor = cmd_line:sub(#(cmd_line:match(".*AnkiNew%s*") or ""), cursor_pos)
  end

  local parts = split_args(before_cursor)
  local arg_index = nil
  if arg_lead and #arg_lead > 0 then
    arg_index = #parts - 1
  else 
    arg_index = #parts
  end

  local prefer_quote = nil
  if arg_lead and #arg_lead > 0 then
    local first = arg_lead:sub(1,1)
    if first == '"' or first == "'" then prefer_quote = first end
  end
  local search_lead = arg_lead or ""
  if prefer_quote then search_lead = search_lead:sub(2) end
  search_lead = search_lead:lower()

  -- generic model formatting
  local function format_model_matches(list)
    local out = {}
    for _, name in ipairs(list) do
      local lname = name:lower()
      if search_lead == "" or lname:find("^" .. vim.pesc(search_lead)) then
        if prefer_quote then
          table.insert(out, escape_for_quote(name, prefer_quote))
        else
          if name:find("%s") or name:find('"') or name:find("'") then
            table.insert(out, quote_candidate(name, nil))
          else
            table.insert(out, name)
          end
        end
      end
    end
    return out
  end

  -- deck-aware formatting: show both top-level names and full deck names; match suffix segment
  local function format_deck_matches(list)
    local out = {}
    local seen = {}

    -- normalize user's typed prefix: collapse any sequence of colons to '::'
    local norm = (search_lead or ""):gsub(":+", "::")

    local has_separator = norm:find("::", 1, true) ~= nil

    for _, deck in ipairs(list) do
      local lname = deck:lower()
      local topo = lname:match("^[^:]+") or lname
      local lastseg = lname:match("([^:]+)$") or lname

      if has_separator then
        -- user asked for a specific path: match full deck names starting with normalized prefix
        if norm == "" or lname:find("^" .. vim.pesc(norm)) then
          local candidate = deck
          if prefer_quote then candidate = escape_for_quote(candidate, prefer_quote)
          else candidate = (deck:find("%s") or deck:find('"') or deck:find("'")) and quote_candidate(deck, nil) or deck end
          if not seen[candidate] then seen[candidate] = true; table.insert(out, candidate) end
        end
      else
        -- no separator typed: offer top-level deck names (deduped) and also decks whose full name starts with the prefix
        if search_lead == "" then
          -- when nothing typed, include top-level names and also any top-level full names (keeps examples simple)
          local top = deck:match("^[^:]+") or deck
          if top and not seen[top] then seen[top] = true; table.insert(out, top) end
        else
          -- match either full deck prefix OR top-level name prefix OR last segment prefix
          if lname:find("^" .. vim.pesc(norm)) or topo:find("^" .. vim.pesc(norm)) or lastseg:find("^" .. vim.pesc(norm)) then
            -- prefer returning top-level token (topo) to let user pick root decks, but also return full name if it is a single-level deck or if it matches fully
            local top = deck:match("^[^:]+") or deck
            if topo:find("^" .. vim.pesc(norm)) and not seen[top] then seen[top] = true; table.insert(out, top) end
            if (lname:find("^" .. vim.pesc(norm)) or lastseg:find("^" .. vim.pesc(norm))) then
              local candidate = deck
              if prefer_quote then candidate = escape_for_quote(candidate, prefer_quote)
              else candidate = (deck:find("%s") or deck:find('"') or deck:find("'")) and quote_candidate(deck, nil) or deck end
              if not seen[candidate] then seen[candidate] = true; table.insert(out, candidate) end
            end
          end
        end
      end
    end

    return out
  end

  if arg_index <= 0 then
    local res = ankiconnect_request({ action = "modelNames", version = M.api_version })
    if not res or type(res) ~= "table" then return {} end
    return format_model_matches(res)
  elseif arg_index == 1 then
    local res = ankiconnect_request({ action = "deckNames", version = M.api_version })
    if not res or type(res) ~= "table" then return {} end
    return format_deck_matches(res)
  else
    return {}
  end
end

local function anki_move_to_field_complete(arg_lead, cmd_line, cursor_pos)
  local directions = { "next", "previous" }
  local positions = { "beginning", "ending" }
  local parts = split_args(cmd_line)
  local arg_index = nil
  if arg_lead and #arg_lead > 0 then
    arg_index = #parts - 1
  else
    arg_index = #parts
  end
  if arg_index == 1 then
    local out = {}
    for _, d in ipairs(directions) do
      if arg_lead == "" or d:find("^" .. vim.pesc(arg_lead:lower())) then
        table.insert(out, d)
      end
    end
    return out
  elseif arg_index == 2 then
    local out = {}
    for _, p in ipairs(positions) do
      if arg_lead == "" or p:find("^" .. vim.pesc(arg_lead:lower())) then
        table.insert(out, p)
      end
    end
    return out
  else
    return {}
  end
end

function M.setup()
  vim.api.nvim_create_user_command("AnkiNew",
    function(opts) M.AnkiNew(opts.fargs) end,
    { nargs = "*", range = true, complete = anki_new_complete })

  vim.api.nvim_create_user_command("AnkiSend",
    function(arg) M.AnkiSend(arg) end,
    { nargs = 1, complete = function () return { "true", "false" } end })

  vim.api.nvim_create_user_command("AnkiJump",
    function(opts) M.AnkiJump(opts) end,
    { nargs = "?", complete = function() return { "next", "previous", "beginning", "ending" } end})

  vim.api.nvim_create_user_command("AnkiDeck",
    function() M.AnkiDeck() end,
    { nargs = 0 })

  vim.api.nvim_create_user_command("AnkiModel",
    function() M.AnkiModel() end,
    { nargs = 0 })
end

-- Auto-setup on require() (optional)
M.setup()

return M
