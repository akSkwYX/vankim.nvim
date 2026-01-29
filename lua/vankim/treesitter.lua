local M = {}

local function detect_platform()
  local os = jit.os
  local arch = jit.arch
  local plat, ext

  if os == "Linux" then ext = ".so"
  elseif os == "OSX" then ext = ".dylib"
  elseif os == "Windows" then ext = ".dll"
  else ext = ".so" end

  local a = arch:match("arm") and "arm64" or (arch == "x64" and "x64" or arch)
  if os == "Linux" then plat = "linux-" .. a
  elseif os == "OSX" then plat = "macos-" .. a
  elseif os == "Windows" then plat = "windows-" .. a
  else plat = os:lower() .. "-" .. a end

  return plat, ext
end

local function exists(path)
  local stat = vim.loop.fs_stat(path)
  return stat and stat.type ~= nil
end

local function plugin_root()
  local info = debug.getinfo(1, "S")
  if not info or not info.source then return nil end
  local this_file = info.source:sub(2)
  local root = vim.fn.fnamemodify(this_file, ":h:h:h")
  return root
end

function M.setup(opts)
  opts = opts or {}
  local subpath = opts.parser_subpath or "parsers/anki"
  local binary_basename = opts.binary_name or "parser"

  local plat, ext = detect_platform()
  local root = plugin_root()
  if not root then
    vim.notify("Vankim: Unable to determine root for treesitter parser registration", vim.log.levels.ERROR)
    return false
  end

  local candidates = {
    string.format("%s/%s/%s/%s%s", root, subpath, "anki", plat, "/" .. binary_basename .. ext),
    string.format("%s/%s/%s/%s%s", root, subpath, plat, binary_basename, ext),
    string.format("%s/%s/%s/%s%s", root, subpath, "anki-" .. plat, binary_basename, ext),
    string.format("%s/%s/%s/%s%s", root, subpath, "anki", plat .. "/" .. binary_basename, ext),
  }

  local found = nil
  for _, p in ipairs(candidates) do
    if exists(p) then
      found = p
      break
    end
  end

  if not found then
    return false
  end

  if vim.treesitter and vim.treesitter.language and vim.treesitter.language.add then
    pcall(vim.treesitter.language.add, "anki", { path = found })
    local ok_parsers, parsers = pcall(require, "nvim-treesitter.parsers")
    if ok_parsers and parsers and parsers.get_parser_configs then
      local cfg = parsers.get_parser_configs()
      cfg.anki = cfg.anki or {}
      cfg.anki.filetype = cfg.anki.filetype or "anki"
      return true
    else
      vim.notify("Vankim: Error configuring nvim-treesitter parser for Anki", vim.log.levels.ERROR)
      return false
    end
  end

  return false
end

return M
