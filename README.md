<div align="center">
  <h1>vv-explorer.nvim</h1>
  <p>English | <a href="./README.zh-CN.md">中文</a></p>
  <img src="./docs/assets/vv-explorer.png" alt="vv-explorer demo" width="900" />
  <p>Want my Neovim configuration? See <a href="https://github.com/beixiyo/dotfiles">dotfiles</a></p>
  <em>A VS Code-style Neovim file tree with live preview, asynchronous fd filtering, trash support, and zero third-party dependencies</em>
  <p>
    <img src="https://img.shields.io/badge/Neovim-0.10+-57A143?style=flat-square&logo=neovim&logoColor=white" alt="Requires Neovim 0.10+" />
    <img src="https://img.shields.io/badge/Lua-2C2D72?style=flat-square&logo=lua&logoColor=white" alt="Lua" />
  </p>
</div>

---

## Dependencies

- **Required**: [vv-utils.nvim](https://github.com/beixiyo/vv-utils.nvim) — shared fs/git/UI utilities
- **Required**: [vv-icons.nvim](https://github.com/beixiyo/vv-icons.nvim) — shared icon registry
- **Optional**: [mini.icons](https://github.com/echasnovski/mini.icons) — colored file/directory icons
- **Optional**: [fd](https://github.com/sharkdp/fd) — required only for `/` filtering
- **Optional**: [Git](https://github.com/git/git) — enables Git status, ignored-file awareness, and Git-aware filtering

## Why this plugin

| | neo-tree / nvim-tree | snacks.explorer | vv-explorer |
|---|---|---|---|
| **Opening behavior** | Double-click by default | Double-click | A **single click** expands or enters directories; files still use `<CR>` / `l` |
| **Live preview** | Requires extra configuration or is unsupported | A small bottom preview that is difficult to read | Moving with `j`/`k` immediately switches the debounced file preview; `<CR>` pins it |
| **Filtering** | None / basic | Picker-based fuzzy matching | Asynchronous fd indexing + three modes (fuzzy / glob / regex) + character highlighting + preserved ancestor chains |
| **Empty-directory grouping** | Supported by neo-tree | — | Supported; a single `a/b/c/` chain is merged into one row |
| **Trash** | Requires another plugin | System trash (`trash=true`) without a panel or restore UI | Built-in panel with restore, size warnings, and browsing UI |
| **Packaging** | Standalone plugin + plenary / nui | A suite bundled with dashboard / picker / notifier and more | Separate small plugins (vv-explorer / vv-utils / vv-icons), installed on demand with zero third-party dependencies |
| **Multiple sources** | buffers / git_status / ... | Multiple picker sources | Focuses only on the file tree; repository-wide picking is left to Telescope / fzf |

## Installation

```lua
{
  'beixiyo/vv-explorer.nvim',
  dependencies = {
    'beixiyo/vv-utils.nvim',
    'beixiyo/vv-icons.nvim',
    -- Optional: colored file icons
    { 'echasnovski/mini.icons', opts = {} },
  },
  keys = { '<leader>e', '<leader>E' },
  ---@type VVExplorerConfig
  opts = {},
}
```

## Configuration

All options and their defaults:

```lua
---@type VVExplorerConfig
opts = {
  position = 'left',           -- 'left' | 'right'
  width = 32,                  -- Window width
  hidden = false,              -- Show dotfiles (toggle with '.')
  group_empty_dirs = true,     -- Merge single-child directory chains
  preview = true,              -- Automatically preview without opening
  watch = true,                -- Auto-refresh with libuv fs_event
  select_move_down = true,     -- Move down one row after Tab selection
  cwd = nil,                   -- Root directory (nil = vim.fn.getcwd())
  sync_cwd_on_cd = 'tab',      -- Sync cwd when changing root with ']' / '[': 'tab' (tcd) | 'global' (cd) | false
  icon_rules = {},             -- Custom icon rules

  filter = {
    custom = {},               -- Permanently hidden globs, e.g. { 'node_modules', '.DS_Store' }
    max_results = 1000,        -- Maximum results to prevent rendering stalls
    debounce_threshold = 5000, -- Start dynamic debounce at this file count (0 ms below it)
    debounce_max_ms = 500,     -- Maximum debounce delay in milliseconds
  },

  git = {
    enabled = true,            -- Async git status index (no-op outside Git repositories)
    show_ignored = false,      -- Show paths matched by .gitignore (toggle with 'I')
  },

  diagnostics = {
    enabled = true,            -- Trailing LSP diagnostic icon + count (vv-icons + Diagnostic* colors)
  },

  binary = {
    intercept = true,          -- Open binary files with the system default application
    extensions = {             -- Extensions treated as binary (lowercase keys)
      -- Defaults include images (png/jpg/gif/webp/…), videos (mp4/mkv/mov/…),
      -- audio (mp3/wav/flac/…), archives (zip/tar/gz/7z/…),
      -- build artifacts (exe/dll/so/o/…), fonts (ttf/otf/woff/…),
      -- binary documents (pdf/docx/xlsx/pptx/…), and databases (sqlite/db)
    },
  },

  trash = {
    enabled = true,            -- Move deleted items to trash instead of deleting permanently
    max_items = 5000,          -- Remove oldest entries after this limit
    warn_size_mb = 500,        -- Warn when trash exceeds this size on explorer open
    scan_on_open = true,       -- Scan trash size asynchronously on startup
  },

  global_mappings = {          -- Set to false to disable all global mappings
    toggle = '<leader>E',      -- Simple file-tree toggle
    reveal = '<leader>e',      -- Reveal current file; toggle if already open
  },

  mappings = { ... },          -- Tree-buffer mappings (see the table below)
}
```

### Filtering (triggered with `/`)

Requires the external [`fd`](https://github.com/sharkdp/fd) command. Switch among three search modes with `<S-Tab>`:

| Mode | Engine | Description |
|---|---|---|
| **fuzzy** | `vim.fn.matchfuzzypos` | Highlights matched character positions (default) |
| **glob** | `vim.glob.to_lpeg` | Automatically crosses path segments when `/` is absent (`*.lua` ≡ `**/*.lua`) |
| **regex** | `vim.regex` | Vim regular expression |

### Trash

Deleted files are moved to `~/.local/share/vv-explorer/trash/` with metadata (original path, time, and size) for restoration. Press `T` or run `:VVExplorerTrash` to open the trash panel

| Option | Default | Description |
|---|---|---|
| `trash.enabled` | `true` | `false` permanently deletes items instead of using trash |
| `trash.max_items` | `5000` | Automatically removes the oldest entries above this limit |
| `trash.warn_size_mb` | `500` | Scans asynchronously when explorer opens and notifies above the limit |
| `trash.scan_on_open` | `true` | Enables the startup scan |

Set `trash = false` to disable trash completely

### Binary-file interception

Enabled by default. When `<CR>`/`l`/`<C-x>`/`<C-v>` encounters a binary file, it opens with the system default application instead of `:edit` in Neovim. Preview also skips binary files

```lua
-- Allow images (for future native Neovim image preview support)
opts = {
  binary = {
    extensions = {
      png = false, jpg = false, jpeg = false,
      gif = false, webp = false, avif = false,
    },
  },
}

-- Disable interception completely
opts = { binary = { intercept = false } }

-- Add a custom extension
opts = { binary = { extensions = { sketch = true } } }
```

`extensions` uses `vim.tbl_deep_extend`, so only overridden keys need to be specified

### Executing files (`X`)

Execution is selected by file type with **shebang taking precedence over extension**. Command resolution uses `vv-utils.exec.resolve` and selects the first `executable()` runner. With the default `confirm = true`, a confirmation dialog displays the command before execution

```lua
opts = {
  execute = {
    enabled = true,
    confirm = true,           -- Confirm and show the command; false skips confirmation
    -- Custom runner; the default opens a native split terminal
    run = function(cmd, ctx)  -- ctx = { path, cwd, runner }
      require('tools.term').run(cmd, ctx.cwd)
    end,
    -- Passed to vv-utils.exec.resolve to add/remove extensions or change priority
    opts = {
      runners = {
        ts = { { 'bun', 'run' }, { 'tsx' } },
        rb = { { 'ruby' } },
      },
    },
  },
}
```

Defaults cover `sh/bash/zsh/fish · ts/tsx/mts/cts · js/mjs/cjs · py · lua · rb · pl · php`, plus any file with an available shebang interpreter

### Custom icon rules

```lua
icon_rules = {
  { glob = '**/*.{test,spec}.{ts,tsx}', icon = '', hl = 'DiagnosticOk' },
  { glob = '.env*',                     icon = '', hl = 'WarningMsg' },
  { pattern = '^README',                icon = '', hl = 'Title', scope = 'file' },
}
```

`scope`: `'file'` / `'directory'` / `'any'` (default). Priority: icon_rules > mini.icons > built-in defaults

### Emitted event

Changing the root with `]` / `[` broadcasts this event, so panels that hold their own root (vv-git and friends) can follow along — `sync_cwd_on_cd` alone cannot reach them, since they read their root once at open time rather than from `getcwd()`:

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'VVExplorerRootChanged',
  callback = function(args)
    local root = args.data.root
  end,
})
```

## Mappings

### In the tree

| Key | Action | Description |
|---|---|---|
| `<CR>` / `l` / `→` | `open` | Open a file / toggle a directory (`→` is equivalent to `l`) |
| `↑` / `↓` | Move | Equivalent to `k` / `j`, including wraparound |
| Single click | Expand/collapse directory | Files remain unopened and use preview |
| Right click | `yank_abs_path` | Copy the absolute path to the clipboard |
| `h` / `←` | `close_node` | Close directory / jump to parent (`←` is equivalent to `h`) |
| `<C-l>` / `<C-h>` | Select chain segment | Select a deeper / shallower level in a grouped empty-directory chain (see below) |
| `]` | `cd_to` | Enter: set the cursor directory as root |
| `[` | `cd_up` | Return to the parent directory |
| `/` | `start_filter` | Open the filter prompt |
| `<Esc>` | `escape` | Clear filter, then selection and clipboard marks together, then close tree |
| `q` | `__quit` | Clear filter or close tree |
| `.` / `<M-.>` | `toggle_hidden` | Toggle dotfiles |
| `I` / `<M-i>` | `toggle_gitignored` | Toggle gitignored paths |
| `R` | `refresh` | Force refresh |
| `Y` | `yank_abs_path` | Copy absolute paths, including all selected items |
| `<C-x>` | `open_split` | Open in a horizontal split |
| `<C-v>` | `open_vsplit` | Open in a vertical split |
| `o` / `gx` | `system_open` | Open directory in file manager or file with default application |
| `X` | `execute` | Execute by file type in a terminal after confirmation |
| `a` | `create` | Create a file; a trailing `/` creates a directory |
| `d` | `delete` | Delete / move to trash with confirmation |
| `r` | `rename` | Rename |
| `y` | `copy_mark` | Mark for copying |
| `x` | `cut_mark` | Mark for cutting |
| `p` | `paste` | Paste into the cursor directory |
| Drag and drop | — | Copy files/directories from the file manager |
| `<Tab>` | `toggle_select` | Toggle multi-selection |
| `T` | `trash_panel` | Open the trash panel |
| `<C-e>` / `<C-y>` | Scroll preview | Scroll the main-window preview |
| `g?` | `help` | Open the mapping help window |

### Grouped empty-directory chain segments

With `group_empty_dirs = true`, a single-child directory chain such as `test/n1/n2` is merged into one row and operations target the **deepest segment** by default. Use `<C-l>` / `<C-h>` to select a deeper / shallower highlighted level; `a` / `d` / `r` / `y` / `x` / `p` then target that level:

```
test/n1/n2   ← default (deepest segment)
test/n1      ← press <C-h> once
test         ← press it again
```

- No selection means the deepest segment; `a` pre-fills the selected level, and leaving the row resets selection
- Navigation with `l` / `h` / `<CR>` / `←` / `→` always targets the whole row
- Some terminals send `<C-h>` as `<BS>`, preventing shallower selection. This is a terminal limitation; `<C-l>` remains available

### Drag-and-drop target

Drag **files or directories** from a system file manager such as Finder into explorer to copy them. Multiple items and recursive directory copying are supported

The mode is selected **automatically by environment**:

| Environment | Behavior |
|---|---|
| **kitty ≥ 0.47 without tmux around Neovim** | VS Code-style copying to the directory under the **mouse release position**, with live target highlighting via kitty DnD OSC 72 |
| **tmux / other terminals** | Falls back to the **keyboard cursor directory** without highlighting via bracketed paste; tmux does not forward inbound OSC 72 |

- **Safety**: name conflicts are automatically renamed to `xxx (copy)` / `xxx (copy 2)`; existing content is never overwritten or deleted
- **Why positional targeting requires no tmux**: OSC 72 supplies terminal coordinates, but tmux does not currently forward the inbound sequence despite the protocol's `i=` multiplexer field. Without coordinates, explorer uses the cursor directory
- Disable positional DnD while keeping paste fallback with `require('vv-utils.drop').setup({ kitty_dnd = false })`

### Filter prompt

| Key | Action |
|---|---|
| `<S-Tab>` | Cycle fuzzy → glob → regex |
| `<C-n>` / `<C-p>` | Jump to next / previous match |
| `<C-x>` / `<C-v>` | Open match in split / vsplit |
| `<CR>` | Submit and jump to the first match |
| `<Esc>` / `q` | Cancel filtering |

### Trash panel

| Key | Action |
|---|---|
| `r` / `<CR>` | Restore to the original path |
| `d` | Permanently delete the entry |
| `D` | Empty trash with confirmation |
| `q` / `<Esc>` | Close |

## Commands

| Command | Description |
|---|---|
| `:VVExplorerToggle` | Toggle the file tree |
| `:VVExplorerOpen` | Open the file tree |
| `:VVExplorerClose` | Close the file tree |
| `:VVExplorerReveal` | Reveal the current file in the tree |
| `:VVExplorerFocus` | Focus the tree window |
| `:VVExplorerTrash` | Open the trash panel |

## License

MIT
