-- probe: log writes to the video registers (gfxctrl, roz bank, K053936 ctrl, fff00c, fff044) per frame, with inputs scripted
local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local scr  = mach.screens[":screen"]
local out  = io.open(os.getenv("PROBEOUT") or "probe.txt", "w")
local frame = 0
local LAST = tonumber(os.getenv("LAST") or "3000")
local FLIP = os.getenv("FLIP") == "1"
local SNAPS = {}
for n in string.gmatch(os.getenv("SNAPS") or "", "%d+") do SNAPS[tonumber(n)] = true end

local function field(port, name)
  local p = mach.ioport.ports[port]
  for n, f in pairs(p.fields) do if n == name then return f end end
  print("no field " .. port .. " " .. name)
end
local F = {
  coin1 = field(":P1", "Coin 1"), start1 = field(":P1", "1 Player Start"),
  b1 = field(":P1", "P1 Button 1"), left = field(":P1", "P1 Left"), right = field(":P1", "P1 Right"),
}
if FLIP then
  local f = field(":DSW0", "Flip Screen"); f:set_value(0)
end

local last = {}
local function tap(name, lo, hi)
  return sp:install_write_tap(lo, hi, name, function(offset, data, mask)
    NW = (NW or 0) + 1
    local key = string.format("%06x", offset)
    local v = string.format("%04x/%04x", data, mask)
    if last[key] ~= v then
      out:write(string.format("f%05d l%03d %s %s %s\n", frame, (scr.vpos or 0), name, key, v))
      last[key] = v
    end
  end)
end
TAPS = {
  tap("gfx", 0xfff000, 0xfff001), tap("ff00c", 0xfff00c, 0xfff00d), tap("roz", 0xfff020, 0xfff03f),
  tap("x44", 0xfff044, 0xfff047), tap("bank", 0xffc000, 0xffc001), tap("io8", 0xfff008, 0xfff00b),
  tap("ff010", 0xfff010, 0xfff01f), tap("ff040", 0xfff040, 0xfff043), tap("ff048", 0xfff048, 0xffffff),
}

emu.register_frame_done(function()
  frame = frame + 1
  local p = {}
  p.coin1 = frame >= 600 and frame < 606
  p.start1 = frame >= 700 and frame < 706
  p.b1 = frame >= 800
  p.left = frame >= 1200 and (frame // 60) % 3 == 0
  for k, f in pairs(F) do if f then f:set_value(p[k] and 1 or 0) end end
  if SNAPS[frame] then scr:snapshot(string.format("snap_%05d.png", frame)) end
  if frame % 500 == 0 then print(frame, NW) end
  if frame >= LAST then out:close(); mach:exit() end
end)
local function rd() return string.format("P1 %04x P2 %04x DSW0 %04x DSW2 %04x DSW1 %04x P3 %04x  fff008 %04x fff00c %04x",
  sp:read_u16(0xfff000), sp:read_u16(0xfff002), sp:read_u16(0xfff004), sp:read_u16(0xfff006), sp:read_u16(0xfff00a), sp:read_u16(0xfff00e), sp:read_u16(0xfff008), sp:read_u16(0xfff00c)) end
emu.register_frame_done(function() if frame == 100 or frame == 1500 then print(rd()) end end)
