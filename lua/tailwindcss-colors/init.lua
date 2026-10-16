-- Credits: contains some code snippets from https://github.com/norcalli/nvim-colorizer.lua
local colors = require "tailwindcss-colors.colors"

local NAMESPACE = vim.api.nvim_create_namespace "tailwindcss-colors"

local HIGHLIGHT_NAME_PREFIX = "TailwindCssColor"

-- This table is used to store the names of highlight colors that have already
-- been created, allowing us to reuse highlights even across multiple buffers,
-- cutting down on the the amount of neovim command calls
local HIGHLIGHT_CACHE = {}

-- Default user configuration
local user_config = {
   colors = {
      dark = "#000000", -- dark text color
      light = "#FFFFFF", -- light text color
   },
   commands = true, -- should add commands
   notify = true, -- should show notifications
   auto_attach = false, -- should automatically attach on LspAttach
}

-- Emits a notification unless notifications have been disabled via the
-- `notify` config option (set `notify = false` in setup to silence them)
local function notify(msg)
   if user_config.notify ~= false then
      vim.notify(msg)
   end
end

-- Creates highlights if they don't already exist
local function create_highlight(color)
   -- pull highlight from cache if it exists to avoid neovim highlight commands
   -- otherwise create the highlight and store the name (computed from the color)
   -- in the cache
   local highlight_name = HIGHLIGHT_CACHE[color.hex]

   if highlight_name then
      return highlight_name
   end

   -- determine which foreground color to use (dark or light)
   local fg_color
   if colors.color_is_bright(color) then
      fg_color = user_config.colors.dark
   else
      fg_color = user_config.colors.light
   end

   highlight_name = table.concat({ HIGHLIGHT_NAME_PREFIX, color.hex }, "_")

   -- create the highlight
   vim.api.nvim_command(string.format("highlight %s guifg=%s guibg=#%s", highlight_name, fg_color, color.hex))

   -- add the highlight to the cache to skip work next time
   HIGHLIGHT_CACHE[color.hex] = highlight_name

   return highlight_name
end

-- Maps each attached buffer to its tailwindcss lsp client (one client per project root)
local ATTACHED_BUFFERS = {}

local function buf_set_highlights(bufnr, lsp_data, change_data)
   -- set the range to the entire buffer if there is no change_data
   local firstline, new_lastline = 0, -1

   if change_data then
      firstline = change_data.firstline
      new_lastline = change_data.new_lastline
   end

   -- clear lines that have been changed
   vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, firstline, new_lastline)

   -- apply highlights only to changed lines
   for _, color_range_info in ipairs(lsp_data) do
      -- add hex data to each color entry
      color_range_info.color = colors.lsp_color_add_hex(color_range_info.color)

      -- extract range info
      local range = color_range_info.range
      local start_col = range.start.character
      local end_col = range["end"].character
      local line = range.start.line

      -- if line is within the changed range, process the highlights
      if not change_data or (line >= firstline and line <= new_lastline) then
         -- create the highlight
         local highlight_name = create_highlight(color_range_info.color)

         -- using async defer with 0 ms delay for potential batch highlight performance gains?
         vim.defer_fn(function()
            vim.api.nvim_buf_add_highlight(bufnr, NAMESPACE, highlight_name, line, start_col, end_col)
         end, 0)
      end
   end
end

-- Returns current buffer if 0 or nil
local function expand_bufnr(bufnr)
   if type(bufnr) == "table" then
      bufnr = bufnr.buf
   end

   if bufnr == 0 or bufnr == nil then
      return vim.api.nvim_get_current_buf()
   else
      return bufnr
   end
end

-- merges tables together
local function merge(...)
   local res = {}
   for i = 1, select("#", ...) do
      local o = select(i, ...)
      for k, v in pairs(o) do
         res[k] = v
      end
   end
   return res
end

local M = {}

-- Takes an optional plugin_config, updates internal config and
-- removes commands if they are disabled
function M.setup(plugin_config)
   -- merge passed in settings with defaults
   user_config = merge(user_config, plugin_config or {})

   -- optionally attach to buffers as soon as the tailwindcss lsp client
   -- attaches. This is opt-in because the plugin is otherwise manual (you
   -- either wire buf_attach into on_attach yourself, or use the commands)
   if user_config.auto_attach then
      local group = vim.api.nvim_create_augroup("tailwindcss-colors", { clear = true })
      vim.api.nvim_create_autocmd("LspAttach", {
         group = group,
         callback = function(args)
            local client = vim.lsp.get_clients({ id = args.data.client_id })[1]
            if client and client.name == "tailwindcss" then
               M.buf_attach(args.buf, client)
            end
         end,
      })
   end

   -- TODO: don't add commands at all if they are disabled (add them here?)
   -- remove commands if they should be disabled
   if not user_config.commands then
      vim.cmd "delcommand TailwindColorsAttach"
      vim.cmd "delcommand TailwindColorsDetach"
      vim.cmd "delcommand TailwindColorsRefresh"
      vim.cmd "delcommand TailwindColorsToggle"
   end
end

-- Updates the highlights in a buffer if the lsp responds with valid color data
function M.update_highlight(bufnr, change_data)
   -- validate bufnr and get its tailwindcss client
   local client = ATTACHED_BUFFERS[bufnr]
   if not client then
      return
   end

   -- check if lsp is still attached
   if not vim.lsp.buf_is_attached(bufnr, client.id) then
      vim.defer_fn(function()
         notify "tailwindcss-colors: current buffer is not attached to tailwindcss lsp client"
      end, 0)
      return
   end

   -- get document uri
   local params = { textDocument = vim.lsp.util.make_text_document_params() }

   -- send this to the lsp client
   client:request("textDocument/documentColor", params, function(err, result, _, _)
      -- if there were no errors, update highlights
      if err == nil and result ~= nil then
         buf_set_highlights(bufnr, result, change_data)
      end
   end, bufnr)
end

-- This function attaches to a buffer, updating highlights on change
function M.buf_attach(bufnr)
   bufnr = expand_bufnr(bufnr)

   -- if we have already attached to this buffer do nothing
   if ATTACHED_BUFFERS[bufnr] then
      return
   end

   -- find the tailwindcss client attached to THIS buffer (there may be several,
   -- one per project root, so we can't cache a single global client)
   local tailwind_lsp_client
   for _, client in ipairs(vim.lsp.get_clients { buffer = bufnr }) do
      if client.name == "tailwindcss" then
         tailwind_lsp_client = client
         break
      end
   end

   -- if we couldn't find it, don't attach
   if not tailwind_lsp_client then
      vim.notify "tailwindcss-colors: can't find tailwindcss lsp client at all (you sure it's loaded?)"
      return
   end

   -- if current buffer is not attached to the client, do nothing
   if not vim.lsp.buf_is_attached(bufnr, tailwind_lsp_client.id) then
      vim.notify "tailwindcss-colors: current buffer is not attached to tailwindcss lsp client"
      return
   end

   ATTACHED_BUFFERS[bufnr] = tailwind_lsp_client

   -- 200ms debounce workaround, the server needs some time go get ready
   -- not deferring for 200ms results in the server not responding at all
   vim.defer_fn(function()
      M.update_highlight(bufnr)
   end, 200)

   -- setup a hook for any changes in the buffer
   vim.api.nvim_buf_attach(bufnr, false, {
      on_lines = function(event_type, buf, changed_tick, firstline, lastline, new_lastline)
         if not ATTACHED_BUFFERS[bufnr] then
            return true
         end

         local change_data = {
            firstline = firstline,
            new_lastline = new_lastline,
         }

         M.update_highlight(bufnr, change_data)
      end,
      on_detach = function()
         M.buf_detach(bufnr)
      end,
      on_reload = function()
         M.update_highlight(bufnr)
      end,
   })
end

-- Detaches from the buffer
function M.buf_detach(bufnr)
   bufnr = expand_bufnr(bufnr)
   -- clear highlights
   vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
   -- remove from attached list
   ATTACHED_BUFFERS[bufnr] = nil
end

-- Refreshes the current buffer, optionally flushing the cache
function M.buf_refresh()
   local bufnr = vim.api.nvim_get_current_buf()
   M.update_highlight(bufnr)
end

-- Attaches or detaches from the current buffer
function M.buf_toggle()
   local bufnr = expand_bufnr(0)

   if ATTACHED_BUFFERS[bufnr] then
      M.buf_detach(bufnr)
      return
   end

   M.buf_attach(bufnr)
end

return M
