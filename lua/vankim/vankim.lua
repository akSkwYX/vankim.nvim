-- Neovim plugin to create Anki cards using AnkiConnect.
-- Usage:
--   :AnkiNew [Model] [DeckName]
--   :AnkiSend [true|false]
--   :AnkiJump [next|previous|beginning|end]
--   :AnkiDeck
--   :AnkiModel

local ankiconnect = require("vankim.ankiconnect")
local buffer_tools = require("vankim.buffer")
local fields = require("vankim.field")

local M = {}

-- Configuration
M.url = "http://127.0.0.1:8765"
ankiconnect.url = M.url
M.api_version = 5
ankiconnect.api_version = M.api_version
M.bufname = "Vankim"
M.latex_tags = { open = "[latex]", close = "[/latex]" }
M.typst_tags = { open = "[typst]", close = "[typst]" }

--------------------------------------------------------------------------------
-- Vankim Public Commands ------------------------------------------------------
--------------------------------------------------------------------------------

function M.AnkiNew(fargs)
  local function parse_fargs(fargs)
    if #fargs == 0 then return { nil, nil } end
    if #fargs == 1 then return { fargs[1], nil } end
    if #fargs == 2 then return fargs end
    local quote_symbol = fargs[1]:sub(1,1)
    local model = fargs[1]
    local i = 2
    if quote_symbol == '"' or quote_symbol == "'" then
      while i <= #fargs + 1 and fargs[i-1]:sub(-1,-1) ~= quote_symbol do
        model = model .. " " .. fargs[i]
        i = i + 1
      end
      model = model:sub(2,-2) -- remove quotes
      if i > #fargs then return { model, nil } end
      if i == #fargs then return { model, fargs[i] } end
    end
    quote_symbol = fargs[i]:sub(1,1)
    local deck = fargs[i]
    i = i + 1
    while i <= #fargs + 1 and fargs[i-1]:sub(-1,-1) ~= quote_symbol do
      deck = deck .. " " .. fargs[i]
      i = i + 1
    end
    deck = deck:sub(2,-2)
    return { model, deck }
  end

  local args = parse_fargs(fargs)
  local last_model, last_deck = ankiconnect.get_last()

  local model = args[1] or last_model or ""
  local deck = args[2] or last_deck or ""

  local fields = {}
  if model and model ~= "" then
    local loc_fields, err = ankiconnect.get_model_fields(model)
    if err or not loc_fields then
      vim.notify("Anki: failed to fetch model fields for '"..model.."': "..tostring(err), vim.log.levels.ERROR)
      return
    end
    fields = loc_fields
  end

  ankiconnect.set_last(model, deck)
  buffer_tools.open_card_buffer(model, deck, fields)
end

function M.AnkiSend(arg)
  local reset = false
  if arg and arg == "true" then reset = true end

  local parsed = buffer_tools.parse_current_buffer()
  if not parsed.model then
    vim.notify("Anki: Model not set in buffer (line 'Model : ...')", vim.log.levels.ERROR)
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
  }
  local payload = { action = "addNote", version = M.api_version, params = { note = note } }
  local res, err = ankiconnect.ankiconnect_request(payload)
  if not res then
    vim.notify("Vankim: addNote failed: "..tostring(err), vim.log.levels.ERROR)
    return
  end
  ankiconnect.set_last(parsed.model, parsed.deck)
  if not reset then vim.notify("Anki: note added (id: "..tostring(res)..")", vim.log.levels.INFO) end

  if reset then
    local buf = vim.api.nvim_get_current_buf()
    local model = parsed.model
    local deck = parsed.deck
    local fields, err = ankiconnect.get_model_fields(model)
    if not fields then
      vim.notify("Anki: failed to fetch model fields for '"..model.."': "..tostring(err), vim.log.levels.ERROR)
      return
    end

    buffer_tools.fill_buffer(buf, model, deck, fields, nil)
  end
end

-- Jump to the next / previous field's value. Accepts opts (user command table) or a string.
function M.AnkiJump(arg)
  local direction = 0
  if arg == "precedent" or arg == "prev" or arg == "p" or arg == "previous" then
    direction = -1
  elseif arg == "next" or arg == "n" then
    direction = 1
  end

  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local fields = fields.get_field_positions()
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

  local decks, err = ankiconnect.ankiconnect_request({ action = "deckNames", version = M.api_version })
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
          table.insert(lines, 2, "Deck: " .. chosen) -- insert after Model
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        ankiconnect.set_last(nil, chosen)
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

  local models, err = ankiconnect.ankiconnect_request({ action = "modelNames", version = M.api_version })
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
        local _, parsed = buffer_tools.parse_current_buffer()
        local old_fields_map
        if not parsed then old_fields_map = {}
        else old_fields_map = parsed.fields or {} end
        -- get names in order from current buffer using positions
        local old_pos = fields.get_field_positions()
        local old_order = {}
        for _, f in ipairs(old_pos) do table.insert(old_order, f.name) end

        local deck
        if not parsed then deck = vim.g.anki_last_deck or ""
        else deck = parsed.deck or vim.g.anki_last_deck or "" end

        -- fetch new model field names
        local new_fields, ferr = ankiconnect.get_model_fields(new_model)
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
        ankiconnect.set_last(new_model, deck)
        buffer_tools.fill_buffer(buf, new_model, deck, new_fields, values)
        vim.notify("Anki: changed model to " .. new_model, vim.log.levels.INFO)
      end)
      return true
    end,
  }):find()
end

function M.AnkiTags(tag)
  local buf = vim.api.nvim_get_current_buf()
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local row = cursor_pos[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local new_lines = {}
  for i, l in ipairs(lines) do
    if i == row then
      if tag == "typst" then
        l = M.typst_tags.open .. l .. M.typst_tags.close
      elseif tag == "latex" then
        l = M.latex_tags.open .. l .. M.latex_tags.close
      end
    end
    table.insert(new_lines, l)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
  vim.api.nvim_win_set_cursor(0, { row, cursor_pos[2]+7 })
end

--------------------------------------------------------------------------------
-- Vankim complete commands ----------------------------------------------------
--------------------------------------------------------------------------------

local function escape_for_quote(s, quote)
  if quote == '"' then
    return s:gsub('"', '\\"')
  elseif quote == "'" then
    return s:gsub("'", "\\'")
  end
  return s
end

local function anki_new_complete(arg_lead, cmd_line, cursor_pos)
  local function parse_args(s)
    local fargs = {}
    for str in s:gmatch("[^%s]+") do
      table.insert(fargs, str)
    end
    local function parse_fargs(fargs)
      if #fargs == 0 then return { nil, nil } end
      if #fargs == 1 then return { fargs[1], nil } end
      if #fargs == 2 then return fargs end
      local quote_symbol = fargs[1]:sub(1,1)
      local model = fargs[1]
      local i = 2
      while i <= #fargs and fargs[i]:sub(-1,-1) ~= quote_symbol do
        model = model .. " " .. fargs[i]
        i = i + 1
      end
      if i > #fargs then return { model, nil } end
      if i == #fargs then return { model, fargs[i] } end
      quote_symbol = fargs[i]:sub(1,1)
      local deck = fargs[i]
      i = i + 1
      while i <= #fargs and fargs[i]:sub(-1,-1) ~= quote_symbol do
        deck = deck .. " " .. fargs[i]
        i = i + 1
      end
      return { model, deck }
    end
    return parse_fargs(fargs)
  end

  local cmd, args = cmd_line:match("^(.*AnkiNew%s*)(.*)$")
  local args = parse_args(args)

  local cursor_pos = cursor_pos - #cmd
  local complete_model = cursor_pos <= #(args[1] or "")

  local prefer_quote = nil
  if arg_lead and #arg_lead > 0 then
    local first = arg_lead:sub(1,1)
    if first == '"' or first == "'" then prefer_quote = first end
  end
  local search_lead = arg_lead or ""
  if prefer_quote then search_lead = search_lead:sub(2) end

  -- model formatting
  local function format_model_matches(list)
    local out = {}
    for _, name in ipairs(list) do
      if name:find("%s") then
        name = '"' .. escape_for_quote(name, '"') .. '"'
      end
      if search_lead == "" or name:find("^" .. vim.pesc(search_lead)) then
        table.insert(out, name)
      end
    end
    return out
  end

  -- deck formatting 
  local function format_deck_matches(list)
    local out = {}
    local seen = {}
    for _, name in ipairs(list) do
      local quoted_name = name
      if name:find("%s") then
        quoted_name = '"' .. escape_for_quote(name, '"') .. '"'
      end
      if search_lead == "" or name:find("^" .. vim.pesc(search_lead)) or quoted_name:find("^" .. vim.pesc(search_lead)) then
        local lead_pre_segment = search_lead:match("^.*::") or ""
        quoted_name = name:match("^" .. vim.pesc(lead_pre_segment) .. "[^:]+:?[^:]+")
                      or quoted_name:match("^" .. vim.pesc(lead_pre_segment) .. "[^:]+:?[^:]+")
        -- Lua is a stupid language which doesn't have 'or' operator for pattern matches...
        if not quoted_name then
          quoted_name = name:match("^" .. vim.pesc(search_lead) .. "[^:]")
                        or quoted_name:match("^" .. vim.pesc(search_lead) .. "[^:]")
        end
        if quoted_name:find("%s") and not (quoted_name:sub(1,1) == '"' or quoted_name:sub(1,1) == "'") then
          quoted_name = '"' .. escape_for_quote(quoted_name, '"') .. '"'
        end
        if quoted_name and not seen[quoted_name] then
          table.insert(out, quoted_name)
          seen[quoted_name] = true
        end
      end
    end
    return out
  end

  if complete_model then
    local res, err = ankiconnect.ankiconnect_request({ action = "modelNames", version = M.api_version })
    if not res or type(res) ~= "table" then
      vim.notify("Vankim: failed to fetch model names: " .. err, vim.log.levels.ERROR)
      return {}
    end
    return format_model_matches(res)
  else
    local res, err = ankiconnect.ankiconnect_request({ action = "deckNames", version = M.api_version })
    if not res or type(res) ~= "table" then
      vim.notify("Vankim: failed to fetch deck names: " .. err, vim.log.levels.ERROR)
      return {}
    end
    return format_deck_matches(res)
  end
end

function M.setup(opts)
  for k,v in pairs(opts or {}) do
    M[k] = v
  end
  vim.g.vankim_bufname = M.bufname

  vim.api.nvim_create_user_command("AnkiNew",
    function(arg) M.AnkiNew(arg.fargs) end,
    { nargs = "*", complete = anki_new_complete })

  vim.api.nvim_create_user_command("AnkiSend",
    function(arg) M.AnkiSend(arg.args) end,
    { nargs = 1, complete = function () return { "true", "false" } end })

  vim.api.nvim_create_user_command("AnkiJump",
    function(arg) M.AnkiJump(arg.args) end,
    { nargs = 1, complete = function() return { "next", "previous", "beginning", "ending" } end})

  vim.api.nvim_create_user_command("AnkiDeck",
    function() M.AnkiDeck() end,
    { nargs = 0 })

  vim.api.nvim_create_user_command("AnkiModel",
    function() M.AnkiModel() end,
    { nargs = 0 })

  vim.api.nvim_create_user_command("AnkiTags",
    function(arg) M.AnkiTags(arg.args) end,
    { nargs = 1, complete = function() return { "typst", "latex" } end })
end

return M
