--- @diagnostic disable: lowercase-global

--- Pose Editor for the Animation Automator.
--- Provides a visual dialog for positioning, rotating, and flipping components
--- to define DMI icon states. Stores transform data in the component sheet's
--- sprite.data alongside the schema.

PoseEditor = {}
PoseEditor.__index = PoseEditor

------------------- CONSTANTS -------------------

local CANVAS_SIZE = 256  -- requested size; rendering adapts if dialog squishes it
local CHECKER_SIZE = 8
local CHECKER_A = app.pixelColor.rgba(180, 180, 180, 255)
local CHECKER_B = app.pixelColor.rgba(140, 140, 140, 255)
local SELECTION_COLOR = app.pixelColor.rgba(0, 200, 255, 200)
local GRID_COLOR = Color { r = 255, g = 255, b = 255, a = 30 }
local CENTER_COLOR = Color { r = 255, g = 80, b = 80, a = 160 }
local ONION_ALPHA = 80  -- 0-255, how visible the onion skin ghost is
local REF_ALPHA = 76    -- ~30% of 255, opacity for reference background layer

--- BYOND direction ordering: south=0, north=1, east=2, west=3
local BYOND_DIR_ORDER = { "south", "north", "east", "west" }

------------------- DATA MODEL -------------------

--- Create a default (identity) transform.
--- @return table transform
local function defaultTransform()
    return {
        x = 0,
        y = 0,
        rotation = 0,
        flip_h = false,
        flip_v = false,
        scale_x = 1.0,
        scale_y = 1.0,
        variant = "default",
        visible = true,
    }
end

--- Deep copy a transform table.
--- @param t table
--- @return table
local function copyTransform(t)
    return {
        x = t.x or 0,
        y = t.y or 0,
        rotation = t.rotation or 0,
        flip_h = t.flip_h or false,
        flip_v = t.flip_v or false,
        scale_x = t.scale_x or t.scale or 1.0,
        scale_y = t.scale_y or t.scale or 1.0,
        variant = t.variant or "default",
        visible = (t.visible == nil) and true or t.visible,
    }
end

--- Deep copy an entire frame (all directions, all components).
--- @param frame table
--- @return table
local function copyFrame(frame)
    local copy = {}
    for dir, comps in pairs(frame) do
        if dir == "mirror_east" then
            copy[dir] = "mirror_east"
        else
            copy[dir] = {}
            for comp, transform in pairs(comps) do
                copy[dir][comp] = copyTransform(transform)
            end
        end
    end
    return copy
end

------------------- EDITOR STATE -------------------

--- Create a new PoseEditor instance.
--- @param sprite Sprite The component sheet sprite
--- @return PoseEditor|nil
function PoseEditor.new(sprite)
    local data = Components.readData(sprite)
    if not data then
        -- Diagnostics: print to console so user can copy/paste
        print("=== DMI Component Sheet Diagnostics ===")

        local rawData = sprite.data
        if rawData and rawData ~= "" then
            print("sprite.data (" .. #rawData .. " chars): " .. rawData:sub(1, 500))
            -- Try to parse and show why readData rejected it
            local jsonStr = rawData
            if jsonStr:sub(1, 8) == "SIDECAR:" then
                local nlPos = jsonStr:find("\n")
                if nlPos then jsonStr = jsonStr:sub(nlPos + 1) end
            end
            local decOk, decVal = pcall(json.decode, jsonStr)
            if decOk and decVal then
                print("  json.decode: OK (type=" .. type(decVal) .. ")")
                pcall(function()
                    print("  decoded.type = " .. tostring(decVal.type))
                    print("  decoded.schema = " .. tostring(decVal.schema))
                    print("  decoded.poses = " .. tostring(decVal.poses))
                end)
            else
                print("  json.decode FAILED: " .. tostring(decVal))
            end
        else
            print("sprite.data: (empty)")
        end

        local sidecarPath = Components.getSidecarPath(sprite)
        if sidecarPath then
            print("sidecar path: " .. sidecarPath)
            if app.fs.isFile(sidecarPath) then
                local sj = Components.readSidecar(sprite)
                if sj then
                    print("sidecar file (" .. #sj .. " chars): " .. sj:sub(1, 500))
                else
                    print("sidecar file: (read failed)")
                end
            else
                print("sidecar file: (not found)")
            end
        else
            print("sidecar path: (sprite not saved to disk)")
        end

        print("=== End Diagnostics ===")
        app.alert("This sprite is not a component sheet.\n\nCheck Aseprite console (View > Console) for diagnostics.")
        return nil
    end

    local self = setmetatable({}, PoseEditor)

    self.sprite = sprite
    self.schema = data.schema
    self.poses = data.poses or {}

    -- Extract all component images from the sheet
    self.componentImages = Components.extractAllComponents(sprite, self.schema)
    self.componentNames = Components.getComponentNames(self.schema)

    -- Editing state
    self.currentState = nil
    self.currentFrame = 1
    self.currentDir = "south"
    self.selectedComponent = self.componentNames[1] or nil

    -- Compute zoom so tile fills CANVAS_SIZE
    local ts = self.schema.tile_size
    self.zoom = math.max(1, math.floor(CANVAS_SIZE / ts))
    self.canvasPixels = self.zoom * ts

    -- UI state
    self.dragging = false
    self.dragStartX = 0
    self.dragStartY = 0
    self.dragOrigX = 0
    self.dragOrigY = 0
    self.updatingControls = false
    self.dialog = nil

    -- Cached preview
    self.previewImage = nil
    self.previewDirty = true

    -- Display options
    self.showGrid = true
    self.showOnionSkin = true
    self.showRefFull = false

    -- Create initial state if none exist
    if not next(self.poses) then
        self:addState("")
    end

    -- Set current state to first available
    for name, _ in pairs(self.poses) do
        self.currentState = name
        break
    end

    -- Get editable directions (exclude west if auto-mirrored)
    self.editableDirs = {}
    for _, dir in ipairs(self.schema.directions) do
        table.insert(self.editableDirs, dir)
    end
    if self.schema.auto_mirror_west then
        table.insert(self.editableDirs, "west")
    end

    -- Reconcile poses with current schema (handles components added/removed
    -- between sessions)
    self:reconcilePoses()

    -- Restore saved reference DMI path if available
    self.refPath = data.ref_path or nil

    return self
end

--- Reconcile existing pose data with the current schema.
--- Ensures every state's layer_order includes all current components,
--- removes references to deleted components, and fills in default
--- transforms for any missing component/direction entries.
function PoseEditor:reconcilePoses()
    local nameSet = {}
    for _, name in ipairs(self.componentNames) do
        nameSet[name] = true
    end

    local allDirs = self.schema.auto_mirror_west
        and { "south", "north", "east", "west" }
        or self.schema.directions

    for _, stateData in pairs(self.poses) do
        -- ── layer_order: add new, prune removed ──
        if stateData.layer_order then
            local orderSet = {}
            for _, n in ipairs(stateData.layer_order) do
                orderSet[n] = true
            end
            -- Append new components that aren't in layer_order yet
            for _, n in ipairs(self.componentNames) do
                if not orderSet[n] then
                    table.insert(stateData.layer_order, n)
                end
            end
            -- Remove components no longer in schema
            local cleaned = {}
            for _, n in ipairs(stateData.layer_order) do
                if nameSet[n] then
                    table.insert(cleaned, n)
                end
            end
            stateData.layer_order = cleaned
        end

        -- ── frames: ensure every dir/comp has a transform ──
        if stateData.frames then
            for _, frame in ipairs(stateData.frames) do
                for _, dir in ipairs(allDirs) do
                    if not frame[dir] then frame[dir] = {} end
                    for _, comp in ipairs(self.componentNames) do
                        if not frame[dir][comp] then
                            frame[dir][comp] = defaultTransform()
                        end
                    end
                end
            end
        end
    end
end

--- Get all state names as a sorted list.
--- @return string[]
--- Convert an internal state key to a display name for the UI.
--- "" → "(blank)", everything else unchanged.
local function stateToDisplay(key)
    if key == "" then return "(blank)" end
    return key
end

--- Convert a display name back to an internal state key.
--- "(blank)" → "", everything else unchanged.
local function displayToState(display)
    if display == "(blank)" then return "" end
    return display
end

--- Check if an internal state key represents a movement state.
local function isMovementState(key)
    return key:sub(-3) == "(m)"
end

--- Get the DMI export name and movement flag from an internal key.
--- "punch(m)" → "punch", true
--- "punch"    → "punch", false
--- ""         → "", false
local function parseStateForExport(key)
    if isMovementState(key) then
        return key:sub(1, -4), true
    end
    return key, false
end

function PoseEditor:getStateNames()
    local names = {}
    for name, _ in pairs(self.poses) do
        table.insert(names, stateToDisplay(name))
    end
    table.sort(names)
    return names
end

--- Add a new state with the given name.
--- @param name string
--- @param dirCount number|nil  1 or 4 (default: schema dirs)
function PoseEditor:addState(name, dirCount)
    if self.poses[name] then return end
    -- layer_order controls draw order: first = back, last = front
    -- Copy from blank state template if it exists, otherwise use default
    local order = {}
    if name ~= "" and self.poses[""] and self.poses[""].layer_order then
        for i, n in ipairs(self.poses[""].layer_order) do
            order[i] = n
        end
    else
        for i, comp in ipairs(self.componentNames) do
            order[i] = comp
        end
    end

    -- Determine direction count
    local schemaDirs = self.schema.auto_mirror_west and 4 or #self.schema.directions
    local dirs = dirCount or schemaDirs
    if dirs ~= 1 and dirs ~= 4 then dirs = schemaDirs end

    self.poses[name] = {
        dirs = dirs,
        frames = { {} }, -- one empty frame
        delays = { 1.0 },
        loop = 0,  -- 0 = infinite
        own_west = false, -- true = this state has its own west frames (no auto-mirror)
        layer_order = order,
    }
    -- Initialize directions with default transforms for frame 1.
    -- If the blank state ("") exists and has frame data, use it as a template
    -- so that new states inherit positioning, scale, rotation, visibility.
    local templateFrame = nil
    if name ~= "" and self.poses[""] and self.poses[""].frames and self.poses[""].frames[1] then
        templateFrame = self.poses[""].frames[1]
    end

    local frame = self.poses[name].frames[1]
    local initDirs
    if dirs == 1 then
        initDirs = { "south" }
    elseif self.schema.auto_mirror_west then
        initDirs = { "south", "north", "east", "west" }
    else
        initDirs = self.schema.directions
    end
    for _, dir in ipairs(initDirs) do
        frame[dir] = {}
        for _, comp in ipairs(self.componentNames) do
            if templateFrame and templateFrame[dir] and templateFrame[dir][comp] then
                frame[dir][comp] = copyTransform(templateFrame[dir][comp])
            else
                local t = defaultTransform()
                if Components.isHiddenByDefault(self.schema, comp) then
                    t.visible = false
                end
                frame[dir][comp] = t
            end
        end
    end
end

--- Delete a state.
--- @param name string
function PoseEditor:deleteState(name)
    self.poses[name] = nil
end

--- Add a frame to the current state (copies the last frame).
function PoseEditor:addFrame()
    local state = self.poses[self.currentState]
    if not state then return end
    local lastFrame = state.frames[#state.frames]
    local newFrame = lastFrame and copyFrame(lastFrame) or {}
    table.insert(state.frames, newFrame)
    table.insert(state.delays, state.delays[#state.delays] or 1.0)
end

--- Delete the current frame from the current state.
function PoseEditor:deleteFrame()
    local state = self.poses[self.currentState]
    if not state or #state.frames <= 1 then return end -- keep at least 1 frame
    table.remove(state.frames, self.currentFrame)
    table.remove(state.delays, self.currentFrame)
    if self.currentFrame > #state.frames then
        self.currentFrame = #state.frames
    end
end

--- Read a .bytes file (Rust raw format) into an Aseprite Image.
--- Format: ASCII width \n ASCII height \n raw RGBA pixel data.
--- @param path string
--- @return Image|nil
local function readBytesFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if not content or #content < 4 then return nil end

    -- Parse ASCII width and height from header
    local headerEnd1 = content:find("\n", 1, true)
    if not headerEnd1 then return nil end
    local headerEnd2 = content:find("\n", headerEnd1 + 1, true)
    if not headerEnd2 then return nil end

    local w = tonumber(content:sub(1, headerEnd1 - 1))
    local h = tonumber(content:sub(headerEnd1 + 1, headerEnd2 - 1))
    if not w or not h or w <= 0 or h <= 0 then return nil end

    local pixelData = content:sub(headerEnd2 + 1)
    if #pixelData < w * h * 4 then return nil end

    local img = Image(w, h, ColorMode.RGB)
    local idx = 1
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local r = pixelData:byte(idx)
            local g = pixelData:byte(idx + 1)
            local b = pixelData:byte(idx + 2)
            local a = pixelData:byte(idx + 3)
            idx = idx + 4
            if a > 0 then
                img:drawPixel(x, y, app.pixelColor.rgba(r, g, b, a))
            end
        end
    end
    return img
end

--- Load a reference DMI file for visual overlay.
--- Reads all states/frames from the DMI and stores images in self.referenceFrames.
--- Merges state metadata (skip existing states, add new ones).
--- @param path string Path to the DMI file
--- @param pluginPath string Plugin path for loading the library
--- @return boolean success
function PoseEditor:loadReferenceDMI(path, pluginPath)
    -- Wrap everything in pcall so a native crash doesn't kill Aseprite
    local success, resultOrErr = pcall(function()
        return self:_loadReferenceDMIInner(path, pluginPath)
    end)
    if not success then
        print("[DMI] loadReferenceDMI CRASHED: " .. tostring(resultOrErr))
        app.alert("Reference load failed (caught crash):\n" .. tostring(resultOrErr))
        return false
    end
    return resultOrErr
end

--- Inner implementation of loadReferenceDMI (separated so pcall can wrap it).
function PoseEditor:_loadReferenceDMIInner(path, pluginPath)
    loadlib(pluginPath)

    -- Create temp directory for reference DMI frames
    if not app.fs.isDirectory(TEMP_DIR) then
        app.fs.makeDirectory(TEMP_DIR)
    end
    local tempDir = app.fs.joinPath(TEMP_DIR, "ref_" .. os.time())
    app.fs.makeDirectory(tempDir)
    if not app.fs.isDirectory(tempDir) then
        app.alert("Failed to create temp directory for reference DMI.")
        return false
    end

    local dmi, err = libdmi.open_file(path, tempDir)
    if err then
        app.alert("Failed to open reference DMI:\n" .. tostring(err))
        pcall(function() libdmi.remove_dir(tempDir, true) end)
        return false
    end

    -- The Rust library creates a subdirectory inside tempDir;
    -- dmi.temp has the actual path where .bytes files were written.
    local bytesDir = dmi.temp or tempDir

    -- Validate tile size matches
    if dmi.width ~= math.floor(self.schema.tile_size) or dmi.height ~= math.floor(self.schema.tile_size) then
        app.alert("Reference DMI size (" .. dmi.width .. "x" .. dmi.height
            .. ") doesn't match schema tile size (" .. math.floor(self.schema.tile_size) .. ").\n"
            .. "Cannot use as reference.")
        pcall(function() libdmi.remove_dir(tempDir, true) end)
        return false
    end

    -- Read all frame images from .bytes files
    -- Store as self.referenceFrames[stateName][frameIdx][dirName] = Image
    self.referenceFrames = {}

    local statesAdded = 0
    local totalImages = 0

    for _, refState in ipairs(dmi.states) do
        -- Build internal state name from DMI state metadata
        local internalName = refState.name or ""
        if refState.movement then
            if internalName == "" then
                internalName = "(m)"
            else
                internalName = internalName .. "(m)"
            end
        end

        -- Read frame images for this state
        local stateFrames = {}
        local dirCount = refState.dirs or 1
        local dirNames = {}
        for i = 1, dirCount do
            dirNames[i] = BYOND_DIR_ORDER[i] or ("dir" .. i)
        end

        for frameIdx = 1, refState.frame_count do
            stateFrames[frameIdx] = {}
            for dirIdx = 1, dirCount do
                local bytesIdx = (frameIdx - 1) * dirCount + (dirIdx - 1)
                local bytesPath = app.fs.joinPath(bytesDir, refState.frame_key .. "." .. bytesIdx .. ".bytes")
                local img = readBytesFile(bytesPath)
                if img then
                    stateFrames[frameIdx][dirNames[dirIdx]] = img
                    totalImages = totalImages + 1
                end
            end
        end

        self.referenceFrames[internalName] = stateFrames

        -- Merge: create pose state if it doesn't exist yet
        if not self.poses[internalName] then
            self:addState(internalName, dirCount)
            local stateData = self.poses[internalName]
            if stateData then
                -- Set loop from reference
                stateData.loop = refState.loop or 0

                -- Add extra frames directly (addState creates 1 frame)
                for frameIdx = 2, refState.frame_count do
                    local lastFrame = stateData.frames[#stateData.frames]
                    local newFrame = lastFrame and copyFrame(lastFrame) or {}
                    table.insert(stateData.frames, newFrame)
                end

                -- Set delays from reference (after frame count is finalized)
                stateData.delays = {}
                for i, d in ipairs(refState.delays or {}) do
                    stateData.delays[i] = d
                end
                -- Fill any missing delays with 1.0
                for i = #stateData.delays + 1, #stateData.frames do
                    stateData.delays[i] = 1.0
                end
                if #stateData.delays == 0 then
                    stateData.delays = { 1.0 }
                end
            end
            statesAdded = statesAdded + 1
        end
    end

    -- Clean up temp .bytes files (images are in memory now)
    pcall(function()
        if bytesDir ~= tempDir then
            libdmi.remove_dir(bytesDir, true)
        end
        libdmi.remove_dir(tempDir, true)
    end)

    self.previewDirty = true

    local totalStates = 0
    for _ in pairs(self.referenceFrames) do totalStates = totalStates + 1 end

    print("[DMI] Reference loaded: " .. totalStates .. " states, " .. totalImages .. " images, " .. statesAdded .. " new")
    app.alert("Reference loaded: " .. totalStates .. " state(s), " .. statesAdded .. " new state(s) added.")
    return true
end

--- Clear the reference overlay.
function PoseEditor:clearReference()
    self.referenceFrames = nil
    self.previewDirty = true
end

--- Get the reference image for the current state/frame/direction.
--- Returns nil if no reference is loaded or no matching frame exists.
--- @return Image|nil
function PoseEditor:getReferenceImage()
    if not self.referenceFrames then return nil end

    local stateFrames = self.referenceFrames[self.currentState]
    if not stateFrames then return nil end

    local frameData = stateFrames[self.currentFrame]
    if not frameData then return nil end

    local dir = self.currentDir
    local img = frameData[dir]

    -- If no west frame, try mirroring east
    if not img and dir == "west" then
        local eastImg = frameData["east"]
        if eastImg then
            local ts = self.schema.tile_size
            img = Image(ts, ts, ColorMode.RGB)
            for y = 0, ts - 1 do
                for x = 0, ts - 1 do
                    local sx = ts - 1 - x
                    local pv = eastImg:getPixel(sx, y)
                    if ((pv >> 24) & 0xFF) > 0 then
                        img:drawPixel(x, y, pv)
                    end
                end
            end
        end
    end

    if not img then return nil end

    -- Determine if this direction is an auto-mirrored flip (grey it out)
    local state = self.poses[self.currentState]
    local isAutoFlip = dir == "west"
        and self.schema.auto_mirror_west
        and not (state and state.own_west)

    -- Apply REF_ALPHA reduction (and desaturate if auto-flipped west)
    -- Unless showRefFull is on, in which case return at full opacity
    local ts = self.schema.tile_size
    if self.showRefFull then
        return img:clone()
    end
    local ghost = Image(ts, ts, ColorMode.RGB)
    for y = 0, ts - 1 do
        for x = 0, ts - 1 do
            local v = img:getPixel(x, y)
            local r = v & 0xFF
            local g = (v >> 8) & 0xFF
            local b = (v >> 16) & 0xFF
            local a = (v >> 24) & 0xFF
            if a > 0 then
                if isAutoFlip then
                    -- Desaturate to greyscale to signal "this is just a flip"
                    local grey = math.floor(r * 0.3 + g * 0.59 + b * 0.11)
                    r, g, b = grey, grey, grey
                    a = math.floor(a * REF_ALPHA / 510) -- half the normal ref opacity
                    if a < 1 then a = 1 end
                else
                    a = math.floor(a * REF_ALPHA / 255)
                    if a < 1 then a = 1 end
                end
                ghost:drawPixel(x, y, app.pixelColor.rgba(r, g, b, a))
            end
        end
    end
    return ghost
end

--- Get the transform for a component in the current context.
--- @param compName string
--- @return table transform
function PoseEditor:getTransform(compName)
    local state = self.poses[self.currentState]
    if not state then return defaultTransform() end
    local frame = state.frames[self.currentFrame]
    if not frame then return defaultTransform() end

    local dir = self.currentDir

    -- If west and auto-mirror (but not own_west), show mirrored east transforms
    local autoMirror = self.schema.auto_mirror_west and not (state.own_west)
    if dir == "west" and autoMirror then
        local eastData = frame["east"]
        if eastData and eastData[compName] then
            local t = copyTransform(eastData[compName])
            t.x = -t.x
            t.flip_h = not t.flip_h
            return t
        end
        return defaultTransform()
    end

    local dirData = frame[dir]
    if not dirData then return defaultTransform() end
    return dirData[compName] or defaultTransform()
end

--- Set the transform for a component in the current context.
--- @param compName string
--- @param transform table
function PoseEditor:setTransform(compName, transform)
    local state = self.poses[self.currentState]
    if not state then return end

    -- Don't allow editing west when auto-mirroring (unless state has own_west)
    local autoMirror = self.schema.auto_mirror_west and not (state.own_west)
    if self.currentDir == "west" and autoMirror then
        return
    end

    local frame = state.frames[self.currentFrame]
    if not frame then
        state.frames[self.currentFrame] = {}
        frame = state.frames[self.currentFrame]
    end

    if not frame[self.currentDir] then
        frame[self.currentDir] = {}
    end

    frame[self.currentDir][compName] = transform
    self.previewDirty = true
end

--- Get the layer order for the current state.
--- Returns an array of component names from back to front.
--- @return string[]
function PoseEditor:getLayerOrder()
    local state = self.poses[self.currentState]
    if state and state.layer_order and #state.layer_order > 0 then
        return state.layer_order
    end
    return self.componentNames
end

--- Move the selected component up (towards front) in the layer order.
function PoseEditor:layerMoveUp()
    local state = self.poses[self.currentState]
    if not state or not state.layer_order then return end
    local order = state.layer_order
    for i, name in ipairs(order) do
        if name == self.selectedComponent and i < #order then
            order[i], order[i + 1] = order[i + 1], order[i]
            return true
        end
    end
    return false
end

--- Move the selected component down (towards back) in the layer order.
function PoseEditor:layerMoveDown()
    local state = self.poses[self.currentState]
    if not state or not state.layer_order then return end
    local order = state.layer_order
    for i, name in ipairs(order) do
        if name == self.selectedComponent and i > 1 then
            order[i], order[i - 1] = order[i - 1], order[i]
            return true
        end
    end
    return false
end

------------------- COMPOSITING -------------------

--- Compose a specific frame for the current state/direction.
--- @param frameIdx number The frame index to compose
--- @return Image The composed tile (tile_size × tile_size)
function PoseEditor:composeFrame(frameIdx)
    local ts = self.schema.tile_size
    local composite = Image(ts, ts, ColorMode.RGB)
    local layerOrder = self:getLayerOrder()

    local state = self.poses[self.currentState]
    if not state then return composite end
    local frame = state.frames[frameIdx]
    if not frame then return composite end

    local dir = self.currentDir

    -- Determine if west auto-mirror applies for this state
    local autoMirrorWest = self.schema.auto_mirror_west and not (state.own_west)

    if dir == "west" and autoMirrorWest then
        -- Post-composite mirror: compose east normally, then flip the whole image.
        -- This correctly handles all transforms (scale, rotation, etc.)
        for _, compName in ipairs(layerOrder) do
            local eastData = frame["east"]
            if not eastData or not eastData[compName] then goto continue_mirror end
            local transform = eastData[compName]

            if transform.visible == false then goto continue_mirror end

            local variant = transform.variant or "default"

            local srcImage = self.componentImages[compName]
                and self.componentImages[compName][variant]
                and self.componentImages[compName][variant]["east"]

            if not srcImage then
                srcImage = self.componentImages[compName]
                    and self.componentImages[compName]["default"]
                    and self.componentImages[compName]["default"]["east"]
            end

            if srcImage then
                local transformed = LuaTransform.transform(srcImage, transform, false)
                local ox = transform.x or 0
                local oy = transform.y or 0
                composite:drawImage(transformed, Point(ox, oy))
            end

            ::continue_mirror::
        end
        -- Flip the entire composed east image to produce the west mirror
        composite = LuaTransform.flipH(composite)
    else
        for _, compName in ipairs(layerOrder) do
            local dirData = frame[dir]
            local transform = dirData and dirData[compName] or defaultTransform()

            if transform.visible == false then goto continue end

            local variant = transform.variant or "default"

            local srcImage = self.componentImages[compName]
                and self.componentImages[compName][variant]
                and self.componentImages[compName][variant][self.currentDir]

            if not srcImage then
                srcImage = self.componentImages[compName]
                    and self.componentImages[compName]["default"]
                    and self.componentImages[compName]["default"][self.currentDir]
            end

            if srcImage then
                local transformed = LuaTransform.transform(srcImage, transform, false)
                local ox = transform.x or 0
                local oy = transform.y or 0
                composite:drawImage(transformed, Point(ox, oy))
            end

            ::continue::
        end
    end

    return composite
end

--- Compose the preview image for the current state/frame/direction.
--- @return Image The composed tile (tile_size × tile_size)
function PoseEditor:composePreview()
    self.previewImage = self:composeFrame(self.currentFrame)
    self.previewDirty = false
    return self.previewImage
end

--- Scale the preview image up for canvas display.
--- @return Image Zoomed image
function PoseEditor:getZoomedPreview()
    if self.previewDirty or not self.previewImage then
        self:composePreview()
    end
    return LuaTransform.scale(self.previewImage, self.canvasPixels, self.canvasPixels)
end

--- Get the onion skin ghost image (previous frame, or frame 1 if on frame 1 of a different state view).
--- Returns nil if there's nothing to show.
--- @return Image|nil
function PoseEditor:getOnionSkinImage()
    local state = self.poses[self.currentState]
    if not state then return nil end

    local ghostFrame
    if self.currentFrame > 1 then
        ghostFrame = self.currentFrame - 1
    else
        -- On frame 1: show frame 1 itself as a faint base (the "rest pose")
        -- Only useful if there are multiple states; otherwise skip
        ghostFrame = 1
    end

    local ghostImg = self:composeFrame(ghostFrame)

    -- Apply alpha reduction to make it a faint ghost
    local ts = self.schema.tile_size
    local ghost = Image(ts, ts, ColorMode.RGB)
    for y = 0, ts - 1 do
        for x = 0, ts - 1 do
            local v = ghostImg:getPixel(x, y)
            local r = v & 0xFF
            local g = (v >> 8) & 0xFF
            local b = (v >> 16) & 0xFF
            local a = (v >> 24) & 0xFF
            if a > 0 then
                a = math.floor(a * ONION_ALPHA / 255)
                if a < 1 then a = 1 end
                ghost:drawPixel(x, y, app.pixelColor.rgba(r, g, b, a))
            end
        end
    end

    return ghost
end

------------------- CANVAS RENDERING -------------------

--- Draw a checkerboard transparency background on the graphics context.
--- @param gc GraphicsContext
local function drawCheckerboard(gc, size)
    for y = 0, size - 1, CHECKER_SIZE do
        for x = 0, size - 1, CHECKER_SIZE do
            local isEven = (math.floor(x / CHECKER_SIZE) + math.floor(y / CHECKER_SIZE)) % 2 == 0
            gc.color = isEven and Color { r = 180, g = 180, b = 180, a = 255 } or Color { r = 140, g = 140, b = 140, a = 255 }
            gc:fillRect(Rectangle(x, y, CHECKER_SIZE, CHECKER_SIZE))
        end
    end
end

--- Draw grid lines on the canvas.
--- @param gc GraphicsContext
--- @param size number Canvas pixel size
--- @param zoom number Zoom factor
--- @param ts number Tile size
local function drawGrid(gc, size, zoom, ts)
    gc.color = Color { r = 255, g = 255, b = 255, a = 30 }
    for i = 0, ts do
        local pos = i * zoom
        -- Vertical lines
        gc:fillRect(Rectangle(pos, 0, 1, size))
        -- Horizontal lines
        gc:fillRect(Rectangle(0, pos, size, 1))
    end
end

--- Draw a center crosshair on the canvas.
--- @param gc GraphicsContext
--- @param size number Canvas pixel size
local function drawCenterCross(gc, size)
    local cx = math.floor(size / 2)
    local cy = math.floor(size / 2)
    local armLen = math.max(6, math.floor(size / 16))

    gc.color = Color { r = 255, g = 80, b = 80, a = 160 }
    -- Horizontal arm
    gc:fillRect(Rectangle(cx - armLen, cy, armLen * 2 + 1, 1))
    -- Vertical arm
    gc:fillRect(Rectangle(cx, cy - armLen, 1, armLen * 2 + 1))
end

--- Canvas onpaint handler.
--- Adapts rendering to the actual canvas dimensions — if the dialog
--- squishes the canvas smaller than requested, we zoom out to fit
--- instead of clipping.
--- @param self PoseEditor
--- @param gc GraphicsContext
local function onCanvasPaint(self, gc)
    local ts = self.schema.tile_size

    -- Detect actual available canvas dimensions.
    -- GraphicsContext exposes .width/.height in Aseprite ≥ v1.3-beta21.
    -- Fall back to the requested canvasPixels if the property is absent.
    local displayW = self.canvasPixels
    local displayH = self.canvasPixels
    if gc.width and gc.width > 0 then displayW = gc.width end
    if gc.height and gc.height > 0 then displayH = gc.height end
    local displaySize = math.min(displayW, displayH)

    -- Compute effective zoom: largest integer multiple of ts that fits
    local z = math.max(1, math.floor(displaySize / ts))
    local size = z * ts  -- actual rendered pixel extent (always ≤ displaySize)

    -- Store for mouse-coordinate conversion
    self.displayZoom = z
    self.displaySize = size

    -- 1) Background: checkerboard when grid ON, white when OFF
    if self.showGrid then
        drawCheckerboard(gc, size)
    else
        gc.color = Color { r = 255, g = 255, b = 255, a = 255 }
        gc:fillRect(Rectangle(0, 0, size, size))
    end

    -- 2) Reference background (loaded DMI frame at 30% opacity)
    --    In showRefFull mode, we skip this here and draw it on top later.
    if not self.showRefFull then
        local refImg = self:getReferenceImage()
        if refImg then
            local zoomedRef = LuaTransform.scale(refImg, size, size)
            gc:drawImage(zoomedRef, zoomedRef.bounds, Rectangle(0, 0, size, size))
        end
    end

    -- 3) Onion skin ghost (previous frame, or base pose on frame 1)
    if self.showOnionSkin and not self.showRefFull then
        local ghost = self:getOnionSkinImage()
        if ghost then
            local zoomedGhost = LuaTransform.scale(ghost, size, size)
            gc:drawImage(zoomedGhost, zoomedGhost.bounds, Rectangle(0, 0, size, size))
        end
    end

    -- 4) Current frame preview  (scale to *actual* display size)
    --    Skip in showRefFull mode — only the reference is shown.
    if not self.showRefFull then
        if self.previewDirty or not self.previewImage then
            self:composePreview()
        end
        local zoomed = LuaTransform.scale(self.previewImage, size, size)
        gc:drawImage(zoomed, zoomed.bounds, Rectangle(0, 0, size, size))
    end

    -- 4b) In showRefFull mode, draw the reference at 100% on top
    if self.showRefFull then
        local refImg = self:getReferenceImage()
        if refImg then
            local zoomedRef = LuaTransform.scale(refImg, size, size)
            gc:drawImage(zoomedRef, zoomedRef.bounds, Rectangle(0, 0, size, size))
        end
    end

    -- 5) Grid lines (subtle pixel grid when checkerboard is showing)
    if self.showGrid then
        drawGrid(gc, size, z, ts)
    end

    -- 6) Center crosshair
    drawCenterCross(gc, size)

    -- 7) Selection highlight around selected component
    if self.selectedComponent then
        local transform = self:getTransform(self.selectedComponent)
        local ox = (transform.x or 0) * z
        local oy = (transform.y or 0) * z
        local sx = math.abs(transform.scale_x or 1.0)
        local sy = math.abs(transform.scale_y or 1.0)
        local selW = math.max(1, math.floor(ts * sx)) * z
        local selH = math.max(1, math.floor(ts * sy)) * z

        gc.color = Color { r = 0, g = 200, b = 255, a = 200 }
        gc:strokeRect(Rectangle(ox, oy, selW, selH))

        -- 8) Drag info overlay: show component name + coords
        if self.dragging then
            local infoText = self.selectedComponent
                .. "  (" .. (transform.x or 0) .. ", " .. (transform.y or 0) .. ")"
            gc.color = Color { r = 0, g = 0, b = 0, a = 180 }
            gc:fillText(infoText, 3, size - 11)
            gc.color = Color { r = 255, g = 255, b = 255, a = 255 }
            gc:fillText(infoText, 2, size - 12)
        end
    end

    -- 9) Auto-mirror indicator when viewing W*
    local state = self.poses[self.currentState]
    if self.currentDir == "west"
        and self.schema.auto_mirror_west
        and not (state and state.own_west) then
        gc.color = Color { r = 0, g = 0, b = 0, a = 150 }
        gc:fillText("MIRROR (east flipped)", 3, 3)
        gc.color = Color { r = 255, g = 200, b = 0, a = 230 }
        gc:fillText("MIRROR (east flipped)", 2, 2)
    end
end

------------------- MOUSE INTERACTION -------------------

--- Convert canvas mouse coordinates to tile-space coordinates.
--- Uses the adaptive displayZoom computed during the last paint, so
--- coordinates stay consistent even when the canvas is squished.
--- @param self PoseEditor
--- @param mouseX number
--- @param mouseY number
--- @return number, number Tile-space X, Y
local function canvasToTile(self, mouseX, mouseY)
    local z = self.displayZoom or self.zoom
    return math.floor(mouseX / z), math.floor(mouseY / z)
end

--- Hit test: find which component is at a tile-space position.
--- Checks from top (last in list) to bottom (first in list) for the first
--- component with a non-transparent pixel at that position.
--- @param self PoseEditor
--- @param tileX number
--- @param tileY number
--- @return string|nil componentName
local function hitTest(self, tileX, tileY)
    -- Check in reverse layer order (front-most first)
    local layerOrder = self:getLayerOrder()
    for i = #layerOrder, 1, -1 do
        local compName = layerOrder[i]
        local transform = self:getTransform(compName)

        -- Skip hidden components
        if transform.visible == false then
            goto continue_hit
        end
        local variant = transform.variant or "default"
        local artDir = self.currentDir

        local srcImage = self.componentImages[compName]
            and self.componentImages[compName][variant]
            and self.componentImages[compName][variant][artDir]

        if not srcImage then
            srcImage = self.componentImages[compName]
                and self.componentImages[compName]["default"]
                and self.componentImages[compName]["default"][artDir]
        end

        if srcImage then
            local ox = transform.x or 0
            local oy = transform.y or 0
            local sx = transform.scale_x or 1.0
            local sy = transform.scale_y or 1.0
            local scaledW = math.max(1, math.floor(srcImage.width * math.abs(sx)))
            local scaledH = math.max(1, math.floor(srcImage.height * math.abs(sy)))
            local localX = tileX - ox
            local localY = tileY - oy

            if localX >= 0 and localX < scaledW and localY >= 0 and localY < scaledH then
                -- Map back to source pixel for alpha check
                local srcX = math.min(math.floor(localX * srcImage.width / scaledW), srcImage.width - 1)
                local srcY = math.min(math.floor(localY * srcImage.height / scaledH), srcImage.height - 1)
                local pv = srcImage:getPixel(srcX, srcY)
                local a = (pv >> 24) & 0xFF
                if a > 10 then
                    return compName
                end
            end
        end

        ::continue_hit::
    end

    return nil
end

------------------- CONTROL UPDATES -------------------

--- Update all transform controls to reflect the selected component's current values.
--- @param self PoseEditor
local function updateControls(self)
    if not self.dialog or not self.selectedComponent then return end

    self.updatingControls = true

    local t = self:getTransform(self.selectedComponent)

    -- Checks
    self.dialog:modify { id = "flip_h", selected = t.flip_h or false }
    self.dialog:modify { id = "flip_v", selected = t.flip_v or false }
    local vis = (t.visible == nil) and true or t.visible
    self.dialog:modify { id = "comp_visible", selected = vis }

    -- Display buttons
    self.dialog:modify { id = "rot_btn", text = "R:" .. (t.rotation or 0) }

    -- Scale display
    local sx = t.scale_x or 1.0
    local sy = t.scale_y or 1.0
    if sx == sy then
        self.dialog:modify { id = "scale_btn", text = "S:" .. sx }
    else
        self.dialog:modify { id = "scale_btn", text = "S:" .. sx .. "x" .. sy }
    end

    -- State combobox (display name)
    self.dialog:modify { id = "state_select", option = stateToDisplay(self.currentState or "") }

    -- Per-state direction count — clamp currentDir if state is 1-dir
    local state = self.poses[self.currentState]
    local stateDirs = (state and state.dirs) or 4
    if stateDirs == 1 and self.currentDir ~= "south" then
        self.currentDir = "south"
    end

    -- Direction buttons — highlight active, disable for 1-dir states
    -- West label: W* = auto-mirrored from east, W = own west frames
    local stateOwnWest = state and state.own_west
    local dirs = {}
    for _, d in ipairs(self.schema.directions) do
        table.insert(dirs, d)
    end
    if self.schema.auto_mirror_west then
        table.insert(dirs, "west")
    end
    for _, dir in ipairs(dirs) do
        local btnId = "dir_" .. dir
        local short = dir:sub(1, 1):upper()
        if dir == "west" and self.schema.auto_mirror_west and not stateOwnWest then
            short = short .. "*"
        end
        local label = (dir == self.currentDir) and ("[" .. short .. "]") or short
        self.dialog:modify { id = btnId, text = label }
        self.dialog:modify { id = btnId, enabled = (stateDirs == 4) }
    end

    -- Own-west toggle
    if self.schema.auto_mirror_west then
        self.dialog:modify { id = "own_west_btn", text = stateOwnWest and "[OW]" or "OW" }
    end

    -- Part combobox
    self.dialog:modify { id = "component_select", option = self.selectedComponent or "?" }

    -- Frame display
    local frameCount = state and #state.frames or 1
    self.dialog:modify { id = "frame_label", text = "F" .. self.currentFrame .. "/" .. frameCount }

    -- Frame delay
    local delay = 1.0
    if state and state.delays and state.delays[self.currentFrame] then
        delay = state.delays[self.currentFrame]
    end
    self.dialog:modify { id = "delay_btn", text = "D:" .. delay }

    -- Loop count
    local loop = (state and state.loop) or 0
    local loopText = (loop == 0) and "Loop:\xE2\x88\x9E" or ("Loop:" .. loop)
    self.dialog:modify { id = "loop_btn", text = loopText }

    -- Layer position
    local layerOrder = self:getLayerOrder()
    local layerPos = 0
    for i, name in ipairs(layerOrder) do
        if name == self.selectedComponent then layerPos = i; break end
    end
    self.dialog:modify { id = "layer_label", text = "L" .. layerPos .. "/" .. #layerOrder }

    self.updatingControls = false
end

--- Read the current values from the transform controls and apply them.
--- Position and rotation are edited via sub-dialogs / canvas drag, not
--- persistent dialog widgets, so we only read checks here.
--- @param self PoseEditor
local function applyControlsToTransform(self)
    if self.updatingControls or not self.selectedComponent then return end

    local t = self:getTransform(self.selectedComponent)
    -- x, y are set by canvas drag
    t.flip_h = self.dialog.data.flip_h or false
    t.flip_v = self.dialog.data.flip_v or false
    t.visible = self.dialog.data.comp_visible
    if t.visible == nil then t.visible = true end

    self:setTransform(self.selectedComponent, t)
    self.previewDirty = true
    self.dialog:repaint()
end

------------------- DMI EXPORT -------------------

--- Export the current component sheet + poses as a DMI file.
--- @param self PoseEditor
--- @param outputPath string
--- @param pluginPath string
--- @return boolean success
local function exportDMI(self, outputPath, pluginPath)
    local schema = self.schema
    local ts = math.floor(schema.tile_size)

    -- Ensure library is loaded
    loadlib(pluginPath)

    -- Create temp directory
    if not app.fs.isDirectory(TEMP_DIR) then
        app.fs.makeDirectory(TEMP_DIR)
    end
    local tempDir = app.fs.joinPath(TEMP_DIR, "component_" .. os.time())
    app.fs.makeDirectory(tempDir)

    -- Verify temp dir was created
    if not app.fs.isDirectory(tempDir) then
        app.alert("Failed to create temp directory:\n" .. tempDir)
        return false
    end

    local states = {}

    -- Check if we actually have poses
    local hasAnyState = false
    for _ in pairs(self.poses) do hasAnyState = true; break end
    if not hasAnyState then
        app.alert("No poses to export. Add at least one state first.")
        return false
    end

    local bytesWritten = 0

    for stateName, stateData in pairs(self.poses) do
        local numFrames = #stateData.frames
        if numFrames == 0 then
            numFrames = 1
        end

        -- Parse movement state: "punch(m)" → name="punch", movement=true
        local exportName, isMovement = parseStateForExport(stateName)

        -- Per-state direction count and auto-mirror override
        local stateDirCount = stateData.dirs or 4
        local autoMirror = schema.auto_mirror_west and not stateData.own_west
        local stateExportDirs
        if stateDirCount == 1 then
            stateExportDirs = { "south" }
        elseif autoMirror then
            stateExportDirs = { "south", "north", "east", "west" }
            stateDirCount = 4
        else
            stateExportDirs = {}
            for _, d in ipairs(schema.directions) do
                table.insert(stateExportDirs, d)
            end
            stateDirCount = #stateExportDirs
        end

        -- frame_key must be unique per state (use internal name)
        local frameKey = stateName

        for frameIdx = 1, numFrames do
            for dirIdx, dir in ipairs(stateExportDirs) do
                -- Compose this frame using manual pixel blitting for safety
                local composite = Image(ts, ts, ColorMode.RGB)
                local layerOrder = stateData.layer_order or self.componentNames

                -- For west auto-mirror: compose east normally, then flip the whole image
                local composeDir = dir
                if dir == "west" and autoMirror then
                    composeDir = "east"
                end

                for _, compName in ipairs(layerOrder) do
                    local frame = stateData.frames[frameIdx]
                    if not frame then goto continue_export end

                    local dirComps = frame[composeDir]
                    if not dirComps or not dirComps[compName] then
                        goto continue_export
                    end
                    local transform = dirComps[compName]

                    -- Skip hidden components
                    if transform.visible == false then
                        goto continue_export
                    end

                    local variant = transform.variant or "default"

                    local srcImage = self.componentImages[compName]
                        and self.componentImages[compName][variant]
                        and self.componentImages[compName][variant][composeDir]

                    if not srcImage then
                        srcImage = self.componentImages[compName]
                            and self.componentImages[compName]["default"]
                            and self.componentImages[compName]["default"][composeDir]
                    end

                    if srcImage then
                        -- Apply transforms (no highQuality - pixel art doesn't need it)
                        local transformed = LuaTransform.transform(srcImage, transform, false)

                        -- Safe pixel-level blit into composite (bounds-checked)
                        local ox = transform.x or 0
                        local oy = transform.y or 0
                        for py = 0, transformed.height - 1 do
                            for px = 0, transformed.width - 1 do
                                local cx = ox + px
                                local cy = oy + py
                                if cx >= 0 and cx < ts and cy >= 0 and cy < ts then
                                    local pv = transformed:getPixel(px, py)
                                    local a = (pv >> 24) & 0xFF
                                    if a > 0 then
                                        composite:drawPixel(cx, cy, pv)
                                    end
                                end
                            end
                        end
                    end

                    ::continue_export::
                end

                -- Post-composite mirror: flip the entire east result to produce west
                if dir == "west" and autoMirror then
                    composite = LuaTransform.flipH(composite)
                end

                -- Write .bytes file
                local bytesIdx = (frameIdx - 1) * stateDirCount + (dirIdx - 1)
                local bytesPath = app.fs.joinPath(tempDir, frameKey .. "." .. bytesIdx .. ".bytes")

                local f = io.open(bytesPath, "wb")
                if f then
                    -- Header: width and height as ASCII numbers separated by newlines
                    f:write(string.format("%d\n%d\n", ts, ts))
                    -- Pixel data: RGBA bytes, row by row
                    local pixelCount = ts * ts
                    local buf = {}
                    for y = 0, ts - 1 do
                        for x = 0, ts - 1 do
                            local v = composite:getPixel(x, y)
                            local r = v & 0xFF
                            local g = (v >> 8) & 0xFF
                            local b = (v >> 16) & 0xFF
                            local a = (v >> 24) & 0xFF
                            buf[#buf + 1] = string.char(r, g, b, a)
                        end
                    end
                    f:write(table.concat(buf))
                    f:close()
                    bytesWritten = bytesWritten + 1
                else
                    app.alert("Failed to write bytes file:\n" .. bytesPath)
                    return false
                end
            end
        end

        -- Build delays array for export (default to 1.0 for each frame)
        local exportDelays = {}
        if numFrames > 1 then
            for fi = 1, numFrames do
                exportDelays[fi] = (stateData.delays and stateData.delays[fi]) or 1.0
            end
        end

        table.insert(states, {
            name = exportName,
            dirs = stateDirCount,
            frame_key = frameKey,
            frame_count = numFrames,
            delays = exportDelays,
            loop = stateData.loop or 0,
            rewind = false,
            movement = isMovement,
            hotspots = {},
        })
    end

    -- Sort states by name for consistent output
    table.sort(states, function(a, b) return a.name < b.name end)

    local dmiTable = {
        name = app.fs.fileTitle(outputPath),
        width = math.floor(ts),
        height = math.floor(ts),
        states = states,
        temp = tempDir,
    }

    print("[ExportDMI] Bytes written: " .. bytesWritten)
    print("[ExportDMI] States: " .. #states)
    print("[ExportDMI] Temp dir: " .. tempDir)
    print("[ExportDMI] Output: " .. outputPath)
    for i, s in ipairs(states) do
        print("[ExportDMI] State " .. i .. ": name='" .. s.name .. "' dirs=" .. s.dirs .. " frames=" .. s.frame_count .. " key='" .. s.frame_key .. "'")
    end

    -- Note: libdmi functions use safe!() wrapper and never throw.
    -- They return (result, error_string) instead.
    local result, saveErr = libdmi.save_file(dmiTable, outputPath)
    print("[ExportDMI] save_file returned: result=" .. tostring(result) .. " err=" .. tostring(saveErr))

    -- Clean up temp files
    local _, cleanErr = libdmi.remove_dir(tempDir, false)
    if cleanErr then
        print("[ExportDMI] cleanup warning: " .. cleanErr)
    end

    if saveErr then
        app.alert("Failed to save DMI:\n" .. tostring(saveErr))
        return false
    end

    local stateCount = #states
    local frameCount = 0
    for _, s in ipairs(states) do frameCount = frameCount + s.frame_count end

    app.alert("Component DMI exported!\n\n" ..
        "States: " .. stateCount .. "\n" ..
        "Total frames: " .. frameCount .. "\n" ..
        "Tile size: " .. ts .. "×" .. ts .. "\n" ..
        "Output: " .. outputPath)

    return true
end

------------------- TEMPLATE EXPORT -------------------

--- Export the pose data as a standalone JSON template file.
--- @param self PoseEditor
--- @param outputPath string
--- @return boolean
local function exportTemplate(self, outputPath)
    local data = {
        type = "pose_template",
        schema = self.schema,
        poses = self.poses,
    }

    local f = io.open(outputPath, "w")
    if not f then
        app.alert("Could not write template file: " .. outputPath)
        return false
    end

    f:write(json.encode(data))
    f:close()

    app.alert("Pose template exported!\n" .. outputPath)
    return true
end

------------------- DIALOG CONSTRUCTION -------------------

--- Helper: cycle to the next item in a list, wrapping around.
local function cycleNext(list, current)
    for i, v in ipairs(list) do
        if v == current then
            return list[(i % #list) + 1]
        end
    end
    return list[1]
end

--- Show the pose editor dialog.
--- @param pluginPath string Plugin installation path
function PoseEditor:show(pluginPath)
    local self_ref = self
    local size = self.canvasPixels

    -- Auto-load saved reference DMI if the file still exists
    if self.refPath and self.refPath ~= "" then
        if app.fs.isFile(self.refPath) then
            pcall(function()
                self:loadReferenceDMI(self.refPath, pluginPath)
            end)
        else
            self.refPath = nil  -- file gone, silently clear
        end
    end

    -- All directions including mirror label
    local allDirs = {}
    for _, dir in ipairs(self.schema.directions) do
        table.insert(allDirs, dir)
    end
    if self.schema.auto_mirror_west then
        table.insert(allDirs, "west")
    end

    local dlg = Dialog {
        title = "Pose Editor — " .. self.schema.name,
        onclose = function()
            local data = Components.readData(self_ref.sprite) or {}
            data.type = "component_sheet"
            data.schema = self_ref.schema
            data.poses = self_ref.poses
            data.ref_path = self_ref.refPath or nil
            Components.saveData(self_ref.sprite, data)
        end,
    }

    self.dialog = dlg

    -- ═══════════════════════════════════════════
    -- ROW 1: State combobox (takes its own row)
    -- ═══════════════════════════════════════════

    dlg:combobox {
        id = "state_select",
        label = "State",
        option = stateToDisplay(self.currentState),
        options = self:getStateNames(),
        onchange = function()
            if self_ref.updatingControls then return end
            self_ref.currentState = displayToState(dlg.data.state_select)
            self_ref.currentFrame = 1
            self_ref.previewDirty = true
            updateControls(self_ref)
            dlg:repaint()
        end,
    }

    -- ROW 2: +/- state, frame nav (all buttons → one row)

    dlg:button {
        id = "add_state",
        text = "+",
        onclick = function()
            local nameDlg = Dialog("Add State")
            nameDlg:entry { id = "name", label = "State Name:", text = "" }
            nameDlg:combobox { id = "dirs", label = "Directions:", option = "4 dirs", options = { "1 dir", "4 dirs" } }
            nameDlg:check { id = "movement", text = "Movement state", selected = false }
            nameDlg:label { text = "Leave name blank for the default idle state." }
            nameDlg:button { id = "ok", text = "OK" }
            nameDlg:button { id = "cancel", text = "Cancel" }
            nameDlg:show()
            if nameDlg.data.ok then
                local rawName = nameDlg.data.name
                local dirCount = (nameDlg.data.dirs == "1 dir") and 1 or 4
                -- Append (m) for movement states
                if nameDlg.data.movement and rawName ~= "" then
                    rawName = rawName .. "(m)"
                elseif nameDlg.data.movement and rawName == "" then
                    -- blank movement state: "(m)" by itself
                    rawName = "(m)"
                end
                -- rawName is "" for blank non-movement state
                if self_ref.poses[rawName] then
                    app.alert("State '" .. stateToDisplay(rawName) .. "' already exists.")
                    return
                end
                self_ref:addState(rawName, dirCount)
                self_ref.currentState = rawName
                self_ref.currentFrame = 1
                self_ref.previewDirty = true
                dlg:modify { id = "state_select", options = self_ref:getStateNames(), option = stateToDisplay(self_ref.currentState) }
                updateControls(self_ref)
                dlg:repaint()
            end
        end,
    }

    dlg:button {
        id = "del_state",
        text = "-",
        onclick = function()
            if self_ref.currentState then
                local displayName = stateToDisplay(self_ref.currentState)
                local result = app.alert {
                    title = "Delete State",
                    text = "Delete state '" .. displayName .. "'?",
                    buttons = { "Yes", "No" },
                }
                if result ~= 1 then return end

                self_ref:deleteState(self_ref.currentState)
                local names = self_ref:getStateNames()
                if #names == 0 then
                    self_ref:addState("")
                    names = self_ref:getStateNames()
                end
                self_ref.currentState = displayToState(names[1])
                self_ref.currentFrame = 1
                self_ref.previewDirty = true
                dlg:modify { id = "state_select", options = names, option = names[1] }
                updateControls(self_ref)
                dlg:repaint()
            end
        end,
    }

    dlg:button {
        id = "loop_btn",
        text = "Loop:\xE2\x88\x9E",
        onclick = function()
            local st = self_ref.poses[self_ref.currentState]
            if not st then return end
            local curLoop = st.loop or 0
            local loopDlg = Dialog("State Loop")
            loopDlg:number { id = "loop", label = "Loop (0=\xE2\x88\x9E):", text = tostring(curLoop), decimals = 0 }
            loopDlg:button { id = "ok", text = "OK" }
            loopDlg:button { id = "cancel", text = "Cancel" }
            loopDlg:show()
            if loopDlg.data.ok then
                st.loop = math.max(0, math.floor(loopDlg.data.loop or 0))
                updateControls(self_ref)
            end
        end,
    }

    dlg:button {
        id = "frame_label",
        text = "F1/1",
        enabled = false,
    }

    dlg:button {
        id = "prev_frame",
        text = "<",
        onclick = function()
            if self_ref.currentFrame > 1 then
                self_ref.currentFrame = self_ref.currentFrame - 1
                self_ref.previewDirty = true
                updateControls(self_ref)
                dlg:repaint()
            end
        end,
    }

    dlg:button {
        id = "next_frame",
        text = ">",
        onclick = function()
            local state = self_ref.poses[self_ref.currentState]
            if state and self_ref.currentFrame < #state.frames then
                self_ref.currentFrame = self_ref.currentFrame + 1
                self_ref.previewDirty = true
                updateControls(self_ref)
                dlg:repaint()
            end
        end,
    }

    dlg:button {
        id = "add_frame",
        text = "+F",
        onclick = function()
            self_ref:addFrame()
            self_ref.currentFrame = #self_ref.poses[self_ref.currentState].frames
            self_ref.previewDirty = true
            updateControls(self_ref)
            dlg:repaint()
        end,
    }

    dlg:button {
        id = "del_frame",
        text = "-F",
        onclick = function()
            self_ref:deleteFrame()
            self_ref.previewDirty = true
            updateControls(self_ref)
            dlg:repaint()
        end,
    }

    dlg:button {
        id = "delay_btn",
        text = "D:1",
        onclick = function()
            local st = self_ref.poses[self_ref.currentState]
            if not st then return end
            local curDelay = (st.delays and st.delays[self_ref.currentFrame]) or 1.0
            local dlyDlg = Dialog("Frame Delay")
            dlyDlg:number { id = "delay", label = "Ticks:", text = tostring(curDelay), decimals = 1 }
            dlyDlg:button { id = "ok", text = "OK" }
            dlyDlg:button { id = "cancel", text = "Cancel" }
            dlyDlg:show()
            if dlyDlg.data.ok then
                if not st.delays then st.delays = {} end
                st.delays[self_ref.currentFrame] = dlyDlg.data.delay or 1.0
                updateControls(self_ref)
            end
        end,
    }

    dlg:newrow()

    -- ═══════════════════════════════════════════
    -- ROW 2: Individual dir buttons + checks
    -- ═══════════════════════════════════════════

    for _, dir in ipairs(allDirs) do
        local short = dir:sub(1, 1):upper()
        if dir == "west" and self.schema.auto_mirror_west then
            short = short .. "*"
        end
        local label = (dir == self.currentDir) and ("[" .. short .. "]") or short
        dlg:button {
            id = "dir_" .. dir,
            text = label,
            onclick = function()
                self_ref.currentDir = dir
                self_ref.previewDirty = true
                updateControls(self_ref)
                dlg:repaint()
            end,
        }
    end

    -- Own-west toggle: this state has its own west frames instead of auto-mirror
    if self.schema.auto_mirror_west then
        dlg:button {
            id = "own_west_btn",
            text = "OW",
            onclick = function()
                local st = self_ref.poses[self_ref.currentState]
                if st then
                    st.own_west = not st.own_west
                    self_ref.previewDirty = true
                    updateControls(self_ref)
                    dlg:repaint()
                end
            end,
        }
    end

    dlg:check {
        id = "show_grid",
        text = "Grid",
        selected = self.showGrid,
        onclick = function()
            self_ref.showGrid = dlg.data.show_grid
            dlg:repaint()
        end,
    }

    dlg:check {
        id = "show_onion",
        text = "Onion",
        selected = self.showOnionSkin,
        onclick = function()
            self_ref.showOnionSkin = dlg.data.show_onion
            dlg:repaint()
        end,
    }

    dlg:check {
        id = "show_ref_full",
        text = "ShowRef",
        selected = false,
        onclick = function()
            self_ref.showRefFull = dlg.data.show_ref_full
            dlg:repaint()
        end,
    }

    dlg:check {
        id = "comp_visible",
        text = "Vis",
        selected = true,
        onclick = function()
            if not self_ref.updatingControls then
                applyControlsToTransform(self_ref)
            end
        end,
    }

    dlg:check {
        id = "flip_h",
        text = "Flip H",
        selected = false,
        onclick = function()
            if not self_ref.updatingControls then
                applyControlsToTransform(self_ref)
            end
        end,
    }

    dlg:check {
        id = "flip_v",
        text = "Flip V",
        selected = false,
        onclick = function()
            if not self_ref.updatingControls then
                applyControlsToTransform(self_ref)
            end
        end,
    }

    dlg:newrow()

    -- ═══════════════════════════════════════════
    -- CANVAS
    -- ═══════════════════════════════════════════

    dlg:canvas {
        id = "preview",
        width = size,
        height = size,

        onpaint = function(ev)
            onCanvasPaint(self_ref, ev.context)
        end,

        onkeydown = function(ev)
            if not self_ref.selectedComponent then return end
            local code = ev.code
            local dx, dy = 0, 0
            if code == "ArrowLeft" then dx = -1
            elseif code == "ArrowRight" then dx = 1
            elseif code == "ArrowUp" then dy = -1
            elseif code == "ArrowDown" then dy = 1
            else return end
            ev:stopPropagation()
            local t = self_ref:getTransform(self_ref.selectedComponent)
            t.x = (t.x or 0) + dx
            t.y = (t.y or 0) + dy
            self_ref:setTransform(self_ref.selectedComponent, t)
            self_ref.previewDirty = true
            updateControls(self_ref)
            dlg:repaint()
        end,

        onmousedown = function(ev)
            local tileX, tileY = canvasToTile(self_ref, ev.x, ev.y)
            local hit = hitTest(self_ref, tileX, tileY)

            if hit then
                self_ref.selectedComponent = hit
                self_ref.previewDirty = true
                self_ref.updatingControls = true
                dlg:modify { id = "component_select", option = hit }
                self_ref.updatingControls = false
                updateControls(self_ref)

                -- Start drag
                self_ref.dragging = true
                self_ref.dragStartX = tileX
                self_ref.dragStartY = tileY
                local t = self_ref:getTransform(hit)
                self_ref.dragOrigX = t.x or 0
                self_ref.dragOrigY = t.y or 0
            end

            dlg:repaint()
        end,

        onmousemove = function(ev)
            if self_ref.dragging and self_ref.selectedComponent then
                local tileX, tileY = canvasToTile(self_ref, ev.x, ev.y)
                local dx = tileX - self_ref.dragStartX
                local dy = tileY - self_ref.dragStartY

                local t = self_ref:getTransform(self_ref.selectedComponent)
                t.x = self_ref.dragOrigX + dx
                t.y = self_ref.dragOrigY + dy
                self_ref:setTransform(self_ref.selectedComponent, t)

                self_ref.previewDirty = true
                updateControls(self_ref)
                dlg:repaint()
            end
        end,

        onmouseup = function(ev)
            self_ref.dragging = false
        end,
    }

    dlg:newrow()

    -- ═══════════════════════════════════════════
    -- ROW 3: Part combobox (takes its own row)
    -- ═══════════════════════════════════════════

    dlg:combobox {
        id = "component_select",
        label = "Part",
        option = self.selectedComponent or "",
        options = self.componentNames,
        onchange = function()
            if self_ref.updatingControls then return end
            self_ref.selectedComponent = dlg.data.component_select
            self_ref.previewDirty = true
            updateControls(self_ref)
            dlg:repaint()
        end,
    }

    -- ROW 4: Layer + rotation (buttons → one row)

    dlg:button {
        id = "layer_up",
        text = "Up",
        onclick = function()
            if self_ref:layerMoveUp() then
                self_ref.previewDirty = true
                updateControls(self_ref)
                dlg:repaint()
            end
        end,
    }

    dlg:button {
        id = "layer_down",
        text = "Dn",
        onclick = function()
            if self_ref:layerMoveDown() then
                self_ref.previewDirty = true
                updateControls(self_ref)
                dlg:repaint()
            end
        end,
    }

    dlg:button {
        id = "layer_label",
        text = "L1/1",
        enabled = false,
    }

    dlg:button {
        id = "rot_btn",
        text = "R:0",
        onclick = function()
            local t = self_ref:getTransform(self_ref.selectedComponent)
            local origRot = t.rotation or 0
            local rotDlg = Dialog { title = "Rotation", parent = dlg }
            rotDlg:slider {
                id = "rot", label = "Degrees:", min = -180, max = 180, value = origRot,
                onchange = function()
                    local rt = self_ref:getTransform(self_ref.selectedComponent)
                    rt.rotation = rotDlg.data.rot or 0
                    self_ref:setTransform(self_ref.selectedComponent, rt)
                    self_ref.previewDirty = true
                    updateControls(self_ref)
                    dlg:repaint()
                end,
            }
            rotDlg:button { id = "ok", text = "OK" }
            rotDlg:button { id = "cancel", text = "Cancel" }
            rotDlg:show()
            if not rotDlg.data.ok then
                -- Revert on cancel
                local rt = self_ref:getTransform(self_ref.selectedComponent)
                rt.rotation = origRot
                self_ref:setTransform(self_ref.selectedComponent, rt)
                self_ref.previewDirty = true
                updateControls(self_ref)
                dlg:repaint()
            end
        end,
    }

    dlg:button {
        id = "scale_btn",
        text = "S:1",
        onclick = function()
            local t = self_ref:getTransform(self_ref.selectedComponent)
            local origSX = t.scale_x or 1.0
            local origSY = t.scale_y or 1.0
            local scaleDlg = Dialog { title = "Scale", parent = dlg }
            scaleDlg:number {
                id = "sx", label = "Scale X:", text = tostring(origSX), decimals = 2,
                onchange = function()
                    local st = self_ref:getTransform(self_ref.selectedComponent)
                    st.scale_x = scaleDlg.data.sx or 1.0
                    self_ref:setTransform(self_ref.selectedComponent, st)
                    self_ref.previewDirty = true
                    updateControls(self_ref)
                    dlg:repaint()
                end,
            }
            scaleDlg:number {
                id = "sy", label = "Scale Y:", text = tostring(origSY), decimals = 2,
                onchange = function()
                    local st = self_ref:getTransform(self_ref.selectedComponent)
                    st.scale_y = scaleDlg.data.sy or 1.0
                    self_ref:setTransform(self_ref.selectedComponent, st)
                    self_ref.previewDirty = true
                    updateControls(self_ref)
                    dlg:repaint()
                end,
            }
            scaleDlg:button { id = "ok", text = "OK" }
            scaleDlg:button { id = "cancel", text = "Cancel" }
            scaleDlg:show()
            if not scaleDlg.data.ok then
                -- Revert on cancel
                local st = self_ref:getTransform(self_ref.selectedComponent)
                st.scale_x = origSX
                st.scale_y = origSY
                self_ref:setTransform(self_ref.selectedComponent, st)
                self_ref.previewDirty = true
                updateControls(self_ref)
                dlg:repaint()
            end
        end,
    }

    dlg:newrow()

    -- ═══════════════════════════════════════════
    -- ROW 5: Actions (all buttons → one shared row)
    -- ═══════════════════════════════════════════

    dlg:button {
        id = "add_part",
        text = "+Part",
        onclick = function()
            local addDlg = Dialog("Add Component")
            addDlg:entry {
                id = "parts",
                label = "Components:",
                text = "",
            }
            addDlg:label {
                text = "Use / for variants: cape, cape/red",
            }
            addDlg:button { id = "ok", text = "Add" }
            addDlg:button { id = "cancel", text = "Cancel" }
            addDlg:show()

            if addDlg.data.ok and addDlg.data.parts ~= "" then
                local added = Components.addRows(
                    self_ref.sprite, self_ref.schema, addDlg.data.parts)

                if added == 0 then
                    app.alert("All specified components already exist.")
                    return
                end

                self_ref.componentImages = Components.extractAllComponents(
                    self_ref.sprite, self_ref.schema)
                self_ref.componentNames = Components.getComponentNames(
                    self_ref.schema)
                self_ref:reconcilePoses()

                local data = {
                    type = "component_sheet",
                    schema = self_ref.schema,
                    poses = self_ref.poses,
                }
                Components.saveData(self_ref.sprite, data)

                dlg:modify {
                    id = "component_select",
                    options = self_ref.componentNames,
                    option = self_ref.selectedComponent or self_ref.componentNames[1],
                }

                self_ref.previewDirty = true
                updateControls(self_ref)
                dlg:repaint()

                app.alert(added .. " row(s) added.\n\nClose to draw art for new parts, then reopen.")
            end
        end,
    }

    dlg:button {
        id = "copy_frame",
        text = "Copy",
        onclick = function()
            local state = self_ref.poses[self_ref.currentState]
            if state then
                self_ref._copiedFrame = copyFrame(state.frames[self_ref.currentFrame] or {})
                app.alert("Frame copied")
            end
        end,
    }

    dlg:button {
        id = "paste_frame",
        text = "Paste",
        onclick = function()
            if self_ref._copiedFrame then
                local state = self_ref.poses[self_ref.currentState]
                if state then
                    state.frames[self_ref.currentFrame] = copyFrame(self_ref._copiedFrame)
                    self_ref.previewDirty = true
                    updateControls(self_ref)
                    dlg:repaint()
                    app.alert("Frame pasted")
                end
            else
                app.alert("No frame copied")
            end
        end,
    }

    dlg:button {
        id = "save",
        text = "Save",
        onclick = function()
            local data = Components.readData(self_ref.sprite) or {}
            data.type = "component_sheet"
            data.schema = self_ref.schema
            data.poses = self_ref.poses
            data.ref_path = self_ref.refPath or nil
            Components.saveData(self_ref.sprite, data)
            app.alert("Poses saved to sprite data")
        end,
    }

    dlg:button {
        id = "export_dmi",
        text = "Export",
        onclick = function()
            local exportOk, exportErr = pcall(function()
                loadlib(pluginPath)
                local dmiName = self_ref.schema.name or "component"
                local outputPath, dlgErr = libdmi.save_dialog(
                    "Export Component DMI",
                    dmiName .. ".dmi",
                    app.fs.filePath(self_ref.sprite.filename) ~= ""
                        and app.fs.filePath(self_ref.sprite.filename)
                        or app.fs.userDocsPath
                )
                if dlgErr then
                    app.alert("Save dialog error:\n" .. tostring(dlgErr))
                    return
                end
                if outputPath and outputPath ~= "" then
                    exportDMI(self_ref, outputPath, pluginPath)
                end
            end)
            if not exportOk then
                app.alert("Export error:\n" .. tostring(exportErr))
            end
        end,
    }

    dlg:button {
        id = "ref_btn",
        text = "Ref",
        onclick = function()
            if self_ref.referenceFrames then
                -- Already loaded — ask whether to clear or change
                local refDlg = Dialog("Reference DMI")
                refDlg:button { id = "change", text = "Change" }
                refDlg:button { id = "clear", text = "Clear" }
                refDlg:button { id = "cancel", text = "Cancel" }
                refDlg:show()
                if refDlg.data.clear then
                    self_ref:clearReference()
                    self_ref.refPath = nil
                    updateControls(self_ref)
                    dlg:repaint()
                    return
                elseif not refDlg.data.change then
                    return
                end
                -- Fall through to file picker if "Change" was clicked
            end

            local defaultDir = app.fs.filePath(self_ref.sprite.filename) ~= ""
                and app.fs.filePath(self_ref.sprite.filename)
                or app.fs.userDocsPath
            local fileDlg = Dialog("Load Reference DMI")
            fileDlg:file {
                id = "path",
                label = "DMI File:",
                filename = app.fs.joinPath(defaultDir, ""),
                filetypes = { "dmi" },
                open = true,
            }
            fileDlg:button { id = "ok", text = "OK" }
            fileDlg:button { id = "cancel", text = "Cancel" }
            fileDlg:show()
            if fileDlg.data.ok and fileDlg.data.path ~= "" then
                self_ref:loadReferenceDMI(fileDlg.data.path, pluginPath)
                self_ref.refPath = fileDlg.data.path
                -- Update state list since new states may have been added
                dlg:modify {
                    id = "state_select",
                    options = self_ref:getStateNames(),
                    option = stateToDisplay(self_ref.currentState)
                }
                updateControls(self_ref)
                dlg:repaint()
            end
        end,
    }

    dlg:button {
        id = "export_template",
        text = "Template",
        onclick = function()
            local tplName = self_ref.schema.name or "template"
            local defaultDir = app.fs.filePath(self_ref.sprite.filename) ~= ""
                and app.fs.filePath(self_ref.sprite.filename)
                or app.fs.userDocsPath
            local tplDlg = Dialog("Export Pose Template")
            tplDlg:file {
                id = "path",
                label = "Save As:",
                filename = app.fs.joinPath(defaultDir, tplName .. ".json"),
                filetypes = { "json" },
                save = true,
            }
            tplDlg:button { id = "ok", text = "OK" }
            tplDlg:button { id = "cancel", text = "Cancel" }
            tplDlg:show()
            if tplDlg.data.ok and tplDlg.data.path ~= "" then
                exportTemplate(self_ref, tplDlg.data.path)
            end
        end,
    }

    dlg:button {
        id = "use_default",
        text = "Default",
        onclick = function()
            if not self_ref.currentState then return end
            local state = self_ref.poses[self_ref.currentState]
            if not state or not state.frames or not state.frames[1] then
                app.alert("Current state has no frame data to use as default.")
                return
            end
            local result = app.alert {
                title = "Use as Default",
                text = {
                    "This will overwrite the transforms of ALL other states",
                    "with the current state's frame 1 transforms.",
                    "",
                    "This cannot be undone. Continue?",
                },
                buttons = { "Yes", "No" },
            }
            if result ~= 1 then return end

            local srcFrame = state.frames[1]
            local srcOrder = state.layer_order
            for stateName, stateData in pairs(self_ref.poses) do
                if stateName ~= self_ref.currentState then
                    -- Overwrite ALL frames' transforms from source frame 1
                    if stateData.frames then
                        for frameIdx = 1, #stateData.frames do
                            local targetFrame = stateData.frames[frameIdx]
                            if targetFrame then
                                for dir, comps in pairs(srcFrame) do
                                    if not targetFrame[dir] then
                                        targetFrame[dir] = {}
                                    end
                                    for comp, t in pairs(comps) do
                                        targetFrame[dir][comp] = copyTransform(t)
                                    end
                                end
                            end
                        end
                    end
                    -- Copy layer order
                    if srcOrder then
                        stateData.layer_order = {}
                        for i, name in ipairs(srcOrder) do
                            stateData.layer_order[i] = name
                        end
                    end
                end
            end

            self_ref.previewDirty = true
            updateControls(self_ref)
            dlg:repaint()
            app.alert("All states updated with current transforms.")
        end,
    }

    -- Initialize controls and build the first preview frame eagerly
    self.previewDirty = true
    self:composePreview()
    updateControls(self)

    -- Show (modal). The canvas may not paint on first display, so we
    -- use a one-shot timer to force a repaint after the dialog appears.
    local initialRepaintDone = false
    local repaintTimer
    repaintTimer = Timer {
        interval = 0.05,
        ontick = function()
            if not initialRepaintDone then
                initialRepaintDone = true
                pcall(function() dlg:repaint() end)
            end
            repaintTimer:stop()
        end,
    }
    repaintTimer:start()

    dlg:show()
end
