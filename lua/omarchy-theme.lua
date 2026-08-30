-- Keep Neovim synchronized with the active Omarchy theme.
-- Omarchy writes a lazy.nvim-style spec to the active theme's neovim.lua.
-- This bridge translates the colorscheme entry to Neovim's built-in vim.pack.

local M = {}

local uv = vim.uv or vim.loop

local THEME_PATHS = {
  vim.fn.expand '~/.local/state/omarchy/current/theme/neovim.lua',
  vim.fn.expand '~/.config/omarchy/current/theme/neovim.lua',
}

local WATCH_DIRS = {
  vim.fn.expand '~/.local/state/omarchy/current',
  vim.fn.expand '~/.config/omarchy',
}

local AETHER_REPO = 'bjarneo/aether.nvim'

local function readable(path)
  return path and vim.fn.filereadable(path) == 1
end

local function theme_path()
  for _, path in ipairs(THEME_PATHS) do
    if readable(path) then
      return path
    end
  end
end

local function read_file(path)
  if not readable(path) then
    return ''
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and table.concat(lines, '\n') or ''
end

local function signature(path)
  local colors_path = path and vim.fs.joinpath(vim.fs.dirname(path), 'colors.toml')
  return vim.fn.sha256(read_file(path) .. '\n-- colors --\n' .. read_file(colors_path))
end

local function plugin_repo(entry)
  if type(entry) ~= 'table' then
    return nil
  end

  local repo = entry[1] or entry.name
  return type(repo) == 'string' and repo or nil
end

local function is_lazyvim(entry)
  local repo = plugin_repo(entry)
  return repo and repo:find('LazyVim/LazyVim', 1, true) ~= nil
end

local function is_aether(entry)
  local repo = plugin_repo(entry)
  return repo and repo:find('aether.nvim', 1, true) ~= nil
end

local function read_spec(path)
  if not readable(path) then
    return nil, 'theme spec is missing'
  end

  local ok, spec = pcall(dofile, path)
  if not ok then
    return nil, spec
  end
  if type(spec) ~= 'table' then
    return nil, 'theme spec did not return a table'
  end

  return spec
end

local function find_theme_entries(spec)
  local plugin_entry
  local colorscheme

  for _, entry in ipairs(spec) do
    if is_lazyvim(entry) then
      if type(entry.opts) == 'table' and type(entry.opts.colorscheme) == 'string' then
        colorscheme = entry.opts.colorscheme
      end
    elseif not plugin_entry and plugin_repo(entry) then
      plugin_entry = entry
    end
  end

  return plugin_entry, colorscheme
end

local function github_source(repo)
  if repo:match '^https?://' or repo:match '^git@' or repo:sub(1, 1) == '/' then
    return repo
  end
  return 'https://github.com/' .. repo
end

local function pack_name(entry, repo)
  if type(entry.name) == 'string' then
    return entry.name
  end
  return repo:match '([^/]+)$'
end

local function add_pack_entry(entry, added)
  if type(entry) == 'string' then
    entry = { entry }
  end
  if type(entry) ~= 'table' then
    return true
  end

  local repo = plugin_repo(entry)
  if not repo or is_lazyvim(entry) then
    return true
  end

  -- Aether is added explicitly in init.lua on its v3 branch.
  if repo == AETHER_REPO then
    return true
  end

  if type(entry.dependencies) == 'table' then
    for _, dependency in ipairs(entry.dependencies) do
      local ok, err = add_pack_entry(dependency, added)
      if not ok then
        return false, err
      end
    end
  end

  local name = pack_name(entry, repo)
  if not name or added[name] then
    return true
  end

  local pack_spec = {
    src = github_source(repo),
    name = name,
  }
  if type(entry.branch) == 'string' then
    pack_spec.version = entry.branch
  elseif type(entry.version) == 'string' then
    pack_spec.version = entry.version
  end

  local ok, err = pcall(vim.pack.add, { pack_spec }, { confirm = false, load = true })
  if not ok then
    return false, err
  end

  added[name] = true
  return true
end

local function plugin_options(entry)
  if type(entry.opts) == 'table' then
    return vim.deepcopy(entry.opts)
  end
  if type(entry.opts) == 'function' then
    local ok, opts = pcall(entry.opts, entry, {})
    if ok and type(opts) == 'table' then
      return opts
    end
  end
  return {}
end

local function module_candidates(entry)
  local repo = plugin_repo(entry) or ''
  local basename = repo:match '([^/]+)$' or ''
  local stripped = basename:gsub('%.nvim$', ''):gsub('%-nvim$', ''):gsub('^nvim%-', '')
  local compact = stripped:gsub('%-', '')

  return vim.tbl_filter(function(value)
    return type(value) == 'string' and value ~= ''
  end, {
    entry.main,
    entry.name,
    stripped,
    compact,
  })
end

local function configure_plugin(entry)
  local opts = plugin_options(entry)

  if type(entry.config) == 'function' then
    local ok, err = pcall(entry.config, entry, opts)
    return ok, err
  end

  -- Use lazy.nvim's common setup shape. Calling setup({}) matters when moving
  -- from a configured variant (for example catppuccin-latte) back to defaults.
  for _, module_name in ipairs(module_candidates(entry)) do
    local ok, module = pcall(require, module_name)
    if ok and type(module) == 'table' and type(module.setup) == 'function' then
      local setup_ok, err = pcall(module.setup, opts)
      return setup_ok, err
    end
  end

  if vim.tbl_isempty(opts) then
    return true
  end
  return false, 'could not find the theme plugin setup module'
end

local function telescope_highlights(highlights, colors)
  highlights.TelescopePromptPrefix = { fg = colors.cyan }
  highlights.TelescopeSelectionCaret = { fg = colors.cyan, bg = colors.lighter_bg }
  highlights.TelescopeMatching = { fg = colors.cyan, bold = true }
  highlights.TelescopePromptTitle = { fg = colors.bg, bg = colors.cyan, bold = true }
  highlights.TelescopePreviewTitle = { fg = colors.bg, bg = colors.blue, bold = true }
  highlights.TelescopeResultsTitle = { fg = colors.bg, bg = colors.red, bold = true }
end

local function with_aether_overrides(opts)
  opts = vim.tbl_deep_extend('force', {}, opts or {})
  local user_on_highlights = opts.on_highlights

  opts.on_highlights = function(highlights, colors)
    if user_on_highlights then
      user_on_highlights(highlights, colors)
    end
    telescope_highlights(highlights, colors)
  end
  opts.styles = vim.tbl_deep_extend('force', {
    comments = { italic = false },
    keywords = { italic = false },
  }, opts.styles or {})

  return opts
end

local function apply_aether(opts)
  local ok, aether = pcall(require, 'aether')
  if not ok then
    return false, aether
  end

  local setup_ok, err = pcall(aether.setup, with_aether_overrides(opts))
  if not setup_ok then
    return false, err
  end

  local colorscheme_ok, colorscheme_err = pcall(vim.cmd.colorscheme, 'aether')
  return colorscheme_ok, colorscheme_err
end

local AETHER_COLOR_MAP = {
  background = 'bg',
  dark_background = 'dark_bg',
  darker_background = 'darker_bg',
  lighter_background = 'lighter_bg',
  foreground = 'fg',
  dark_foreground = 'dark_fg',
  light_foreground = 'light_fg',
  bright_foreground = 'bright_fg',
}

local function aether_opts_from_colors(path)
  local colors_path = vim.fs.joinpath(vim.fs.dirname(path), 'colors.toml')
  local colors = {}

  for line in read_file(colors_path):gmatch '[^\n]+' do
    local key, value = line:match '^%s*([%w_]+)%s*=%s*["\'](#[%x]+)["\']'
    if key and value then
      colors[AETHER_COLOR_MAP[key] or key] = value
    end
  end

  colors.cursor = colors.bright_fg or colors.fg
  colors.foreground = colors.fg
  colors.background = colors.bg
  colors.selection_background = colors.selection
  colors.selection_foreground = colors.bright_fg or colors.fg

  return { colors = colors }
end

local function set_background(path)
  local colors_path = vim.fs.joinpath(vim.fs.dirname(path), 'colors.toml')
  local mode = read_file(colors_path):match 'mode%s*=%s*["\'](light|dark)["\']'
  if mode then
    vim.o.background = mode
  end
end

local function apply_exact_theme(plugin_entry, colorscheme)
  if not plugin_entry or not colorscheme then
    return false, 'theme spec has no colorscheme plugin entry'
  end

  if is_aether(plugin_entry) then
    return apply_aether(plugin_options(plugin_entry))
  end

  local add_ok, add_err = add_pack_entry(plugin_entry, {})
  if not add_ok then
    return false, add_err
  end

  local configure_ok, configure_err = configure_plugin(plugin_entry)
  if not configure_ok then
    vim.schedule(function()
      vim.notify('omarchy-theme: ' .. tostring(configure_err), vim.log.levels.WARN)
    end)
  end

  local ok, err = pcall(vim.cmd.colorscheme, colorscheme)
  return ok, err
end

function M.reload(force)
  local path = theme_path()
  if not path then
    vim.notify('omarchy-theme: active theme spec was not found', vim.log.levels.WARN)
    return false
  end

  local current_signature = signature(path)
  if not force and current_signature == M._last_signature then
    return true
  end

  local spec, spec_err = read_spec(path)
  if not spec then
    vim.notify('omarchy-theme: failed to load ' .. path .. ': ' .. tostring(spec_err), vim.log.levels.WARN)
    return false
  end

  set_background(path)
  local plugin_entry, colorscheme = find_theme_entries(spec)
  local ok, err = apply_exact_theme(plugin_entry, colorscheme)

  if not ok then
    local fallback_ok, fallback_err = apply_aether(aether_opts_from_colors(path))
    if not fallback_ok then
      vim.notify(
        'omarchy-theme: exact theme failed (' .. tostring(err) .. '); fallback failed (' .. tostring(fallback_err) .. ')',
        vim.log.levels.ERROR
      )
      return false
    end

    vim.notify(
      'omarchy-theme: exact theme failed (' .. tostring(err) .. '); using its Omarchy palette with aether',
      vim.log.levels.WARN
    )
  end

  M._last_signature = current_signature
  vim.cmd 'redraw!'
  return true
end

local function schedule_reload()
  M._reload_generation = (M._reload_generation or 0) + 1
  local generation = M._reload_generation

  vim.defer_fn(function()
    if generation == M._reload_generation then
      M.reload(false)
    end
  end, 300)
end

local function start_watchers()
  M._watchers = M._watchers or {}

  for _, directory in ipairs(WATCH_DIRS) do
    if vim.fn.isdirectory(directory) == 1 and not M._watchers[directory] then
      local handle = uv.new_fs_event()
      local ok = handle:start(directory, {}, function(err, filename)
        if err then
          return
        end

        if not filename or filename == 'theme' or filename == 'theme.name' or filename == 'neovim.theme' or filename == 'current' then
          vim.schedule(schedule_reload)
        end
      end)

      if ok then
        M._watchers[directory] = handle
      else
        handle:close()
      end
    end
  end

  local group = vim.api.nvim_create_augroup('OmarchyTheme', { clear = true })
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    pattern = THEME_PATHS,
    callback = schedule_reload,
    desc = 'Reload the active Omarchy theme',
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      for _, handle in pairs(M._watchers) do
        if not handle:is_closing() then
          handle:close()
        end
      end
      M._watchers = {}
    end,
  })
end

function M.setup()
  vim.o.termguicolors = true
  M.reload(true)
  start_watchers()

  vim.api.nvim_create_user_command('OmarchyThemeReload', function()
    M.reload(true)
  end, { desc = 'Reload the active Omarchy theme' })
end

return M
