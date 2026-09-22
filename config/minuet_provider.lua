local M = {}

-- 配置优先级：API：环境变量 → Codex → Claude Code；模型与思考：环境变量 → 对应协议的默认值
local default_settings = {
  openai = {
    model = "gpt-5.6-luna",
    effort = "none",
    -- duet_model = "gpt-5.6-luna", -- NES 模型，默认与行内补全相同
    -- duet_effort = "low", -- NES 思考强度
  },
  claude = {
    model = "claude-haiku-4-5-20251001",
    effort = "none",
    -- duet_model = "claude-sonnet-5",
    -- duet_effort = "low",
  },
  -- codex_chat_endpoint = "https://your-gateway/v1/chat/completions",
  -- inline_optional = { max_completion_tokens = 128 }, -- OpenAI 格式的可选参数
  -- inline_optional = { max_tokens = 256 }, -- Anthropic 格式的可选参数
  -- duet_optional = {}, -- NES 不宜设置很小的输出限制
}

-- nil：未解析；false：无可用配置
local cached
M.info = { skipped = {} } -- 诊断信息不含密钥或请求头

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
  -- Python 3.11+ 标准库解析 TOML
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

-- none 表示关闭思考；default 表示不发送思考参数，由服务端决定
-- Claude 的其他强度使用 adaptive thinking，仅适用于 Sonnet 等支持它的模型
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

function M.get()
  if cached ~= nil then
    return cached or nil
  end
  cached = false

  local api = from_env() or from_codex() or from_claude()
  if not api then
    vim.schedule(function()
      vim.notify(
        "Minuet 未启用：没有可用的 API 配置。\n" .. table.concat(M.info.skipped, "\n"),
        vim.log.levels.WARN
      )
    end)
    return
  end

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

  -- 复用 API 连接信息；行内补全和 NES 各自使用 Minuet 默认提示词和输出限制
  local duet = vim.deepcopy(inline)
  duet.model = env("MINUET_DUET_MODEL") or env_model or preset.duet_model or preset.model
  inline.optional = request_options(api.provider, inline_effort, default_settings.inline_optional)
  duet.optional = request_options(api.provider, duet_effort, default_settings.duet_optional)
  cached = {
    provider = api.provider,
    provider_options = { [api.provider] = inline },
    duet = { provider = api.provider, provider_options = { [api.provider] = duet } },
  }
  M.info.source = api.source
  M.info.provider = api.provider
  M.info.model = inline.model
  M.info.duet_model = duet.model
  M.info.effort = inline_effort
  M.info.duet_effort = duet_effort
  return cached
end

return M
