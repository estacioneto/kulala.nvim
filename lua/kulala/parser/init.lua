local FS = require("kulala.utils.fs")
local GLOBALS = require("kulala.globals")
local CONFIG = require("kulala.config")
local DYNAMIC_VARS = require("kulala.parser.dynamic_vars")
local STRING_UTILS = require("kulala.utils.string")
local TABLE_UTILS = require("kulala.utils.table")
local ENV_PARSER = require("kulala.parser.env")
local PLUGIN_TMP_DIR = FS.get_plugin_tmp_dir()
local CLIENT_PIPE = require("kulala.client_pipe")
local M = {}

local function parse_string_variables(str, variables)
  local env = ENV_PARSER.get_env()
  local function replace_placeholder(variable_name)
    local value = ""
    -- If the variable name contains a `$` symbol then try to parse it as a dynamic variable
    if variable_name:find("^%$") then
      local variable_value = DYNAMIC_VARS.read(variable_name)
      if variable_value then
        value = variable_value
      end
    elseif variables[variable_name] then
      value = variables[variable_name]
    elseif env[variable_name] then
      value = env[variable_name]
    else
      value = "{{" .. variable_name .. "}}"
      vim.notify(
        "The variable '"
          .. variable_name
          .. "' was not found in the document or in the environment. Returning the string as received ..."
      )
    end
    if type(value) == "string" then
      ---@cast variable_value string
      value = value:gsub('"', "")
    end
    return value
  end
  local result = str:gsub("{{(.-)}}", replace_placeholder)
  return result
end

local function parse_headers(headers, variables)
  local h = {}
  for key, value in pairs(headers) do
    h[key] = parse_string_variables(value, variables)
  end
  return h
end

local function encode_url_params(url)
  local url_parts = {}
  local url_parts = vim.split(url, "?")
  local url = url_parts[1]
  local query = url_parts[2]
  local query_parts = {}
  if query then
    query_parts = vim.split(query, "&")
  end
  local query_params = ""
  for _, query_part in ipairs(query_parts) do
    local query_param = vim.split(query_part, "=")
    query_params = query_params .. "&" .. STRING_UTILS.url_encode(query_param[1]) .. "=" .. STRING_UTILS.url_encode(query_param[2])
  end
  if query_params ~= "" then
    return url .. "?" .. query_params:sub(2)
  end
  return url
end

local function parse_url(url, variables)
  url = parse_string_variables(url, variables)
  url = encode_url_params(url)
  url = url:gsub('"', "")
  return url
end

local function parse_body(body, variables)
  if body == nil then
    return nil
  end
  return parse_string_variables(body, variables)
end

M.get_document = function()
  local content_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local content = table.concat(content_lines, "\n")
  local variables = {}
  local requests = {}
  local blocks = vim.split(content, "\n###\n", { plain = true, trimempty = false })
  local line_offset = 0
  for _, block in ipairs(blocks) do
    local is_request_line = true
    local is_body_section = false
    local lines = vim.split(block, "\n", { plain = true, trimempty = false })
    local block_line_count = #lines
    local request = {
      headers = {},
      body = nil,
      start_line = line_offset + 1,
      block_line_count = block_line_count,
      lines_length = #lines,
      variables = {},
    }
    for _, line in ipairs(lines) do
      line = vim.trim(line)
      if line:sub(1, 1) == "#" then
        -- It's a comment, skip it
      elseif line == "" and is_body_section == false then
        -- Skip empty lines
        if is_request_line == false then
          is_body_section = true
        end
      elseif line:match("^@%w+") then
        -- Variable
        -- Variables are defined as `@variable_name=value`
        -- The value can be a string, a number or boolean
        local variable_name, variable_value = line:match("^%@(%w+)%s*=%s*(.*)$")
        if variable_name and variable_value then
          -- remove the @ symbol from the variable name
          variable_name = variable_name:sub(1)
          variables[variable_name] = parse_string_variables(variable_value, variables)
        end
      elseif is_body_section == true and #line > 0 then
        if request.body == nil then
          request.body = ""
        end
        if line:find("^<") then
          if request.headers["content-type"] ~= nil and request.headers["content-type"]:find("^multipart/form%-data") then
            request.body = request.body .. line
          else
            local file_path = vim.trim(line:sub(2))
            local contents = FS.read_file(file_path)
            if contents then
              request.body = request.body .. contents
            else
              vim.notify("The file '" .. file_path .. "' was not found. Skipping ...", "warn")
            end
          end
        else
          if request.headers["content-type"] ~= nil and request.headers["content-type"]:find("^multipart/form%-data") then
            request.body = request.body .. line .. "\r\n"
          else
            request.body = request.body .. line
          end
        end
      elseif is_request_line == false and line:match("^(.+):%s*(.*)$") then
        -- Header
        -- Headers are defined as `key: value`
        -- The key is case-insensitive
        -- The key can be anything except a colon
        -- The value can be a string or a number
        -- The value can be a variable
        -- The value can be a dynamic variable
        -- variables are defined as `{{variable_name}}`
        -- dynamic variables are defined as `{{$variable_name}}`
        local key, value = line:match("^(.+):%s*(.*)$")
        if key and value then
          request.headers[key:lower()] = value
        end
      elseif is_request_line == true then
        -- Request line (e.g., GET http://example.com HTTP/1.1)
        -- Split the line into method, URL and HTTP version
        -- HTTP Version is optional
        local parts = vim.split(line, " ", true)
        request.method = parts[1]
        request.url = parts[2]
        if parts[3] then
          request.http_version = parts[3]:gsub("HTTP/", "")
        end
        is_request_line = false
      end
    end
    if request.body ~= nil then
      request.body = vim.trim(request.body)
    end
    request.end_line = line_offset + block_line_count
    line_offset = request.end_line + 1 -- +1 for the '###' separator line
    table.insert(requests, request)
  end
  return variables, requests
end

M.get_request_at_cursor = function(requests)
  local cursor_pos = vim.api.nvim_win_get_cursor(0) -- {line, col}
  local cursor_line = cursor_pos[1]
  for _, request in ipairs(requests) do
    if cursor_line >= request.start_line and cursor_line <= request.end_line then
      return request
    end
  end
  return nil
end

M.get_previous_request = function(requests)
  local cursor_pos = vim.api.nvim_win_get_cursor(0) -- {line, col}
  local cursor_line = cursor_pos[1]
  for i, request in ipairs(requests) do
    if cursor_line >= request.start_line and cursor_line <= request.end_line then
      if i > 1 then
        return requests[i - 1]
      end
    end
  end
  return nil
end

M.get_next_request = function(requests)
  local cursor_pos = vim.api.nvim_win_get_cursor(0) -- {line, col}
  local cursor_line = cursor_pos[1]
  for i, request in ipairs(requests) do
    if cursor_line >= request.start_line and cursor_line <= request.end_line then
      if i < #requests then
        return requests[i + 1]
      end
    end
  end
  return nil
end

---Parse a request and return the request on itself, its headers and body
---@return Request Table containing the request data
function M.parse()
  local res = {
    method = "GET",
    url = {},
    headers = {},
    body = {},
    cmd = {},
    client_pipe = nil,
    ft = "text",
  }

  local document_variables, requests = M.get_document()
  local req = M.get_request_at_cursor(requests)

  res.url = parse_url(req.url, document_variables)
  res.method = req.method
  res.http_version = req.http_version
  res.headers = parse_headers(req.headers, document_variables)
  res.body = parse_body(req.body, document_variables)

  -- We need to append the contents of the file to
  -- the body if it is a POST request,
  -- or to the URL itself if it is a GET request
  if req.body_type == "input" then
    if req.body_path:match("%.graphql$") or req.body_path:match("%.gql$") then
      local graphql_file = io.open(req.body_path, "r")
      local graphql_query = graphql_file:read("*a")
      graphql_file:close()
      if res.method == "POST" then
        res.body = "{ \"query\": \"" .. graphql_query .."\" }"
      else
        graphql_query = STRING_UTILS.url_encode(STRING_UTILS.remove_extra_space(STRING_UTILS.remove_newline(graphql_query)))
        res.graphql_query = STRING_UTILS.url_decode(graphql_query)
        res.url = res.url .. "?query=" .. graphql_query
      end
    else
      local file = io.open(req.body_path, "r")
      local body = file:read("*a")
      file:close()
      res.body = body
    end
  end

  local client_pipe = nil

  -- build the command to exectute the request
  table.insert(res.cmd, "curl")
  table.insert(res.cmd, "-s")
  table.insert(res.cmd, "-D")
  table.insert(res.cmd, PLUGIN_TMP_DIR .. "/headers.txt")
  table.insert(res.cmd, "-o")
  table.insert(res.cmd, PLUGIN_TMP_DIR .. "/body.txt")
  table.insert(res.cmd, "-X")
  table.insert(res.cmd, res.method)
  if res.headers["content-type"] ~= nil then
    if res.headers["content-type"] == "text/plain" then
      table.insert(res.cmd, "--data-raw")
      table.insert(res.cmd, res.body)
    elseif res.headers["content-type"]:match("application/[^/]+json") then
      table.insert(res.cmd, "--data")
      table.insert(res.cmd, res.body)
    elseif res.headers["content-type"] == "application/x-www-form-urlencoded" then
      table.insert(res.cmd, "--data")
      table.insert(res.cmd, res.body)
    elseif res.headers["content-type"]:find("^multipart/form%-data") then
      table.insert(res.cmd, "--data-binary")
      table.insert(res.cmd, res.body)
    end
  end
  for key, value in pairs(res.headers) do
    -- if key starts with `http-client-` then it is a special header
    if key:find("^http%-client%-") then
      if key == "http-client-pipe" then
        res.client_pipe = value
      end
    else
      table.insert(res.cmd, "-H")
      table.insert(res.cmd, key ..":".. value)
    end
  end
  if res.http_version ~= nil then
    table.insert(res.cmd, "--http" .. res.http_version)
  end
  table.insert(res.cmd, "-A")
  table.insert(res.cmd, "kulala.nvim/".. GLOBALS.VERSION)
  for _, additional_curl_option in pairs(CONFIG.get().additional_curl_options) do
    table.insert(res.cmd, additional_curl_option)
  end
  table.insert(res.cmd, res.url)
  if res.headers['accept'] == "application/json" then
    res.ft = "json"
  elseif res.headers['accept'] == "application/xml" then
    res.ft = "xml"
  elseif res.headers['accept'] == "text/html" then
    res.ft = "html"
  end
  FS.delete_file(PLUGIN_TMP_DIR .. "/headers.txt")
  FS.delete_file(PLUGIN_TMP_DIR .. "/body.txt")
  FS.delete_file(PLUGIN_TMP_DIR .. "/ft.txt")
  FS.write_file(PLUGIN_TMP_DIR .. "/ft.txt", res.ft)
  if CONFIG.get().debug then
    FS.write_file(PLUGIN_TMP_DIR .. "/request.txt", table.concat(res.cmd, " "))
  end
  return res
end

return M
