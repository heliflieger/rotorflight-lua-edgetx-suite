-- The Settings > Dashboard > In-Flight Tuning page's flight controller action, on its own.
--
-- It is a module rather than part of page.lua for one measured reason. The page is opened on a
-- radio whose tool sits near its heap ceiling -- the pilot's froze there with 134 kB free -- and
-- everything a page's chunk holds is paid on ENTRY, whether the pilot presses anything or not.
-- This half is never needed to DRAW the page: it is wanted only after the button is pressed, and
-- it drags widgets/dashboard/inflight/fcsetup.lua and the whole adjustment function table behind
-- it. So it is read off the card then, and not before.
--
-- Everything it touches comes in through the context table: the settings module its own text
-- helper is built from, the settings being edited, the page state it reports into, and the repaint
-- it asks for. It reaches for nothing on its own except the two modules it drives.

local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

local FcSetup = nil
local ConfirmDialog = nil

-- This file's text helper. A module-level local because the sentence builders below are
-- module-level too: they are built once per load rather than once per press.
local t = nil

--- The helper, built HERE from the page key rather than borrowed from the page's context.
--
-- .vscode/scripts/precompile_i18n.py derives a file's key prefix from the file it REWRITES, and
-- takes it from a pageT call in that file. A module whose `t` arrives from somewhere else has no
-- prefix to derive, so every one of the t(i18n, ...) calls below survives precompilation as a
-- runtime lookup -- and a packaged install carries no locale bundle for one to resolve against
-- (bin/package/build_package.py writes the sources and the fonts, not i18n/), so every string in
-- this file would fall back to its English text whatever the radio's language is. Their
-- check_translations.py cannot see it either: the calls name literal keys, which is what it looks
-- for, in a file it cannot work out a prefix for.
--
-- The page key is the one app/pages/setup/controls/inflight/page.lua names, since these strings
-- live in that page's own block.
local function textHelper(ctx)
  local Common = ctx.common
  if type(Common) == "table" and type(Common.pageT) == "function" then
    return Common.pageT("setup_controls_inflight")
  end
  -- Nothing to build one from: the caller's own, which resolves the same keys the same way. What
  -- is lost is the precompilation, not the lookup.
  return ctx.t
end

-- How many slots are named one by one in the question. Past this the rest are counted instead: a
-- confirmation nobody reads to the end is not a confirmation.
local SLOT_LINES_SHOWN = 6

--- Why the flight controller cannot be read or written, in words.
--
-- Every reason the writer can answer with is named. A reason with no sentence of its own still
-- reaches the screen, appended to the general one, because a code the pilot can read out is worth
-- more than a polished sentence that hides which of eight things went wrong.
local function refusalText(i18n, reason)
  if reason == "armed" then
    return t(i18n, "fc_armed", "The model is armed.")
  elseif reason == "arm_unknown" then
    return t(i18n, "fc_arm_unknown", "The arming state cannot be read, so nothing is written.")
  elseif reason == "no_link" then
    return t(i18n, "fc_no_link", "No link to the flight controller.")
  elseif reason == "no_sensors" or reason == "no_api" then
    return t(i18n, "fc_unavailable", "This build cannot reach the flight controller.")
  elseif reason == "old_api" then
    return t(i18n, "fc_old_api", "This flight controller does not answer the paged reads.")
  elseif reason == "same_channel" then
    return t(i18n, "plan_same_channel", "The two channels have to be different.")
  elseif reason == "ena_channel" or reason == "adj_channel" then
    return t(i18n, "fc_channel", "No receiver channel of the flight controller reaches that channel.")
  end
  return t(i18n, "fc_failed", "The flight controller write failed") .. ": " .. tostring(reason)
end

--- What the board carries today, held against the standard set.
--
-- The verdict comes from the function-id reply and from nothing else, so what it can say is which
-- slots name the right FUNCTION. "Already carries this set" would overstate that -- a slot naming
-- the right function can still watch the wrong channel through the wrong window -- so the matching
-- case is worded at the level it was actually measured at.
local function compareText(i18n, compare)
  local verdict = (type(compare) == "table") and compare.verdict or nil
  if verdict == "match" then
    return t(i18n, "fc_board_functions_match",
      "Every slot of this set already names the function it should.")
  elseif verdict == "empty" then
    return t(i18n, "fc_board_empty", "The flight controller carries none of this set.")
  elseif verdict == "differ" then
    return string.format("%s %d", t(i18n, "fc_board_differs", "Slots differing from this set:"),
      compare.count)
  end
  return t(i18n, "fc_board_unknown", "The flight controller has not been compared.")
end

--- The question the pilot answers, built from the plan and not from what the page intended.
--
-- The counts come first because they are what cannot be taken back, and the overwrites get a list
-- of their own rather than a number in a row: a slot being overwritten is a parameter moving
-- somewhere else on the screen, or a control the pilot flies with that stops working, and the
-- function each of them holds today is the only thing on this screen he can recognise it by.
--
-- What the question no longer claims is which CHANNEL each of those slots watches. That was worth
-- thirty-six extra round trips before the plan and is worth one sentence in it, so it is a
-- sentence saying it was not looked at.
local function question(i18n, plan)
  local lines = {}
  lines[#lines + 1] = compareText(i18n, plan.compare)
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("%s %d (%d..%d)",
    t(i18n, "fc_write_slots", "Adjustment slots written:"), plan.writes,
    plan.slots[1].slot0, plan.slots[#plan.slots].slot0)
  lines[#lines + 1] = string.format("%s %d",
    t(i18n, "fc_overwritten", "Of them already in use:"), plan.overwritten)

  local shown = 0
  for i = 1, #plan.slots do
    local entry = plan.slots[i]
    if entry.overwritten then
      if shown >= SLOT_LINES_SHOWN then
        lines[#lines + 1] = string.format("  ... %d", plan.overwritten - shown)
        break
      end
      shown = shown + 1
      lines[#lines + 1] = string.format("  %d: %s -> %s", entry.slot0,
        tostring(entry.heldName), tostring(entry.name))
    end
  end

  if plan.overwritten > 0 then
    lines[#lines + 1] = t(i18n, "fc_overwritten_note",
      "Slots holding another function are overwritten, whichever switch they belong to.")
  end

  if plan.idsOnly then
    lines[#lines + 1] = ""
    lines[#lines + 1] = t(i18n, "fc_ids_only",
      "Only the function of each slot was read. Which channel it watches is checked after the write.")
  end

  local kept = {}
  for i = 1, #plan.keep do kept[#kept + 1] = tostring(plan.keep[i].slot0) end
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("%s %s",
    t(i18n, "fc_kept", "Left alone:"), table.concat(kept, ", "))

  -- The two things this action cannot check for itself and cannot work without. They are settings
  -- of the flight controller's own telemetry, not of its adjustments, so nothing read here says
  -- anything about them -- and without both the values never come back and every parameter on the
  -- tuning screen stays a dash.
  lines[#lines + 1] = ""
  lines[#lines + 1] = t(i18n, "fc_reminder",
    "The values only come back to the radio with telemetry sensor 99 selected and CRSF custom telemetry on.")
  return table.concat(lines, "\n")
end

--- Where the action has got to, for the line under the button.
--
-- Called from a reactive closure on that line, so it formats one string and reads nothing but the
-- run's own counters. The two write phases carry the sentence that matters more than the number:
-- the page must not be left while they run, because they are the phases nothing cancels.
local function progressText(i18n, run)
  local phase = run.phase
  local done, total = run.done or 0, run.total or 0
  if phase == FcSetup.PHASE_WRITING or phase == FcSetup.PHASE_COMMIT then
    return string.format("%s %d/%d - %s", t(i18n, "fc_writing", "Writing"), done, total,
      t(i18n, "fc_do_not_leave", "do not leave this page"))
  elseif phase == FcSetup.PHASE_VERIFY then
    return string.format("%s %d/%d - %s", t(i18n, "fc_verifying", "Reading back"), done, total,
      t(i18n, "fc_do_not_leave", "do not leave this page"))
  end
  return string.format("%s %d/%d", t(i18n, "fc_reading", "Reading the flight controller"), done, total)
end

--- Read, ask, write, read back -- and write nothing at all if the answer is no.
--
-- Every callback checks that the run it belongs to is still THIS page's run before it touches
-- anything on screen. A page that has been left still has its messages in the queue, and a write
-- already under way is deliberately not abandoned: a half-written adjustment table is a worse
-- state to leave a flight controller in than a finished one nobody watched.
function M.offer(ctx)
  local i18n = ctx.i18n
  local ui = ctx.state
  local requestRepaint = ctx.repaint
  t = textHelper(ctx)

  if FcSetup == nil then
    FcSetup = loadModule("widgets/dashboard/inflight/fcsetup.lua")
  end
  if type(FcSetup) ~= "table" then
    ui.fcNotice = t(i18n, "fc_unavailable", "This build cannot reach the flight controller.")
    requestRepaint()
    return
  end

  local run = FcSetup.newRun(ctx.config)
  ui.fcRun = run
  ui.fcPhase = nil
  -- The line under the button reads THIS while the run is on, and the page draws it through a
  -- closure rather than as a string baked into the tree. Set here so that the closure has
  -- something to answer with from the first frame.
  ui.fcProgress = function() return progressText(i18n, run) end

  local function mine()
    return ui.fcRun == run
  end

  --- One reply has moved the counters. Nothing is REBUILT for it.
  --
  -- The pilot's third radio round is what this is written from. The read used to rebuild the whole
  -- page once per record, because the percentage moved by three points every time -- thirty-six
  -- rebuilds, each of them a fresh set of closures and a fresh child list, on a radio that had 134
  -- kB of heap left. His log has the tool climbing from 1078 to 1575 kB across that phase and a
  -- `low heap` warning inside it.
  --
  -- So the NUMBER travels through a reactive closure, which costs one formatted string per frame
  -- and no tree at all, and a rebuild is asked for only when the PHASE changes -- four times in a
  -- whole run, and each of those genuinely changes what is on the screen.
  local function progress()
    if not mine() then return end
    if run.phase ~= ui.fcPhase then
      ui.fcPhase = run.phase
      requestRepaint()
    end
  end

  --- The run is over, however it ended: the moving line goes away and a fixed one takes its place.
  --
  -- One place, so that no exit path can leave the progress closure standing over a run that has
  -- stopped -- which would read as a read still going, for ever.
  local function settle(text)
    ui.fcRun = nil
    ui.fcProgress = nil
    ui.fcPhase = nil
    ui.fcNotice = text
    requestRepaint()
  end

  local function failed(_, reason)
    if not mine() then return end
    settle(refusalText(i18n, reason))
  end

  local function done(_, report)
    if not mine() then return end
    if report.verdict == "match" then
      settle(string.format("%s (%d)",
        t(i18n, "fc_done", "Flight controller set up"), report.written))
    elseif report.stepOnly == true then
      -- Every slot holds the right function on the right channels through the right windows and
      -- the STEP alone disagrees, which is worth its own sentence: it is the one field of a slot
      -- this page's own setting decides, so naming it names the remedy as well. A count of
      -- differing slots would be the same fact in a form nobody can act on.
      settle(string.format("%s (%d)",
        t(i18n, "fc_verify_step_only", "Written, but the flight controller kept another step"),
        report.steps))
    else
      -- The write said yes to every slot and the read-back disagrees, which is the one outcome
      -- worth spelling out: it is not a failure the queue reported and it is not a success.
      settle(string.format("%s (%d)",
        t(i18n, "fc_verify_differs", "Written, but the read-back does not match"), report.count))
    end
  end

  local function planned(_, plan)
    if not mine() then return end
    if plan.ok ~= true then
      settle(refusalText(i18n, plan.refused))
      return
    end

    if ConfirmDialog == nil then
      ConfirmDialog = loadModule("ui/confirm_dialog.lua")
    end

    local handlers = { onProgress = progress, onError = failed, onDone = done }
    local shown = false
    if ConfirmDialog and type(ConfirmDialog.show) == "function" then
      shown = ConfirmDialog.show({
        title = t(i18n, "setup_fc", "Set up the flight controller"),
        message = question(i18n, plan),
        onConfirm = function()
          if not mine() then return end
          FcSetup.apply(run, handlers)
        end,
        onCancel = function()
          -- Deliberately empty of writes AND deliberately present: a declined plan changes
          -- nothing, and saying so here is what keeps that from being an accident of the dialog's
          -- defaults.
          if not mine() then return end
          settle(t(i18n, "plan_cancelled", "Nothing was changed"))
        end
      })
    end

    if not shown then
      -- No confirmation could be put up, so there is no answer to act on. Writing a flight
      -- controller is not something to do on the assumption that the pilot would have said yes.
      settle(t(i18n, "plan_no_dialog", "This radio cannot show the confirmation."))
    end
  end

  ui.fcNotice = nil
  ui.fcPhase = run.phase
  requestRepaint()
  FcSetup.begin(run, { onProgress = progress, onPlan = planned, onError = failed, onDone = done })
end

--- Give up a run the pilot has walked away from, if it is in a phase that may be given up.
--
-- The page calls this on its way out. Only the READ is abandoned -- a write chain stopped half way
-- leaves the flight controller holding part of one adjustment set and part of another, which is a
-- worse state than a finished write nobody watched, so the write is left to the queue and the
-- screen says so while it runs.
--
-- Answers whether anything was given up, so the caller can tell "cancelled" from "left running".
function M.cancel(ui)
  if type(ui) ~= "table" then return false end
  local run = ui.fcRun
  if run == nil or type(FcSetup) ~= "table" or type(FcSetup.cancel) ~= "function" then return false end
  local cancelled = FcSetup.cancel(run)
  if cancelled then
    ui.fcRun = nil
    ui.fcProgress = nil
    ui.fcPhase = nil
  end
  return cancelled
end

return M
