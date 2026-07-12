-- vv-explorer LSP 适配层边界测试
local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local root = vim.fn.fnamemodify(this, ':h:h')

package.path = table.concat({
  root .. '/lua/?.lua',
  root .. '/lua/?/init.lua',
  package.path,
}, ';')

local calls = {}
local fixture_clients = { { name = 'fixture-lsp' } }

package.loaded['vv-utils.lsp.file_operations'] = {
  clients = function(capability)
    calls.capability = capability
    return fixture_clients
  end,
  will_rename_async = function(old_path, new_path, timeout_ms, on_done)
    calls.request = { old_path, new_path, timeout_ms }
    on_done({ { edit = { changes = {} }, encoding = 'utf-16' } }, false)
  end,
  notify_did_rename = function(old_path, new_path)
    calls.notification = { old_path, new_path }
  end,
}

package.loaded['vv-utils.lsp.workspace_edit'] = {
  prepare = function(edits)
    calls.prepared = edits
    return { edits_count = 1 }
  end,
  apply = function(transaction, opts)
    calls.applied = { transaction = transaction, opts = opts }
    return true
  end,
}

local Lsp = require('vv-explorer.lsp')

assert(Lsp.will_rename_clients() == fixture_clients)
assert(calls.capability == 'willRename')

local timed_out
Lsp.will_rename_async('/code/old.ts', '/code/new.ts', 1200, function(value)
  timed_out = value
end)

assert(timed_out == false)
assert(calls.request[1] == '/code/old.ts' and calls.request[2] == '/code/new.ts')
assert(calls.request[3] == 1200)
assert(#calls.prepared == 1)
assert(calls.applied.transaction.edits_count == 1)
assert(calls.applied.opts.save == false)

Lsp.did_rename('/code/old.ts', '/code/new.ts')
assert(calls.notification[1] == '/code/old.ts')
assert(calls.notification[2] == '/code/new.ts')

print('vv-explorer LSP adapter test: ok')
