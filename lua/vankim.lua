-- lua/vankim.lua
-- Minimal Neovim helper to create Anki cards using AnkiConnect (via curl + JSON).
-- Usage:
--   :AnkiNew [Model] [DeckName]
--   :AnkiSend [true|false]
--   :AnkiJump [next|previous|beginning|end]
--   :AnkiDeck
--   :AnkiModel

local M = {}

-- Configuration
M.url = "http://127.0.0.1:8765"
M.api_version = 6
M.bufname_prefix = "Vankim:"
M.latex_tags = { open = "[latex]", close = "[/latex]" }
M.typst_tags = { open = "[typst]", close = "[/typst]" }

-- Helper
-- Parse command arg to appropriate shape (table of strings)
-- I'm not sure if it's useful I didn't really understand arguments
local function parse_arg(arg)
  local args = {}

  local function split_raw_arg(raw)
    local i = 1
    local len = #raw
    while i <= len do
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
  end

  local function split_table(tbl)
    local raw = {}
    for i, v in ipairs(tbl) do table.insert(raw, v) end
    if #raw > 0 then
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
          table.insert(args, table.concat(parts, " "))
        else
          -- strip surrounding quotes if both present
          if #tok > 1 and ((tok:sub(1,1) == '"' and tok:sub(-1,-1) == '"') or (tok:sub(1,1) == "'" and tok:sub(-1,-1) == "'")) then
            table.insert(args, tok:sub(2, -2))
          else
            table.insert(args, tok)
          end
          i = i + 1
        end
      end
    end
  end

  if type(arg) == "table" and arg.args and arg.args ~= "" then
    split_raw_arg(arg.args)
  elseif type(arg) == "string" and arg ~= "" then
    split_raw_arg(arg)
  elseif type(arg) == "table" and arg.fargs and #arg.fargs > 0 then
    args = arg.fargs
  elseif type(arg) == "table" then
    split_table(arg)
  end
  return args
end

--------------------------------------------------------------------------------
-- Field management tools ------------------------------------------------------
--------------------------------------------------------------------------------

-- Fields names
local Fields_names = {}
local function set_fields_names(names)
  for _, n in ipairs(names) do
    Fields_names[n] = true
  end
end
local function is_a_field(name)
  if name:sub(#name, #name) == ":" then
    name = name:sub(1, #name-1)
  end
  while name:sub(1,1) == " " do name = name:sub(2,#name) end
  while name:sub(#name,#name) == " " do name = name:sub(1,#name-1) end
  return Fields_names[name] ~= nil
end

-- Get field positions in the current buffer
local function get_field_positions(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local fields = {}
  local i = 3 -- Skip Model and Deck headers
  while i <= #lines do
    local l = lines[i]
    -- detect header lines of the form "FieldName:" optionally with trailing spaces
    local name = l:match("^%s*([^:]+):%s*$")
    if name and is_a_field(name) then
      local header = i
      local start = header + 1
      while start <= #lines and lines[start]:match("^%s*$") do start = start + 1 end
      if start > #lines or (lines[start]:match("^%s*[^:]+:%s*$") and is_a_field(lines[start]:match("^%s*[^:]+:%s*$"))) then
        table.insert(fields, { name = name, header = header, start = start-2, ending = start-2 })
        i = start
      else
        local j = start
        while j <= #lines and not (lines[j]:match("^%s*[^:]+:%s*$") and is_a_field(lines[j]:match("^%s*[^:]+:%s*$"))) do
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
  if #fields ~= #Fields_names then
    vim.notify("Vankim: Incorrect number of field, ensure that no field appear twice", vim.log.levels.ERROR)
    return {}
  end
  return fields
end

-- Set the i-th field (1-based) value in buf. Replaces the lines that were the previous value.
local function set_field_value(buf, field_index, text)
  local function split_into_lines(s)
    if not s or s == "" then return { "" } end
    local out = {}
    for line in (s .. "\n"):gmatch("(.-)\n") do table.insert(out, line) end
    return out
  end

  buf = buf or vim.api.nvim_get_current_buf()
  local fields = get_field_positions(buf)
  local f = fields[field_index]
  if not f then return false, "field index out of range" end
  local new_lines = split_into_lines(text)
  -- replace existing value region [start, end] (1-based lines -> 0-based indexes)
  local start0 = f.start - 1
  local end0 = f.ending
  vim.api.nvim_buf_set_lines(buf, start0, end0, false, new_lines)
  return true
end

--------------------------------------------------------------------------------
-- Highlighting ----------------------------------------------------------------
--------------------------------------------------------------------------------

-- highlight namespace and default links (uses user's colorscheme groups) ------
local ns = vim.api.nvim_create_namespace('anki_highlight')
vim.cmd('highlight default link AnkiFieldName Identifier')
vim.cmd('highlight default link AnkiHeader Type')

local function update_highlights(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  for i, l in ipairs(lines) do
    -- detect "Name: ..." style lines (fields and headers)
    local name = l:match('^([^:]+):')
    if name and (l:match('^Model:') or l:match('^Deck:')) then
      vim.api.nvim_buf_add_highlight(buf, ns, 'AnkiHeader', i-1, 0, #name)
    end
    if name and is_a_field(name) then
      vim.api.nvim_buf_add_highlight(buf, ns, 'AnkiFieldName', i-1, 0, #name)
    end
  end
end

--------------------------------------------------------------------------------
-- AnkiConnect interactions ----------------------------------------------------
--------------------------------------------------------------------------------

-- Helpers to store last-used model/deck in vim.g
local function set_last(model, deck)
  if model then vim.g.anki_last_model = model end
  if deck  then vim.g.anki_last_deck  = deck  end
end

local function get_last()
  return vim.g.anki_last_model, vim.g.anki_last_deck
end

-- Handle AnkiConnect requests
local function ankiconnect_request(payload)
  local json = vim.fn.json_encode(payload)
  local cmd = { "curl", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-d", json, M.url }
  local ok_res = vim.fn.system(cmd)
  if ok_res == false then
    return nil, "Error in ankiconnect request"
  end
  if ok_res == nil then
    return true, nil
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

-- Fetch model field names
local function get_model_fields(model_name)
  local payload = { action = "modelFieldNames", version = M.api_version, params = { modelName = model_name } }
  return ankiconnect_request(payload)
end

--------------------------------------------------------------------------------
-- Typst & Latex ---------------------------------------------------------------
--------------------------------------------------------------------------------

local function sanitize_filename(name)
  return (name or ""):gsub("%s+", "_"):gsub("[^%w_-]", "")
end

local function save_preamble_remote(type, name, text)
  local safe = sanitize_filename(name):lower()
  local filename = ("_anki_preamble_%s_%s.txt"):format(type, safe)
  local b64 = vim.fn.systemlist({"base64", "--wrap=0"}, text)[1]
  local payload = {
    action = "storeMediaFile",
    version = M.api_version,
    params = {
      filename = filename,
      data = b64
    }
  }
  local res, err = ankiconnect_request(payload)
  if not res then return nil, err end
  return filename
end

local function load_preamble_remote(type, name)
  local safe = sanitize_filename(name):lower()
  local filename = ("_anki_preamble_%s_%s.txt"):format(type, safe)
  local payload = {
    action = "retrieveMediaFile",
    version = M.api_version,
    params = {
      filename = filename
    }
  }
  local res, err = ankiconnect_request(payload)
  if not res then return nil, err end
  local decoded = vim.fn.systemlist({"base64", "--decode"}, res)
  return table.concat(decoded, "\n")
end

local function save_preamble_local(type, name, text)
  local safe = sanitize_filename(name):lower()
  local filename = ("_anki_preamble_%s_%s.txt"):format(type, safe)
  local filepath = vim.fn.stdpath("cache") .. "/" .. filename
  local ok, res = pcall(vim.fn.writefile, vim.split(text, "\n"), filepath)
  if not ok then return nil, "Failed to write preamble file: " .. tostring(res) end
  return filepath
end

local function load_preamble_local(type, name)
  local safe = sanitize_filename(name):lower()
  local filename = ("_anki_preamble_%s_%s.txt"):format(type, safe)
  local filepath = vim.fn.stdpath("cache") .. "/" .. filename
  if vim.fn.filereadable(filepath) == 0 then
    return nil, "Preamble file not found: " .. filepath
  end
  return table.concat(vim.fn.readfile(filepath), "\n")
end

local function load_preamble(type, name)
  local text, err = load_preamble_local(type, name)
  if text then return text end
  text, err = load_preamble_remote(type, name)
  if text then save_preamble_local(type, name, text); return text end
end

local function save_preamble(type, name, text)
  local filepath, err = save_preamble_local(type, name, text)
  if filepath then
    local remote_path, rerr = save_preamble_remote(type, name, text)
    if not remote_path then
      vim.notify("Vankim: failed to save remote preamble: " .. tostring(rerr), vim.log.levels.WARN)
      return
    end
    local safe = sanitize_filename(name):lower()
    local filename = ("_anki_preamble_%s_%s.txt"):format(type, safe)
    local anki_preambles, err = ankiconnect_request({
      action = "retrieveMediaFile",
      version = M.api_version,
      params = {
        filename = "_anki_preamble_list.txt"
      }
    })
    anki_preambles = vim.fn.systemlist({"base64", "--decode"}, anki_preambles) or ""
    local need_to_save = false
    if not anki_preambles then anki_preambles = filename; need_to_save = true
    elseif anki_preambles:find(filename) == nil then 
      anki_preambles = anki_preambles .. "\n" .. filename; need_to_save = true end
    if need_to_save then 
      local b64 = vim.fn.systemlist({"base64", "--wrap=0"}, anki_preambles)[1]
      local ok, err = ankiconnect_request({
        action = "storeMediaFile",
        version = M.api_version,
        params = {
          filename = "_anki_preamble_list.txt",
          data = b64
        }
      })
      if not ok then vim.notify("Vankim: failed to update preamble list: " .. tostring(err), vim.log.levels.WARN) end
    end
  else
    vim.notify("Vankim: failed to save local preamble: " .. tostring(err), vim.log.levels.ERROR)
  end
end

local function delete_preamble(typ, name)
  local safe = sanitize_filename(name):lower()
  local filename = ("_anki_preamble_%s_%s.txt"):format(typ, safe)
  local payload = {
    action = "deleteMediaFile",
    version = M.api_version,
    params = {
      filename = filename
    }
  }
  local res, err = ankiconnect_request(payload)
  if not res then return false, err end
  local filepath = vim.fn.stdpath("cache") .. "/" .. filename
  if vim.fn.filereadable(filepath) then
    local ok, err = pcall(vim.fn.delete, filepath)
    if not ok then return false, "Failed to delete local preamble file: " .. tostring(err) end
  end
  local preamble_list, err = ankiconnect_request({
    action = "retrieveMediaFile",
    version = M.api_version,
    params = {
      filename = "_anki_preamble_list.txt"
    }
  })
  if not preamble_list then return false, err end
  preamble_list = vim.fn.systemlist({"base64", "--decode"}, preamble_list) or {}
  local new_list = {}
  for _, line in ipairs(preamble_list) do
    if line:match(filename) == nil then table.insert(new_list, line) end
  end
  local b64 = vim.fn.systemlist({"base64", "--wrap=0"}, table.concat(new_list, "\n"))[1]
  local ok, err = ankiconnect_request({
    action = "storeMediaFile",
    version = M.api_version,
    params = {
      filename = "_anki_preamble_list.txt",
      data = b64
    }
  })
  if not ok then return false, "Failed to update preamble list: " .. tostring(err) end
  return true
end

local function save_ending_remote(type, name, text)
  local safe = sanitize_filename(name):lower()
  local filename = ("_anki_ending_%s_%s.txt"):format(type, safe)
  local b64 = vim.fn.systemlist({"base64", "--wrap=0"}, text)[1]
  local payload = {
    action = "storeMediaFile",
    version = M.api_version,
    params = {
      filename = filename,
      data = b64
    }
  }
  local res, err = ankiconnect_request(payload)
  if not res then return nil, err end
  return filename
end

local function load_ending_remote(type, name)
  local safe = sanitize_filename(name):lower()
  local filename = ("_anki_ending_%s_%s.txt"):format(type, safe)
  local payload = {
    action = "retrieveMediaFile",
    version = M.api_version,
    params = {
      filename = filename
    }
  }
  local res, err = ankiconnect_request(payload)
  if not res then return nil, err end
  local decoded = vim.fn.systemlist({"base64", "--decode"}, res)
  return table.concat(decoded, "\n")
end

local function save_ending_local(type, name, text)
  local safe = sanitize_filename(name):lower()
  local filename = ("_anki_ending_%s_%s.txt"):format(type, safe)
  local filepath = vim.fn.stdpath("cache") .. "/" .. filename
  local ok, res = pcall(vim.fn.writefile, vim.split(text, "\n"), filepath)
  if not ok then return nil, "Failed to write ending file: " .. tostring(res) end
  return filepath
end

local function load_ending_local(type, name)
  local safe = sanitize_filename(name):lower()
  local filename = ("_anki_ending_%s_%s.txt"):format(type, safe)
  local filepath = vim.fn.stdpath("cache") .. "/" .. filename
  if vim.fn.filereadable(filepath) == 0 then
    return nil, "Ending file not found: " .. filepath
  end
  return table.concat(vim.fn.readfile(filepath), "\n")
end

local function load_ending(type, name)
  local text, err = load_ending_local(type, name)
  if text then return text end
  text, err = load_ending_remote(type, name)
  if text then save_ending_local(type, name, text); return text end
end

local function save_ending(type, name, text)
  local filepath, err = save_ending_local(type, name, text)
  if filepath then
    local remote_path, rerr = save_ending_remote(type, name, text)
    if not remote_path then
      vim.notify("Vankim: failed to save remote ending : " .. tostring(rerr), vim.log.levels.WARN)
    end
    return filepath
  else
    vim.notify("Vankim: failed to save local ending : " .. tostring(err), vim.log.levels.ERROR)
  end
end

--------------------------------------------------------------------------------
-- Buffer management -----------------------------------------------------------
--------------------------------------------------------------------------------

-- Fill buffer
local function fill_buffer(buf, model, deck, fields, values)
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
  set_fields_names(fields)
  update_highlights(buf)
  return buf
end

-- Create a scratch buffer prefilled with headers and fields
local function open_card_buffer(model, deck, fields)
  local curbuf = vim.api.nvim_get_current_buf()
  local curname = vim.api.nvim_buf_get_name(curbuf) or ""
  local buf

  if curname:match("^" .. vim.pesc(M.bufname_prefix)) then
    -- Reuse current buffer if it already is an Anki buffer
    buf = curbuf
  else
    buf = vim.api.nvim_create_buf(true, true) -- listed=false, scratch=true
    vim.api.nvim_buf_set_name(buf, M.bufname_prefix .. (model or "untitled"))
  end

  vim.api.nvim_buf_set_option(buf, "filetype", "anki")

  fill_buffer(buf, model, deck, fields, nil)

  -- show the buffer in current window
  local w = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(w, buf)

  return buf
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
    local m = l:match("^%s*Model:%s*(.+)%s*$")
    local d = l:match("^%s*Deck:%s*(.+)%s*$")
    if m then model = m end
    if d then deck = d end
    i = i + 1
  end

  local typst_preamble = load_preamble("typst", model) or ""
  local typst_ending = load_ending("typst", model) or ""
  local latex_preamble = load_preamble("latex", model) or ""
  local latex_ending = load_ending("latex", model) or ""

  local err = false

  while i <= #lines do
    local l = lines[i]
    local fname, rest = l:match("^%s*([^:]+):%s*(.*)$")
    if fname and is_a_field(fname) then
      -- gather subsequent non-field lines as continuation until next field or EOF
      local value_lines = {}
      if rest and rest ~= "" then table.insert(value_lines, rest) end
      i = i + 1
      while i <= #lines do
        local nxt = lines[i]
        local nxt_fname = nxt:match("^%s*([^:]+):%s*(.*)$")
        if nxt_fname and is_a_field(nxt_fname) then break end
        table.insert(value_lines, nxt)
        i = i + 1
      end
      local field_value = table.concat(value_lines, "\n")
      field_value = field_value:gsub(vim.pesc(M.typst_tags.open) .. "%s*(.*)%s*" .. vim.pesc(M.typst_tags.close), 
        function(match)
          local tmp = vim.fn.tempname()

          local typst_input = tmp .. ".typ"
          local latex_input = tmp .. ".tex"
          local output = tmp .. ".svg"
          vim.fn.writefile(
            vim.split(typst_preamble .. "\n" .. match .. "\n" .. typst_ending, "\n"),
            typst_input
          )
          local error = vim.fn.system({ "typst", "compile", typst_input, output })
          if vim.v.shell_error ~= 0 then
            err = true
            vim.notify("Vankim: Typst compilation failed" .. "\n" .. error, vim.log.levels.ERROR)
          end

          local data = vim.fn.readfile(output, "b")
          local b64 = vim.fn.system("base64", data)

          local filename = "typst-" .. vim.fn.fnamemodify(tmp, ":t") .. ".svg"

          local res, error = ankiconnect_request({
            action = "storeMediaFile",
            version = M.api_version,
            params = {
              filename = filename,
              data = b64
            },
          })
          if not res then
            err = true
            vim.notify("Vankim: Failed to store typst media: " .. tostring(error), vim.log.levels.ERROR)
          end
          return '<img src="' .. filename .. '">'
        end)
      field_value = field_value:gsub(vim.pesc(M.latex_tags.open) .. "%s*(.*)%s*" .. vim.pesc(M.latex_tags.close), 
        function(match)
          local tmp = vim.fn.tempname()

          local typst_input = tmp .. ".typ"
          local latex_input = tmp .. ".tex"
          local output = tmp .. ".svg"
          vim.fn.writefile(
            vim.split(latex_preamble .. "\n" .. match .. "\n" .. latex_ending, "\n"),
            latex_input
          )
          local latex_error = vim.fn.system({ "latex", "-interactions=nonstopmode", "-halt-on-error", "-output-directory=/tmp", latex_input})
          if vim.v.shell_error ~= 0 then
            err = true
            vim.notify("Vankim: Latex compilation failed" .. "\n" .. latex_error, vim.log.levels.ERROR)
          end
          local dvi_error = vim.fn.system({ "dvisvgm", "--no-fonts", "-n", "-o", output, tmp .. ".dvi"})
          if vim.v.shell_error ~= 0 then
            err = true
            vim.notify("Vankim: DVI to SVG conversion failed" .. "\n" .. dvi_error, vim.log.levels.ERROR)
          end

          local data = vim.fn.readfile(output, "b")
          local b64 = vim.fn.system("base64", data)

          local filename = "latex-" .. vim.fn.fnamemodify(tmp, ":t") .. ".svg"

          local res, err = ankiconnect_request({
            action = "storeMediaFile",
            version = M.api_version,
            params = {
              filename = filename,
              data = b64
            },
          })
          if not res then
            err = true
            vim.notify("Vankim: Failed to store latex media: " .. tostring(err), vim.log.levels.ERROR)
          end
          return '<img src="' .. filename .. '">'
        end)
      fields[fname] = field_value
    else
      i = i + 1
    end
  end

  return err, { model = model, deck = deck, fields = fields }
end


--------------------------------------------------------------------------------
-- Telescope helpers -----------------------------------------------------------
--------------------------------------------------------------------------------

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local function telescope_select(items, opts, on_choice)
  pickers.new(opts or {}, {
    prompt_title = opts and opts.prompt or "Select",
    finder = finders.new_table({ results = items }),
    sorter = conf.generic_sorter(opts or {}),
    attach_mappings = function(bufnr, map)
      actions.select_default:replace(function()
        actions.close(bufnr)
        local entry = action_state.get_selected_entry()
        if entry then on_choice(entry[1]) end
      end)
      return true
    end,
  }):find()
end

local function telescope_input(opts, on_confirm)
  opts = opts or {}
  pickers.new(opts, {
    prompt_title = opts.prompt or "Input",
    finder = finders.new_table({ results = {} }),
    sorter = conf.generic_sorter(opts),
    previewer = false,
    layout_strategy = "center",
    layout_config = {
      width = opts.width or 0.5,
      height = opts.height or 0,
      prompt_position = "top",
    },
    attach_mappings = function(bufnr, map)
      actions.select_default:replace(function()
        local prompt = action_state.get_current_line()
        actions.close(bufnr)
        if prompt and prompt ~= "" then
          on_confirm(prompt)
        else
          on_confirm(nil)
        end
      end)
      return true
    end,
  }):find()
end

--------------------------------------------------------------------------------
-- Vankim Public Commands ------------------------------------------------------
--------------------------------------------------------------------------------

function M.AnkiNew(opts)
  local args = parse_arg(opts)

  local model = nil
  local deck = nil
  if args and #args >= 1 and args[1] ~= "" then model = args[1] end
  if args and #args >= 2 and args[2] ~= "" then deck = args[2] end

  local last_model, last_deck = get_last()
  model = model or last_model or ""
  deck = deck or last_deck or ""

  -- Doesn't work need to be fixed later
  local mode = vim.fn.mode()
  local sel_text = nil
  if mode == "v" then
    local s_start = vim.fn.getpos(".")
    local s_end = vim.fn.getpos("v")
    sel_text = vim.fn.nvim_buf_get_text(0, s_start[2]-1, s_start[3]-1, s_end[2]-1, s_end[3], {})
  elseif mode == "V" then
    local s_start = vim.fn.line("'<")
    local s_end = vim.fn.line("'>")
    sel_text = vim.fn.nvim_buf_get_lines(0, s_start-1, s_end, false)
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

function M.AnkiSend(arg)
  local reset = false
  if arg and arg.args == "true" then reset = true end

  local err, parsed = parse_current_buffer()
  if not parsed.model then
    vim.notify("Anki: Model not set in buffer (line 'Model : ...')", vim.log.levels.ERROR)
    return
  end
  if not parsed.deck then
    vim.notify("Anki: Deck not set in buffer (line 'Deck: ...')", vim.log.levels.ERROR)
    return
  end
  if err then return end

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

    fill_buffer(buf, model, deck, fields, nil)
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
          table.insert(lines, 2, "Deck: " .. chosen) -- insert after Model
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
        local _, parsed = parse_current_buffer()
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
        fill_buffer(buf, new_model, deck, new_fields, values)
        vim.notify("Anki: changed model to " .. new_model, vim.log.levels.INFO)
      end)
      return true
    end,
  }):find()
end

function M.AnkiPreambleAdd(args)
  local args = parse_arg(args)
  local typ = args[1] and args[1]:lower() or nil
  if typ and typ ~= "latex" and typ ~= "typst" then typ = nil end

  local function ask_type(cb)
    vim.ui.select({ "latex", "typst" }, { prompt = "Preamble type:" }, cb)
  end

  local function ask_name(cb)
    vim.ui.input({ prompt = "Preamble name: " }, cb)
  end

  local function open_editor_for(typ, name)
    if not typ or typ == "" then
      vim.notify("Vankim: preamble type not specified", vim.log.levels.ERROR); return
    end
    if not name or name == "" then
      vim.notify("Vankim: preamble name not specified", vim.log.levels.ERROR); return
    end

    local buf = vim.api.nvim_create_buf(true, true)
    local safe_name = sanitize_filename(name)
    local bufname = ("AnkiPreamble:%s:%s"):format(typ, safe_name)
    vim.api.nvim_buf_set_name(buf, bufname)

    if typ == "typst" then
      pcall(vim.api.nvim_buf_set_option, buf, "filetype", "typst")
    else
      pcall(vim.api.nvim_buf_set_option, buf, "filetype", "tex")
    end

    local existing_text, err = load_preamble(typ, name)
    if existing_text then
      local lines = vim.split(existing_text, "\n")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end

    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    local augroup = vim.api.nvim_create_augroup("AnkiPreambleSave_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd("BufUnload", {
      group = augroup,
      buffer = buf,
      callback = function()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local text = table.concat(lines, "\n")
        pcall(save_preamble, typ, name, text)
      end,
    })
  end

  if not typ then
    ask_type(function(choice)
      if not choice then
        vim.notify("Vankim: preamble type not specified", vim.log.levels.ERROR); return
      end
      ask_name(function(name)
        if not name or name == "" then
          vim.notify("Vankim: preamble name not specified", vim.log.levels.ERROR); return
        end
        open_editor_for(choice, name)
      end)
    end)
  else
    local provided_name = args[2]
    if provided_name and provided_name ~= "" then
      open_editor_for(typ, provided_name)
    else
      ask_name(function(name)
        if not name or name == "" then
          vim.notify("Vankim: preamble name not specified", vim.log.levels.ERROR); return
        end
        open_editor_for(typ, name)
      end)
    end
  end
end

function M.AnkiEndingAdd(args)
  local args = parse_arg(args)
  local typ = args[1] and args[1]:lower() or nil
  if typ and typ ~= "latex" and typ ~= "typst" then typ = nil end

  local function ask_type(cb)
    vim.ui.select({ "latex", "typst" }, { prompt = "Ending type:" }, cb)
  end

  local function ask_name(cb)
    vim.ui.input({ prompt = "Ending name: " }, cb)
  end

  local function open_editor_for(typ, name)
    if not typ or typ == "" then
      vim.notify("Vankim: ending type not specified", vim.log.levels.ERROR); return
    end
    if not name or name == "" then
      vim.notify("Vankim: ending name not specified", vim.log.levels.ERROR); return
    end

    local buf = vim.api.nvim_create_buf(true, true)
    local safe_name = sanitize_filename(name)
    local bufname = ("AnkiEnding:%s:%s"):format(typ, safe_name)
    vim.api.nvim_buf_set_name(buf, bufname)

    if typ == "typst" then
      pcall(vim.api.nvim_buf_set_option, buf, "filetype", "typst")
    else
      pcall(vim.api.nvim_buf_set_option, buf, "filetype", "tex")
    end

    local existing_text, err = load_ending(typ, name)
    if existing_text then
      local lines = vim.split(existing_text, "\n")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end

    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    local augroup = vim.api.nvim_create_augroup("AnkiEndingSave_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd("BufUnload", {
      group = augroup,
      buffer = buf,
      callback = function()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local text = table.concat(lines, "\n")
        pcall(save_preamble, typ, name, text)
      end,
    })
  end

  if not typ then
    ask_type(function(choice)
      if not choice then
        vim.notify("Vankim: ending type not specified", vim.log.levels.ERROR); return
      end
      ask_name(function(name)
        if not name or name == "" then
          vim.notify("Vankim: ending name not specified", vim.log.levels.ERROR); return
        end
        open_editor_for(choice, name)
      end)
    end)
  else
    local provided_name = args[2]
    if provided_name and provided_name ~= "" then
      open_editor_for(typ, provided_name)
    else
      ask_name(function(name)
        if not name or name == "" then
          vim.notify("Vankim: ending name not specified", vim.log.levels.ERROR); return
        end
        open_editor_for(typ, name)
      end)
    end
  end
end

function M.AnkiPreamble()
  local preamble_list, err = ankiconnect_request({
    action = "retrieveMediaFile",
    version = M.api_version,
    params = {
      filename = "_anki_preamble_list.txt"
    }
  })
  preamble_list = vim.fn.systemlist({"base64", "--decode"}, preamble_list)
  telescope_select(preamble_list or {}, { prompt = "Select preamble:" }, function(chosen)
    if not chosen then M.AnkiPreambleAdd(); return end
    local typ, name = chosen:match("^_anki_preamble_(%a+)_(.+)%.txt$")
    if not typ or not name then
      vim.notify("Vankim: invalid preamble name format: " .. tostring(chosen), vim.log.levels.ERROR)
      return
    end
    local buf = vim.api.nvim_create_buf(true, true)
    local bufname = ("AnkiPreamble:%s:%s"):format(typ, name)
    vim.api.nvim_buf_set_name(buf, bufname)

    if typ == "typst" then
      pcall(vim.api.nvim_buf_set_option, buf, "filetype", "typst")
    else
      pcall(vim.api.nvim_buf_set_option, buf, "filetype", "tex")
    end

    local existing_text, err = load_preamble(typ, name)
    if existing_text then
      local lines = vim.split(existing_text, "\n")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end

    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    local augroup = vim.api.nvim_create_augroup("AnkiEndingSave_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd("BufUnload", {
      group = augroup,
      buffer = buf,
      callback = function()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local text = table.concat(lines, "\n")
        pcall(save_preamble, typ, name, text)
      end,
    })
  end)
end

function M.AnkiPreambleDelete()
  local preamble_list, err = ankiconnect_request({
    action = "retrieveMediaFile",
    version = M.api_version,
    params = {
      filename = "_anki_preamble_list.txt"
    }
  })
  preamble_list = vim.fn.systemlist({"base64", "--decode"}, preamble_list)
  telescope_select(preamble_list or {}, { prompt = "Select preamble to delete:" }, function(chosen)
    if not chosen then return end
    local typ, name = chosen:match("^_anki_preamble_(%a+)_(.+)%.txt$")
    if not typ or not name then
      vim.notify("Vankim: invalid preamble name format: " .. tostring(chosen), vim.log.levels.ERROR)
      return
    end
    local ok, err = delete_preamble(typ, name)
    if not ok then
      vim.notify("Vankim: failed to delete preamble: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
  end)
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

  local parts = parse_arg(before_cursor)
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

  -- generic model formatting
  local function format_model_matches(list)
    local out = {}
    for _, name in ipairs(list) do
      if search_lead == "" or name:find("^" .. vim.pesc(search_lead)) then
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
    print("Formatting decks for lead: " .. search_lead)
    local out = {}
    local seen = {}

    if search_lead == "" then
      for _, deck in ipairs(list) do
        local top = deck:match("^[^:]+") or deck
        if not seen[top] then
          seen[top] = true
          if prefer_quote then
            table.insert(out, escape_for_quote(top, prefer_quote))
          else
            if top:find("%s") or top:find('"') or top:find("'") then
              table.insert(out, quote_candidate(top, nil))
            else
              table.insert(out, top)
            end
          end
        end
      end
      return out
    end
    for _, deck in ipairs(list) do
      local lead, name = deck:match("(" .. vim.pesc(search_lead) .. ")(.*)$") 
      if lead == nil then goto continue end
      if name == nil then table.insert(out, name); goto continue end
      local colon, rest = name:match("^(::)(.*)$") or "", name
      print("Colon : " .. colon .. " Rest: " .. rest)
      local name, _ = rest:match("(.*)((::).*)$") or rest, ""
      print("Name: " .. name)
      name = lead .. colon .. name
      if not seen[name] then
        seen[name] = true
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
      ::continue::
    end

    return out
  end

  if arg_index <= 0 then
    local res = ankiconnect_request({ action = "modelNames", version = M.api_version })
    if not res or type(res) ~= "table" then 
      vim.notify("Vankim: failed to fetch model names (Is Anki running with AnkiConnect?)", vim.log.levels.ERROR)
      return {}
    end
    return format_model_matches(res)
  elseif arg_index == 1 then
    local res = ankiconnect_request({ action = "deckNames", version = M.api_version })
    if not res or type(res) ~= "table" then 
      vim.notify("Vankim: failed to fetch deck names (Is Anki running with AnkiConnect?)", vim.log.levels.ERROR)
      return {} 
    end
    return format_deck_matches(res)
  else
    return {}
  end
end

local function anki_move_to_field_complete(arg_lead, cmd_line, cursor_pos)
  local directions = { "next", "previous" }
  local positions = { "beginning", "ending" }
  local parts = parse_arg(cmd_line)
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

function M.setup(opts)
  for k,v in pairs(opts or {}) do
    M[k] = v
  end

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

  vim.api.nvim_create_user_command("AnkiPreambleAdd",
    function(args) M.AnkiPreambleAdd(args.args) end,
    { nargs = "*"})

  vim.api.nvim_create_user_command("AnkiEndingAdd",
    function(args) M.AnkiEndingAdd(args.args) end,
    { nargs = "*" })

  vim.api.nvim_create_user_command("AnkiPreamble",
    M.AnkiPreamble,
    { nargs = 0 })

  vim.api.nvim_create_user_command("AnkiPreambleDelete",
    M.AnkiPreambleDelete,
    { nargs = 0 })
end

return M
