<div align="center">
  <h1>vv-explorer.nvim</h1>
  <p>English | <a href="./README.zh-CN.md">中文</a></p>
  <video muted autoplay loop controls src="https://github.com/user-attachments/assets/d51c28c1-4d21-4d1e-9bba-12dbe13e6669" width="900" title="vv-explorer demo"></video>
  
  <img src="https://github.com/beixiyo/vv-explorer.nvim/releases/download/assets-2026-07-25/vv-explorer.png" alt="vv-explorer demo" width="600" />
  <table>
    <tr>
      <td><img src="https://github.com/beixiyo/vv-explorer.nvim/releases/download/assets-2026-07-25/vv-explorer-filter.png" alt="Asynchronous filter" width="440" /></td>
      <td><img src="https://github.com/beixiyo/vv-explorer.nvim/releases/download/assets-2026-07-25/vv-explorer-completion.png" alt="Filter completion" width="440" /></td>
    </tr>
    <tr>
      <td><img src="https://github.com/beixiyo/vv-explorer.nvim/releases/download/assets-2026-07-25/vv-explorer-fileinfo.png" alt="Directory information" width="440" /></td>
      <td><img src="https://github.com/beixiyo/vv-explorer.nvim/releases/download/assets-2026-07-25/vv-explorer-help.png" alt="Keymap help" width="440" /></td>
    </tr>
  </table>
  <p>Want my Neovim configuration? See <a href="https://github.com/beixiyo/dotfiles">dotfiles</a></p>
  <em>A VS Code-style Neovim file tree with live preview, asynchronous fd filtering, trash support, and zero third-party dependencies</em>
  <p>
    <img src="https://img.shields.io/badge/Neovim-0.11+-57A143?style=flat-square&logo=neovim&logoColor=white" alt="Requires Neovim 0.11+" />
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
  event = 'VimEnter', -- Required when persist_open should restore without pressing a key first
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
  width = 32,                  -- Initial width; manual resize is persisted by vv-utils.state
  persist_open = true,         -- Restore the previous open/closed state on the next Neovim session
  state = nil,                 -- Optional VVStateHandle (default: vv-explorer/panel)
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
    intercept = true,          -- Preview metadata; use o/gx for the system application
    extensions = {             -- Extension overrides for content detection
      -- Defaults include images (png/jpg/gif/webp/…), videos (mp4/mkv/mov/…),
      -- audio (mp3/wav/flac/…), archives (zip/tar/gz/7z/…),
      -- build artifacts (exe/dll/so/o/…), fonts (ttf/otf/woff/…),
      -- binary documents (pdf/docx/xlsx/pptx/…), and databases (sqlite/db)
    },
  },

  directory_preview = {
    enabled = true,            -- Preview directory attributes when the cursor rests on a directory
    recursive = true,          -- Allow recursive total size and file count scans
    scan_on_demand = true,     -- Require ⇧K for large trees; false = always scan fully on preview
    auto_scan_max_entries = 1000, -- Auto-show totals when the directory tree has at most this many entries; 0 = disabled
    max_entries = 200000,      -- Entry cap for the recursive scan; reported as "at least" once reached
    budget_ms = 8,             -- Maximum milliseconds a single scan slice may hold the main loop
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
| **glob** | `vv-utils.glob` + `vim.glob.to_lpeg` | VS Code-style shorthand with any-depth paths, `./` anchoring, comma lists, and `!` exclusions |
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

`<CR>` / `l` and `<C-x>` / `<C-v>` focus that view without creating another split. Use `o` / `gx` to open the file with the system default application

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

### Directory attribute preview

When the cursor rests on a directory, the main window shows that directory's attributes instead of keeping the previous file:

```
Directory

Path: ~/Documents/code/frontend
Items: 42 (38 dirs, 4 files)
Modified: 2026-08-07 14:22

Total size: 13.9 GiB (14,972,003,328 bytes)
Total files: 892,993
Total dirs: 142,035
```

`Items` and `Modified` are read synchronously and appear as soon as the cursor stops.

By default, directories with at most `auto_scan_max_entries` entries are calculated automatically

Larger trees keep the `⇧K` hint and wait for manual calculation

Semantics worth knowing:

- **Filters and gitignore are not applied.** The numbers report real disk usage and match `du -sh`, including `node_modules`, `.git`, and hidden files
- **Symlinks are not followed.** A link counts only its own size, so a link pointing at an ancestor cannot create a cycle
- Reaching `max_entries` stops the scan and reports `≥`, instead of walking a huge directory forever
- Moving the cursor away, opening a file with `<CR>`, or closing the panel **physically cancels** the in-flight scan rather than merely discarding its result
- Completed results are cached until the filesystem changes (any `watch` fs_event invalidates the whole cache), so returning to the same directory does not rescan

```lua
-- Shallow information only, no recursive scan
opts = { directory_preview = { recursive = false } }

-- Never probe automatically; always wait for ⇧K
opts = { directory_preview = { auto_scan_max_entries = 0 } }

-- Restore automatic recursive scans when a directory is previewed
opts = { directory_preview = { scan_on_demand = false } }

-- Disable entirely: the main window stays unchanged on directories
opts = { directory_preview = false }
```

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
| `⇧K` | `scan_directory` | Calculate and cache totals for the hovered directory |
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
