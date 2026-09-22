local function accept()
  local virtualtext = require("minuet.virtualtext").action
  if virtualtext.is_visible() then
    virtualtext.accept()
    return true
  end
  local duet = require("minuet.duet").action
  if duet.is_visible() then
    vim.schedule(duet.apply)
    return true
  end
end

local function dismiss()
  require("minuet.virtualtext").action.dismiss()
  require("minuet.duet").action.dismiss()
end

return {
  "milanglacier/minuet-ai.nvim",
  -- 禁用懒加载，使首个打开的 buffer 也能启用 Duet 自动触发
  lazy = false,
  cond = function()
    return require("config.minuet_provider").get() ~= nil
  end,
  opts = function()
    return vim.tbl_deep_extend("force", require("config.minuet_provider").get(), {
      virtualtext = {
        auto_trigger_ft = { "*" },
        auto_trigger_ignore_ft = { "markdown", "text" },
        keymap = {
          accept_line = "<M-Down>",
          prev = "<M-h>", -- 上一个候选；尚无候选时触发请求
          next = "<M-l>", -- 下一个候选；尚无候选时触发请求
        },
      },
      duet = {
        auto_trigger = {
          auto_trigger_ft = { "*" },
          auto_trigger_ignore_ft = { "markdown", "text" },
          enable_predicates = {
            function()
              return vim.fn.mode() == "n"
            end,
          },
        },
      },
      -- debounce = 400, -- 默认值；增大可减少请求
      -- throttle = 1000,
      -- request_timeout = 3,
    })
  end,
  config = function(_, opts)
    require("minuet").setup(opts)
    -- 接入 LazyVim 的 Tab 链：沿用补全菜单默认优先级。
    LazyVim.cmp.actions.ai_accept = accept
    -- 监听 ESC 按键，不覆盖原有 Esc 映射。
    local esc = vim.keycode("<Esc>")
    vim.on_key(function(_, typed)
      if typed == esc then
        dismiss()
      end
    end, vim.api.nvim_create_namespace("minuet.dismiss"))
  end,
  -- stylua: ignore
  keys = {
    { "<Tab>", function() return accept() and "" or "<Tab>" end, mode = "n", expr = true, desc = "Accept Minuet Next Edit" },
    { "<leader>an", "<cmd>Minuet duet predict<cr>", desc = "Predict Minuet Next Edit" },
    { "<leader>ai", "<cmd>Minuet virtualtext toggle<cr>", desc = "Toggle Minuet Completion (Buffer)" },
    { "<leader>aN", "<cmd>Minuet duet toggle<cr>", desc = "Toggle Minuet Next Edit (Buffer)" },
  },
}
