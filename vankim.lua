-- lua/anki.lua
-- Minimal Neovim helper to create Anki cards using AnkiConnect (via curl + JSON).
-- Usage:
--   :AnkiNew [CardType] [DeckName]
--   :AnkiSend [true|false]
--   :AnkiJump [next|previous]
--   :AnkiMoveField [beginning|end]

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

-- Fallback to any deck if none provided
local function first_deck_name()
  local res, err = ankiconnect_request({ action = "deckNames", version = M.api_version })
  if not res then return nil, err end
  return res[1], nil
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

  -- Set up autocmds for updating highlights on change (buffer-local)
  -- Remove any previous autocmds for this buffer name to avoid duplicates
  -- vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged", "TextChangedI" }, {
  --   buffer = buf,
  --   callback = function() update_highlights(buf) end,
  -- })

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

-- Replace start of M.AnkiNew with this (rest of function stays the same)
function M.AnkiNew(opts)
  local fargs = parse_opts_to_fargs(opts)

  local model = nil
  local deck = nil
  if fargs and #fargs >= 1 and fargs[1] ~= "" then model = fargs[1] end
  if fargs and #fargs >= 2 and fargs[2] ~= "" then deck = fargs[2] end

  local last_model, last_deck = get_last()
  if not model then model = last_model end
  if not deck  then deck  = last_deck  end

  if not deck then
    local d, err = first_deck_name()
    if not d then
      vim.notify("Anki: failed to get a deck list: "..tostring(err), vim.log.levels.ERROR)
      return
    end
    deck = d
  end

  if not model then
    model = vim.fn.input("Anki model name (note type): ")
    if model == "" then
      vim.notify("Anki: no model specified", vim.log.levels.ERROR)
      return
    end
  end

  local fields, err = get_model_fields(model)
  if not fields then
    vim.notify("Anki: failed to fetch model fields for '"..model.."': "..tostring(err), vim.log.levels.ERROR)
    return
  end

  set_last(model, deck)
  open_card_buffer(model, deck, fields)
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

-- Public command: AnkiSend
function M.AnkiSend(args)
  if args and args[1] and args[1] == "true" then
    local reset = true
  else
    local reset = false
  end

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
  vim.notify("Anki: note added (id: "..tostring(res)..")", vim.log.levels.INFO)

  if reset then
    local model = parsed.model
    local deck = parsed.deck
    local fields, err = get_model_fields(model)
    if not fields then
      vim.notify("Anki: failed to fetch model fields for '"..model.."': "..tostring(err), vim.log.levels.ERROR)
      return
    end

    open_card_buffer(model, deck, fields)
    vim.notify("Anki: opened editor for model '"..model.."' (deck: "..deck..")", vim.log.levels.INFO)
  end
end

-- Return a list of field descriptors { name, header, start, ["end"] } (1-based line numbers)
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

-- Jump to the next / previous field's value. Accepts opts (user command table) or a string.
function M.AnkiJump(opts)
  local arg = nil
  if type(opts) == "table" and opts.args then arg = opts.args:lower() elseif type(opts) == "string" then arg = opts:lower() end
  local forward = true
  if arg == "precedent" or arg == "prev" or arg == "p" or arg == "previous" then forward = false end

  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local fields = get_field_positions(buf)
  if #fields == 0 then vim.notify("Anki: no fields found", vim.log.levels.WARN); return end

  local target = nil
  local current_field = 1
  while current_field <= #fields and fields[current_field].header < row do
    current_field = current_field + 1
  end
  if forward then
    target = fields[current_field] or fields[1]
  else
    target = fields[current_field - 2] or fields[#fields]
  end

  local to_line = target.start
  vim.api.nvim_win_set_cursor(0, { to_line, 0 })
end

-- Move inside the current field: to beginning or end of its value.
function M.AnkiMoveField(opts)
  local arg = nil
  if type(opts) == "table" and opts.args then arg = opts.args:lower() elseif type(opts) == "string" then arg = opts:lower() end
  local to_begin = true
  if arg == "ending" or arg == "end" then to_begin = false end

  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local fields = get_field_positions(buf)
  if #fields == 0 then vim.notify("Anki: no fields found", vim.log.levels.WARN); return end

  -- find the field that contains or precedes the cursor
  local current_field = 1
  while current_field <= #fields and fields[current_field].header < row do
    current_field = current_field + 1
  end

  if to_begin then
    local target_line = fields[current_field-1].start
    vim.api.nvim_win_set_cursor(0, { target_line, 0 })
  else
    local target_line = fields[current_field-1].ending
    local text = vim.api.nvim_buf_get_lines(buf, target_line-1, target_line, false)[1] or ""
    local col = #text
    vim.api.nvim_win_set_cursor(0, { target_line, col })
  end
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

-- anki_new_complete uses split_args (already in your file) to determine argument index.
local function anki_new_complete(arg_lead, cmd_line, cursor_pos)
  -- Determine text up to cursor to correctly parse quoted tokens
  local before_cursor = cmd_line
  if cursor_pos and type(cursor_pos) == "number" and cursor_pos <= #cmd_line then
    before_cursor = cmd_line:sub(1, cursor_pos)
  end

  local parts = split_args(before_cursor)
  -- which argument are we completing? parts[1] is "AnkiNew"
  local arg_index = #parts -- number of tokens currently typed (includes the token being completed if any)
  if arg_index == 0 then arg_index = 1 end
  -- If the user has started typing the token (arg_lead), detect opening quote
  local prefer_quote = nil
  if arg_lead and #arg_lead > 0 then
    local first = arg_lead:sub(1,1)
    if first == '"' or first == "'" then prefer_quote = first end
  end

  local search_lead = arg_lead or ""
  if prefer_quote then search_lead = search_lead:sub(2) end
  search_lead = search_lead:lower()

  local function format_matches(list)
    local out = {}
    for _, name in ipairs(list) do
      local lname = name:lower()
      if search_lead == "" or lname:find("^" .. vim.pesc(search_lead)) then
        if prefer_quote then
          -- user opened a quote: complete inside it (don't return surrounding quotes)
          table.insert(out, escape_for_quote(name, prefer_quote))
        else
          -- If name contains whitespace or quotes, return quoted form; otherwise return unquoted to allow bare usage.
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

  if arg_index <= 1 then
    local res = ankiconnect_request({ action = "modelNames", version = M.api_version })
    if not res or type(res) ~= "table" then return {} end
    return format_matches(res)
  elseif arg_index == 2 then
    local res = ankiconnect_request({ action = "deckNames", version = M.api_version })
    if not res or type(res) ~= "table" then return {} end
    return format_matches(res)
  else
    return {}
  end
end

function M.setup()
  vim.api.nvim_create_user_command("AnkiNew",
    function(opts) M.AnkiNew(opts.fargs) end,
    { nargs = "*", complete = anki_new_complete })

  vim.api.nvim_create_user_command("AnkiSend",
    function() M.AnkiSend() end,
    { nargs = "*"})

  vim.api.nvim_create_user_command("AnkiJump",
    function(opts) M.AnkiJump(opts) end,
    { nargs = "?", complete = function() return { "next", "previous" } end})

  vim.api.nvim_create_user_command("AnkiMoveField",
    function(opts) M.AnkiMoveField(opts) end,
    { nargs = "?", complete = function() return { "beginning", "begining", "ending", "end" } end})
end

-- Auto-setup on require() (optional)
M.setup()

return M
