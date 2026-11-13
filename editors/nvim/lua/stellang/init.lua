-- stellang for Neovim: starts `stellang lsp` (the compiler itself) for *.st buffers.
-- Errors, hover types, completion, go to definition, symbols, formatting and semantic
-- highlighting all come from the compiler, so they follow the language as it changes.
local M = {
  config = {
    cmd = { "stellang", "lsp" },
    format_on_save = false,
    inlay_hints = true, -- `let x = f()` shows `: Type` (Neovim 0.10+)
  },
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

function M.attach(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  if vim.fn.executable(M.config.cmd[1]) == 0 then
    vim.notify_once("stellang: `" .. M.config.cmd[1] .. "` not found; install it with `cargo install --path .`", vim.log.levels.WARN)
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local root = vim.fs.root and vim.fs.root(buf, { ".git" }) or vim.fs.dirname(name)
  vim.lsp.start({ name = "stellang", cmd = M.config.cmd, root_dir = root }, { bufnr = buf })
  if M.config.inlay_hints and vim.lsp.inlay_hint then
    pcall(vim.lsp.inlay_hint.enable, true, { bufnr = buf })
  end
  if M.config.format_on_save then
    vim.api.nvim_create_autocmd("BufWritePre", {
      buffer = buf,
      callback = function() vim.lsp.buf.format({ bufnr = buf, name = "stellang" }) end,
    })
  end
end

return M
