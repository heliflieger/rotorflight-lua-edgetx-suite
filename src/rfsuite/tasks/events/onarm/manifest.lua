-- Manifest for onarm tasks (ordered)
--
-- flight_record runs FIRST, and the order matters for the same reason it does on the disarm side:
-- the runner takes the first unfinished task of this list and runs one task per wakeup, so the
-- record is open before any task behind it can look at it. It needs nothing but session memory.
return {
  { name = "flight_record", context = "widget" },
  { name = "flight_log", context = "widget" },
}
