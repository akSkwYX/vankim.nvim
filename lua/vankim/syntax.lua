local M = {}

function M.define_fields()
  vim.cmd("silent! syn clear ankiField")
  for _, name in ipairs(vim.g.vankim_fields_names or {}) do
    local pat = vim.fn.escape(name, [[\/]])
    vim.cmd(("syn match ankiField /\\V^%s\\s\\*:\\s\\*$/"):format(pat))
  end
end

return M
