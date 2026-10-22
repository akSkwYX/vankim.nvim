--------------------------------------------------------------------------------
-- Telescope helpers -----------------------------------------------------------
--------------------------------------------------------------------------------

local M = {}

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

function M.telescope_select(items, opts, on_choice)
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

function M.telescope_input(opts, on_confirm)
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
