-- NVSD_ItemView_DoubleClick.lua
-- Mouse modifier wrapper: MIDI items → MIDI editor, audio items → NVSD_ItemView
--
-- Setup:
--   1. Load both this script AND NVSD_ItemView.lua into the Action List
--   2. Preferences → Mouse Modifiers → Media item left click →
--      Double click → Action... → select this script

local item = reaper.GetSelectedMediaItem(0, 0)
if not item then return end
local take = reaper.GetActiveTake(item)
if not take then return end

if reaper.TakeIsMIDI(take) then
  reaper.Main_OnCommand(40153, 0)  -- Item: Open in built-in MIDI editor
else
  -- Find NVSD_ItemView command ID from registered actions
  local f = io.open(reaper.GetResourcePath() .. "/reaper-kb.ini", "r")
  if f then
    for line in f:lines() do
      if line:find("NVSD_ItemView.lua", 1, true)
          and not line:find("DoubleClick", 1, true) then
        local rs_id = line:match("(RS%x+)")
        if rs_id then
          f:close()
          local cmd = reaper.NamedCommandLookup("_" .. rs_id)
          if cmd > 0 then reaper.Main_OnCommand(cmd, 0) end
          return
        end
      end
    end
    f:close()
  end
  reaper.MB("NVSD_ItemView.lua not found in Action List.\nLoad it via Actions > Show Action List > Load ReaScript.",
      "NVSD_ItemView", 0)
end
