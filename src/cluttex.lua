#!/usr/bin/env texlua
--[[
  Copyright 2016,2018 ARATA Mizuki

  This file is part of ClutTeX.

  ClutTeX is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  ClutTeX is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with ClutTeX.  If not, see <http://www.gnu.org/licenses/>.
]]

-- Standard libraries
local table = table
local os = os
local io = io
local string = string
local ipairs = ipairs
local coroutine = coroutine
local tostring = tostring

-- External libraries (included in texlua)
local filesys = require "lfs"
local md5     = require "md5"
-- local kpse = require "kpse"

-- My own modules
local pathutil    = require "texrunner.pathutil"
local fsutil      = require "texrunner.fsutil"
local shellutil   = require "texrunner.shellutil"
local reruncheck  = require "texrunner.reruncheck"
local luatexinit  = require "texrunner.luatexinit"
local recoverylib = require "texrunner.recovery"
local message     = require "texrunner.message"
local handle_cluttex_options = require "texrunner.handleoption".handle_cluttex_options

-- arguments: input file name, jobname, etc...
local function genOutputDirectory(...)
  -- The name of the temporary directory is based on the path of input file.
  local message = table.concat({...}, "\0")
  local hash = md5.sumhexa(message)
  local tmpdir = os.getenv("TMPDIR") or os.getenv("TMP") or os.getenv("TEMP")
  if tmpdir == nil then
    local home = os.getenv("HOME") or os.getenv("USERPROFILE") or error("environment variable 'TMPDIR' not set!")
    tmpdir = pathutil.join(home, ".latex-build-temp")
  end
  return pathutil.join(tmpdir, 'latex-build-' .. hash)
end

local inputfile, engine, options = handle_cluttex_options(arg)

local jobname = options.jobname or pathutil.basename(pathutil.trimext(inputfile))
assert(jobname ~= "", "jobname cannot be empty")

if options.output_format == nil then
  options.output_format = "pdf"
end
local output_extension
if options.output_format == "dvi" then
  output_extension = engine.dvi_extension or "dvi"
else
  output_extension = "pdf"
end

if options.output == nil then
  options.output = jobname .. "." .. output_extension
end

-- Prepare output directory
if options.output_directory == nil then
  local inputfile_abs = pathutil.abspath(inputfile)
  options.output_directory = genOutputDirectory(inputfile_abs, jobname, options.engine)

  if not fsutil.isdir(options.output_directory) then
    assert(fsutil.mkdir_rec(options.output_directory))

  elseif options.fresh then
    -- The output directory exists and --fresh is given:
    -- Remove all files in the output directory
    if CLUTTEX_VERBOSITY >= 1 then
      message.info("Cleaning '", options.output_directory, "'...")
    end
    assert(fsutil.remove_rec(options.output_directory))
    assert(filesys.mkdir(options.output_directory))
  end

elseif options.fresh then
  message.error("--fresh and --output-directory cannot be used together.")
  os.exit(1)
end

local original_wd = filesys.currentdir()
if options.change_directory then
  local TEXINPUTS = os.getenv("TEXINPUTS") or ""
  filesys.chdir(options.output_directory)
  options.output = pathutil.abspath(options.output, original_wd)
  os.setenv("TEXINPUTS", original_wd .. ":" .. TEXINPUTS)
end

-- Set `max_print_line' environment variable if not already set.
if os.getenv("max_print_line") == nil then
  os.setenv("max_print_line", "65536")
end
-- TODO: error_line, half_error_line
--[[
  According to texmf.cnf:
    45 < error_line < 255,
    30 < half_error_line < error_line - 15,
    60 <= max_print_line.
]]

local function path_in_output_directory(ext)
  return pathutil.join(options.output_directory, jobname .. "." .. ext)
end

local recorderfile = path_in_output_directory("fls")

local tex_options = {
  interaction = options.interaction,
  file_line_error = options.file_line_error,
  halt_on_error = options.halt_on_error,
  synctex = options.synctex,
  output_directory = options.output_directory,
  shell_escape = options.shell_escape,
  shell_restricted = options.shell_restricted,
  jobname = options.jobname,
  fmt = options.fmt,
  extraoptions = options.tex_extraoptions,
}
if options.output_format ~= "pdf" and engine.supports_pdf_generation then
  tex_options.output_format = options.output_format
end

-- Setup LuaTeX initialization script
if engine.is_luatex then
  local initscriptfile = path_in_output_directory("cluttexinit.lua")
  luatexinit.create_initialization_script(initscriptfile, tex_options)
  tex_options.lua_initialization_script = initscriptfile
end

-- Run TeX command (*tex, *latex)
-- should_rerun, newauxstatus = single_run([auxstatus])
local function single_run(auxstatus, iteration)
  local minted = false
  if fsutil.isfile(recorderfile) then
    -- Recorder file already exists
    local filelist = reruncheck.parse_recorder_file(recorderfile, options)
    auxstatus = reruncheck.collectfileinfo(filelist, auxstatus)
    for _,v in ipairs(filelist) do
      if string.match(v.path, "minted/minted%.sty$") then
        minted = true
        break
      end
    end
  else
    -- This is the first execution
    if auxstatus ~= nil then
      message.error("Recorder file was not generated during the execution!")
      os.exit(1)
    end
    auxstatus = {}
  end
  --local timestamp = os.time()

  if minted and not (tex_options.tex_injection and string.find(tex_options.tex_injection,"minted") == nil) then
    tex_options.tex_injection = string.format("%s\\PassOptionsToPackage{outputdir=%s}{minted}", tex_options.tex_injection or "", options.output_directory)
  end

  local current_tex_options, lightweight_mode = tex_options, false
  if iteration == 1 and options.start_with_draft then
    current_tex_options = {}
    for k,v in pairs(tex_options) do
      current_tex_options[k] = v
    end
    if engine.supports_draftmode then
      current_tex_options.draftmode = true
      options.start_with_draft = false
    end
    current_tex_options.interaction = "batchmode"
    lightweight_mode = true
  else
    current_tex_options.draftmode = false
  end

  local command = engine:build_command(inputfile, current_tex_options)

  local recovered = false
  local function recover()
    -- Check log file
    local logfile = assert(io.open(path_in_output_directory("log")))
    local execlog = logfile:read("*a")
    logfile:close()
    recovered = recoverylib.try_recovery{
      execlog = execlog,
      auxfile = path_in_output_directory("aux"),
      options = options,
      original_wd = original_wd,
    }
    return recovered
  end
  coroutine.yield(command, recover) -- Execute the command
  if recovered then
    return true, {}
  end

  local filelist = reruncheck.parse_recorder_file(recorderfile, options)

  if options.makeindex then
    -- Look for .idx files and run MakeIndex
    for _,file in ipairs(filelist) do
      if pathutil.ext(file.path) == "idx" then
        -- Run makeindex if the .idx file is new or updated
        local idxfileinfo = {path = file.path, abspath = file.abspath, kind = "auxiliary"}
        if reruncheck.comparefileinfo({idxfileinfo}, auxstatus) then
          local output_ind = pathutil.replaceext(file.abspath, "ind")
          local idx_dir = pathutil.dirname(file.abspath)
          local makeindex_command = {
            "cd", shellutil.escape(idx_dir), "&&",
            options.makeindex, -- Do not escape options.makeindex to allow additional options
            "-o", pathutil.basename(output_ind),
            pathutil.basename(file.abspath)
          }
          coroutine.yield(table.concat(makeindex_command, " "))
          table.insert(filelist, {path = output_ind, abspath = output_ind, kind = "auxiliary"})
        end
      end
    end
  else
    -- Check log file
    local logfile = assert(io.open(path_in_output_directory("log")))
    local execlog = logfile:read("*a")
    logfile:close()
    if string.match(execlog, "No file [^\n]+%.ind%.") then
      message.diag("You may want to use --makeindex option.")
    end
  end

  local should_rerun, auxstatus = reruncheck.comparefileinfo(filelist, auxstatus)
  return should_rerun or lightweight_mode, auxstatus
end

-- Run (La)TeX (possibly multiple times) and produce a PDF file.
-- This function should be run in a coroutine.
local function do_typeset_c()
  local iteration = 0
  local should_rerun, auxstatus
  repeat
    iteration = iteration + 1
    should_rerun, auxstatus = single_run(auxstatus, iteration)
  until not should_rerun or iteration >= options.max_iterations

  if should_rerun then
    message.warn("LaTeX should be run once more.")
  end

  -- Successful
  if options.output_format == "dvi" or engine.supports_pdf_generation then
    -- Output file (DVI/PDF) is generated in the output directory
    local outfile = path_in_output_directory(output_extension)
    coroutine.yield(fsutil.copy_command(outfile, options.output))
    if #options.dvipdfmx_extraoptions > 0 then
      message.warn("--dvipdfmx-option[s] are ignored.")
    end

  else
    -- DVI file is generated
    local dvifile = path_in_output_directory("dvi")
    local dvipdfmx_command = {"dvipdfmx", "-o", shellutil.escape(options.output)}
    for _,v in ipairs(options.dvipdfmx_extraoptions) do
      table.insert(dvipdfmx_command, v)
    end
    table.insert(dvipdfmx_command, shellutil.escape(dvifile))
    coroutine.yield(table.concat(dvipdfmx_command, " "))
  end
end

local function do_typeset()
  -- Execute the command string yielded by do_typeset_c
  for command, recover in coroutine.wrap(do_typeset_c) do
    message.exec(command)
    local success, termination, status_or_signal = os.execute(command)
    if type(success) == "number" then -- Lua 5.1 or LuaTeX
      local code = success
      success = code == 0
      termination = nil
      status_or_signal = code
    end
    if not success and not (recover and recover()) then
      if termination == "exit" then
        message.error("Command exited abnormally: exit status ", tostring(status_or_signal))
      elseif termination == "signal" then
        message.error("Command exited abnormally: signal ", tostring(status_or_signal))
      else
        message.error("Command exited abnormally: ", tostring(status_or_signal))
      end
      return false, termination, status_or_signal
    end
  end
  -- Successful
  if CLUTTEX_VERBOSITY >= 1 then
    message.info("Command exited successfully")
  end
  return true
end

if options.watch then
  -- Watch mode
  local success, status = do_typeset()
  local filelist = reruncheck.parse_recorder_file(recorderfile, options)
  local input_files_to_watch = {}
  for _,fileinfo in ipairs(filelist) do
    if fileinfo.kind == "input" then
      table.insert(input_files_to_watch, fileinfo.abspath)
    end
  end
  local fswatch_command = {"fswatch", "--event=Updated", "--"}
  for _,path in ipairs(input_files_to_watch) do
    table.insert(fswatch_command, shellutil.escape(path))
  end
  if CLUTTEX_VERBOSITY >= 1 then
    message.exec(table.concat(fswatch_command, " "))
  end
  local fswatch = assert(io.popen(table.concat(fswatch_command, " "), "r"))
  for l in fswatch:lines() do
    local found = false
    for _,path in ipairs(input_files_to_watch) do
      if l == path then
        found = true
        break
      end
    end
    if found then
      local success, status = do_typeset()
      if not success then
        -- Not successful
      end
    end
  end

else
  -- Not in watch mode
  local success, status = do_typeset()
  if not success then
    os.exit(1)
  end
end
