-- 逐项弹窗测试
-- 测试1: 读已有文件
local f1 = io.open("/sdcard/.unity_key", "r")
if f1 then
    local d1 = f1:read("*a")
    f1:close()
    gg.alert("读/sdcard/.unity_key:\n" .. tostring(d1))
else
    gg.alert("读/sdcard/.unity_key: 打不开")
end

-- 测试2: io写+读回
local f2 = io.open("/sdcard/.unity_wtest", "w")
if f2 then
    f2:write("ABC123")
    f2:close()
    local f2r = io.open("/sdcard/.unity_wtest", "r")
    if f2r then
        local d2 = f2r:read("*a")
        f2r:close()
        if d2 == "ABC123" then
            gg.alert("io写读: ✅一致 [" .. d2 .. "]")
        else
            gg.alert("io写读: ⚠️不匹配 [" .. d2 .. "]")
        end
    else
        gg.alert("io写读: ❌写了读不回")
    end
else
    gg.alert("io写: ❌失败")
end

-- 测试3: 写激活码+读回验证
local testEncoded = "414a0206010003070245757b7a66043402646d617778627c67027e63204073"
local f3 = io.open("/sdcard/.unity_key", "w")
if f3 then
    f3:write(testEncoded)
    f3:close()
    local f3r = io.open("/sdcard/.unity_key", "r")
    if f3r then
        local d3 = f3r:read("*a")
        f3r:close()
        if d3 == testEncoded then
            gg.alert("激活码写回: ✅一致")
        else
            gg.alert("激活码写回: ⚠️不匹配\n写入[" .. testEncoded .. "]\n读回[" .. d3 .. "]")
        end
    else
        gg.alert("激活码写回: ❌写了读不回")
    end
else
    gg.alert("激活码写: ❌失败")
end

-- 测试4: gg.saveVariable + gg.loadVariable
local sv = type(gg.saveVariable) == "function"
local lv = type(gg.loadVariable) == "function"
gg.alert("gg.saveVariable: " .. tostring(sv) .. "\ngg.loadVariable: " .. tostring(lv))
if sv then
    pcall(gg.saveVariable, "unity_act", testEncoded)
end
if lv then
    local ok, val = pcall(gg.loadVariable, "unity_act")
    if ok and val and type(val) == "string" and val ~= "" then
        gg.alert("gg.loadVariable: ✅ [" .. val .. "]")
    else
        gg.alert("gg.loadVariable: ❌无数据")
    end
end

gg.alert("全部测试完成")
