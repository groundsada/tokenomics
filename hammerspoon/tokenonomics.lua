--- tokenonomics.lua — VPN + spend menubar widget for Hammerspoon.
--- Load with:  require("tokenonomics")   (put this file in your Hammerspoon config dir)
--- Config lives in the sibling `tokenonomics.env` (see tokenonomics.env.example).
--- This module contains NO machine-specific paths/values: everything comes from
--- the env file. It does not include any keyboard shortcuts or other bindings.

local M = {}

-- ---------- config (from tokenonomics.env) ----------
local function loadEnv(path)
  local env = {}
  local f = io.open(path, "r")
  if not f then return env end
  for line in f:lines() do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and not line:match("^#") and line:find("=") then
      local k, v = line:match("^([^=]+)=(.*)$")
      if k then
        env[k:gsub("%s+$", "")] = v:gsub("^%s+", ""):gsub("%s+$", "")
      end
    end
  end
  f:close()
  return env
end

local thisDir = debug.getinfo(1, "S").source:match("^(.-)[^/]+$") or "./"
local env = loadEnv(os.getenv("TOKENONOMICS_ENV") or (thisDir .. "tokenonomics.env"))
local TOK_DIR     = env.TOK_DIR or (thisDir .. "..")
local STATE_DIR   = env.TOK_STATE_DIR or (TOK_DIR .. "/state")
local ASSETS_DIR  = env.TOK_ASSETS_DIR or (TOK_DIR .. "/assets")
local MAKEBLOB    = env.TOK_MAKEBLOB or (TOK_DIR .. "/scripts/makeblob")
local VPNCTL      = (TOK_DIR .. "/scripts/vpnctl")
local SPEND       = ("python3 " .. TOK_DIR .. "/scripts/esnet_spend.py")
local LOGO_ESNET  = env.LOGO_ESNET or (ASSETS_DIR .. "/esnet_logo.png")
local LOGO_LBL    = env.LOGO_LBL or (ASSETS_DIR .. "/lbl_logo.png")
local LOGO_CBORG  = env.LOGO_CBORG or (ASSETS_DIR .. "/cborg_logo.png")
local ES_BUDGET   = tonumber(env.ES_SPEND_BUDGET) or 500
local CB_BUDGET   = tonumber(env.CBORG_MAX_BUDGET) or 500

local SPEND_JSON    = STATE_DIR .. "/spend.json"
local CBORG_JSON    = STATE_DIR .. "/cborg.json"

-- ---------- helpers ----------
local function async(cmd, cb)
  local t = hs.task.new("/bin/bash", function(_, out, err)
    if cb then cb(out or "", err or "") end
  end, { "-lc", cmd })
  t:start()
end

local function fmtMoney(x)
  x = x or 0
  local s = string.format("%.2f", x)
  local i, f = s:match("^(%d+)%.(.*)$")
  if i then
    i = i:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return "$" .. i .. "." .. f
  end
  return "$" .. s
end

local function fmtShort(x)
  x = x or 0
  if x >= 10 then return string.format("$%.0f", x) end
  return string.format("$%.2f", x)
end

local function fmtSince(s)
  local y, m, d = s:match("^(%d+)-(%d+)-(%d+)$")
  if not y then return s end
  local names = {"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"}
  local mi = tonumber(m)
  return ((mi and names[mi]) or m) .. " " .. tostring(tonumber(d))
end

local function fileJson(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a"); f:close()
  local ok, d = pcall(function() return hs.json.decode(s) end)
  if ok and type(d) == "table" then return d end
  return nil
end

-- ---------- widget ----------
local snap = { esnet = false, lbl = false, es = 0, cb = nil, cbBudget = nil }
local bar = hs.menubar.new(true, "Tokenonomics…")
M.snap = snap

local function render()
  local up, mode, amt, logoPath
  if snap.esnet then
    up, mode, amt, logoPath = true, "esnet", fmtShort(snap.es), LOGO_ESNET
  elseif snap.lbl then
    up, mode, amt, logoPath = true, "lbl", fmtShort(snap.cb or 0), LOGO_LBL
  else
    up, mode, amt, logoPath = false, "esnet", fmtShort(snap.es), LOGO_ESNET
  end
  async("'" .. MAKEBLOB .. "' " .. mode .. " " .. (up and "1" or "0") .. " '" .. amt .. "' /tmp/tokenonomics_blob.png '" .. logoPath .. "'",
    function()
      local im = hs.image.imageFromPath("/tmp/tokenonomics_blob.png")
      pcall(function() bar:setIcon(im or "/tmp/tokenonomics_blob.png", false) end)
      bar:setTitle("")
    end)
end

local function updateSnap()
  async(VPNCTL .. " status", function(out)
    snap.esnet = out:find("ESnet: CONNECTED") ~= nil
    snap.lbl   = out:find("LBL:   CONNECTED") ~= nil
    local g = fileJson(SPEND_JSON)
    local fresh = g and g.age_sec and g.age_sec < 600 and g.month == os.date("%Y-%m")
    snap.es = g and g.spend or 0
    snap.esSrc = fresh and "gateway" or (g and "cached" or "offline")
    snap.models = (g and g.by_model) or nil
    snap.modelsSince = (g and g.by_model_since) or nil
    local cb = fileJson(CBORG_JSON)
    if cb and cb.spend then
      snap.cb = cb.spend
      snap.cbBudget = cb.budget
    end
    pcall(function() bar:setTooltip(
      "ESnet " .. fmtMoney(snap.es) .. " (" .. snap.esSrc .. ") · CBorg " .. fmtMoney(snap.cb or 0)) end)
    render()
    bar:setMenu(menuRows())
  end)
end

local function refreshSpend()
  async(SPEND, function()
    if snap.lbl then
      async("python3 " .. TOK_DIR .. "/scripts/cborg_spend.py", function() updateSnap() end)
    else
      updateSnap()
    end
  end)
end

local function act(cmd)
  snap.busy = cmd
  hs.timer.doAfter(30, function()
    if snap.busy == cmd then snap.busy = nil; render(); bar:setMenu(menuRows()) end
  end)
  async(VPNCTL .. " " .. cmd, function()
    hs.timer.doAfter(3, updateSnap)
    hs.timer.doAfter(20, updateSnap)
    hs.timer.doAfter(45, updateSnap)
  end)
end

local function menuRows()
  local cbTxt = fmtMoney(snap.cb or 0)
  if snap.cbBudget then cbTxt = cbTxt .. " / " .. fmtMoney(snap.cbBudget) .. " mo" end
  if not snap.lbl then cbTxt = cbTxt .. " (cached)" end
  local esRow
  if snap.busy == "esnet" then
    esRow = { title = "ESnet  … connecting" }
  elseif snap.esnet then
    esRow = { title = "ESnet ● Connected   " .. fmtMoney(snap.es) .. " (" .. (snap.esSrc or "?") .. ")",
              fn = function() act("off") end }
  else
    esRow = { title = "ESnet ○ Off   " .. fmtMoney(snap.es) .. " (" .. (snap.esSrc or "cached") .. ")",
              fn = function() act("esnet") end }
  end
  local lblRow
  if snap.busy == "lbl" then
    lblRow = { title = "LBL   … connecting (approve MFA)" }
  elseif snap.lbl then
    lblRow = { title = "LBL ● Connected   CBorg " .. cbTxt,
               fn = function() act("off") end }
  else
    lblRow = { title = "LBL ○ Off   CBorg " .. cbTxt,
               fn = function() act("lbl") end }
  end
  local rows = {
    esRow,
    lblRow,
    { title = "-" },
    { title = "Refresh", fn = function() refreshSpend() end },
  }
  if snap.models and #snap.models > 0 then
    rows[#rows+1] = { title = "-" }
    rows[#rows+1] = { title = "ESnet models (since " .. fmtSince(snap.modelsSince or "") .. ")" }
    for i, mm in ipairs(snap.models) do
      if i > 4 then break end
      rows[#rows+1] = { title = "    " .. mm.model .. "  " .. fmtMoney(mm.spend) }
    end
  end
  return rows
end

-- ---------- start ----------
bar:setMenu(function() local m = menuRows(); updateSnap(); refreshSpend(); return m end)
hs.timer.new(15, function() updateSnap() end):start()
hs.timer.new(60, function() refreshSpend() end):start()
updateSnap()

return M
