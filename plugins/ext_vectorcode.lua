local has_uv = vim.fn.executable("uv") == 1

return {
  "Davidyz/VectorCode",
  dependencies = { "nvim-lua/plenary.nvim" },
  build = has_uv and function(plugin)
    local notify_opts = { title = "VectorCode CLI", id = "vectorcode_cli_build" }
    vim.notify("正在安装或更新 CLI…", vim.log.levels.INFO, notify_opts)
    local task = require("lazy.async").running()
    ---@cast task LazyTask
    task:on("done", function()
      local failed = task:has_errors()
      vim.notify(
        failed and "CLI 安装或更新失败，请在 :Lazy 中查看详情。" or "CLI 安装或更新完成。",
        failed and vim.log.levels.ERROR or vim.log.levels.INFO,
        notify_opts
      )
    end)
    -- origin: 原始安装命令：上游修复合并后可恢复此段
    -- assert(
    --   task:spawn("uv", {
    --     args = { "tool", "install", "--upgrade", "--python", "3.12", "--reinstall-package", "vectorcode", "." },
    --     cwd = plugin.dir,
    --     timeout = 30 * 60 * 1000, -- 单位ms；延长超时以等待依赖下载
    --   }),
    --   "uv tool install 失败"
    -- )
    -- endorigin
    -- fix: 规避 tree-sitter 0.26.0 的 Point 堆损坏及随机段错误，以及新版解析器包异常未捕获问题；待上游修复后移除此段。
    assert(
      task:spawn("uv", {
        args = {
          "tool",
          "install",
          "--upgrade",
          "--python",
          "3.12",
          "--reinstall-package",
          "vectorcode",
          "--with",
          "tree-sitter==0.25.2",
          "--with",
          "tree-sitter-language-pack==0.13.0",
          ".",
        },
        cwd = plugin.dir,
        timeout = 30 * 60 * 1000, -- 单位毫秒；首次下载较大依赖时允许等待 30 分钟。
      }),
      "uv tool install 失败"
    )
  -- endfix
  end or false,
  opts = function()
    local cli = "vectorcode"
    if has_uv then
      local result = vim.system({ "uv", "tool", "dir", "--bin" }, { text = true }):wait()
      if result.code == 0 then
        cli = vim.fs.joinpath(vim.trim(result.stdout), "vectorcode")
      end
    end
    return {
      cli_cmds = { vectorcode = cli },
      notify = false, -- 是否显示检索通知；异步检索也继承此值。
      async_opts = {
        debounce = 10, -- 后端的查询间隔（秒）；调小使缓存更及时，但增加检索次数。
        n_query = 8, -- 每次检索的代码块数量；按相关性排序后受 Minuet 总字符预算限制。
        run_on_register = true, -- 文件注册后立即查询，不等待后续编辑事件。
        single_job = true, -- 同一文件的新查询取消尚未完成的旧查询。
        -- 以光标附近共 2 行作为查询内容；-1 表示整个文件。
        query_cb = require("vectorcode.utils").make_surrounding_lines_cb(2),
      },
    }
  end,
  config = function(plugin, opts)
    local cli = opts.cli_cmds.vectorcode
    local function setup()
      local setup_opts = vim.deepcopy(opts)
      -- CLI 可用时才启用转发脚本，避免脚本本身掩盖 CLI 尚未安装的状态。
      if vim.fn.executable(cli) == 1 then
        vim.env.NVIM_VECTORCODE_CLI = cli
        setup_opts.cli_cmds.vectorcode =
          vim.fs.joinpath(vim.fn.stdpath("config"), "etc", "vectorcode", "query-chunk-wrapper")
      end
      require("vectorcode").setup(setup_opts)
    end
    setup()
    local config = require("vectorcode.config")
    local cacher = config.get_cacher_backend()
    local function register(buf)
      if
        not config.has_cli()
        or not vim.api.nvim_buf_is_valid(buf)
        or #vim.lsp.get_clients({ bufnr = buf }) == 0
        or cacher.buf_is_registered(buf)
      then
        return
      end
      cacher.async_check("config", function()
        if
          vim.api.nvim_buf_is_valid(buf)
          and #vim.lsp.get_clients({ bufnr = buf }) > 0
          and not cacher.buf_is_registered(buf)
        then
          cacher.register_buffer(buf, {})
        end
      end)
    end
    local function register_attached()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        register(buf)
      end
    end
    local group = vim.api.nvim_create_augroup("vectorcode_context", { clear = true })
    vim.api.nvim_create_autocmd("LspAttach", {
      group = group,
      callback = function(args)
        register(args.buf)
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = group,
      callback = function(args)
        if cacher.buf_is_registered(args.buf) then
          cacher.deregister_buffer(args.buf)
        end
      end,
    })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = { "LazyBuild", "LazyUpdate" },
      -- CLI 安装完成后启用转发脚本，并补注册已连接语言服务的文件。
      callback = function()
        setup()
        register_attached()
      end,
    })
    register_attached()
    -- 已有插件缺少 CLI 时，异步补装，避免阻塞编辑器启动。
    if has_uv and not config.has_cli() then
      vim.schedule(function()
        require("lazy").build({ plugins = { plugin.name }, show = false })
      end)
    end
  end,
}
