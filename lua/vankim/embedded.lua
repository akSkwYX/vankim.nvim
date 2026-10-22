local M = {}

local LANGS = {
  latex = { open = "[latex]", close = "[/latex]", ft = "tex", ext = "tex", server = "texlab", preamble = "" },
  typst = { open = "[typst]", close = "[typst]", ft = "typst", ext = "typ", server = "tinymist", preamble = "" }
}

local state = {} -- state[host][lang] = { buf = vbuf, keep = { {s, e}, ... } }

local function virtual_lines(lines, lang)
  local spec = LANGS[lang]
  local text = table.concat(lines, "\n")
  local blank = (text:gsub("[^\n]", " "))
  local keep, pos = {}, 1
  while true do
    local _, oe = text:find(spec.open, pos, true)
    if not oe then break end
    local cs, ce = text:find(spec.close, oe + 1, true)
    if not cs then break end
    keep[#keep + 1] = { oe + 1, cs - 1 }
    pos = ce + 1
  end
  local parts, p = {}, 1
  for _, r in ipairs(keep) do
    parts[#parts + 1] = blank:sub(p, r[1] - 1)
    local chunk = text:sub(r[1], r[2])
    chunk = chunk:gsub("<br>", "  "):gsub("&nbsp;", "    ")
    parts[#parts + 1] = chunk
    p = r[2] + 1
  end
  parts[#parts + 1] = blank:sub(p)
  local out = vim.split(table.concat(parts), "\n", { plain = true })
  if spec.preamble ~= "" then out[1] = spec.preamble end
  return out, keep
end

local function ensure(host, lang)
  state[host] = state[host] or {}
  local st = state[host][lang]
  if st and vim.api.nvim_buf_is_valid(st.buf) then return st end

  local spec = LANGS[lang]
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local vb = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(vb, ("%s/vankim_virtual_lsp.%s"):format(dir, spec.ext))
  vim.bo[vb].filetype = spec.ft

  local cfg = vim.deepcopy(vim.lsp.config[spec.server])
  cfg.name = spec.server
  cfg.root_dir = dir
  vim.lsp.start(cfg, { bufnr = vb })

  local ns = vim.api.nvim_create_namespace("vankim_embedded_" .. lang)
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    buffer = vb,
    callback = function(args)
      if vim.api.nvim_buf_is_valid(host) then
        vim.diagnostic.set(ns, host, args.data.diagnostics)
      end
    end,
  })

  st = { buf = vb, keep = {} }
  state[host][lang] = st
  return st
end

local function at_cursor(host)
  local pos = vim.api.nvim_win_get_cursor(0)
  local row, col = pos[1], pos[2]
  local i = vim.fn.line2byte(row) + col
  for lang, st in pairs(state[host] or {}) do
    for _, r in ipairs(st.keep) do
      if i >= r[1] and i <= r[2] + 1 then return lang, st end
    end
  end
end

local function position_params(st)
  local client = vim.lsp.get_clients({ bufnr = st.buf })[1]
  if not client then return end
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  params.textDocument = { uri = vim.uri_from_bufnr(st.buf) }
  return params, client
end

function M.hover()
  local lang, st = at_cursor(vim.api.nvim_get_current_buf())
  if not lang then return vim.lsp.buf.hover() end
  local params, client = position_params(st)
  if not params then return end
  client:request("textDocument/hover", params, function(_, res)
    if not (res and res.contents) then return end
    local lines = vim.lsp.util.convert_input_to_markdown_lines(res.contents)
    if #lines > 0 then
      vim.lsp.util.open_floating_preview(lines, "markdown", { border = "rounded" })
    end
  end, st.buf)
end 

function M.omnifunc(findstart, base)
  if findstart == 1 then
    local before = vim.api.nvim_get_current_line():sub(1, vim.fn.col(".") - 1)
    return vim.fn.match(before, [==[[\\#]\=\k*$]==])
  end
  local lang, st = at_cursor(vim.api.nvim_get_current_buf())
  if not lang then return {} end
  local params, client = position_params(st)
  if not params then return {} end
  local res = client:request_sync("textDocument/completion", params, 1000, st.buf)
  local result = res and res.result or {}
  local items = result.items or result
  local words = {}
  for _, it in ipairs(items) do
    if it.label:lower():find(base:lower(), 1, true) then
      words[#words + 1] = {word = it.label, menu = it.detail or ""; kind = ""}
    end
  end
  return words
end

function M.attach(host)
  host = host or vim.api.nvim_get_current_buf()

  local function sync()
    local lines = vim.api.nvim_buf_get_lines(host, 0, -1, false)
    for lang in pairs(LANGS) do
      local st = ensure(host, lang)
      local vl, keep = virtual_lines(lines, lang)
      st.keep = keep
      vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, vl)
    end
  end

  sync()
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" },
    { buffer = host, callback = sync })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = host,
    callback = function()
      for _, st in pairs(state[host] or {}) do
        pcall(vim.api.nvim_buf_delete, st.buf, { force = true })
      end
      state[host] = nil
    end,
  })

  vim.bo[host].omnifunc = "v:lua.require'vankim.embedded'.omnifunc"
  vim.keymap.set("n", "K", M.hover, { buffer = host })
end

return M
