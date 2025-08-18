local Async = require("kulala.utils.async")
local CONFIG = require("kulala.config")
local DB = require("kulala.db")
local FS = require("kulala.utils.fs")
local Float = require("kulala.ui.float")
local GLOBALS = require("kulala.globals")
local Logger = require("kulala.logger")
local Shell = require("kulala.cmd.shell_utils")

local M = {}

local NPM_EXISTS = vim.fn.executable("npm") == 1
local NODE_EXISTS = vim.fn.executable("node") == 1

local NPM_BIN = vim.fn.exepath("npm")
local NODE_BIN = vim.fn.exepath("node")

local SCRIPTS_DIR = FS.get_scripts_dir()
local REQUEST_SCRIPTS_DIR = FS.get_request_scripts_dir()
local SCRIPTS_BUILD_DIR = FS.get_tmp_scripts_build_dir()
local SCRIPTS_ENGINE_LIB_DIR = FS.get_js_engine_lib_dir()

local BASE_DIR = FS.join_paths(SCRIPTS_DIR, "engines", "javascript", "lib")

---Generates the base file path for a given script type and file extension.
---@param script_type string The script type (e.g., "pre_request_client_only").
---@param file_extension string The file extension (e.g., ".js" or ".mjs").
---@return string The generated base file path.
local function generate_base_file_path(script_type, file_extension)
  return FS.join_paths(SCRIPTS_BUILD_DIR, "dist", script_type .. file_extension)
end

local FILE_MAPPING = {
  [".js"] = {
    pre_request_client_only = generate_base_file_path("pre_request_client_only", ".js"),
    pre_request = generate_base_file_path("pre_request", ".js"),
    post_request_client_only = generate_base_file_path("post_request_client_only", ".js"),
    post_request = generate_base_file_path("post_request", ".js"),
  },
  [".mjs"] = {
    pre_request_client_only = generate_base_file_path("pre_request_client_only", ".mjs"),
    pre_request = generate_base_file_path("pre_request", ".mjs"),
    post_request_client_only = generate_base_file_path("post_request_client_only", ".mjs"),
    post_request = generate_base_file_path("post_request", ".mjs"),
  },
}

local function get_build_ver()
  local package = FS.read_json(BASE_DIR .. "/package.json")
  return package and package.version or ""
end

local is_uptodate = function()
  DB.session.js_build_ver_repo = DB.session.js_build_ver_repo or get_build_ver()

  return DB.settings.js_build_ver_local == DB.session.js_build_ver_repo
    and FS.file_exists(FILE_MAPPING[".js"].pre_request)
    and FS.file_exists(FILE_MAPPING[".js"].post_request)
    and FS.file_exists(FILE_MAPPING[".mjs"].pre_request)
    and FS.file_exists(FILE_MAPPING[".mjs"].post_request)
end

---@param wait boolean|nil -- wait to complete
M.install_dependencies = function(wait)
  if is_uptodate() then return true end
  if vim.g.kulala_js_installing then return false end

  local cmd = require("kulala.cmd")
  vim.g.kulala_js_installing = true

  Logger.info("Javascript dependencies not found or are out of date.")
  local progress = Float.create_progress_float("Installing JS dependencies...")

  _ = not wait and cmd.queue:pause()

  local co, cmd_install, cmd_build
  co = coroutine.create(function()
    FS.copy_dir(BASE_DIR, SCRIPTS_BUILD_DIR)

    cmd_install = Shell.run(
      { NPM_BIN, "clean-install", "--prefix", SCRIPTS_BUILD_DIR },
      { err_msg = "JS dependencies install failed: ", on_error = progress.hide },
      function()
        Async.co_resume(co)
      end
    )
    Async.co_yield(co)

    cmd_build = Shell.run(
      { NPM_BIN, "run", "build", "--prefix", SCRIPTS_BUILD_DIR },
      { err_msg = "JS dependencies build failed: ", on_error = progress.hide },
      function()
        Async.co_resume(co)
      end
    )
    Async.co_yield(co)

    DB.settings:write { js_build_ver_local = DB.session.js_build_ver_repo }
    vim.g.kulala_js_installing = false

    progress.hide()
    Logger.info("Javascript dependencies installed")

    _ = not wait and cmd.queue:resume()
  end)

  Async.co_resume(co)

  _ = wait and cmd_install and cmd_install:wait()
  if not cmd_build then return false end

  _ = wait and cmd_build:wait()

  return false
end

---@param script_type "pre_request_client_only" | "pre_request" | "post_request_client_only" | "post_request"
---@param is_external_file boolean -- is external file
---@param script_data string[]|string -- either list of inline scripts or path to script file
---@return string|nil, string|nil
local generate_one = function(script_type, is_external_file, script_data)
  local userscript

  local output_file_extension = type(script_data) == "string" and script_data:match("%.mjs$") and ".mjs" or ".js"
  local base_file_path = FILE_MAPPING[output_file_extension] and FILE_MAPPING[output_file_extension][script_type]
  if not base_file_path then return end

  local base_file = FS.read_file(base_file_path)
  if not base_file then return end

  local script_cwd
  local buf_dir = FS.get_current_buffer_dir()
  if is_external_file then
    assert(type(script_data) == "string", "script_data must be a string when is_external_file is true")

    -- if script_data starts with ./ or ../, it is a relative path
    if string.match(script_data, "^%./") or string.match(script_data, "^%../") then
      local local_script_path = script_data:gsub("^%./", "")
      script_data = FS.join_paths(buf_dir, local_script_path)
    end

    if FS.file_exists(script_data) then
      script_cwd = FS.get_dir_by_filepath(script_data)

      local temp_file_path = FS.join_paths(REQUEST_SCRIPTS_DIR, FS.get_uuid() .. output_file_extension)
      local cmd = {
        NODE_BIN,
        NPM_BIN,
        "--prefix",
        SCRIPTS_ENGINE_LIB_DIR,
        "exec",
        "--",
        "rollup",
        "--input",
        script_data,
        "--file",
        temp_file_path,
      }

      local output, co
      co = coroutine.create(function()
        output = Shell.run(cmd, { err_msg = "Rollup build failed", verbose = true }, function()
          Async.co_resume(co)
        end)
        Async.co_yield(co)
      end)

      Async.co_resume(co)

      output:wait()
      if output and output.stderr and not output.stderr:match("^%s*$") then
        Logger.error(("Rollup errors: %s"):format(output.stderr))
        userscript = ""
      else
        userscript = FS.read_file(temp_file_path)
        vim.print(FS.file_exists(temp_file_path))
        FS.delete_file(temp_file_path) -- Delete the temp file after reading
      end
    else
      Logger.error(("Could not read the %s script: %s"):format(script_type, script_data))
      userscript = ""
    end
  end

  script_cwd = script_cwd or buf_dir
  userscript = userscript or type(script_data) == "table" and vim.fn.join(script_data, "\n") or ""
  base_file = base_file .. "\n" .. userscript

  local uuid = FS.get_uuid()
  local script_path = FS.join_paths(REQUEST_SCRIPTS_DIR, uuid .. output_file_extension)

  FS.write_file(script_path, base_file)

  return script_path, script_cwd
end

---@class JsScripts
---@field path string -- path to script
---@field cwd string -- current working directory

---@param script_type "pre_request_client_only" | "pre_request" | "post_request_client_only" | "post_request" -- type of script
---@param scripts_data ScriptData -- data for scripts
---@return JsScripts<table> -- paths to scripts
local generate_all = function(script_type, scripts_data)
  local scripts = {}
  local script_path, script_cwd

  for _, script_data in ipairs(scripts_data.files) do
    script_path, script_cwd = generate_one(script_type, true, script_data)
    if script_path and script_cwd then table.insert(scripts, { path = script_path, cwd = script_cwd }) end
  end

  script_path, script_cwd = generate_one(script_type, false, scripts_data.inline)

  local pos = scripts_data.priority == "inline" and 1 or (#scripts + 1)
  if script_path and script_cwd then table.insert(scripts, pos, { path = script_path, cwd = script_cwd }) end

  return scripts
end

local scripts_is_empty = function(scripts_data)
  return #scripts_data.inline == 0 and #scripts_data.files == 0
end

local function default_node_path_resolver(_, script_file_dir, _)
  local path =
    vim.fs.find({ "node_modules" }, { path = script_file_dir, limit = 1, type = "directory", upward = true })[1]
  return path or FS.join_paths(script_file_dir, "node_modules")
end

---@param type "pre_request_client_only" | "pre_request" | "post_request_client_only" | "post_request" -- type of script
---@param data ScriptData
---@return boolean|nil status
M.run = function(type, data)
  local files = { ["pre_request"] = GLOBALS.SCRIPT_PRE_OUTPUT_FILE, ["post_request"] = GLOBALS.SCRIPT_POST_OUTPUT_FILE }
  local disable_output = CONFIG.get().disable_script_print_output

  if scripts_is_empty(data) then return end
  if not NODE_EXISTS then return Logger.error("node not found, please install nodejs") end
  if not NPM_EXISTS then return Logger.error("npm not found, please install nodejs") end

  if not M.install_dependencies() then return end

  local scripts = generate_all(type, data)
  if #scripts == 0 then return end

  for _, script in ipairs(scripts) do
    local buf_dir = FS.get_current_buffer_dir()
    local node_path_resolver = CONFIG.get().scripts.node_path_resolver or default_node_path_resolver

    local output = vim
      .system(
        { NODE_BIN, script.path },
        { cwd = script.cwd, env = { NODE_PATH = node_path_resolver(buf_dir, script.cwd, data) } }
      )
      :wait()

    if output.stderr and not output.stderr:match("^%s*$") then
      if not disable_output then Logger.error(("Errors while running JS script: %s"):format(output.stderr)) end
      FS.write_file(files[type], output.stderr)
    end

    if output.stdout and not output.stdout:match("^%s*$") then
      _ = not disable_output and Logger.info(output.stdout, { title = "Kulala JS Script Output" })
      if not FS.write_file(files[type], output.stdout) then return Logger.error("write " .. files[type] .. " fail") end
    end
  end

  return true
end

return M
