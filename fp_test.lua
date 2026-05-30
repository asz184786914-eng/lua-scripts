-- 设备指纹稳定性测试
local function getFP()
    local ids = {}
    local f, c

    f = io.open("/proc/cmdline", "r")
    if f then
        c = f:read("*a"); f:close()
        local s = c:match("androidboot%.serialno=(%S+)")
            or c:match("serialno=(%S+)")
        if s then
            s = s:gsub("[,;\"]", "")
            ids[#ids + 1] = "cmdline:" .. s
        end
    else
        ids[#ids + 1] = "cmdline:FAIL"
    end

    f = io.open("/proc/cpuinfo", "r")
    if f then
        c = f:read("*a"); f:close()
        local hw = c:match("Hardware%s*:%s*(.-)\n")
        local s = c:match("Serial%s*:%s*(%S+)")
        if hw then
            hw = hw:gsub("%s+$", "")
            ids[#ids + 1] = "hw:" .. hw
        end
        if s and s ~= "0000000000000000" then
            ids[#ids + 1] = "serial:" .. s
        end
    else
        ids[#ids + 1] = "cpuinfo:FAIL"
    end

    f = io.open("/sys/devices/soc0/serial_number", "r")
    if f then
        c = f:read("*a"):gsub("%s", "")
        f:close()
        if c ~= "" then ids[#ids + 1] = "soc_serial:" .. c end
    end

    f = io.open("/sys/devices/soc0/machine", "r")
    if f then
        c = f:read("*a"):gsub("%s", "")
        f:close()
        if c ~= "" then ids[#ids + 1] = "soc_machine:" .. c end
    end

    local pkg = gg.getSelectedPackage() or "unknown"
    ids[#ids + 1] = "pkg:" .. pkg

    local raw = table.concat(ids, "|")
    return raw
end

local fp1 = getFP()
gg.alert("当前指纹:\n\n" .. fp1 .. "\n\n请截图后重新运行一次此脚本，对比两次结果是否一致")

-- 同时保存到文件方便对比
local f = io.open("/sdcard/.fp_test_result", "w")
if f then
    f:write(fp1)
    f:close()
end
