--- @diagnostic disable: lowercase-global

--- Component sheet management for the Animation Automator.
--- Handles schema definition, component sheet creation with labeled rows/columns,
--- and extraction of component images from sheets.

Components = {}
Components.__index = Components

--- Plugin key for sprite.properties storage (publisher/name from package.json).
Components.PLUGIN_KEY = "Masterdan/asprite-dmi-MD"
Components.SIDECAR_SUFFIX = ".component.json"

--- Get the sidecar JSON file path for a sprite.
--- e.g. "C:/art/player.aseprite" -> "C:/art/player.component.json"
--- @param sprite Sprite
--- @return string|nil path, string|nil relativeName
function Components.getSidecarPath(sprite)
    if not sprite or not sprite.filename or sprite.filename == "" then
        return nil, nil
    end
    local dir = app.fs.filePath(sprite.filename)
    local title = app.fs.fileTitle(sprite.filename)
    if not dir or dir == "" or not title or title == "" then
        return nil, nil
    end
    local relName = title .. Components.SIDECAR_SUFFIX
    local fullPath = app.fs.joinPath(dir, relName)
    return fullPath, relName
end

--- Write the sidecar JSON file for a sprite.
--- @param sprite Sprite
--- @param encoded string The JSON string to write
--- @return boolean success
function Components.writeSidecar(sprite, encoded)
    local path, _ = Components.getSidecarPath(sprite)
    if not path then return false end
    local ok, err = pcall(function()
        local f = io.open(path, "w")
        if f then
            f:write(encoded)
            f:close()
        else
            error("Could not open file for writing: " .. path)
        end
    end)
    if not ok then
        print("[DMI] writeSidecar failed: " .. tostring(err))
    end
    return ok
end

--- Read the sidecar JSON file for a sprite.
--- @param sprite Sprite
--- @return string|nil rawJson
function Components.readSidecar(sprite)
    local path, _ = Components.getSidecarPath(sprite)
    if not path then return nil end
    if not app.fs.isFile(path) then return nil end
    local ok, result = pcall(function()
        local f = io.open(path, "r")
        if f then
            local content = f:read("*a")
            f:close()
            return content
        end
        return nil
    end)
    if ok then return result end
    return nil
end

--- Width of the label column in pixels.
Components.LABEL_WIDTH = 64

--- Directions list for 3-dir mode.
Components.DIRS_3 = { "south", "north", "east" }

--- Directions list for 4-dir mode.
Components.DIRS_4 = { "south", "north", "east", "west" }

--- Short direction labels for header row.
Components.DIR_SHORT = { south = "S", north = "N", east = "E", west = "W" }

------------------- PIXEL FONT -------------------

--- 3×5 pixel font for rendering labels on the reference layer.
--- Each character is a table of 5 rows; each row is a 3-bit bitmask (bit2=left, bit1=center, bit0=right).
local FONT = {
    -- Digits
    [48] = {7,5,5,5,7}, -- 0
    [49] = {2,6,2,2,7}, -- 1
    [50] = {7,1,7,4,7}, -- 2
    [51] = {7,1,7,1,7}, -- 3
    [52] = {5,5,7,1,1}, -- 4
    [53] = {7,4,7,1,7}, -- 5
    [54] = {7,4,7,5,7}, -- 6
    [55] = {7,1,1,1,1}, -- 7
    [56] = {7,5,7,5,7}, -- 8
    [57] = {7,5,7,1,7}, -- 9
    -- Uppercase letters
    [65]  = {2,5,7,5,5}, -- A
    [66]  = {6,5,6,5,6}, -- B
    [67]  = {3,4,4,4,3}, -- C
    [68]  = {6,5,5,5,6}, -- D
    [69]  = {7,4,6,4,7}, -- E
    [70]  = {7,4,6,4,4}, -- F
    [71]  = {3,4,5,5,3}, -- G
    [72]  = {5,5,7,5,5}, -- H
    [73]  = {7,2,2,2,7}, -- I
    [74]  = {1,1,1,5,2}, -- J
    [75]  = {5,5,6,5,5}, -- K
    [76]  = {4,4,4,4,7}, -- L
    [77]  = {5,7,7,5,5}, -- M
    [78]  = {5,7,7,5,5}, -- N
    [79]  = {2,5,5,5,2}, -- O
    [80]  = {6,5,6,4,4}, -- P
    [81]  = {2,5,5,6,3}, -- Q
    [82]  = {6,5,6,5,5}, -- R
    [83]  = {3,4,2,1,6}, -- S
    [84]  = {7,2,2,2,2}, -- T
    [85]  = {5,5,5,5,2}, -- U
    [86]  = {5,5,5,2,2}, -- V
    [87]  = {5,5,7,7,5}, -- W
    [88]  = {5,5,2,5,5}, -- X
    [89]  = {5,5,2,2,2}, -- Y
    [90]  = {7,1,2,4,7}, -- Z
    -- Lowercase (same glyphs as uppercase for simplicity)
    [97]  = {2,5,7,5,5}, -- a
    [98]  = {6,5,6,5,6}, -- b
    [99]  = {3,4,4,4,3}, -- c
    [100] = {6,5,5,5,6}, -- d
    [101] = {7,4,6,4,7}, -- e
    [102] = {7,4,6,4,4}, -- f
    [103] = {3,4,5,5,3}, -- g
    [104] = {5,5,7,5,5}, -- h
    [105] = {7,2,2,2,7}, -- i
    [106] = {1,1,1,5,2}, -- j
    [107] = {5,5,6,5,5}, -- k
    [108] = {4,4,4,4,7}, -- l
    [109] = {5,7,7,5,5}, -- m
    [110] = {5,7,7,5,5}, -- n
    [111] = {2,5,5,5,2}, -- o
    [112] = {6,5,6,4,4}, -- p
    [113] = {2,5,5,6,3}, -- q
    [114] = {6,5,6,5,5}, -- r
    [115] = {3,4,2,1,6}, -- s
    [116] = {7,2,2,2,2}, -- t
    [117] = {5,5,5,5,2}, -- u
    [118] = {5,5,5,2,2}, -- v
    [119] = {5,5,7,7,5}, -- w
    [120] = {5,5,2,5,5}, -- x
    [121] = {5,5,2,2,2}, -- y
    [122] = {7,1,2,4,7}, -- z
    -- Symbols
    [47]  = {1,1,2,4,4}, -- /
    [95]  = {0,0,0,0,7}, -- _
    [45]  = {0,0,7,0,0}, -- -
    [46]  = {0,0,0,0,2}, -- .
    [32]  = {0,0,0,0,0}, -- space
}

--- Draw a single character from the pixel font.
--- @param image Image Target image
--- @param charCode number ASCII code of the character
--- @param x number X position
--- @param y number Y position
--- @param color number Packed RGBA pixel color
local function drawChar(image, charCode, x, y, color)
    local pattern = FONT[charCode]
    if not pattern then return end
    for row = 0, 4 do
        for col = 0, 2 do
            if (pattern[row + 1] & (4 >> col)) ~= 0 then
                local px, py = x + col, y + row
                if px >= 0 and px < image.width and py >= 0 and py < image.height then
                    image:drawPixel(px, py, color)
                end
            end
        end
    end
end

--- Draw a text string using the pixel font (4px pitch per character).
--- @param image Image Target image
--- @param text string Text to draw
--- @param x number X position
--- @param y number Y position
--- @param color number Packed RGBA pixel color
local function drawText(image, text, x, y, color)
    for i = 1, #text do
        local code = string.byte(text, i)
        drawChar(image, code, x + (i - 1) * 4, y, color)
    end
end

------------------- SCHEMA PARSING -------------------

--- Parse a comma-separated component string into a structured component list.
--- Supports variants via slash notation: "head, legs, legs/walk1, legs/walk2"
--- Components are ordered by first appearance. Variants are grouped under their component.
--- @param str string Comma-separated component string
--- @return table[] componentList Ordered list of {name, variants} tables
--- @return table[] rowList Ordered list of {name, variant} for each row
function Components.parseComponentString(str)
    local seen = {}       -- name → index in componentList
    local componentList = {} -- ordered unique components with variants
    local rowList = {}       -- ordered rows (name + variant per row)

    for part in str:gmatch("[^,]+") do
        part = part:match("^%s*(.-)%s*$") -- trim whitespace
        if part ~= "" then
            -- Check for ? prefix (hidden by default)
            local hidden = false
            if part:sub(1, 1) == "?" then
                hidden = true
                part = part:sub(2)
            end

            local name, variant
            local slashPos = part:find("/")
            if slashPos then
                name = part:sub(1, slashPos - 1)
                variant = part:sub(slashPos + 1)
            else
                name = part
                variant = "default"
            end

            -- Track unique components
            if not seen[name] then
                seen[name] = #componentList + 1
                table.insert(componentList, { name = name, variants = { variant }, hidden_by_default = hidden })
            else
                -- Add variant to existing component (avoid duplicates)
                local comp = componentList[seen[name]]
                -- If any entry for this component has ?, mark it hidden
                if hidden then comp.hidden_by_default = true end
                local found = false
                for _, v in ipairs(comp.variants) do
                    if v == variant then found = true; break end
                end
                if not found then
                    table.insert(comp.variants, variant)
                end
            end

            -- Every entry becomes a row
            table.insert(rowList, { name = name, variant = variant })
        end
    end

    return componentList, rowList
end

--- Create a new schema table from parameters.
--- @param name string Schema name
--- @param tileSize number Tile size in pixels
--- @param dirCount number Number of directions (3 or 4)
--- @param autoMirrorWest boolean Whether to auto-mirror west from east
--- @param componentStr string Comma-separated component string
--- @return table schema
function Components.newSchema(name, tileSize, dirCount, autoMirrorWest, componentStr)
    local componentList, rowList = Components.parseComponentString(componentStr)

    local directions
    if dirCount == 4 then
        directions = { "south", "north", "east", "west" }
        autoMirrorWest = false
    else
        directions = { "south", "north", "east" }
    end

    return {
        name = name,
        tile_size = tileSize,
        label_width = Components.LABEL_WIDTH,
        directions = directions,
        auto_mirror_west = autoMirrorWest,
        components = componentList,
        row_list = rowList,
    }
end

------------------- REFERENCE IMAGE -------------------

--- Generate the reference layer image for a component sheet.
--- Renders direction headers in row 0, component/variant labels in column 0.
--- No grid lines — just labels on a dark background.
--- @param schema table The schema definition
--- @return Image The reference image
function Components.generateReference(schema)
    local ts = schema.tile_size
    local lw = schema.label_width
    local dirs = schema.directions
    local rows = schema.row_list

    local canvasW = lw + #dirs * ts
    local canvasH = ts + #rows * ts
    local img = Image(canvasW, canvasH, ColorMode.RGB)

    local bgColor = app.pixelColor.rgba(40, 40, 45, 200)
    local textColor = app.pixelColor.rgba(220, 220, 220, 230)
    local textShadow = app.pixelColor.rgba(0, 0, 0, 180)
    local dimTextColor = app.pixelColor.rgba(160, 160, 170, 200)

    -- Fill header row background (full width)
    for y = 0, ts - 1 do
        for x = 0, canvasW - 1 do
            img:drawPixel(x, y, bgColor)
        end
    end

    -- Fill label column background (below header)
    for y = ts, canvasH - 1 do
        for x = 0, lw - 1 do
            img:drawPixel(x, y, bgColor)
        end
    end

    -- Draw direction headers centered in each column
    for i, dir in ipairs(dirs) do
        local label = Components.DIR_SHORT[dir] or dir:sub(1, 1):upper()
        local labelW = #label * 4 - 1
        local x = lw + (i - 1) * ts + math.floor((ts - labelW) / 2)
        local y = math.floor((ts - 5) / 2)
        drawText(img, label, x + 1, y + 1, textShadow)
        drawText(img, label, x, y, textColor)
    end

    -- Draw component/variant labels in the label column
    for i, row in ipairs(rows) do
        local label
        if row.variant == "default" then
            label = row.name
        else
            label = row.name .. "/" .. row.variant
        end

        -- Truncate if too long for label column
        local maxChars = math.floor((lw - 4) / 4)
        if #label > maxChars then
            label = label:sub(1, maxChars)
        end

        local x = 2 -- small left margin
        local y = ts + (i - 1) * ts + math.floor((ts - 5) / 2)
        drawText(img, label, x + 1, y + 1, textShadow)
        drawText(img, label, x, y, dimTextColor)
    end

    -- Draw schema name in the corner cell (row 0, column 0)
    local cornerLabel = schema.name
    local maxCornerChars = math.floor((lw - 4) / 4)
    if #cornerLabel > maxCornerChars then
        cornerLabel = cornerLabel:sub(1, maxCornerChars)
    end
    local cx = 2
    local cy = math.floor((ts - 5) / 2)
    drawText(img, cornerLabel, cx + 1, cy + 1, textShadow)
    drawText(img, cornerLabel, cx, cy, textColor)

    return img
end

------------------- SHEET CREATION -------------------

--- Create a new component sheet sprite from a schema.
--- The sprite has a locked Reference layer with labels and an active Art layer.
--- Schema JSON is stored in sprite.data.
--- @param schema table The schema definition
--- @return Sprite|nil The created sprite
function Components.newSheet(schema)
    local ts = schema.tile_size
    local lw = schema.label_width
    local dirs = schema.directions
    local rows = schema.row_list

    local canvasW = lw + #dirs * ts
    local canvasH = ts + #rows * ts

    -- Create sprite
    local sprite = Sprite(canvasW, canvasH, ColorMode.RGB)

    -- Rename default layer to Art
    local artLayer = sprite.layers[1]
    artLayer.name = "Art"

    -- Create reference layer
    local refLayer = sprite:newLayer()
    refLayer.name = "Reference"
    refLayer.opacity = 180

    -- Generate and place reference image
    local refImage = Components.generateReference(schema)
    sprite:newCel(refLayer, 1, refImage, Point(0, 0))

    -- Move reference to bottom, lock it
    refLayer.stackIndex = 1
    refLayer.isEditable = false

    -- Store schema + empty poses in sprite data as JSON.
    -- Write to both sprite.data and sprite.properties for maximum compatibility.
    local data = {
        type = "component_sheet",
        schema = schema,
        poses = {},
    }
    Components.saveData(sprite, data)

    -- Activate the art layer
    app.activeLayer = sprite.layers[2]
    app.refresh()

    return sprite
end

------------------- SHEET READING -------------------

--- Read the stored data (schema + poses) from a sprite.
--- Reads from sprite.properties first (reliable persistence), falls back to
--- sprite.data for backward compatibility with older saves.
--- @param sprite Sprite
--- @return table|nil data The parsed data table, or nil if not a component sheet
function Components.readData(sprite)
    if not sprite then
        return nil
    end

    local rawData = nil
    local source = "none"

    -- 1) Try sprite.data first
    local spriteData = sprite.data
    if spriteData and spriteData ~= "" then
        -- sprite.data format: "SIDECAR:filename.component.json\n{...json...}"
        -- or just plain JSON for backward compat
        local jsonStr = spriteData
        -- Strip the sidecar header if present
        if jsonStr:sub(1, 8) == "SIDECAR:" then
            local nlPos = jsonStr:find("\n")
            if nlPos then
                jsonStr = jsonStr:sub(nlPos + 1)
            end
        end
        local ok, decoded = pcall(json.decode, jsonStr)
        if ok and decoded then
            -- Accept data if it has type="component_sheet" OR has schema+poses fields
            local isValid = false
            pcall(function()
                if decoded.type == "component_sheet" then
                    isValid = true
                elseif decoded.schema and decoded.poses then
                    isValid = true
                end
            end)
            if isValid then
                rawData = jsonStr
                source = "sprite.data"
            end
        end
    end

    -- 2) Fallback: read sidecar .component.json file
    if not rawData then
        local sidecarJson = Components.readSidecar(sprite)
        if sidecarJson and sidecarJson ~= "" then
            local ok, decoded = pcall(json.decode, sidecarJson)
            if ok and decoded then
                local isValid = false
                pcall(function()
                    if decoded.type == "component_sheet" then
                        isValid = true
                    elseif decoded.schema and decoded.poses then
                        isValid = true
                    end
                end)
                if isValid then
                    rawData = sidecarJson
                    source = "sidecar"
                end
            end
        end
    end

    if not rawData then
        return nil
    end

    local ok, decoded = pcall(json.decode, rawData)
    if not ok or not decoded then
        return nil
    end

    -- Aseprite's json.decode returns userdata, so we can't use type() == "table".
    -- Just access fields directly from the userdata.

    -- Check that it has the expected fields
    local hasType = false
    local hasSchema = false
    local hasPoses = false
    pcall(function()
        if decoded.type == "component_sheet" then hasType = true end
        if decoded.schema then hasSchema = true end
        if decoded.poses then hasPoses = true end
    end)

    if not hasType and not (hasSchema and hasPoses) then
        return nil
    end

    -- Convert the userdata to a plain Lua table so the rest of our code works
    local data = {
        type = decoded.type,
        schema = {},
        poses = {},
    }

    -- Copy optional ref_path
    pcall(function()
        if decoded.ref_path and decoded.ref_path ~= "" then
            data.ref_path = decoded.ref_path
        end
    end)

    -- Copy schema fields
    local s = decoded.schema
    if s then
        data.schema = {
            name = s.name,
            tile_size = s.tile_size,
            label_width = s.label_width,
            auto_mirror_west = s.auto_mirror_west,
            directions = {},
            components = {},
            row_list = {},
        }
        -- Copy directions
        if s.directions then
            for i = 1, #s.directions do
                data.schema.directions[i] = s.directions[i]
            end
        end
        -- Copy components
        if s.components then
            for i = 1, #s.components do
                local comp = s.components[i]
                local variants = {}
                if comp.variants then
                    for j = 1, #comp.variants do
                        variants[j] = comp.variants[j]
                    end
                end
                data.schema.components[i] = {
                    name = comp.name,
                    variants = variants,
                    hidden_by_default = comp.hidden_by_default or false,
                }
            end
        end
        -- Copy row_list
        if s.row_list then
            for i = 1, #s.row_list do
                local row = s.row_list[i]
                data.schema.row_list[i] = { name = row.name, variant = row.variant }
            end
        end
    end

    -- Copy poses (may be empty table or have state data)
    if decoded.poses then
        -- poses could be an empty array [] (decoded as userdata) or a keyed object
        -- Try iterating with pairs
        local posesOk, _ = pcall(function()
            for stateName, stateData in pairs(decoded.poses) do
                data.poses[stateName] = {
                    dirs = stateData.dirs,
                    loop = stateData.loop,
                    own_west = stateData.own_west,
                    delays = {},
                    frames = {},
                    layer_order = {},
                }
                if stateData.delays then
                    for i = 1, #stateData.delays do
                        data.poses[stateName].delays[i] = stateData.delays[i]
                    end
                end
                -- Copy layer_order if present (per-direction or flat)
                if stateData.layer_order then
                    if type(stateData.layer_order[1]) == "string" then
                        -- Old flat format → migrate to per-dir
                        local flat = {}
                        for i = 1, #stateData.layer_order do flat[i] = stateData.layer_order[i] end
                        local dirs = { "south", "north", "east", "west" }
                        data.poses[stateName].layer_order = {}
                        for _, d in ipairs(dirs) do
                            data.poses[stateName].layer_order[d] = {}
                            for i, n in ipairs(flat) do
                                data.poses[stateName].layer_order[d][i] = n
                            end
                        end
                    else
                        -- Per-direction format
                        data.poses[stateName].layer_order = {}
                        for d, dirOrder in pairs(stateData.layer_order) do
                            data.poses[stateName].layer_order[d] = {}
                            for i = 1, #dirOrder do
                                data.poses[stateName].layer_order[d][i] = dirOrder[i]
                            end
                        end
                    end
                end
                if stateData.frames then
                    for fi = 1, #stateData.frames do
                        local frame = stateData.frames[fi]
                        data.poses[stateName].frames[fi] = {}
                        for dir, comps in pairs(frame) do
                            data.poses[stateName].frames[fi][dir] = {}
                            for comp, transform in pairs(comps) do
                                data.poses[stateName].frames[fi][dir][comp] = {
                                    x = transform.x,
                                    y = transform.y,
                                    rotation = transform.rotation,
                                    flip_h = transform.flip_h,
                                    flip_v = transform.flip_v,
                                    scale_x = transform.scale_x or transform.scale or 1.0,
                                    scale_y = transform.scale_y or transform.scale or 1.0,
                                    variant = transform.variant,
                                    visible = (transform.visible == nil) and true or transform.visible,
                                }
                            end
                        end
                    end
                end
            end
        end)
    end

    -- If recovered from sidecar, backfill sprite.data
    if source == "sidecar" then
        pcall(function()
            Components.saveData(sprite, data)
        end)
    end

    return data
end

--- Save data (schema + poses) back to a sprite.
--- Writes to both sprite.data and the sidecar .component.json file.
--- sprite.data format: "SIDECAR:filename.component.json\n{json}"
--- so the sidecar path is always at the start (survives truncation).
--- @param sprite Sprite
--- @param data table The data table to save
function Components.saveData(sprite, data)
    local encoded = json.encode(data)

    -- Build sprite.data with sidecar header at the front
    local _, relName = Components.getSidecarPath(sprite)
    local dataStr
    if relName then
        dataStr = "SIDECAR:" .. relName .. "\n" .. encoded
    else
        dataStr = encoded
    end

    app.transaction("Save component data", function()
        sprite.data = dataStr
    end)

    -- Auto-save the .aseprite file so sprite.data persists on disk
    if sprite.filename and sprite.filename ~= "" then
        pcall(function() sprite:saveAs(sprite.filename) end)
    end

    -- Also write sidecar file
    Components.writeSidecar(sprite, encoded)
end

--- Extract a single component image from a component sheet.
--- @param sprite Sprite The component sheet sprite
--- @param schema table The schema
--- @param rowIndex number Row index (1-based, in row_list)
--- @param dirIndex number Direction index (1-based, in schema.directions)
--- @return Image The extracted image (tile_size × tile_size)
function Components.extractCell(sprite, schema, rowIndex, dirIndex)
    local ts = schema.tile_size
    local lw = schema.label_width

    local sx = lw + (dirIndex - 1) * ts
    local sy = ts + (rowIndex - 1) * ts -- +ts for header row

    -- Flatten visible non-reference layers for this region
    local img = Image(ts, ts, ColorMode.RGB)
    for _, layer in ipairs(sprite.layers) do
        if layer.name ~= "Reference" and layer.isVisible then
            local cel = layer:cel(1)
            if cel then
                -- Calculate the overlap between the cel and our target rectangle
                local celX = cel.position.x
                local celY = cel.position.y
                local celImg = cel.image
                for y = 0, ts - 1 do
                    for x = 0, ts - 1 do
                        local srcX = sx + x - celX
                        local srcY = sy + y - celY
                        if srcX >= 0 and srcX < celImg.width and srcY >= 0 and srcY < celImg.height then
                            local pv = celImg:getPixel(srcX, srcY)
                            local a = (pv >> 24) & 0xFF
                            if a > 0 then
                                img:drawPixel(x, y, pv)
                            end
                        end
                    end
                end
            end
        end
    end

    return img
end

--- Extract all component images from a component sheet.
--- Returns a nested table: images[componentName][variant][direction] = Image
--- If auto_mirror_west is true, west images are generated by flipping east.
--- @param sprite Sprite The component sheet sprite
--- @param schema table The schema
--- @return table images Nested lookup table of component images
function Components.extractAllComponents(sprite, schema)
    local images = {}
    local dirs = schema.directions

    -- Build row index lookup: for each component/variant, which row?
    for rowIdx, row in ipairs(schema.row_list) do
        if not images[row.name] then
            images[row.name] = {}
        end
        if not images[row.name][row.variant] then
            images[row.name][row.variant] = {}
        end

        for dirIdx, dir in ipairs(dirs) do
            images[row.name][row.variant][dir] = Components.extractCell(sprite, schema, rowIdx, dirIdx)
        end

        -- Auto-mirror west from east if needed
        if schema.auto_mirror_west and not images[row.name][row.variant]["west"] then
            local eastImg = images[row.name][row.variant]["east"]
            if eastImg then
                images[row.name][row.variant]["west"] = LuaTransform.flipH(eastImg)
            end
        end
    end

    return images
end

--- Get the ordered list of component names (for z-order / display).
--- @param schema table
--- @return string[] names
function Components.getComponentNames(schema)
    local names = {}
    local seen = {}
    for _, row in ipairs(schema.row_list) do
        if not seen[row.name] then
            seen[row.name] = true
            table.insert(names, row.name)
        end
    end
    return names
end

--- Get the variant list for a specific component.
--- @param schema table
--- @param componentName string
--- @return string[] variants
function Components.getVariants(schema, componentName)
    for _, comp in ipairs(schema.components) do
        if comp.name == componentName then
            return comp.variants
        end
    end
    return { "default" }
end

--- Check if a component is hidden by default.
--- @param schema table
--- @param componentName string
--- @return boolean
function Components.isHiddenByDefault(schema, componentName)
    for _, comp in ipairs(schema.components) do
        if comp.name == componentName then
            return comp.hidden_by_default == true
        end
    end
    return false
end

------------------- ADDING ROWS TO EXISTING SHEET -------------------

--- Add new component rows to an existing component sheet.
--- Parses the component string, skips duplicates, extends the sprite canvas,
--- regenerates the reference layer, and returns the count of rows added.
--- The schema table is modified in place.
--- @param sprite Sprite The component sheet sprite
--- @param schema table The schema (modified in place)
--- @param newComponentStr string Comma-separated component string (same format as newSchema)
--- @return number addedCount How many new rows were actually added
function Components.addRows(sprite, schema, newComponentStr)
    local newComps, newRows = Components.parseComponentString(newComponentStr)

    -- Filter out rows that already exist
    local existingKeys = {}
    for _, row in ipairs(schema.row_list) do
        existingKeys[row.name .. "\0" .. row.variant] = true
    end

    local rowsToAdd = {}
    for _, row in ipairs(newRows) do
        local key = row.name .. "\0" .. row.variant
        if not existingKeys[key] then
            table.insert(rowsToAdd, row)
            existingKeys[key] = true
        end
    end

    if #rowsToAdd == 0 then
        return 0
    end

    -- Append to schema.row_list
    for _, row in ipairs(rowsToAdd) do
        table.insert(schema.row_list, row)
    end

    -- Update schema.components (add new components or new variants to existing)
    for _, row in ipairs(rowsToAdd) do
        local found = false
        for _, comp in ipairs(schema.components) do
            if comp.name == row.name then
                found = true
                local vExists = false
                for _, v in ipairs(comp.variants) do
                    if v == row.variant then vExists = true; break end
                end
                if not vExists then
                    table.insert(comp.variants, row.variant)
                end
                break
            end
        end
        if not found then
            table.insert(schema.components, { name = row.name, variants = { row.variant } })
        end
    end

    -- Compute new canvas dimensions
    local ts = schema.tile_size
    local lw = schema.label_width
    local dirs = schema.directions
    local newCanvasW = lw + #dirs * ts
    local newCanvasH = ts + #schema.row_list * ts

    -- Extend canvas and regenerate reference layer
    app.transaction("Add component rows", function()
        -- Extend canvas downward (crop to larger bounds)
        if newCanvasH > sprite.height or newCanvasW > sprite.width then
            sprite:crop(0, 0,
                math.max(newCanvasW, sprite.width),
                math.max(newCanvasH, sprite.height))
        end

        -- Find and regenerate the reference layer
        for _, layer in ipairs(sprite.layers) do
            if layer.name == "Reference" then
                local cel = layer:cel(1)
                if cel then
                    sprite:deleteCel(cel)
                end
                local refImage = Components.generateReference(schema)
                sprite:newCel(layer, 1, refImage, Point(0, 0))
                break
            end
        end
    end)

    return #rowsToAdd
end

------------------- SCHEMA DIALOG -------------------

--- Show the "New Component Sheet" dialog.
--- Prompts for schema name, tile size, directions, and component list.
--- Creates the component sheet sprite on confirmation.
--- @return Sprite|nil The created sprite, or nil if cancelled
function Components.showNewSchemaDialog()
    local dlg = Dialog("New Component Sheet")

    dlg:entry {
        id = "name",
        label = "Schema Name:",
        text = "humanoid",
    }

    dlg:number {
        id = "tile_size",
        label = "Tile Size:",
        text = "64",
        decimals = 0,
    }

    dlg:combobox {
        id = "dir_mode",
        label = "Directions:",
        option = "3 (auto-mirror West)",
        options = { "3 (auto-mirror West)", "4 (explicit West)" },
    }

    dlg:entry {
        id = "components",
        label = "Components:",
        text = "head, torso, right_arm, left_arm, legs",
    }

    dlg:label {
        text = "Tip: / for variants, ? for hidden: legs, legs/walk1, ?cape",
    }

    dlg:button { id = "ok", text = "Create Sheet" }
    dlg:button { id = "cancel", text = "Cancel" }
    dlg:show()

    if not dlg.data.ok then return nil end

    -- Validate
    local tileSize = dlg.data.tile_size
    if tileSize < 8 or tileSize % 2 ~= 0 then
        app.alert("Tile size must be an even number >= 8")
        return nil
    end

    local schemaName = dlg.data.name
    if schemaName == "" then
        app.alert("Schema name is required")
        return nil
    end

    local compStr = dlg.data.components
    if compStr == "" then
        app.alert("At least one component is required")
        return nil
    end

    local dirMode = dlg.data.dir_mode
    local dirCount = dirMode:sub(1, 1) == "3" and 3 or 4
    local autoMirror = dirCount == 3

    local schema = Components.newSchema(schemaName, tileSize, dirCount, autoMirror, compStr)

    if #schema.row_list == 0 then
        app.alert("No valid components found")
        return nil
    end

    return Components.newSheet(schema)
end

------------------- EDIT SHEET DIALOG -------------------

--- Show the "Edit Component Sheet" dialog.
--- Lets the user add new component/variant rows to the currently open
--- component sheet without needing to open the Pose Editor.
--- @return boolean success
function Components.showEditSheetDialog()
    local sprite = app.sprite
    if not sprite then
        app.alert("No sprite is currently open.")
        return false
    end

    local data = Components.readData(sprite)
    if not data then
        app.alert("This sprite is not a component sheet.\n\nUse 'New Component Sheet' first.")
        return false
    end

    local schema = data.schema

    -- Build a readable summary of existing rows
    local existingParts = {}
    for _, row in ipairs(schema.row_list) do
        local prefix = Components.isHiddenByDefault(schema, row.name) and "?" or ""
        if row.variant == "default" then
            table.insert(existingParts, prefix .. row.name)
        else
            table.insert(existingParts, prefix .. row.name .. "/" .. row.variant)
        end
    end

    local dlg = Dialog("Edit Component Sheet")

    dlg:label {
        text = "Current parts: " .. table.concat(existingParts, ", "),
    }

    dlg:entry {
        id = "new_parts",
        label = "Add Parts:",
        text = "",
    }

    dlg:label {
        text = "/ for variants, ? for hidden: cape, cape/red, ?sword",
    }

    dlg:button { id = "ok", text = "Add" }
    dlg:button { id = "cancel", text = "Cancel" }
    dlg:show()

    if not dlg.data.ok or dlg.data.new_parts == "" then
        return false
    end

    local added = Components.addRows(sprite, schema, dlg.data.new_parts)
    if added == 0 then
        app.alert("All specified components already exist.")
        return false
    end

    -- Save updated schema + poses back to sprite.data
    data.schema = schema
    Components.saveData(sprite, data)
    app.refresh()

    app.alert(added .. " row(s) added to the component sheet.")
    return true
end
