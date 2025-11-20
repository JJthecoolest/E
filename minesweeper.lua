-- === CONFIG === --
_G.MS_RUN = true
local FLAG = game:GetService("Workspace").Flag
local MS = FLAG.Parts
local SAFE_TEXT = "failed to fetch text"
local MINE_COLOR = Color3.fromRGB(205, 142, 100)   -- confirmed real mine color
local SPACING = 5                                   -- tiles spaced by 5 studs
local ORIGIN = Vector3.new(0, 70, 0)

local LOOP_DELAY = 0.01          -- main loop delay
local NEW_CHECK_INTERVAL = 1.0  -- how often (seconds) to scan MS:GetChildren() for new/removed tiles
local NEW_CHECK_TICKS = math.max(1, math.floor(NEW_CHECK_INTERVAL / LOOP_DELAY))

-- === DRAWING HELPERS === --
local function new_marker(txt, color)
    local d = Drawing.new("Text")
    d.Text = txt
    d.Color = color
    d.Outline = true
    d.Center = true
    d.Size = Vector2.new(22,22)
    d.Visible = true
    return d
end

local markers = {}   -- part -> Drawing

-- world→screen mapping
local hasWTS = (type(WorldToScreen) == "function")
local function w2s_safe(pos)
    if not hasWTS then return nil end
    local ok, res = pcall(function() return WorldToScreen(pos) end)
    if ok then return res end
    return nil
end

local function set_marker(part, txt, col)
    if not part then return end
    local m = markers[part]
    if not m then
        m = new_marker(txt, col)
        markers[part] = m
    else
        m.Text = txt
        m.Color = col
    end
    -- safe w2s call
    if part and part.Parent then
        local s = w2s_safe(part.Position)
        if s then
            m.Position = s
            m.Visible = true
        else
            m.Visible = false
        end
    else
        m.Visible = false
    end
end

local function remove_marker_for_part(part)
    if not part then return end
    local m = markers[part]
    if m then
        -- safe removal
        pcall(function() m:Remove() end)
        markers[part] = nil
    end
end

-- === TILE CLASSIFICATION (robust) === --
local function classify_tile(part)
    -- guard against part being nil or removed
    if not part or not part.Parent then
        return "deleted", nil
    end

    -- First check for number GUI (revealed tile). Use safe checks + pcall for Text.
    local okGui, gui = pcall(function() return part:FindFirstChild("NumberGui") end)
    if okGui and gui and gui.Parent then
        local okLabel, label = pcall(function() return gui:FindFirstChild("TextLabel") end)
        if okLabel and label and label.Parent then
            local okText, text = pcall(function() return label.Text end)
            if okText and type(text) == "string" then
                if text == SAFE_TEXT then
                    return "empty", 0
                end
                local n = tonumber(text)
                if n then
                    return "number", n
                end
            end
            -- if pcall failed or text non-string, fallthrough to other checks
        end
    end

    -- No number → could be mine or unknown. Read color safely.
    local okCol, col = pcall(function() return part.Color end)
    if okCol and col == MINE_COLOR then
        return "mine", nil
    end

    -- Otherwise it's a covered tile
    return "unknown", nil
end

-- === SAFE POSITION → grid key helper === --
local function safe_pos_to_key(part)
    if not part or not part.Parent then return nil end
    local ok, pos = pcall(function() return part.Position end)
    if not ok or not pos then return nil end
    local gx = math.floor((pos.X - ORIGIN.X) / SPACING + 0.5)
    local gz = math.floor((pos.Z - ORIGIN.Z) / SPACING + 0.5)
    return gx.."|"..gz, gx, gz
end

-- === TILE STORAGE === --
local tiles = {}   -- array of tile objects {part,gx,gz,type,number,predicted}
local grid = {}    -- map "gx|gz" -> tile

local function generate_tile(part)
    if not part or not part.Parent then return end
    local key, gx, gz = safe_pos_to_key(part)
    if not key then return end

    if grid[key] then
        -- If already exists and same part, nothing to do
        if grid[key].part == part then return end
        -- otherwise, remove previous tile's marker and replace
        remove_marker_for_part(grid[key].part)
    end

    local tp, val = classify_tile(part)
    local t = {
        part = part,
        gx = gx,
        gz = gz,
        type = tp,
        number = val,
        predicted = false,
    }
    tiles[#tiles+1] = t
    grid[key] = t
end

-- initial fill (pcall for safety)
local ok_init, children_init = pcall(function() return MS:GetChildren() end)
if ok_init and children_init then
    for _, part in pairs(children_init) do
        generate_tile(part)
    end
end

-- === NEIGHBOR OFFSETS === --
local neigh = {
    {-1,-1},{-1,0},{-1,1},
    {0,-1},        {0,1},
    {1,-1},{1,0},{1,1}
}

local function neighbors(t)
    local out = {}
    for _,o in ipairs(neigh) do
        local key = (t.gx + o[1]).."|"..(t.gz + o[2])
        local v = grid[key]
        if v then out[#out+1] = v end
    end
    return out
end

-- === HELPER: analyze neighbors quickly === --
local function analyze_adjacent(t)
    local adj = neighbors(t)
    local knownM = 0
    local unknowns = {}
    for _, n in ipairs(adj) do
        if n.type == "mine" or n.predicted == "mine" then
            knownM = knownM + 1
        elseif n.type == "unknown" then
            unknowns[#unknowns+1] = n
        end
    end
    return knownM, unknowns
end

-- === BASIC SINGLE-TILE DEDUCTION (original rules) === --
local function solve_once_basic()
    local changed = false
    for _, t in ipairs(tiles) do
        if t.type == "number" then
            local knownM, unknowns = analyze_adjacent(t)
            local needed = t.number - knownM
            local U = #unknowns
            if U > 0 then
                if needed == 0 then
                    for _, u in ipairs(unknowns) do
                        if u.predicted ~= "safe" then
                            u.predicted = "safe"
                            changed = true
                        end
                    end
                elseif needed == U then
                    for _, u in ipairs(unknowns) do
                        if u.predicted ~= "mine" then
                            u.predicted = "mine"
                            changed = true
                        end
                    end
                end
            end
        end
    end
    return changed
end

-- === REMAINING-MINES DEDUCTION (fix for your corner case) === --
local function solve_once_remaining_mines()
    local changed = false
    for _, t in ipairs(tiles) do
        if t.type == "number" then
            local knownM, unknowns = analyze_adjacent(t)
            local remaining = t.number - knownM
            if remaining > 0 and #unknowns == remaining then
                for _, u in ipairs(unknowns) do
                    if u.predicted ~= "mine" then
                        u.predicted = "mine"
                        changed = true
                    end
                end
            end
        end
    end
    return changed
end

-- === LIGHTWEIGHT PAIRWISE SUBSET INFERENCE === --
local function solve_once_subset()
    local changed = false

    local number_tiles = {}
    for _, t in ipairs(tiles) do
        if t.type == "number" then number_tiles[#number_tiles+1] = t end
    end

    local info = {}
    for _, t in ipairs(number_tiles) do
        local knownM, unknowns = analyze_adjacent(t)
        local needed = t.number - knownM
        local ucount = #unknowns
        local uset = {}
        for _, u in ipairs(unknowns) do uset[u] = true end
        info[t] = { unknowns = unknowns, needed = needed, ucount = ucount, uset = uset }
    end

    for i = 1, #number_tiles do
        local A = number_tiles[i]
        local Ai = info[A]
        if not Ai or Ai.ucount == 0 then
            -- nothing
        else
            for j = i + 1, #number_tiles do
                local B = number_tiles[j]
                local Bi = info[B]
                if not Bi or Bi.ucount == 0 then
                    -- skip
                else
                    -- A subset B?
                    local a_in_b = true
                    for u,_ in pairs(Ai.uset) do if not Bi.uset[u] then a_in_b = false break end end
                    if a_in_b then
                        local diff = Bi.ucount - Ai.ucount
                        if Ai.needed == Bi.needed and diff > 0 then
                            for u,_ in pairs(Bi.uset) do
                                if not Ai.uset[u] and u.predicted ~= "safe" then
                                    u.predicted = "safe"; changed = true
                                end
                            end
                        elseif (Bi.needed - Ai.needed) == diff and diff > 0 then
                            for u,_ in pairs(Bi.uset) do
                                if not Ai.uset[u] and u.predicted ~= "mine" then
                                    u.predicted = "mine"; changed = true
                                end
                            end
                        end
                    end

                    -- B subset A?
                    local b_in_a = true
                    for u,_ in pairs(Bi.uset) do if not Ai.uset[u] then b_in_a = false break end end
                    if b_in_a then
                        local diff2 = Ai.ucount - Bi.ucount
                        if Bi.needed == Ai.needed and diff2 > 0 then
                            for u,_ in pairs(Ai.uset) do
                                if not Bi.uset[u] and u.predicted ~= "safe" then
                                    u.predicted = "safe"; changed = true
                                end
                            end
                        elseif (Ai.needed - Bi.needed) == diff2 and diff2 > 0 then
                            for u,_ in pairs(Ai.uset) do
                                if not Bi.uset[u] and u.predicted ~= "mine" then
                                    u.predicted = "mine"; changed = true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return changed
end

-- === RUN MIXED PASSES UNTIL STABLE === --
local function solve_all()
    for _ = 1, 200 do
        local c1 = solve_once_basic()
        local c2 = solve_once_remaining_mines()
        local c3 = solve_once_subset()
        if not (c1 or c2 or c3) then break end
    end
end

-- initial solve + draw
solve_all()
for _, t in ipairs(tiles) do
    if t.predicted == "mine" and t.type ~= "mine" then
        set_marker(t.part, "M", Color3.fromRGB(255,40,40))
    elseif t.predicted == "safe" and t.type == "unknown" then
        set_marker(t.part, "S", Color3.fromRGB(50,255,50))
    end
end

-- === MAIN LOOP (optimized checks) === --
local tick = 0
local last_child_count = (pcall(function() return #MS:GetChildren() end) and #MS:GetChildren()) or 0

while _G.MS_RUN do
    local changed = false
    tick = tick + 1

    -- 1) Occasionally scan for new/removed tiles (cheap if interval > loop)
    if (tick % NEW_CHECK_TICKS) == 0 then
        local ok_children, children = pcall(function() return MS:GetChildren() end)
        if ok_children and children then
            local cur_count = #children
            if cur_count ~= last_child_count then
                last_child_count = cur_count
                -- add new ones
                for _, part in ipairs(children) do
                    local key = nil
                    local okk, kx, kz = pcall(function() return safe_pos_to_key(part) end)
                    if okk and kx then key = kx end
                    -- safe_pos_to_key returns (key,gx,gz) so when used inside pcall we get multiple returns; handle
                    if not key then
                        -- attempt direct safe call without pcall wrapper
                        key = safe_pos_to_key(part)
                    end
                    if key and not grid[key] then
                        generate_tile(part)
                        changed = true
                    end
                end
                -- remove deleted ones
                for i = #tiles, 1, -1 do
                    local t = tiles[i]
                    if not t.part or not t.part.Parent then
                        remove_marker_for_part(t.part)
                        if t.gx and t.gz then grid[t.gx.."|"..t.gz] = nil end
                        table.remove(tiles, i)
                        changed = true
                    end
                end
            end
        end
    end

    -- 2) Reclassify existing tiles quickly each loop so revealed numbers are noticed promptly.
    for _, t in ipairs(tiles) do
        local ok, newType, newNumber = pcall(function() return classify_tile(t.part) end)
        if ok then
            if newType ~= t.type or newNumber ~= t.number then
                t.type = newType
                t.number = newNumber
                t.predicted = false
                remove_marker_for_part(t.part)
                changed = true
            end
        else
            -- classification error — mark changed so solver re-evaluates next loop
            changed = true
        end
    end

    -- 3) Re-solve only if something changed
    if changed then
        solve_all()
    end

    -- 4) Update/create markers for predictions; remove invalid ones
    for _, t in ipairs(tiles) do
        if t.predicted == "mine" and t.type ~= "mine" then
            set_marker(t.part, "M", Color3.fromRGB(255,40,40))
        elseif t.predicted == "safe" and t.type == "unknown" then
            set_marker(t.part, "S", Color3.fromRGB(50,255,50))
        else
            remove_marker_for_part(t.part)
        end
    end

    -- 5) Update marker positions and cleanup vanished parts
    for part, m in pairs(markers) do
        if part and part.Parent then
            local s = w2s_safe(part.Position)
            if s then
                m.Position = s
                m.Visible = true
            else
                m.Visible = false
            end
        else
            pcall(function() m:Remove() end)
            markers[part] = nil
        end
    end

    task.wait(LOOP_DELAY)
end

-- cleanup on exit
for p, m in pairs(markers) do
    pcall(function() m:Remove() end)
    markers[p] = nil
end
