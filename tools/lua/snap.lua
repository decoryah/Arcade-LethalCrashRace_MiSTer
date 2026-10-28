-- snapshots only, no inputs: SNAPS=a,b,c LAST=n
local scr = manager.machine.screens[":screen"]
local frame = 0
local LAST = tonumber(os.getenv("LAST") or "1000")
local SNAPS = {}
for n in string.gmatch(os.getenv("SNAPS") or "", "%d+") do SNAPS[tonumber(n)] = true end
emu.register_frame_done(function()
  frame = frame + 1
  if SNAPS[frame] then scr:snapshot(string.format("snap_%05d.png", frame)) end
  if frame >= LAST then manager.machine:exit() end
end)
