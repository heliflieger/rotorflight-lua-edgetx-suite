-- The names a Rotorflight flight controller prints beside its serial sockets.
--
-- A board reports a board design over MSP_BOARD_INFO -- a four-character code such as F7A1 --
-- and the design decides which socket is labelled what. The table below is the Configurator's
-- own portNamesRF2 (rotorflight-configurator src/js/tabs/configuration.js:43-188), restated
-- entry for entry: a design, then the serial port identifier the firmware reports mapped to the
-- label silkscreened next to that socket. It is data rather than logic, and there is nothing on
-- a radio to derive it from.
--
-- A board whose design is not one of these sixteen is named with plain UART names, which is
-- what the Configurator falls back to as well (configuration.js:475-481).
--
-- TRANSLITERATED, and that is the one deliberate difference from the source. The Configurator
-- writes the circled capitals of the Enclosed Alphanumerics block: its "Port A" is the word
-- Port followed by U+24B6, and DSM D by U+24B9. A radio has no glyph for any of them. EdgeTX
-- bakes a fixed character set into its fonts: ASCII 0x20-0x7F, U+00B0, U+2022, U+2265, Latin-1
-- Supplement 0xC0-0xFF and Latin Extended-A 0x100-0x17F, plus its own symbol ranges
-- (edgetx radio/src/fonts/lvgl/make_fonts.sh:23-39, handed to the font converter at :129).
-- U+24B6 is in none of them, so it would draw as nothing at all. The plain capital says the
-- same thing to a pilot reading the board.

local PortLabels = {}

PortLabels.byDesign = {
  ["F7A1"] = { [0] = "DSM D", [1] = "S.BUS", [2] = "Port C", [3] = "Port A", [4] = "Port E", [5] = "Port B" },
  ["F7A2"] = { [0] = "DSM D", [1] = "S.BUS", [2] = "Port G", [3] = "Port A", [4] = "Port E", [5] = "Port G" },
  ["F7A3"] = { [0] = "DSM D", [1] = "S.BUS", [2] = "Port C", [3] = "Port A", [4] = "Int.Rx", [5] = "Port B" },
  ["F7A4"] = { [0] = "DSM D", [1] = "S.BUS", [2] = "Port G", [3] = "Port A", [4] = "Int.Rx", [5] = "Port G" },
  ["F7B1"] = { [0] = "S.BUS", [1] = "TELEM", [2] = "Port C", [3] = "Port A", [4] = "DSM D", [5] = "Port B" },
  ["F7B2"] = { [0] = "S.BUS", [1] = "TELEM", [2] = "Port G", [3] = "Port A", [4] = "DSM D", [5] = "Port G" },
  ["F7B3"] = { [0] = "S.BUS", [1] = "TELEM", [2] = "Port C", [3] = "Port A", [4] = "Port E", [5] = "Port B" },
  ["F7B4"] = { [0] = "S.BUS", [1] = "TELEM", [2] = "Port G", [3] = "Port A", [4] = "Port E", [5] = "Port G" },
  ["F7B5"] = { [0] = "S.BUS", [1] = "TELEM", [2] = "Port C", [3] = "Port A", [4] = "Int.Rx", [5] = "Port B" },
  ["F7B6"] = { [0] = "S.BUS", [1] = "TELEM", [2] = "Port G", [3] = "Port A", [4] = "Int.Rx", [5] = "Port G" },
  ["F7C1"] = { [0] = "S.BUS", [1] = "TELEM", [2] = "Port C", [3] = "Port A", [4] = "DSM D", [5] = "Port B" },
  ["F7C2"] = { [0] = "S.BUS", [1] = "TELEM", [2] = "Port G", [3] = "Port A", [4] = "DSM D", [5] = "Port G" },
  ["F7C3"] = { [0] = "S.BUS", [1] = "TELEM", [2] = "Port C", [3] = "Port A", [4] = "Port E", [5] = "Port B" },
  ["F7C4"] = { [0] = "S.BUS", [1] = "TELEM", [2] = "Port G", [3] = "Port A", [4] = "Port E", [5] = "Port G" },
  ["F7C5"] = { [0] = "S.BUS", [1] = "TELEM", [2] = "Port C", [3] = "Port A", [4] = "Int.Rx", [5] = "Port B" },
  ["F7C6"] = { [0] = "S.BUS", [1] = "TELEM", [2] = "Port G", [3] = "Port A", [4] = "Int.Rx", [5] = "Port G" }
}

-- The label a board prints beside one of its ports, or nil where there is none to print.
--
-- Nil covers two cases and they are treated alike: a design this table does not know, and a
-- design that knows nothing about that particular identifier -- a softserial port on a board
-- whose entry only names its six UARTs. The Configurator draws the literal text "undefined" in
-- the second case; here the caller falls back to the UART name, which is at least something the
-- pilot can act on.
function PortLabels.label(design, identifier)
  if type(design) ~= "string" or design == "" then return nil end
  local names = PortLabels.byDesign[design]
  if names == nil then return nil end
  local label = names[identifier]
  if type(label) ~= "string" or label == "" then return nil end
  return label
end

return PortLabels
