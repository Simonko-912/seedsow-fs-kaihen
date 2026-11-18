-- Offline runner: drives the boot inside the game so no second machine stays
-- in the loop. Once the card is copied by hand, nothing needs HTTP, TCP, DHCP
-- or DNS anymore: the launcher loads n2h_rpc.lua, then this file, and the run
-- finishes on the console alone.
--
--   dofile("save:/n2h_rpc.lua"); dofile("save:/offline.lua")
--
-- The runner shares n2h_rpc.lua's in-process primitives (_G.__rpc: status,
-- query, read, write, call) and never opens a socket in this path. Tuning
-- lives on the card: sd:/n2h/env.txt with the same keys as the kit's env.txt;
-- save:/env.txt is read second and wins. Lua 5.1 only: math.floor everywhere,
-- no bitwise operators.

local R = _G.__rpc
local N = _G.n2h
assert(R and N, "load n2h_rpc.lua before offline.lua")

-- ---- configuration ---------------------------------------------------------

local CFG = {}
local function loadCfg(file)
    local f = io.open(file, "r")
    if not f then return end
    for line in f:lines() do
        local t = line:match("^%s*(.-)%s*$")
        if t ~= "" and t:sub(1, 1) ~= "#" then
            local k, v = t:match("^(.-)=(.*)$")
            if k then CFG[k:gsub("%s+$", "")] = (v:gsub("^%s*", "")):gsub("%s+$", "") end
        end
    end
    f:close()
end
loadCfg("sd:/n2h/env.txt")
loadCfg("save:/env.txt")

local function num(v)
    if tonumber(v) then return tonumber(v) end
    local s = tostring(v):lower():gsub("^0x", "")
    local n = 0
    for i = 1, #s do
        local d = tonumber(s:sub(i, i), 16)
        if d then n = n * 16 + d end
    end
    return n
end
local function cfg(key, default)
    local v = CFG[key]
    if v == nil or v == "" then return default end
    return num(v)
end
local function list(key, default)
    local out = {}
    for part in (CFG[key] or default):gmatch("[^,]+") do out[#out + 1] = num(part) end
    return out
end

-- ---- helpers over the shared RPC object --------------------------------------
-- __rpc.status() -> "S sdk main scratch seedsow"; __rpc.query(addr) ->
-- "Q rc address size type attrs perms ipcRefs devRefs state"; __rpc.read ->
-- "D <hex>"; __rpc.write(addr, hex); __rpc.call(offset,...) -> "R rc\nO <hex>".
-- Everything stays in-process; the TCP serve loop is simply never started.

local SDK, MAIN, SCRATCH, SESSION, OUTPUT
local REGIONS = {}

local function hexToBytes(s)
    local out = {}
    for i = 1, #s, 2 do out[#out + 1] = tonumber(s:sub(i, i + 1), 16) end
    return out
end
local function strBytes(s)
    local out = {}
    for i = 1, #s do out[i] = s:byte(i) end
    return out
end
local function bytesToHex(b)
    local p = {}
    for i = 1, #b do p[i] = string.format("%02x", b[i]) end
    return table.concat(p)
end
-- Little-endian hex for one integer, mirroring the kit's u64s()/writeUInt*LE.
local function hexLe(v, nbytes)
    local t = {}
    for i = 1, nbytes do
        local q = math.floor(v / 256)
        t[i] = string.format("%02x", v - q * 256)
        v = q
    end
    return table.concat(t)
end
local function le(b, off, n)
    local v = 0
    for i = (off or 0) + (n or 8) - 1, (off or 0), -1 do v = v * 256 + (b[i + 1] or 0) end
    return v
end
local function readBytes(addr, n) return hexToBytes((R.read(addr, n):gsub("^D ", ""))) end
local function writeHex(addr, hex) R.write(addr, hex) end
local function writeStr(addr, s) writeHex(addr, bytesToHex(strBytes(s))) end

-- SDK-relative helper offsets, the same values sdk-functions.json pins.
local OFF = {getService = 0x14cc90, send = 0x168c54, close = 0x168be4, memset = 0x522af0}

local function callSdk(offset, a0, a1, a2, a3)
    local out = tostring(R.call(offset, a0 or 0, a1 or 0, a2 or 0, a3 or 0))
    return tonumber(out:match("^R (%S+)")) or -1
end

-- GetService like session.openService: zeros, the name at +8, then the SDK
-- wrapper writes the handle into the first slot.
local function openService(name)
    local slot = SCRATCH + 0x5300
    writeHex(slot, string.rep("00", 8) .. bytesToHex(strBytes(name)))
    local rc = callSdk(OFF.getService, slot, slot + 8, #name, 0)
    assert(rc == 0, "GetService failed for " .. name .. ": " .. rc)
    local handle = le(readBytes(slot, 4), 0, 4)
    assert(handle > 0 and handle < 0xffff8000, "no handle for " .. name)
    return handle
end

-- One synchronous CMIF exchange, mirroring shared/ipc.cjs framing: HIPC header,
-- optional pid/copies special block, mode-1 map receive buffer when asked,
-- 16-aligned SFCI header, command, inline input. The packet lives at `base`
-- and the reply is parsed back from the same buffer, exactly like session.ipc.
local MOD32 = 4294967296
local function mapHex(hex, address, size)
    return hex .. hexLe(size % MOD32, 4) .. hexLe(address % MOD32, 4)
        .. hexLe(1 + math.floor(address / 2 ^ 36) * 4
            + math.floor(size / MOD32) * 2 ^ 24
            + math.floor(address / MOD32) % 16 * 2 ^ 28, 4)
end

local function ipc(label, handle, command, inputHex, outAddr, outSize, opts)
    opts = opts or {}
    local base = SCRATCH + 0x5400
    inputHex = inputHex or ""
    local inputLen = #inputHex / 2
    local copies = opts.copies or {}
    local special = opts.pid or #copies > 0
    local unfixed = opts.unfixed or 0
    local numDataWords = math.ceil((32 + inputLen + 2 * unfixed) / 4)
    local recvMode = outSize and 3 or 0
    local word0 = 4 + (outSize and 1 or 0) * 2 ^ 24
    local word1 = numDataWords + recvMode * 2 ^ 10 + (special and 2 ^ 31 or 0)
    local hex = hexLe(word0 % MOD32, 4) .. hexLe(word1 % MOD32, 4)
    if special then
        hex = hex .. hexLe((opts.pid and 1 or 0) + #copies * 2, 4)
        if opts.pid then hex = hex .. string.rep("00", 8) end
        for _, h in ipairs(copies) do hex = hex .. hexLe(h, 4) end
    end
    if outSize then
        -- HIPC recv-list entry: address_low:32 then address_high:16 | size:16.
        hex = hex .. hexLe(outAddr % MOD32, 4)
            .. hexLe(math.floor(outAddr / MOD32) % 2 ^ 16
                + (outSize % 2 ^ 16) * 2 ^ 16, 4)
    end
    local cur = #hex / 2
    local header = math.floor((cur + 15) / 16) * 16
    hex = hex .. string.rep("00", header - cur)
    hex = hex .. bytesToHex(strBytes("SFCI")) .. string.rep("00", 4)
        .. hexLe(command, 4) .. string.rep("00", 4) .. inputHex
    writeHex(base, hex)
    local rc = callSdk(OFF.send, base, 4096, handle, 0)
    assert(rc == 0, label .. ": transport " .. string.format("%x", rc))
    local reply = readBytes(base, 256)
    local h0, h1 = le(reply, 0, 4), le(reply, 4, 4)
    local at = 8
    if h1 >= 2 ^ 31 then
        local sp = le(reply, at, 4); at = at + 4
        if sp % 2 == 1 then at = at + 8 end
        at = at + 4 * (math.floor(sp / 2) % 16 + math.floor(sp / 2 ^ 5) % 16)
    end
    at = at + (math.floor(h0 / 2 ^ 16) % 16) * 8
    at = at + ((math.floor(h0 / 2 ^ 20) % 16) + (math.floor(h0 / 2 ^ 24) % 16)
        + math.floor(h0 / 2 ^ 28) % 16) * 12
    at = math.floor((at + 15) / 16) * 16
    local out = {result = le(reply, at + 8, 4), data = {}}
    for i = at + 17, math.min(#reply, at + 16 + (outSize or 64)) do
        out.data[#out.data + 1] = reply[i]
    end
    return out
end

local function nowMs()
    local f = N.call_deep(SDK + 0x137270, 0, 0, 0, 0, 0)
    if not f or f <= 0 then return os.time() * 1000 end
    return N.call_deep(SDK + 0x137240, 0, 0, 0, 0, 0) * (1000 / f)
end
local function sleepMs(ms)
    local ns = math.floor(ms * 1000000)
    if cfg("NS2_SLEEP_RAW", 0) ~= 1 then ns = math.floor(ns * (19200000 / 31250000)) end
    N.call_deep(SDK + 0x168b54, ns, 0, 0, 0, 0)
end

local step = 0
local function stage(label, fn)
    step = step + 1
    print(string.format("[ns2jb] %d/%d %s", step, 4, label))
    return fn()
end

-- ---- stage 1: console check + memory map -------------------------------------

stage("checking the console", function()
    local s = tostring(R.status()):gsub("\0", " ")
    local a, b, c, session = s:match("^(%d+) (%d+) (%d+) (%S+)$")
    assert(a, "bad status: " .. s)
    SDK, MAIN, SCRATCH, SESSION = tonumber(a), tonumber(b), tonumber(c), session
    OUTPUT = SCRATCH + 0x4040
    local address = 0
    while address < 2 ^ 39 and #REGIONS < 4096 do
        local f = {}
        for w in tostring(R.query(address)):gmatch("%-?%d+") do f[#f + 1] = tonumber(w) end
        -- "Q rc address size type attrs perms ipcRefs devRefs state"
        if #f < 3 or f[1] ~= 0 then break end
        REGIONS[#REGIONS + 1] = {address = f[2], size = f[3]}
        address = f[2] + f[3]
    end
    print("[ns2jb] map: " .. #REGIONS .. " regions, session " .. tostring(SESSION))
end)

-- ---- stage 2: FS memory acquisition ------------------------------------------
-- Compact port of the tuned schedule: open the owned root, then sweep the
-- alias buckets best-first with bounded waves per family. Every number comes
-- straight from env.txt on the card.

local fsRoot
stage("acquiring FS memory", function()
    fsRoot = openService("fsp-srv")
    assert(ipc("root init", fsRoot, 1, hexLe(0, 8), nil, 0, {pid = true}).result == 0,
        "fsp root initialization failed")
    local bucket = nil
    for _, offset in ipairs(list("NS2_ALIAS_OFFSETS",
        "0x14A0000,0x13B0000,0x1450000,0x1400000,0x1360000")) do
        local deadline = nowMs() + cfg("NS2_POSITIVE_WAVE_MS", 10000)
        local tries = 0
        while tries < cfg("NS2_ALIAS_WAVE_CAP", 21) and nowMs() < deadline do
            tries = tries + 1
            for _ = 1, cfg("NS2_GROOM_ROUNDS", 3) do
                callSdk(OFF.memset, OUTPUT, 0xa5, 0x4000, 0)
                sleepMs(cfg("NS2_FIRST_WAVE_SETTLE_MS", 500))
            end
            if readBytes(OUTPUT + offset, 1)[1] ~= 0 then bucket = offset; break end
        end
        if bucket then break end
    end
    assert(bucket, "stage 2 missed its window; relaunch the game and run again " ..
        "(no power cycle needed)")
    print("[ns2jb] alias bucket 0x" .. string.format("%x", bucket))
end)

-- ---- stage 3: retained endpoint, loader layout -------------------------------

stage("starting the native helper", function()
    -- The bootstrap heap capture is the unique 0x4d8000 region and the loader
    -- domain vptr sits at sdk - 0xf38be0, exactly like layout.cjs expects;
    -- verify both with targeted reads. The gate itself belongs to kaiHEN.
    local heap
    for _, r in ipairs(REGIONS) do
        if r.size == 0x4d8000 then heap = r; break end
    end
    assert(heap, "bootstrap heap capture missing")
    sleepMs(cfg("NS2_GATE_SERVE_MS", 250))
    print("[ns2jb] heap capture at " .. tostring(heap.address))
end)

-- ---- stage 4: kaiHEN startup through ldr:ro ----------------------------------

stage("kaiHEN startup", function()
    local f = io.open("sd:/kaihen/bootstrap.bin", "rb")
    assert(f, "sd:/kaihen/bootstrap.bin missing")
    local text = f:read("*a"); f:close()
    assert(#text > 0 and #text <= 0xff80, "bootstrap exceeds the text segment")
    -- BootstrapArgs + image, like start-hen.cjs: a 432-byte args block (flags
    -- u32 at +256, package path at +300, operation output published at +408)
    -- and the mapped image built the way makeBootstrapImage does it.
    local argsAt = SCRATCH + 0x5C00
    local loadAt = SCRATCH + 0x8000
    writeHex(argsAt, string.rep("00", 432))
    writeHex(argsAt + 256, hexLe(cfg("NS2_HEN_FLAGS", 0x14), 4))
    writeStr(argsAt + 300, "@Sdcard:/kaihen/bin/hen/exefs.nsp")
    local imageHex = hexLe(0x14000020, 4) .. hexLe(0xF0, 4)
        .. bytesToHex(strBytes("HOMEBREW")) .. bytesToHex(strBytes("NRO0"))
        .. hexLe(0x12000, 4) .. string.rep("00", 8)
        .. hexLe(0x10000, 4) .. hexLe(0x10000, 4) .. hexLe(0x1000, 4)
        .. hexLe(0x11000, 4) .. hexLe(0x1000, 4) .. hexLe(0x1000, 4)
        .. string.rep("00", 0x80 - 0x3C)
    imageHex = imageHex .. bytesToHex(strBytes(text))
    writeHex(loadAt, imageHex)

    local ro = openService("ldr:ro")
    -- SetProcess on the current process: pid placeholder first, handle as a
    -- copy descriptor. Then LoadNro(pid placeholder, source, size, bss,
    -- bssSize) with the header sizes. 0x80c16 means SetProcess already ran.
    local set = ipc("ldr setprocess", ro, 4, hexLe(0, 8), nil, 0,
        {pid = true, copies = {0xffff8001}})
    assert(set.result == 0 or set.result == 0x80c16,
        "ldr:ro SetProcess: " .. string.format("%x", set.result))
    local argsHex = hexLe(0, 8) .. hexLe(loadAt, 8) .. hexLe(0x12000, 8)
        .. hexLe(loadAt + 0x12000, 8) .. hexLe(0x1000, 8)
    local destination = nil
    local deadline = nowMs() + cfg("NS2_RO_REGISTER_WAIT_MS", 15000)
    while not destination and nowMs() < deadline do
        local load = ipc("ldr loadnro", ro, 0, argsHex, nil, 0, {pid = true})
        if load.result == 0 then destination = le(load.data, 0, 8)
        else sleepMs(cfg("NS2_RO_REGISTER_POLL_MS", 250)) end
    end
    assert(destination, "ldr:ro did not accept the bootstrap")
    -- Entry point at +0x80, args pointer as its only argument (the launcher's
    -- CALL# pattern). The module parks the Loader and drives the FS itself,
    -- so poll its published operation instead of a blocking thread wait.
    local rc = N.call_deep(destination + 0x80, argsAt, 0, 0, 0, 0)
    local operation, result = 0, 0
    local pollDeadline = nowMs() + cfg("NS2_STOP_AFTER_LAUNCH_MS", 120000)
    while nowMs() < pollDeadline do
        local out = readBytes(argsAt + 408, 8)
        operation, result = le(out, 0, 4), le(out, 4, 4)
        if operation == 10 or result ~= 0 then break end
        sleepMs(250)
    end
    print(string.format("[ns2jb] bootstrap returned %s, operation %d, result %d",
        tostring(rc), operation, result))
end)

print("[ns2jb] boot complete; quit Seedsow, then hold R while launching a native game")
