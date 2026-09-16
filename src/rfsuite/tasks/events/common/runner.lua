-- Generic sequential tasks runner for RFSuite events
-- Supports shared state between Tool and Widget contexts
local M = {}

-- This has to stay ABOVE the give-up of anything a task puts on the MSP queue, or the runner
-- re-queues a task whose request is still in flight and the queue ends up holding two copies of
-- the same read. The queue's own give-up is (maxRetries + 1) x the message timeout, and its
-- transport-wide maxRetries is 5 on CRSF -- so a 5 s read there ran for 30 s against this 25 s.
-- The connect reads now carry a maxRetries of their own for exactly this reason.
local DEFAULT_TASK_TIMEOUT_SECONDS = 25
local MAX_RETRIES = 3
local RETRY_BACKOFF_SECONDS = 1

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

-- getTime() is hundredths of a second since boot and is always available; the os
-- library is not opened by the Lua state at all, so os.clock() alone leaves `now`
-- at 0 and every elapsed-time test below reads as "no time has passed".
local function nowSeconds()
  if type(getTime) == "function" then
    local ok, v = pcall(getTime)
    if ok and type(v) == "number" then return v / 100 end
  end
  if type(os) == "table" and type(os.clock) == "function" then return os.clock() end
  return 0
end

function M.new(category)
  local runner = {}
  local BASE_PATH = "tasks/events/" .. category .. "/tasks/"
  local COMMON_PATH = "tasks/events/common/"
  local MANIFEST_PATH = "tasks/events/" .. category .. "/manifest.lua"

  local tasksQueue = {}
  local tasksLoaded = false
  local tasksDoneLogged = false

  local Log = nil
  local Env = nil
  local lastStartedTask = nil

  local function ensureEnv()
    if not Env then Env = loadModule("lib/env.lua") end
  end

  local function loadManifest()
    if Log == nil then Log = loadModule("lib/log.lua") or false end
    local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/" .. MANIFEST_PATH, "t")
    if type(chunk) ~= "function" then
      if type(Log) == "table" and type(Log.emit) == "function" then pcall(Log.emit, "rfsuite.tasks." .. category, "manifest missing: " .. tostring(MANIFEST_PATH), "debug") end
      tasksLoaded = true
      return
    end
    local ok, manifest = pcall(chunk)
    if not ok or type(manifest) ~= "table" then
      if type(Log) == "table" and type(Log.emit) == "function" then pcall(Log.emit, "rfsuite.tasks." .. category, "invalid manifest: " .. tostring(MANIFEST_PATH), "debug") end
      tasksLoaded = true
      return
    end

    for _, entry in ipairs(manifest) do
      local name = nil
      local context = "both"

      if type(entry) == "table" then
        name = entry.name
        context = entry.context or "both"
      else
        name = entry
      end

      if name then
        tasksQueue[#tasksQueue + 1] = {
          name = name,
          context = context,
          path = BASE_PATH .. name .. ".lua",
          module = nil,
          initialized = false,
          complete = false,
          failed = false,
          attempts = 0,
          nextEligibleAt = 0,
          startTime = nil,
        }
      end
    end

    tasksLoaded = true
  end

  local function clearTaskEntries()
    for i = #tasksQueue, 1, -1 do tasksQueue[i] = nil end
    tasksDoneLogged = false
  end

  local function ensureTaskModule(task)
    if not task or not task.path then return nil, "invalid task" end
    if task.module then return task.module end
    local chunk, err = loadScript("/SCRIPTS/TOOLS/rfsuite-core/" .. task.path, "t")
    if type(chunk) ~= "function" then
      -- Fallback to common path if not already using it and local load failed
      if not string.find(task.path, COMMON_PATH, 1, true) then
        local commonPath = COMMON_PATH .. task.name .. ".lua"
        chunk, err = loadScript("/SCRIPTS/TOOLS/rfsuite-core/" .. commonPath, "t")
      end
    end

    if type(chunk) ~= "function" then return nil, "load failed: " .. tostring(err) end
    local ok, mod = pcall(chunk)
    if not ok or type(mod) ~= "table" then return nil, "invalid module: " .. tostring(mod) end
    task.module = mod
    return mod
  end

  local function releaseTaskModule(task, runReset)
    if not task or not task.module then return end
    local mod = task.module
    if runReset and type(mod.reset) == "function" then pcall(mod.reset) end
    task.module = nil
  end

  local function resetQueuesAndState()
    for i = 1, #tasksQueue do
      local t = tasksQueue[i]
      releaseTaskModule(t, true)
      t.initialized = false
      t.complete = false
      t.failed = false
      t.attempts = 0
      t.nextEligibleAt = 0
      t.startTime = nil
    end
    tasksDoneLogged = false
  end

  local function findNextEligibleTask(currentEnv)
    for i = 1, #tasksQueue do
      local t = tasksQueue[i]
      if not t.complete and not t.failed then
        local eligible = false
        if t.context == "both" then
          eligible = true
        elseif t.context == "tool" and currentEnv == "tool" then
          eligible = true
        elseif t.context == "widget" and currentEnv == "widget" then
          eligible = true
        end

        if eligible then
          return t, i
        end
      end
    end
    return nil
  end

  function runner.findTasks()
    if tasksLoaded then return end
    clearTaskEntries()
    loadManifest()
  end

  function runner.resetAllTasks()
    resetQueuesAndState()
  end

  function runner.reset()
    resetQueuesAndState()
  end

  function runner.wakeup(args)
    if Log == nil then Log = loadModule("lib/log.lua") or false end
    if not tasksLoaded then runner.findTasks() end
    if #tasksQueue == 0 then return end

    ensureEnv()
    local currentEnv = Env and Env.get() or "tool"
    local task, idx = findNextEligibleTask(currentEnv)

    if not task then
      if not tasksDoneLogged then
        if Log and type(Log.emit) == "function" then pcall(Log.emit, "rfsuite.tasks." .. category, "all eligible " .. category .. " tasks complete for " .. currentEnv, "debug") end
        tasksDoneLogged = true
      end
      return
    end

    local now = nowSeconds()

    if task.nextEligibleAt and task.nextEligibleAt > now then return end

    if not task.initialized then task.initialized = true; task.startTime = now end

    local module, err = ensureTaskModule(task)
    if not module then
      task.failed = true
      task.startTime = nil
      task.nextEligibleAt = 0
      if Log and type(Log.emit) == "function" then pcall(Log.emit, "rfsuite.tasks." .. category, "failed to load task " .. tostring(task.name) .. ": " .. tostring(err or "?"), "info") end
      return
    end

    if type(module.wakeup) == "function" then
      -- Said BEFORE the call, and into the step file as well as the log. The runner reports
      -- tasks it has finished; a task that never finishes is reported by nothing, and the
      -- connect chain is where a start with a flight controller attached spends its time. The
      -- step file is closed immediately, so it survives a wakeup that does not come back.
      -- Only when the task CHANGES. wakeup runs once per pass and a task stays eligible until
      -- it reports itself complete, so a line per call was a third of the file and said the
      -- same thing thirty times. What a hang looks like is unaffected: the last name written
      -- with no `completed` after it is the one that never returned, and the step file -- which
      -- is rewritten every pass and carries a counter -- is where the repetition is visible.
      if lastStartedTask ~= task.name then
        lastStartedTask = task.name
        if Log and type(Log.emitf) == "function" then
          pcall(Log.emitf, "rfsuite.tasks." .. category, "debug", "start task %s attempt=%s",
            tostring(task.name), tostring(task.attempts or 1))
        end
      end
      local step = _G.rfsuite and _G.rfsuite.logStep
      if type(step) == "function" then
        pcall(step, "task " .. category .. ":" .. tostring(task.name))
      end
      pcall(module.wakeup, args)
    end

    if module.isComplete and module.isComplete() then
      task.complete = true
      task.startTime = nil
      task.nextEligibleAt = 0
      releaseTaskModule(task, false)
      if Log and type(Log.emit) == "function" then pcall(Log.emit, "rfsuite.tasks." .. category, "completed task " .. tostring(task.name), "debug") end
      return
    end

    local timeout = DEFAULT_TASK_TIMEOUT_SECONDS
    if task.startTime and (now - task.startTime) > timeout then
      task.attempts = (task.attempts or 0) + 1
      if task.attempts <= MAX_RETRIES then
        local backoff = RETRY_BACKOFF_SECONDS * (2 ^ (task.attempts - 1))
        task.nextEligibleAt = now + backoff
        task.initialized = false
        task.startTime = nil
        -- The module instance goes with the attempt, or the next one sends nothing. Every task
        -- latches its request in a module-local flag and returns on its first line while that
        -- flag is set, so a re-queue that kept the instance re-ran a wakeup that does nothing
        -- and the line below announced work that never happened. Releasing it with its reset is
        -- what the complete and the give-up branches around this one already do.
        releaseTaskModule(task, true)
        if Log and type(Log.emit) == "function" then pcall(Log.emit, "rfsuite.tasks." .. category, string.format("Task '%s' timed out. Re-queueing (attempt %d/%d) in %.1fs.", task.name, task.attempts, MAX_RETRIES, backoff), "info") end
      else
        task.failed = true
        task.startTime = nil
        releaseTaskModule(task, false)
        if Log and type(Log.emit) == "function" then pcall(Log.emit, "rfsuite.tasks." .. category, string.format("Task '%s' failed after %d attempts. Skipping.", task.name, MAX_RETRIES), "info") end
      end
    end
  end

  function runner.active()
    ensureEnv()
    local currentEnv = Env and Env.get() or "tool"
    return findNextEligibleTask(currentEnv) ~= nil
  end

  function runner.getPendingTaskName()
    ensureEnv()
    local currentEnv = Env and Env.get() or "tool"
    local task = findNextEligibleTask(currentEnv)
    if task and type(task.name) == "string" and task.name ~= "" then
      return task.name
    end
    return nil
  end

  function runner.getProgress()
    ensureEnv()
    local currentEnv = Env and Env.get() or "tool"
    local total = 0
    local done = 0
    for i = 1, #tasksQueue do
      local t = tasksQueue[i]
      local eligible = false
      if t.context == "both" then
        eligible = true
      elseif t.context == "tool" and currentEnv == "tool" then
        eligible = true
      elseif t.context == "widget" and currentEnv == "widget" then
        eligible = true
      end
      if eligible then
        total = total + 1
        if t.complete or t.failed then
          done = done + 1
        end
      end
    end
    return { done = done, total = total }
  end

  return runner
end

return M
