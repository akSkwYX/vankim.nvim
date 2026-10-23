--------------------------------------------------------------------------------
-- AnkiConnect interactions ----------------------------------------------------
--------------------------------------------------------------------------------

local M = {}

-- Helpers to store last-used model/deck in vim.g
---@param model string|nil
---@param deck string|nil
function M.set_last(model, deck)
  if model then vim.g.vankim_last_model = model end
  if deck  then vim.g.vankim_last_deck = deck  end
end

---@return string|nil model
---@return string|nil deck
function M.get_last()
  return vim.g.vankim_last_model or nil, vim.g.vankim_last_deck or nil
end

-- Handle AnkiConnect requests
---@param payload table
---@return table|nil request_return
---@return string|nil error
function M.ankiconnect_request(payload)
  -- Need to set json in a file to handle huge json requests (curl limitation)
  local json = vim.fn.json_encode(payload)
  local tmp = vim.fn.tempname()
  local ok_write, write_err = pcall(vim.fn.writefile, { json }, tmp)
  if not ok_write then
    return nil, "failed to write temp payload: " .. tostring(write_err)
  end

  local cmd = { "curl", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-d", "@" .. tmp, M.url }
  local ok_res = vim.fn.system(cmd)
  if not ok_res or ok_res == "" then
    return nil, "failed to get response from AnkiConnect"
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
---@param model_name string
---@return table|nil model_fields
---@return string|nil error
function M.get_model_fields(model_name)
  local payload = { action = "modelFieldNames", version = M.api_version, params = { modelName = model_name } }
  return M.ankiconnect_request(payload)
end

return M
