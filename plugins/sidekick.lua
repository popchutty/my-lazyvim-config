return {
  "folke/sidekick.nvim",
  -- 移除 ai.sidekick extra 中与 Copilot 相关的功能
  -- 关闭 NES 并移除相关键绑定
  opts = function(_, opts)
    LazyVim.cmp.actions.ai_nes = nil
    vim.keymap.del("n", "<leader>uN")
    return vim.tbl_deep_extend("force", opts, {
      nes = { enabled = false },
      copilot = { status = { enabled = false } },
    })
  end,
  keys = {
    { "<Tab>", false, mode = "n" },
  },
}
