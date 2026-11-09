local M = {}

-- 环境变量优先于以下默认值；effort 的 none 关闭思考，default 交给服务端决定。
local default_settings = {
  openai = {
    model = "gpt-5.6-luna", -- OpenAI 协议的行内补全模型。
    effort = "none", -- 行内补全的思考强度，取值需模型支持。
    -- duet_model = "gpt-5.6-luna", -- Duet 独立模型；省略时沿用上方 model。
    -- duet_effort = "low", -- Duet 独立思考强度；省略时沿用 effort。
  },
  claude = {
    model = "claude-haiku-4-5-20251001", -- Anthropic 协议的行内补全模型。
    effort = "none", -- 行内补全的思考强度，取值需模型支持。
    -- duet_model = "claude-sonnet-5", -- Duet 独立模型；省略时沿用上方 model。
    -- duet_effort = "low", -- Duet 独立思考强度；省略时沿用 effort。
  },
  -- codex_chat_endpoint = "https://your-gateway/v1/chat/completions", -- 覆盖 Codex 来源的 Chat 接口地址。
  -- inline_optional = { max_completion_tokens = 128 }, -- OpenAI 行内输出 token 上限。
  -- inline_optional = { max_tokens = 256 }, -- Anthropic 行内输出 token 上限；与上一项按协议选用。
  -- duet_optional = {}, -- Duet 的额外请求参数，如模型支持的输出 token 上限。
}

local choices, selected, baseline, decorate
local priority = { "env", "local_fim", "codex", "claude" }
local service = "llamacpp-service.service"
-- 需与 manager.py 启动模型时的 alias 一致，用于请求和就绪检查。
local local_alias = "local-llm"
local lease
local apply
local mode = "auto"
local local_failed = false
local model_overrides = {}
M.info = { skipped = {} }

local function nonempty(value)
  return type(value) == "string" and value ~= "" and value or nil
end

local function env(name)
  return nonempty(vim.env[name])
end

local function skip(reason)
  table.insert(M.info.skipped, reason)
end

local function read_json(path)
  local file = io.open(path, "rb")
  if not file then
    return {}
  end
  local content = file:read("*a")
  file:close()
  local ok, data = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  return ok and type(data) == "table" and data or {}
end

local function read_toml(path)
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  local script = [[
import json, sys, tomllib
with open(sys.argv[1], "rb") as f:
    print(json.dumps(tomllib.load(f), default=str))
]]
  for _, command in ipairs({ { "python3" }, { "python" }, { "py", "-3" } }) do
    if vim.fn.executable(command[1]) == 1 then
      vim.list_extend(command, { "-c", script, path })
      local result = vim.system(command, { text = true }):wait(2000)
      if result.code == 0 then
        return vim.json.decode(result.stdout)
      end
    end
  end
  skip("Codex: TOML 读取失败（需要 Python 3.11+，或检查 TOML 语法）")
  return {}
end

local function home_dir(variable, directory)
  return vim.fs.normalize(env(variable) or vim.fs.joinpath(vim.uv.os_homedir(), directory))
end

local function endpoint(base, resource)
  base = base:gsub("/+$", "")
  if vim.endswith(base, "/" .. resource) then
    return base
  end
  return base .. "/" .. resource
end

local function from_codex()
  local home = home_dir("CODEX_HOME", ".codex")
  local config = read_toml(vim.fs.joinpath(home, "config.toml"))
  if not next(config) then
    return
  end
  if config.profile then
    local profile = read_toml(vim.fs.joinpath(home, config.profile .. ".config.toml"))
    config = vim.tbl_deep_extend("force", config, (config.profiles or {})[config.profile] or {}, profile)
  end
  local id = config.model_provider or "openai"
  local provider = (config.model_providers or {})[id] or {}
  local key
  if id == "openai" or provider.requires_openai_auth then
    if config.forced_login_method == "chatgpt" then
      skip("Codex: 配置要求使用 ChatGPT 登录")
      return
    end
    if (config.cli_auth_credentials_store or "file") ~= "file" then
      skip("Codex: 非 file 凭据存储，不能从 auth.json 确认当前认证方式")
      return
    end
    local auth = read_json(vim.fs.joinpath(home, "auth.json"))
    if auth.auth_mode == "apikey" or (not auth.auth_mode and not auth.tokens) then
      key = nonempty(auth.OPENAI_API_KEY)
    end
  elseif not provider.auth then
    key = nonempty(provider.experimental_bearer_token) or (provider.env_key and env(provider.env_key))
  end
  if not key then
    skip("Codex: 没有可读取的 API key（跳过 ChatGPT/OAuth、keyring、命令认证）")
    return
  end

  local base = provider.base_url
    or (id == "openai" and (config.openai_base_url or env("OPENAI_BASE_URL") or "https://api.openai.com/v1"))
  base = base and base:gsub("/+$", "")
  local url = env("MINUET_CODEX_CHAT_ENDPOINT") or nonempty(default_settings.codex_chat_endpoint)
  if
    not url
    and base
    and (provider.wire_api == "chat" or vim.endswith(base, "/chat/completions") or base == "https://api.openai.com/v1")
  then
    url = endpoint(base, "chat/completions")
  end
  if not url then
    skip("Codex: Minuet 不支持 Responses；确认兼容后设置 MINUET_CODEX_CHAT_ENDPOINT")
    return
  end
  if next(provider.query_params or {}) then
    skip("Codex: 自定义 query_params 未适配，请使用环境变量提供完整接口")
    return
  end
  local headers = provider.http_headers or {}
  for name, variable in pairs(provider.env_http_headers or {}) do
    headers[name] = env(variable) or headers[name]
  end
  return {
    source = "Codex",
    provider = "openai_compatible",
    key = key,
    url = url,
    headers = headers,
  }
end

local function anthropic_api(values, source)
  for _, name in ipairs({ "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY" }) do
    if values[name] == "1" or values[name] == "true" then
      skip(source .. ": 跳过云平台认证")
      return
    end
  end
  local token = nonempty(values.ANTHROPIC_AUTH_TOKEN)
  local key = token or nonempty(values.ANTHROPIC_API_KEY)
  if not key then
    return
  end
  local base = nonempty(values.ANTHROPIC_BASE_URL) or "https://api.anthropic.com"
  local url = base:gsub("/+$", "")
  if not vim.endswith(url, "/v1/messages") then
    url = endpoint(vim.endswith(url, "/v1") and url or url .. "/v1", "messages")
  end
  return { source = source, provider = "claude", key = key, bearer = token ~= nil, url = url }
end

local function from_claude()
  local config = read_json(vim.fs.joinpath(home_dir("CLAUDE_CONFIG_DIR", ".claude"), "settings.json"))
  return anthropic_api(config.env or {}, "Claude Code")
end

local function from_env()
  local provider = env("MINUET_PROVIDER")
  if provider and not vim.tbl_contains({ "openai", "openai_compatible", "claude" }, provider) then
    skip("环境变量: MINUET_PROVIDER 仅支持 openai、openai_compatible、claude")
    return
  end
  local key = env("MINUET_API_KEY")
  if key then
    local url = env("MINUET_ENDPOINT")
    if not url then
      skip("Environment: 缺少完整接口 URL，请设置 MINUET_ENDPOINT")
      return
    end
    return { source = "Environment", provider = provider or "openai_compatible", key = key, url = url }
  end
  key = env("OPENAI_API_KEY")
  if provider ~= "claude" and key then
    return {
      source = "Environment (OpenAI)",
      provider = provider or "openai_compatible",
      key = key,
      url = endpoint(env("OPENAI_BASE_URL") or "https://api.openai.com/v1", "chat/completions"),
    }
  end
  if not provider or provider == "claude" then
    return anthropic_api(vim.env, "Environment (Anthropic)")
  end
end

local function from_local()
  local directory = vim.fn.stdpath("config") .. "/etc/llamacpp-service"
  local config_home = env("XDG_CONFIG_HOME")
  if not config_home or not vim.startswith(config_home, "/") then
    config_home = vim.uv.os_homedir() .. "/.config"
  end
  local cfg = read_json(directory .. "/config.json")
  if not env("XDG_RUNTIME_DIR") or vim.fn.executable("systemctl") == 0 then
    skip("Local FIM: 需要 Linux 用户级 systemd / XDG_RUNTIME_DIR")
  elseif
    not next(cfg)
    or vim.fn.filereadable(config_home .. "/systemd/user/" .. service) == 0
    or vim.fn.filereadable(directory .. "/service/manager.py") == 0
  then
    skip("Local FIM: 请先运行 etc/llamacpp-service/install-service")
  elseif vim.fn.executable("llama-server") == 0 then
    skip("Local FIM: PATH 中未找到 llama-server")
  elseif not nonempty(cfg.model) or vim.fn.filereadable(vim.fn.expand(cfg.model)) == 0 then
    skip("Local FIM: 模型路径无效")
  elseif type(cfg.port) ~= "number" or cfg.port % 1 ~= 0 or cfg.port < 1 or cfg.port > 65535 then
    skip("Local FIM: port 需要是 1–65535 的整数")
  elseif type(cfg.startup_timeout) ~= "number" or cfg.startup_timeout <= 0 then
    skip("Local FIM: startup_timeout 需要大于 0")
  else
    return { source = "Local FIM", config = cfg, runtime = vim.env.XDG_RUNTIME_DIR .. "/llamacpp-service" }
  end
end

-- Claude 的非 none/default 强度映射到 adaptive thinking，需模型支持。
local function request_options(provider, effort, extra)
  local options = vim.deepcopy(extra or {})
  if effort == "default" then
    return options
  end
  if provider ~= "claude" then
    options.reasoning_effort = effort
  elseif effort == "none" then
    options.thinking = { type = "disabled" }
  else
    options.thinking = { type = "adaptive" }
    options.output_config = options.output_config or {}
    options.output_config.effort = effort
  end
  return options
end

local function cloud_options(api)
  local is_claude = api.provider == "claude"
  local preset = default_settings[is_claude and "claude" or "openai"]
  local env_model = env("MINUET_MODEL") or env(is_claude and "ANTHROPIC_MODEL" or "OPENAI_MODEL")
  local env_effort = env("MINUET_REASONING_EFFORT")
  local inline_effort = env_effort or preset.effort
  local duet_effort = env("MINUET_DUET_REASONING_EFFORT") or env_effort or preset.duet_effort or preset.effort
  local inline = {
    model = env_model or preset.model,
    end_point = api.url,
    api_key = function()
      return api.key
    end,
    name = api.source,
  }
  if api.bearer or next(api.headers or {}) then
    inline.transform = {
      function(request)
        if api.bearer then
          request.headers["x-api-key"] = nil
          request.headers.Authorization = "Bearer " .. api.key
        end
        for name, value in pairs(api.headers or {}) do
          request.headers[name] = value
        end
        return request
      end,
    }
  end

  -- Duet 复用连接信息，但独立配置模型和生成参数。
  local duet = vim.deepcopy(inline)
  duet.model = env("MINUET_DUET_MODEL") or env_model or preset.duet_model or preset.model
  inline.optional = request_options(api.provider, inline_effort, default_settings.inline_optional)
  duet.optional = request_options(api.provider, duet_effort, default_settings.duet_optional)
  return {
    provider = api.provider,
    provider_options = { [api.provider] = inline },
    duet = { provider = api.provider, provider_options = { [api.provider] = duet } },
    n_completions = 1, -- 请求的补全候选数。
    context_window = 12000, -- 光标前后文的字符总上限，不含 VectorCode 检索内容。
    debounce = 500, -- 自动补全的防抖等待时间（毫秒）；0 关闭防抖。
    throttle = 1500, -- 补全请求的最小发送间隔（毫秒）；0 关闭节流。
    request_timeout = 15, -- 补全请求超时（秒）。
  }
end

local function local_options(cfg)
  return {
    provider = "openai_fim_compatible",
    n_completions = 1, -- 本地补全的候选数。
    context_window = 6000, -- 光标前后文的字符总上限，不含 VectorCode 检索内容。
    debounce = 300, -- 本地自动补全的防抖等待时间（毫秒）；0 关闭防抖。
    throttle = 800, -- 本地补全请求的最小发送间隔（毫秒）；0 关闭节流。
    request_timeout = 10, -- 本地补全请求超时（秒）。
    provider_options = {
      openai_fim_compatible = {
        name = "Local FIM",
        model = local_alias,
        end_point = "http://127.0.0.1:" .. cfg.port .. "/v1/completions",
        api_key = function()
          return "local"
        end,
        optional = {
          max_tokens = 96, -- 单次生成的 token 上限。
          temperature = 0, -- 采样温度；0 使用贪心选择，调高增加随机性。
          cache_prompt = true, -- 复用相同提示词前缀的计算缓存。
          -- 遇到这些 Qwen FIM 标记时停止生成；更换模型时需匹配其标记。
          stop = { "<|endoftext|>", "<|fim_prefix|>", "<|fim_suffix|>", "<|fim_middle|>", "<|file_sep|>" },
        },
      },
    },
    duet = {}, -- FIM 不支持 Duet；下面按可用来源另选云端 Chat。
  }
end

local function discover()
  choices = {}
  M.info.skipped = {}
  local resolvers = { env = from_env, local_fim = from_local, codex = from_codex, claude = from_claude }
  for _, id in ipairs(priority) do
    local api = resolvers[id]()
    if api then
      choices[id] = {
        id = id,
        source = api.source,
        local_config = api.config,
        runtime = api.runtime,
        opts = api.config and local_options(api.config) or cloud_options(api),
      }
    end
  end
  local cloud = choices.env or choices.codex or choices.claude
  if choices.local_fim and cloud then
    choices.local_fim.opts.duet = vim.deepcopy(cloud.opts.duet)
  end
end

local function automatic()
  for _, id in ipairs(priority) do
    if choices[id] and not (id == "local_fim" and local_failed) then
      return choices[id]
    end
  end
end

local function options(choice)
  M.info = { skipped = M.info.skipped, mode = mode, source = choice and choice.source or "Disabled" }
  local opts = vim.deepcopy(baseline)
  if choice then
    opts = vim.tbl_deep_extend("force", opts, choice.opts)
    if model_overrides[choice.id] then
      opts.provider_options[opts.provider].model = model_overrides[choice.id]
    end
    decorate(opts)
    M.info.provider = opts.provider
    M.info.model = opts.provider_options[opts.provider].model
    local duet = choice.opts.duet
    M.info.duet_model = duet.provider and duet.provider_options[duet.provider].model or nil
  end
  return opts
end

local function process_start(pid)
  if type(pid) ~= "number" then
    return
  end
  local file = io.open("/proc/" .. pid .. "/stat", "r")
  if not file then
    return
  end
  local fields = vim.split(file:read("*a"):match(".*%) (.*)") or "", "%s+")
  file:close()
  -- 启动时间用于区分复用的 PID；不把僵尸或已退出进程视为存活。
  return fields[1] ~= "Z" and fields[1] ~= "X" and fields[20] or nil
end

local function release_local()
  if not lease then
    return
  end
  if lease.timer then
    lease.timer:stop()
    lease.timer:close()
  end
  os.remove(lease.path)
  os.remove(lease.path .. ".tmp")
  lease = nil
end

local function acquire_local()
  if lease or local_failed or not selected or not selected.local_config or #vim.api.nvim_list_uis() == 0 then
    return
  end
  local cfg, runtime = selected.local_config, selected.runtime
  local pid = vim.fn.getpid()
  local start = process_start(pid)
  if not start then
    return
  end
  local current = { path = runtime .. "/clients/" .. pid .. "-" .. start .. ".json", ready = false }
  lease = current
  local function fail(reason)
    -- 以登记对象识别本轮加载，忽略切换模型/退出后到达的旧回调。
    if lease ~= current then
      return
    end
    release_local()
    local_failed = reason
    vim.notify("Local FIM 不可用：" .. reason, vim.log.levels.WARN)
    if mode == "auto" then
      apply(automatic())
    end
  end
  local ok = pcall(function()
    vim.fn.mkdir(runtime .. "/clients", "p", 448)
    vim.fn.writefile({ vim.json.encode({ pid = pid, start = start }) }, current.path .. ".tmp")
    assert(os.rename(current.path .. ".tmp", current.path))
  end)
  if not ok then
    fail("无法登记本地模型使用实例")
    return
  end
  local last_ready = vim.uv.now()
  current.timer = vim.uv.new_timer()
  current.timer:start(
    0,
    500,
    vim.schedule_wrap(function()
      if lease ~= current then
        return
      end
      local status = read_json(runtime .. "/status.json")
      local live = status.manager_start ~= nil and process_start(status.manager_pid) == status.manager_start
      current.ready = live
        and status.phase == "ready"
        and status.server_start ~= nil
        and process_start(status.server_pid) == status.server_start
        and status.port == cfg.port
        and status.alias == local_alias
      if live and status.phase == "error" then
        fail(status.detail or "请检查服务日志")
      elseif current.ready then
        last_ready = vim.uv.now()
      elseif vim.uv.now() - last_ready > (cfg.startup_timeout + 10) * 1000 then
        fail("本地模型加载超时")
      end
    end)
  )
  ok = pcall(
    vim.system,
    { "systemctl", "--user", "start", "--no-block", service },
    { text = true, timeout = 5000 },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          fail("启动服务失败，请检查 journalctl --user -u llamacpp-service")
        end
      end)
    end
  )
  if not ok then
    fail("无法调用 systemctl")
  end
end

function M.ready()
  return selected ~= nil and (not selected.local_config or (lease ~= nil and lease.ready)) or false
end

function M.duet_ready()
  return selected ~= nil and selected.opts.duet.provider ~= nil
end

apply = function(choice)
  release_local()
  selected = choice
  require("minuet.backends.common").terminate_all_jobs()
  require("minuet.duet.backends.common").terminate_all_jobs()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_call(buf, function()
        require("minuet.virtualtext").action.dismiss()
        require("minuet.duet").action.dismiss()
      end)
    end
  end
  require("minuet").config = options(choice)
  acquire_local()
end

function M.configure(common, context_decorator)
  decorate = context_decorator
  -- 切换时从基线重新构建，避免同协议的不同账号残留请求头、密钥或参数。
  baseline = vim.tbl_deep_extend("force", vim.deepcopy(require("minuet.config")), common)
  discover()
  selected = automatic()
  return options(selected)
end

function M.attach()
  local group = vim.api.nvim_create_augroup("minuet_provider", { clear = true })
  vim.api.nvim_create_autocmd({ "VimEnter", "UIEnter" }, { group = group, callback = acquire_local })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = release_local })
  if vim.v.vim_did_enter == 1 then
    acquire_local()
  end
end

function M.select(id)
  if id ~= "auto" and id ~= "off" and not choices[id] then
    vim.notify("该补全来源尚未配置。\n" .. table.concat(M.info.skipped, "\n"), vim.log.levels.WARN)
    return
  end
  mode, local_failed = id, false
  apply(id == "auto" and automatic() or choices[id])
  vim.notify("Minuet: " .. M.info.source .. (M.info.model and (" / " .. M.info.model) or ""))
end

function M.status()
  local config = require("minuet").config
  local inline = config.provider_options[config.provider] or {}
  local duet = config.duet.provider_options[config.duet.provider] or {}
  local function enabled(value)
    return value and "开启" or "关闭"
  end
  local lines = {
    "# 补全来源",
    "- 选择模式：" .. (mode == "auto" and "自动" or mode == "off" and "关闭" or "手动"),
    "- 选择来源：" .. M.info.source,
    "- 当前协议 / 模型：" .. config.provider .. " / " .. (inline.model or "未配置"),
    "- 行内请求：" .. (M.ready() and "可发起（未检测 API 连通性）" or "未就绪 / 已关闭"),
    ("- 上下文：%s 字符；候选：%s；请求超时：%s 秒"):format(
      config.context_window,
      config.n_completions,
      config.request_timeout
    ),
    ("- 防抖 / 节流：%s / %s 毫秒"):format(config.debounce, config.throttle),
    "",
    "# 当前缓冲区",
    "- 文件类型：" .. (nonempty(vim.bo.filetype) or "未设置"),
    "- 行内自动触发开关：" .. enabled(vim.b.minuet_virtual_text_auto_trigger),
    "- Duet 自动触发开关：" .. enabled(vim.b.minuet_duet_auto_trigger),
    "- Duet 来源配置：" .. (M.duet_ready() and "可用" or "不可用"),
    "- Duet 当前协议 / 模型：" .. config.duet.provider .. " / " .. (duet.model or "未配置"),
    ("- 进行中请求：行内 %d，Duet %d"):format(
      #require("minuet.backends.common").current_jobs,
      #require("minuet.duet.backends.common").current_jobs
    ),
    "",
    "# 本地模型服务",
    "- 本实例使用登记：" .. (lease and "已登记" or "未登记"),
  }
  local runtime = env("XDG_RUNTIME_DIR")
  runtime = runtime and (runtime .. "/llamacpp-service")
  local status = runtime and read_json(runtime .. "/status.json") or {}
  local live = status.manager_start ~= nil and process_start(status.manager_pid) == status.manager_start
  if live then
    local server_live = status.server_start ~= nil and process_start(status.server_pid) == status.server_start
    local phases = { idle = "空闲", loading = "加载中", ready = "就绪", error = "错误" }
    local phase = status.phase == "ready" and not server_live and "状态已过期（模型进程不存在）"
      or phases[status.phase]
      or "未知"
    lines[#lines + 1] = "- 模型状态：" .. phase
    lines[#lines + 1] = ("- 管理进程：%s；模型进程：%s"):format(
      status.manager_pid,
      server_live and status.server_pid or "未运行"
    )
    lines[#lines + 1] = ("- 模型标识 / 监听端口：%s / %s"):format(status.alias, status.port)
    local clients = 0
    for _, path in ipairs(vim.fn.globpath(runtime .. "/clients", "*.json", false, true)) do
      local client = read_json(path)
      if client.start ~= nil and process_start(client.pid) == client.start then
        clients = clients + 1
      end
    end
    lines[#lines + 1] = "- 存活使用实例：" .. clients
    if nonempty(status.detail) then
      lines[#lines + 1] = "- 服务信息：" .. status.detail
    end
  else
    lines[#lines + 1] = "- 模型状态：未运行 / 无有效服务状态"
  end
  if local_failed then
    lines[#lines + 1] = "- 最近加载失败：" .. local_failed
  end
  vim.list_extend(lines, { "", "# VectorCode（当前缓冲区）" })
  local vectorcode = package.loaded["vectorcode.config"]
  if vectorcode and vectorcode.has_cli() then
    local cacher = vectorcode.get_cacher_backend()
    lines[#lines + 1] = "- 缓存注册：" .. (cacher.buf_is_registered(0) and "已注册" or "未注册")
    lines[#lines + 1] = "- 缓存刷新：" .. enabled(cacher.buf_is_enabled(0))
    lines[#lines + 1] = ("- 缓存代码块：%d；进行中检索：%d"):format(
      #cacher.query_from_cache(0, { notify = false }),
      cacher.buf_job_count(0)
    )
  else
    lines[#lines + 1] = "- " .. (vectorcode and "CLI 不可用" or "插件未加载")
  end
  if #M.info.skipped > 0 then
    vim.list_extend(lines, { "", "# 来源诊断（最近一次解析）" })
    for _, reason in ipairs(M.info.skipped) do
      lines[#lines + 1] = "- " .. reason
    end
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, {
    title = "Minuet Status",
    id = "minuet_status",
    ft = "markdown",
    timeout = 10000, -- 状态通知的显示时长（毫秒）。
  })
end

function M.menu()
  discover()
  local entries = { { id = "auto", label = "自动：环境变量 → Local FIM → Codex → Claude Code" } }
  for _, id in ipairs(priority) do
    local choice = choices[id]
    if choice then
      local model = model_overrides[id] or choice.opts.provider_options[choice.opts.provider].model
      table.insert(entries, { id = id, label = choice.source .. " / " .. model })
    end
  end
  if selected and not selected.local_config and choices[selected.id] then
    table.insert(
      entries,
      { id = "custom", target = selected.id, model = M.info.model, label = "自定义当前云端补全模型…" }
    )
  end
  table.insert(entries, { id = "off", label = "关闭 Minuet（行内与 Duet）" })
  table.insert(entries, { id = "status", label = "查看当前来源与不可用原因" })
  vim.ui.select(entries, {
    prompt = "Minuet 补全模型（当前：" .. M.info.source .. "）",
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    if not item then
      return
    end
    if item.id == "status" then
      M.status()
    elseif item.id == "custom" then
      -- 捕获打开菜单时的来源，避免异步回退后修改另一来源的模型。
      vim.ui.input({ prompt = "补全模型 ID: ", default = item.model }, function(model)
        if model and vim.trim(model) ~= "" then
          model_overrides[item.target] = vim.trim(model)
          M.select(item.target)
        end
      end)
    else
      M.select(item.id)
    end
  end)
end

return M
