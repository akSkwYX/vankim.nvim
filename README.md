# Vankim.nvim

A small, focused Neovim plugin that creates Anki notes from a Neovim buffer using AnkiConnect.  
Designed for fast editing: open a prefilled card buffer, edit fields with normal Neovim workflows, then push the note to Anki.

## Features

- `:AnkiNew [Model] [Deck]` — open a scratch buffer for a new note. Supports quoted multi-word names:
  - `:AnkiNew Simple Deck`
  - `:AnkiNew "Card Type" "My Deck Name"`
- `:AnkiSend [reset]` — parse the current buffer and add a note with AnkiConnect. If `reset` (`:AnkiSend reset`) is given, the buffer is reset with fresh placeholders.
- Completion for `:AnkiNew` (models and decks).
- Buffer-local highlights for field names (uses the user's colorscheme).
- Field navigation:
  - `:AnkiJump next|precedent` — jump to the next / previous field value.
  - `:AnkiMoveField begining|ending` — move to the beginning / end of the current field's value.
- Minimal, dependency-free requests (uses `curl` by default; optionally adaptable to job-based async calls).

## Prerequisites

- Anki desktop running with the [AnkiConnect] add-on enabled (default API: `http://127.0.0.1:8765`).
- `curl` available in your shell (used for HTTP requests).  
- Neovim >= 0.7 recommended.

## Quickstart

### Install with `lazy.nvim` (recommended)

Add this to `require("lazy").setup({ ... })`:

```lua
{
  "akSkwYX/vankim.nvim",
  lazy = true,
  cmd = { "AnkiNew", "AnkiSend", "AnkiJump", "AnkiMoveField" },
  keys = {
    { "<leader>an", "<cmd>AnkiNew<cr>", desc = "Anki: New Note" },
    { "<leader>as", "<cmd>AnkiSend<cr>", desc = "Anki: Send Note" },
    { "<leader>aj", "<cmd>AnkiJump next<cr>", desc = "Anki: Jump to next field" },
    { "<leader>ak", "<cmd>AnkiJump previous<cr>", desc = "Anki: Jump to previous field" },
    { "<leader>ab", "<cmd>AnkiMoveField beginning<cr>", desc = "Anki: Move to begining of field" },
    { "<leader>ae", "<cmd>AnkiMoveField end<cr>", desc = "Anki: Move to end of field" },
  },
  config = function()
    require("vankim").setup()
  end,
}
```

Restart Neovim and run:

```vim
:AnkiNew Simple "My Deck Name"
-- edit the fields in the opened buffer
:AnkiSend
:AnkiSend reset  " send and reset buffer placeholders
```

### Repo layout

```
anki.nvim/
├─ lua/
│  └─ anki.lua         -- main module; require("anki") loads it
├─ init.lua             -- optional: `return require("anki")`
└─ README.md
```

## Usage & examples

Open a new note buffer:

- Single-word model + quoted deck:
  ```
  :AnkiNew Simple "This is a deck"
  ```
- Quoted model + single-word deck:
  ```
  :AnkiNew "Card Type" test
  ```
- Both quoted:
  ```
  :AnkiNew "Card Type" "Deck Name"
  ```

Send the note in the current buffer:

```
:AnkiSend
:AnkiSend reset   " send then reset fields (new placeholders)
```

Navigate fields inside the Anki buffer:

```
:AnkiJump next
:AnkiJump precedent

:AnkiMoveField begining
:AnkiMoveField ending
```

## Contributing

1. Fork the repository.
2. Create a feature branch: `git checkout -b my-feature`.
3. Commit and push your changes.
4. Open a pull request.

## Contact

akSkwYX — akskwyx@gmail.com
