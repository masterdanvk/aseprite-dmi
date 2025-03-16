--- @diagnostic disable: lowercase-global

--- MDFunctions module provides additional functionality for the DMI Editor,
--- including spritesheet editing, East to West mirroring, and West frame deletion.
--- This module extends the core DMI Editor functionality while minimizing changes
--- to the original codebase.

MDFunctions = {}
MDFunctions.__index = MDFunctions

--- Settings for the module
local settings = {
    debugMode = false
}

--- Global debug mode setting - set to false to disable all debug output
MDFunctions.debugMode = false

--- Debug message function
function MDFunctions.dbgMsg(msg)
    if MDFunctions.debugMode then
        print("DEBUG: " .. msg)
    end
end

--- Forces a refresh of the sprite display
--- @param sprite Sprite The sprite to refresh
function MDFunctions.refreshDisplay(sprite)
    if not sprite then return end
    
    -- Force Aseprite to refresh the sprite view
    app.refresh()
    
    -- Some additional tricks to force a refresh
    -- Toggle a property to trigger a view update
    local currentFrame = app.activeFrame.frameNumber
    
    -- Try to change the active frame and then change it back
    if #sprite.frames > 1 then
        local nextFrame = currentFrame < #sprite.frames and currentFrame + 1 or currentFrame - 1
        app.frame = nextFrame
        app.frame = currentFrame
    else
        -- If there's only one frame, try toggling the zoom
        app.command.Zoom { action = "in" }
        app.command.Zoom { action = "out" }
    end
    
    -- Final refresh
    app.refresh()
end

--- Safely clean up a temporary file
--- @param filepath string Path to file to clean up
function MDFunctions.safeCleanupFile(filepath)
    if app.fs.isFile(filepath) then
        -- Try to truncate the file (open with "w" mode and immediately close)
        local file = io.open(filepath, "w")
        if file then
            file:close()
        end
    end
end

--- Tracking point system for DMI editor
-- This allows overlays to track specific points on sprites across frames and states

-- Tracking point color range (magenta-ish colors)
local TRACKING_COLOR_MIN_RED = 200
local TRACKING_COLOR_MAX_GREEN = 50
local TRACKING_COLOR_MIN_BLUE = 200

-- Store tracking points with their associations
MDFunctions.trackingPoints = {}

-- Define a set of predefined tracking colors
MDFunctions.trackingColors = {
    HEAD = Color{red=255, green=0, blue=255, alpha=255}, -- Magenta
    TORSO = Color{red=255, green=0, blue=200, alpha=255},
    RIGHT_ARM = Color{red=240, green=0, blue=255, alpha=255},
    LEFT_ARM = Color{red=225, green=0, blue=255, alpha=255},
    RIGHT_LEG = Color{red=255, green=0, blue=240, alpha=255},
    LEFT_LEG = Color{red=255, green=0, blue=225, alpha=255},
    ACCESSORY = Color{red=225, green=0, blue=225, alpha=255},
    CUSTOM1 = Color{red=200, green=0, blue=255, alpha=255},
    CUSTOM2 = Color{red=255, green=0, blue=175, alpha=255}
}

-- Get user-friendly name for predefined tracking points
MDFunctions.trackingPointNames = {
    HEAD = "Head",
    TORSO = "Torso",
    RIGHT_ARM = "Right Arm",
    LEFT_ARM = "Left Arm",
    RIGHT_LEG = "Right Leg",
    LEFT_LEG = "Left Leg",
    ACCESSORY = "Accessory",
    CUSTOM1 = "Custom 1",
    CUSTOM2 = "Custom 2"
}

-- Helper function to safely check if a table has any keys
function table.keys_len(t)
    if not t then return 0 end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

-- Function to find tracking pixels in an image
-- Returns a table of tracking points with their positions
function MDFunctions.findTrackingPoints(image)
    local points = {}
    
    -- Scan every pixel in the image
    for it in image:pixels() do
        local x, y = it.x, it.y
        local color = Color(it())
        
        -- Check if this is a tracking color (in the magenta range)
        if color.red > TRACKING_COLOR_MIN_RED and 
           color.green < TRACKING_COLOR_MAX_GREEN and 
           color.blue > TRACKING_COLOR_MIN_BLUE then
            
            -- Generate a string ID from the color components
            local colorID = string.format("R%dG%dB%d", color.red, color.green, color.blue)
            
            -- Find name for this color if it's one of our predefined colors
            local pointName = "Unknown Point"
            local matchedKey = nil
            for pointKey, pointColor in pairs(MDFunctions.trackingColors) do
                if math.abs(color.red - pointColor.red) < 5 and
                   math.abs(color.green - pointColor.green) < 5 and
                   math.abs(color.blue - pointColor.blue) < 5 then
                    pointName = MDFunctions.trackingPointNames[pointKey]
                    matchedKey = pointKey
                    break
                end
            end
            
            table.insert(points, {
                id = colorID,
                key = matchedKey,
                x = x,
                y = y,
                color = color,
                name = pointName
            })
        end
    end
    
    return points
end

-- Calculate offsets between reference points and current points
function MDFunctions.calculateOffsets(referencePoints, currentPoints)
    local offsets = {}
    
    -- For each reference point, find the matching current point
    for _, refPoint in ipairs(referencePoints) do
        for _, curPoint in ipairs(currentPoints) do
            if refPoint.id == curPoint.id then
                -- Calculate offset
                offsets[refPoint.id] = {
                    x = curPoint.x - refPoint.x,
                    y = curPoint.y - refPoint.y
                }
                break
            end
        end
    end
    
    return offsets
end

-- Apply an overlay to a specific frame based on tracking points
function MDFunctions.applyOverlay(targetSprite, overlaySprite, targetFrameNumber, targetLayerName, trackingPointId)
    -- Validate inputs
    if not targetSprite or not overlaySprite then
        return false  -- Silent fail - no console output
    end
    
    -- Find tracking points in the overlay sprite
    local overlayPoints = {}
    for _, layer in ipairs(overlaySprite.layers) do
        if layer.isVisible and layer:cel(1) then
            local cel = layer:cel(1)
            local points = MDFunctions.findTrackingPoints(cel.image)
            for _, point in ipairs(points) do
                overlayPoints[point.id] = {
                    point = point,
                    cel = cel
                }
            end
        end
    end
    
    -- If no tracking points found, exit
    if table.keys_len(overlayPoints) == 0 then
        return false  -- Silent fail - no console output
    end
    
    -- Find the target layer
    local targetLayer = nil
    for _, layer in ipairs(targetSprite.layers) do
        if layer.name == targetLayerName then
            targetLayer = layer
            break
        end
    end
    
    if not targetLayer then
        return false  -- Silent fail - no console output
    end
    
    -- Get the target cel
    local targetCel = targetLayer:cel(targetFrameNumber)
    if not targetCel then
        return false  -- Silent fail - no console output
    end
    
    -- Find tracking points in the target sprite
    local targetPoints = MDFunctions.findTrackingPoints(targetCel.image)
    
    -- If specific tracking point requested, filter for that
    if trackingPointId and trackingPointId ~= "" then
        local filteredPoints = {}
        for _, point in ipairs(targetPoints) do
            if point.id == trackingPointId then
                table.insert(filteredPoints, point)
            end
        end
        targetPoints = filteredPoints
    end
    
    if #targetPoints == 0 then
        return false  -- Silent fail - no console output
    end
    
    -- For each tracking point in target, apply the overlay if we have matching point
    app.transaction("Apply Overlay", function()
        for _, targetPoint in ipairs(targetPoints) do
            if overlayPoints[targetPoint.id] then
                local overlayInfo = overlayPoints[targetPoint.id]
                local offX = targetPoint.x - overlayInfo.point.x
                local offY = targetPoint.y - overlayInfo.point.y
                
                -- Create or find overlay layer
                local overlayLayer = nil
                local layerName = "Overlay_" .. targetPoint.name
                
                for _, layer in ipairs(targetSprite.layers) do
                    if layer.name == layerName then
                        overlayLayer = layer
                        break
                    end
                end
                
                if not overlayLayer then
                    overlayLayer = targetSprite:newLayer()
                    overlayLayer.name = layerName
                    overlayLayer.opacity = 255
                end
                
                -- Apply the overlay
                local overlayImage = overlayInfo.cel.image:clone()
                
                -- Remove the tracking pixel from the overlay
                for y = 0, overlayImage.height - 1 do
                    for x = 0, overlayImage.width - 1 do
                        local color = overlayImage:getPixel(x, y)
                        local c = Color(color)
                        if c.red > TRACKING_COLOR_MIN_RED and 
                           c.green < TRACKING_COLOR_MAX_GREEN and 
                           c.blue > TRACKING_COLOR_MIN_BLUE then
                            overlayImage:putPixel(x, y, app.pixelColor.rgba(0, 0, 0, 0))
                        end
                    end
                end
                
                -- Create a new cel with the overlay
                targetSprite:newCel(overlayLayer, targetFrameNumber, overlayImage, Point(offX, offY))
            end
        end
    end)
    
    return true
end

-- Apply overlays to all frames of a sprite
function MDFunctions.applyOverlaysToAllFrames(targetSprite, overlaySprite, targetLayerName, trackingPointId)
    local success = false
    
    for _, frame in ipairs(targetSprite.frames) do
        local frameSuccess = MDFunctions.applyOverlay(
            targetSprite, 
            overlaySprite, 
            frame.frameNumber,
            targetLayerName,
            trackingPointId
        )
        
        success = success or frameSuccess
    end
    
    return success
end

-- Dialog to apply overlays from an existing layer
function MDFunctions.showLayerOverlayDialog(sprite)
    if not sprite then
        app.alert("No sprite is currently open")
        return
    end
    
    local dlg = Dialog("Apply Layer as Overlay")
    
    -- Get list of available layers for source and target
    local layerOptions = {}
    for _, layer in ipairs(sprite.layers) do
        table.insert(layerOptions, layer.name)
    end
    
    dlg:label { text = "This will apply a layer as an overlay to other frames" }
    dlg:label { text = "using tracking points to position the overlay correctly." }
    
    dlg:separator()
    
    -- Source layer (overlay content)
    dlg:combobox {
        id = "overlayLayer",
        label = "Overlay Source Layer:",
        options = layerOptions,
        option = layerOptions[1]
    }
    
    -- Target layer (where tracking pixels are)
    dlg:combobox {
        id = "targetLayer",
        label = "Target Layer (with tracking points):",
        options = layerOptions,
        option = layerOptions[1]
    }
    
    -- Create a dropdown to select which tracking point type to use
    local trackingPointOptions = {"Any tracking point"}
    
    -- Add all predefined tracking point types
    for pointKey, pointName in pairs(MDFunctions.trackingPointNames) do
        table.insert(trackingPointOptions, pointName)
    end
    
    dlg:combobox {
        id = "trackingPointType",
        label = "Use Tracking Point Type:",
        options = trackingPointOptions,
        option = trackingPointOptions[1]
    }
    
    -- Option to create a new layer for overlays or use the source layer
    dlg:check {
        id = "createNewLayer",
        label = "Create new overlay layers",
        selected = true
    }
    
    -- Choose which frames to use as source
    dlg:label { text = "Use the first N frames as source:" }
    
    dlg:number {
        id = "sourceFrames",
        label = "Source Frames:",
        text = "4",
        decimals = 0,
        min = 1,
        max = #sprite.frames
    }
    
    -- Apply options
    dlg:separator { text = "Apply To" }
    
    dlg:check {
        id = "applyToAll",
        label = "Apply to all frames",
        selected = true
    }
    
    dlg:check {
        id = "respectDirections",
        label = "Respect SNEW directions (match same directions)",
        selected = true
    }
    
    dlg:button {
        id = "ok",
        text = "Apply",
        onclick = function()
            local overlayLayerName = dlg.data.overlayLayer
            local targetLayerName = dlg.data.targetLayer
            local createNewLayer = dlg.data.createNewLayer
            local sourceFrames = dlg.data.sourceFrames
            local applyToAll = dlg.data.applyToAll
            local respectDirections = dlg.data.respectDirections
            
            -- Get the selected tracking point type
            local selectedTrackingPointType = dlg.data.trackingPointType
            local selectedTrackingColor = nil
            
            if selectedTrackingPointType ~= "Any tracking point" then
                -- Find the key for the selected tracking point type
                local selectedKey = nil
                for key, name in pairs(MDFunctions.trackingPointNames) do
                    if name == selectedTrackingPointType then
                        selectedKey = key
                        break
                    end
                end
                
                -- Get the color for the selected tracking point type
                if selectedKey and MDFunctions.trackingColors[selectedKey] then
                    selectedTrackingColor = MDFunctions.trackingColors[selectedKey]
                end
            end
            
            -- Find the source and target layers
            local overlayLayer = nil
            local targetLayer = nil
            
            for _, layer in ipairs(sprite.layers) do
                if layer.name == overlayLayerName then
                    overlayLayer = layer
                end
                if layer.name == targetLayerName then
                    targetLayer = layer
                end
            end
            
            if not overlayLayer or not targetLayer then
                app.alert("Could not find one of the specified layers")
                return
            end
            
            -- Apply the overlay
            app.transaction("Apply Layer Overlay", function()
                local success = MDFunctions.applyLayerAsOverlay(
                    sprite,
                    overlayLayer, 
                    targetLayer,
                    sourceFrames,
                    createNewLayer,
                    applyToAll,
                    respectDirections,
                    selectedTrackingColor
                )
                
                if success then
                    app.alert("Overlay applied successfully!")
                else
                    app.alert("Failed to apply overlay. Make sure tracking points exist.")
                end
            end)
            
            dlg:close()
        end
    }
    
    dlg:button { id = "cancel", text = "Cancel" }
    dlg:show()
end

-- Function to copy overlays from source cells to target cells with proper shifting
function MDFunctions.applyLayerAsOverlay(sprite, overlayLayer, targetLayer, sourceFrameCount, createNewLayers, applyToAll, respectDirections, specificTrackingColor)
    if not sprite or not overlayLayer or not targetLayer then
        app.alert("Required layers not found")
        return false
    end
    
    print("===== STARTING OVERLAY COPY+SHIFT =====")
    print("Sprite: " .. sprite.width .. "x" .. sprite.height .. " pixels")
    
    -- Determine grid cell size
    local gridSize = 32  -- Default for most DMI files
    local detectedSize = MDFunctions.detectIconSize(sprite)
    if detectedSize then
        gridSize = detectedSize
    end
    print("Using grid size: " .. gridSize .. "x" .. gridSize)
    
    -- Calculate grid dimensions
    local gridCols = sprite.width / gridSize
    local gridRows = sprite.height / gridSize
    print("Grid dimensions: " .. gridCols .. "x" .. gridRows .. " cells")
    
    -- Get cels for both layers
    local targetCel = targetLayer:cel(1)
    local overlayCel = overlayLayer:cel(1)
    
    if not targetCel or not overlayCel then
        app.alert("Missing required cels")
        return false
    end
    
    -- STEP 1: Get direction information
    local directionInfo = {}
    
    -- Try to get metadata from the sprite
    local dmiMetadata = nil
    if sprite.data and sprite.data:find("dmi_source=") then
        local start = sprite.data:find("dmi_source=") + 11
        local endPos = sprite.data:find(";", start) or sprite.data:len() + 1
        local dmiPath = sprite.data:sub(start, endPos - 1)
        
        print("Found DMI path: " .. dmiPath)
        dmiMetadata = MDFunctions.getDmiMetadata(sprite)
    end
    
    if dmiMetadata and dmiMetadata.states and #dmiMetadata.states > 0 then
        print("Successfully retrieved DMI metadata with " .. #dmiMetadata.states .. " states")
        
        -- Create a mapping of cell indices to directions
        local cellIndex = 0
        for stateIdx, state in ipairs(dmiMetadata.states) do
            for frame = 0, state.frame_count - 1 do
                for dir = 0, state.dirs - 1 do
                    directionInfo[cellIndex] = {
                        direction = dir,
                        directionName = dir < #DIRECTION_NAMES and DIRECTION_NAMES[dir + 1] or "Unknown",
                        stateIndex = stateIdx
                    }
                    cellIndex = cellIndex + 1
                end
            end
        end
    else
        print("No DMI metadata - will use positional assumptions")
        -- Create basic direction info for first 4 cells
        for i = 0, 3 do
            directionInfo[i] = {
                direction = i,
                directionName = DIRECTION_NAMES[i + 1] or "Unknown",
                stateIndex = 1
            }
        end
    end
    
    -- STEP 2: Find all tracking points in the sprite
    print("\n===== SCANNING FOR TRACKING POINTS =====")
    
    local cellTrackingPoints = {}  -- Indexed by cell index
    local targetImage = targetCel.image
    
    -- Scan every pixel for tracking points
    for y = 0, targetImage.height - 1 do
        for x = 0, targetImage.width - 1 do
            local pixelColor = targetImage:getPixel(x, y)
            local c = Color(pixelColor)
            
            -- Check for magenta-range tracking pixels
            if c.red > TRACKING_COLOR_MIN_RED and 
               c.green < TRACKING_COLOR_MAX_GREEN and 
               c.blue > TRACKING_COLOR_MIN_BLUE then
                
                -- Calculate grid cell information
                local gridCol = math.floor(x / gridSize)
                local gridRow = math.floor(y / gridSize)
                local cellIndex = gridRow * gridCols + gridCol
                
                -- Calculate position relative to the cell
                local cellX = x % gridSize
                local cellY = y % gridSize
                
                -- Track this point
                if not cellTrackingPoints[cellIndex] then
                    cellTrackingPoints[cellIndex] = {}
                end
                
                -- Add this tracking point
                table.insert(cellTrackingPoints[cellIndex], {
                    x = cellX,
                    y = cellY,
                    absolute = {x = x, y = y},
                    color = c
                })
                
                local dirText = ""
                if directionInfo[cellIndex] then
                    dirText = " (" .. directionInfo[cellIndex].directionName .. ")"
                end
                
                print("Found tracking point in cell " .. cellIndex .. dirText .. 
                      " at relative position (" .. cellX .. "," .. cellY .. ")")
            end
        end
    end
    
    -- Count cells with tracking points
    local cellsWithPoints = 0
    for idx, points in pairs(cellTrackingPoints) do
        if #points > 0 then
            cellsWithPoints = cellsWithPoints + 1
        end
    end
    
    print("Found tracking points in " .. cellsWithPoints .. " cells")
    
    if cellsWithPoints == 0 then
        app.alert("No tracking points found in any cells")
        return false
    end
    
    -- STEP 3: Identify source cells (first 4 cells with tracking points)
    print("\n===== IDENTIFYING SOURCE CELLS =====")
    
    local sourceCells = {}  -- Maps direction to source cell data
    
    -- First, try to find source cells in the first state
    for cellIndex = 0, 3 do
        if cellTrackingPoints[cellIndex] and #cellTrackingPoints[cellIndex] > 0 then
            -- Determine direction for this cell
            local direction = cellIndex  -- Default to cell index
            if directionInfo[cellIndex] then
                direction = directionInfo[cellIndex].direction
            end
            
            -- Get tracking point for this cell
            local trackingPoint = nil
            for _, tp in ipairs(cellTrackingPoints[cellIndex]) do
                if not specificTrackingColor then
                    trackingPoint = tp
                    break
                else
                    -- Match specific color
                    if math.abs(tp.color.red - specificTrackingColor.red) <= 5 and
                       math.abs(tp.color.green - specificTrackingColor.green) <= 5 and
                       math.abs(tp.color.blue - specificTrackingColor.blue) <= 5 then
                        trackingPoint = tp
                        break
                    end
                end
            end
            
            if trackingPoint then
                -- Calculate grid position
                local gridCol = cellIndex % gridCols
                local gridRow = math.floor(cellIndex / gridCols)
                
                print("Found source cell for direction " .. direction .. 
                      " (" .. (directionInfo[cellIndex] and directionInfo[cellIndex].directionName or "Unknown") .. 
                      ") at cell " .. cellIndex .. " [" .. gridCol .. "," .. gridRow .. 
                      "] with tracking point at (" .. trackingPoint.x .. "," .. trackingPoint.y .. ")")
                
                -- Store this source cell
                sourceCells[direction] = {
                    cellIndex = cellIndex,
                    col = gridCol,
                    row = gridRow,
                    trackingPoint = trackingPoint,
                    direction = direction,
                    bounds = Rectangle(gridCol * gridSize, gridRow * gridSize, gridSize, gridSize)
                }
            end
        end
    end
    
    -- Count source cells
    local sourceCount = 0
    for _ in pairs(sourceCells) do
        sourceCount = sourceCount + 1
    end
    
    print("Found " .. sourceCount .. " usable source cells")
    
    if sourceCount == 0 then
        app.alert("No usable source cells found")
        return false
    end
    
    -- STEP 4: Identify target cells (all cells with tracking points, including source cells)
    print("\n===== IDENTIFYING TARGET CELLS =====")
    
    local targetCells = {}
    
    for cellIndex, points in pairs(cellTrackingPoints) do
        -- Don't exclude source cells
        
        -- Ensure we have tracking points
        if #points == 0 then
            goto continue_target_scan
        end
        
        -- Find appropriate tracking point
        local trackingPoint = nil
        for _, tp in ipairs(points) do
            if not specificTrackingColor then
                trackingPoint = tp
                break
            else
                -- Match specific color
                if math.abs(tp.color.red - specificTrackingColor.red) <= 5 and
                   math.abs(tp.color.green - specificTrackingColor.green) <= 5 and
                   math.abs(tp.color.blue - specificTrackingColor.blue) <= 5 then
                    trackingPoint = tp
                    break
                end
            end
        end
        
        if not trackingPoint then
            goto continue_target_scan
        end
        
        -- Calculate cell position
        local gridCol = cellIndex % gridCols
        local gridRow = math.floor(cellIndex / gridCols)
        
        -- Determine direction
        local direction = 0  -- Default to South (0)
        local directionName = "South"
        
        if directionInfo[cellIndex] then
            direction = directionInfo[cellIndex].direction
            directionName = directionInfo[cellIndex].directionName
        end
        
        -- Store target cell
        table.insert(targetCells, {
            cellIndex = cellIndex,
            col = gridCol,
            row = gridRow,
            trackingPoint = trackingPoint,
            direction = direction,
            directionName = directionName,
            bounds = Rectangle(gridCol * gridSize, gridRow * gridSize, gridSize, gridSize)
        })
        
        print("Found target cell " .. cellIndex .. " [" .. gridCol .. "," .. gridRow .. 
              "] for direction " .. direction .. " (" .. directionName .. 
              ") with tracking point at (" .. trackingPoint.x .. "," .. trackingPoint.y .. ")")
        
        ::continue_target_scan::
    end
    
    print("Found " .. #targetCells .. " target cells")
    
    if #targetCells == 0 then
        app.alert("No target cells found")
        return false
    end
    
    -- STEP 5: Apply overlays to target cells
    print("\n===== APPLYING OVERLAYS TO TARGET CELLS =====")
    
    local successCount = 0
    
    app.transaction("Apply Overlays", function()
        -- Create the destination layer if needed
        local destLayer = nil
        if createNewLayers then
            local layerName = "Overlay"
            
            for _, layer in ipairs(sprite.layers) do
                if layer.name == layerName then
                    destLayer = layer
                    break
                end
            end
            
            if not destLayer then
                destLayer = sprite:newLayer()
                destLayer.name = layerName
                destLayer.opacity = 255
            end
        else
            destLayer = overlayLayer
        end
        
        -- Create a new image if we're creating a new layer, otherwise clone the existing one
        local resultImage = nil
        if createNewLayers then
            resultImage = Image(sprite.width, sprite.height, sprite.colorMode)
            resultImage:clear()
        else
            resultImage = overlayCel.image:clone()
        end
        
        -- Process each target cell
        for _, target in ipairs(targetCells) do
            print("Processing target cell " .. target.cellIndex .. " [" .. target.col .. "," .. target.row .. 
                  "] for direction " .. target.direction .. " (" .. target.directionName .. ")")
            
            -- Skip source cells unless specifically requested
            local isSourceCell = false
            for _, source in pairs(sourceCells) do
                if source.cellIndex == target.cellIndex then
                    isSourceCell = true
                    break
                end
            end
            
            if isSourceCell and not applyToAll then
                print("  Skipping source cell")
                goto continue_apply
            end
            
            -- Determine which source cell to use
            local sourceInfo = nil
            if respectDirections then
                -- Try to find matching direction
                sourceInfo = sourceCells[target.direction]
                
                -- If not found, try fallbacks
                if not sourceInfo then
                    -- For 8-direction sprites, map SE/SW/NE/NW to S/N/E/W
                    if target.direction >= 4 and target.direction <= 7 and
                       sourceCells[target.direction - 4] then
                        sourceInfo = sourceCells[target.direction - 4]
                        print("  Using fallback direction mapping: " .. target.direction .. 
                              " -> " .. (target.direction - 4))
                    else
                        -- Default to South (0)
                        sourceInfo = sourceCells[0]
                        print("  Using default South direction as fallback")
                    end
                end
            else
                -- Just use South (0) or first available
                sourceInfo = sourceCells[0]
                if not sourceInfo then
                    for _, src in pairs(sourceCells) do
                        sourceInfo = src
                        break
                    end
                end
            end
            
            if not sourceInfo then
                print("  No suitable source cell found")
                goto continue_apply
            end
            
            -- Calculate the shift between tracking points
            local shiftX = target.trackingPoint.x - sourceInfo.trackingPoint.x
            local shiftY = target.trackingPoint.y - sourceInfo.trackingPoint.y
            
            print("  Using source cell for direction " .. sourceInfo.direction .. 
                  " with tracking point at (" .. sourceInfo.trackingPoint.x .. "," .. sourceInfo.trackingPoint.y .. ")")
            print("  Target tracking point: (" .. target.trackingPoint.x .. "," .. target.trackingPoint.y .. ")")
            print("  Shift to apply: (" .. shiftX .. "," .. shiftY .. ")")
            
            -- Clear the target area if not creating a new layer
            if not createNewLayers then
                for y = 0, gridSize - 1 do
                    for x = 0, gridSize - 1 do
                        local targetX = target.bounds.x + x
                        local targetY = target.bounds.y + y
                        
                        if targetX < resultImage.width and targetY < resultImage.height then
                            resultImage:putPixel(targetX, targetY, app.pixelColor.rgba(0, 0, 0, 0))
                        end
                    end
                end
            end
            
            -- Copy and shift overlay from source to target
            for y = 0, gridSize - 1 do
                for x = 0, gridSize - 1 do
                    -- Calculate position on the canvas
                    local canvasX = sourceInfo.bounds.x + x
                    local canvasY = sourceInfo.bounds.y + y
                    
                    -- Convert to position relative to the overlay cel
                    local srcX = canvasX - overlayCel.position.x
                    local srcY = canvasY - overlayCel.position.y
                    
                    -- Skip if outside bounds
                    if srcX < 0 or srcX >= overlayCel.image.width or srcY < 0 or srcY >= overlayCel.image.height then
                        goto continue_pixel_copy
                    end
                    
                    -- Get color at this position
                    local color = overlayCel.image:getPixel(srcX, srcY)
                    local c = Color(color)
                    
                    -- Skip tracking pixels and transparent pixels
                    if c.alpha == 0 or (c.red > TRACKING_COLOR_MIN_RED and 
                       c.green < TRACKING_COLOR_MAX_GREEN and 
                       c.blue > TRACKING_COLOR_MIN_BLUE) then
                        goto continue_pixel_copy
                    end
                    
                    -- Calculate shifted position in target cell
                    local targetX = target.bounds.x + x + shiftX
                    local targetY = target.bounds.y + y + shiftY
                    
                    -- Ensure in bounds of the image
                    if targetX >= 0 and targetX < resultImage.width and
                       targetY >= 0 and targetY < resultImage.height then
                        resultImage:putPixel(targetX, targetY, color)
                    end
                    
                    ::continue_pixel_copy::
                end
            end
            
            successCount = successCount + 1
            
            ::continue_apply::
        end
        
        -- Apply the final image
        if createNewLayers then
            sprite:newCel(destLayer, 1, resultImage, Point(0, 0))
        else
            overlayCel.image = resultImage
        end
    end)
    
    print("\n===== OVERLAY APPLICATION COMPLETE =====")
    print("Successfully applied overlays to " .. successCount .. " target cells")
    
    if successCount > 0 then
        app.alert("Successfully applied overlays to " .. successCount .. " cells")
        return true
    else
        app.alert("Failed to apply any overlays")
        return false
    end
end
-- Helper function to get the first key from a table
function list_first_key(t)
    for k, _ in pairs(t) do
        return k
    end
    return nil
end
-- Helper function to get the first key from a table
function list_first_key(t)
    for k, _ in pairs(t) do
        return k
    end
    return nil
end
-- Dialog to manage tracking points
function MDFunctions.showTrackingPointsDialog(sprite)
    local dlg = Dialog("Tracking Points Manager")
    
    -- Find all current tracking points in the sprite
    local allPoints = {}
    for _, layer in ipairs(sprite.layers) do
        if layer.isVisible then
            for _, frame in ipairs(sprite.frames) do
                local cel = layer:cel(frame.frameNumber)
                if cel then
                    local points = MDFunctions.findTrackingPoints(cel.image)
                    for _, point in ipairs(points) do
                        -- Use ID as key to avoid duplicates
                        allPoints[point.id] = point
                    end
                end
            end
        end
    end
    
    -- Convert to array for display
    local pointsArray = {}
    for _, point in pairs(allPoints) do
        table.insert(pointsArray, point)
    end
    
    -- Display tracking points legend
    dlg:label { text = "Tracking Points: " .. #pointsArray .. " found" }
    dlg:separator()
    
    for i, point in ipairs(pointsArray) do
        dlg:label { text = point.name .. " (" .. point.id .. ")" }
        local colorLabel = string.format("R: %d, G: %d, B: %d", 
            point.color.red, point.color.green, point.color.blue)
        dlg:color { id = "color_" .. i, color = point.color }
        dlg:label { text = colorLabel }
        dlg:separator()
    end
    
    -- Add tracking point tools
    dlg:button { 
        text = "Add Tracking Point Tool", 
        onclick = function() 
            dlg:close()
            MDFunctions.showAddTrackingPointDialog(sprite)
        end
    }
    
    -- Apply overlay options
    dlg:separator { text = "Apply Overlays" }
    dlg:button {
        text = "Apply Layer as Overlay",
        onclick = function()
            dlg:close()
            MDFunctions.showLayerOverlayDialog(sprite)
        end
    }
    
    dlg:button {
        text = "Apply Overlay from File",
        onclick = function()
            dlg:close()
            MDFunctions.showApplyOverlayDialog(sprite)
        end
    }
    
    dlg:button { id = "close", text = "Close" }
    dlg:show()
end

-- Dialog to add a new tracking point
function MDFunctions.showAddTrackingPointDialog(sprite)
    local dlg = Dialog("Add Tracking Point")
    
    dlg:label { text = "Select a tracking point to add:" }
    
    -- Create dropdown of available tracking points
    local options = {}
    for pointKey, pointName in pairs(MDFunctions.trackingPointNames) do
        table.insert(options, pointName)
    end
    
    dlg:combobox {
        id = "pointType",
        options = options,
        option = options[1]
    }
    
    dlg:label { text = "Click OK then place the tracking point in your sprite." }
    dlg:label { text = "The tracking point will be a single pixel in the selected color." }
    
    dlg:button {
        id = "ok",
        text = "OK",
        onclick = function()
            -- Find the selected color
            local selectedName = dlg.data.pointType
            local selectedKey = nil
            
            for key, name in pairs(MDFunctions.trackingPointNames) do
                if name == selectedName then
                    selectedKey = key
                    break
                end
            end
            
            if selectedKey then
                local selectedColor = MDFunctions.trackingColors[selectedKey]
                
                -- Start pixel placing tool
                dlg:close()
                
                -- Store the tracking color in global settings so the tool can use it
                app.fgColor = selectedColor
                
                -- Switch to pencil tool - with correct command
                app.activeTool = "pencil"
                
                app.alert {
                    title = "Add Tracking Point",
                    text = {
                        "Click to place the " .. selectedName .. " tracking point.",
                        "It will appear as a single magenta pixel.",
                        "Add it to a visible but separate layer."
                    }
                }
            end
        end
    }
    
    dlg:button { id = "cancel", text = "Cancel" }
    dlg:show()
end

-- Dialog to apply an overlay from a file
function MDFunctions.showApplyOverlayDialog(sprite)
    local dlg = Dialog("Apply Overlay")
    
    dlg:file {
        id = "overlayFile",
        label = "Overlay Sprite:",
        filetypes = { "aseprite", "ase", "dmi" },
        open = true
    }
    
    -- Target layer selection
    local layerOptions = {}
    for _, layer in ipairs(sprite.layers) do
        table.insert(layerOptions, layer.name)
    end
    
    dlg:combobox {
        id = "targetLayer",
        label = "Target Layer:",
        options = layerOptions,
        option = layerOptions[1]
    }
    
    -- Tracking point selection
    dlg:check {
        id = "allPoints",
        label = "All Tracking Points",
        selected = true
    }
    
    dlg:button {
        id = "ok",
        text = "Apply",
        onclick = function()
            local overlayPath = dlg.data.overlayFile
            
            if overlayPath and overlayPath ~= "" then
                -- Load the overlay sprite
                local overlaySprite = nil
                
                app.transaction(function()
                    -- Temporarily load the overlay sprite
                    overlaySprite = Sprite{ fromFile = overlayPath }
                end)
                
                if overlaySprite then
                    -- Apply the overlay
                    local success = MDFunctions.applyOverlaysToAllFrames(
                        sprite,
                        overlaySprite,
                        dlg.data.targetLayer,
                        dlg.data.allPoints and "" or nil  -- If allPoints is checked, don't filter
                    )
                    
                    -- Clean up
                    overlaySprite:close()
                    
                    if success then
                        app.alert("Overlay applied successfully!")
                    else
                        app.alert("Failed to apply overlay. Make sure tracking points match.")
                    end
                else
                    app.alert("Failed to open overlay file.")
                end
            else
                app.alert("Please select an overlay file.")
            end
            
            dlg:close()
        end
    }
    
    dlg:button { id = "cancel", text = "Cancel" }
    dlg:show()
end

-- New function to handle frame sequence overlay applications
function MDFunctions.showApplyOverlaySequenceDialog(sprite)
    if not sprite then
        app.alert("No sprite is currently open")
        return
    end
    
    local dlg = Dialog("Apply Overlay to Sequence")
    
    -- Get list of available layers
    local layerOptions = {}
    for _, layer in ipairs(sprite.layers) do
        table.insert(layerOptions, layer.name)
    end
    
    dlg:label { text = "This will apply an overlay to a sequence of frames" }
    dlg:label { text = "based on tracking points in a reference frame." }
    
    dlg:separator()
    
    dlg:combobox {
        id = "targetLayer",
        label = "Target Layer:",
        options = layerOptions,
        option = layerOptions[1]
    }
    
    dlg:number {
        id = "refFrame",
        label = "Reference Frame:",
        text = "1",
        decimals = 0,
        min = 1,
        max = #sprite.frames
    }
    
    dlg:file {
        id = "overlayFile",
        label = "Overlay File:",
        filetypes = { "aseprite", "ase", "png" },
        open = true
    }
    
    dlg:check {
        id = "applyToAll",
        label = "Apply to all frames",
        selected = true
    }
    
    dlg:button {
        id = "ok",
        text = "Apply",
        onclick = function()
            if not dlg.data.overlayFile or dlg.data.overlayFile == "" then
                app.alert("Please select an overlay file")
                return
            end
            
            local refFrameNumber = math.max(1, math.min(dlg.data.refFrame, #sprite.frames))
            local targetLayerName = dlg.data.targetLayer
            
            app.transaction("Apply Overlay Sequence", function()
                -- Load overlay sprite
                local overlaySprite = nil
                local tempSprite = Sprite{ fromFile = dlg.data.overlayFile }
                if tempSprite then
                    overlaySprite = tempSprite
                
                    -- Apply to reference frame first
                    local success = MDFunctions.applyOverlay(
                        sprite,
                        overlaySprite,
                        refFrameNumber,
                        targetLayerName,
                        ""  -- No specific tracking point filter
                    )
                    
                    -- If successful and apply to all frames is selected
                    if success and dlg.data.applyToAll then
                        -- Apply to other frames
                        for i = 1, #sprite.frames do
                            if i ~= refFrameNumber then
                                MDFunctions.applyOverlay(
                                    sprite,
                                    overlaySprite,
                                    i,
                                    targetLayerName,
                                    ""  -- No specific tracking point filter
                                )
                            end
                        end
                    end
                    
                    -- Clean up
                    overlaySprite:close()
                end
            end)
            
            app.alert("Overlay application complete")
            dlg:close()
        end
    }
    
    dlg:button { id = "cancel", text = "Cancel" }
    dlg:show()
end

-- Create a new overlay template sprite with tracking points
function MDFunctions.createOverlayTemplate()
    local dlg = Dialog("Create Overlay Template")
    
    dlg:number {
        id = "width",
        label = "Width:",
        text = "32",
        decimals = 0
    }
    
    dlg:number {
        id = "height",
        label = "Height:",
        text = "32",
        decimals = 0
    }
    
    dlg:separator { text = "Tracking Points" }
    
    -- Add checkboxes for common tracking points
    dlg:check {
        id = "head",
        label = "Include Head Tracking Point",
        selected = true
    }
    
    dlg:check {
        id = "torso",
        label = "Include Torso Tracking Point",
        selected = true
    }
    
    dlg:check {
        id = "arms",
        label = "Include Arm Tracking Points",
        selected = false
    }
    
    dlg:check {
        id = "legs",
        label = "Include Leg Tracking Points",
        selected = false
    }
    
    dlg:check {
        id = "accessory",
        label = "Include Accessory Tracking Point",
        selected = false
    }
    
    dlg:button {
        id = "ok",
        text = "Create",
        onclick = function()
            -- Create the new sprite
            local width = dlg.data.width
            local height = dlg.data.height
            
            if width < 1 or height < 1 then
                app.alert("Invalid dimensions")
                return
            end
            
            app.transaction("Create Overlay Template", function()
                local sprite = Sprite(width, height)
                
                -- Create base layer
                local baseLayer = sprite.layers[1]
                baseLayer.name = "Base"
                
                -- Create tracking points layer
                local trackingLayer = sprite:newLayer()
                trackingLayer.name = "Tracking Points"
                
                -- Create overlay layer
                local overlayLayer = sprite:newLayer()
                overlayLayer.name = "Overlay"
                
                -- Add tracking points
                local image = Image(width, height, ColorMode.RGB)
                image:clear()
                
                -- Position points at reasonable locations based on typical sprite anatomy
                local centerX = math.floor(width / 2)
                
                if dlg.data.head then
                    -- Head at top center
                    local headY = math.floor(height * 0.25)
                    image:putPixel(centerX, headY, MDFunctions.trackingColors.HEAD.rgbaPixel)
                end
                
                if dlg.data.torso then
                    -- Torso at middle center
                    local torsoY = math.floor(height * 0.5)
                    image:putPixel(centerX, torsoY, MDFunctions.trackingColors.TORSO.rgbaPixel)
                end
                
                if dlg.data.arms then
                    -- Arms at middle sides
                    local armsY = math.floor(height * 0.4)
                    local leftX = math.floor(width * 0.25)
                    local rightX = math.floor(width * 0.75)
                    
                    image:putPixel(leftX, armsY, MDFunctions.trackingColors.LEFT_ARM.rgbaPixel)
                    image:putPixel(rightX, armsY, MDFunctions.trackingColors.RIGHT_ARM.rgbaPixel)
                end
                
                if dlg.data.legs then
                    -- Legs at bottom sides
                    local legsY = math.floor(height * 0.8)
                    local leftX = math.floor(width * 0.35)
                    local rightX = math.floor(width * 0.65)
                    
                    image:putPixel(leftX, legsY, MDFunctions.trackingColors.LEFT_LEG.rgbaPixel)
                    image:putPixel(rightX, legsY, MDFunctions.trackingColors.RIGHT_LEG.rgbaPixel)
                end
                
                if dlg.data.accessory then
                    -- Accessory near top
                    local accY = math.floor(height * 0.15)
                    local accX = math.floor(width * 0.65)
                    
                    image:putPixel(accX, accY, MDFunctions.trackingColors.ACCESSORY.rgbaPixel)
                end
                
                -- Add the tracking points to the tracking layer
                sprite:newCel(trackingLayer, 1, image, Point(0, 0))
                
                -- Create a simple visual reference on the base layer
                local baseImage = Image(width, height, ColorMode.RGB)
                baseImage:clear()
                
                -- Draw a simple stick figure outline
                for x = centerX-4, centerX+4 do
                    for y = height*0.2, height*0.3 do
                        if math.abs(x - centerX)^2 + math.abs(y - height*0.25)^2 < 16 then
                            baseImage:putPixel(x, y, app.pixelColor.rgba(200, 200, 200, 128))
                        end
                    end
                end
                
                -- Draw body
                for y = height*0.3, height*0.6 do
                    baseImage:putPixel(centerX, y, app.pixelColor.rgba(200, 200, 200, 128))
                end
                
                -- Draw arms and legs (simple lines)
                if dlg.data.arms then
                    local armsY = math.floor(height * 0.4)
                    for x = width*0.3, width*0.7 do
                        baseImage:putPixel(x, armsY, app.pixelColor.rgba(200, 200, 200, 128))
                    end
                end
                
                if dlg.data.legs then
                    local legsTopY = math.floor(height * 0.6)
                    local legsBottomY = math.floor(height * 0.9)
                    
                    for y = legsTopY, legsBottomY do
                        local leftX = centerX - (y - legsTopY) * 0.3
                        local rightX = centerX + (y - legsTopY) * 0.3
                        
                        baseImage:putPixel(leftX, y, app.pixelColor.rgba(200, 200, 200, 128))
                        baseImage:putPixel(rightX, y, app.pixelColor.rgba(200, 200, 200, 128))
                    end
                end
                
                sprite:newCel(baseLayer, 1, baseImage, Point(0, 0))
                
                -- Add instructions
                app.alert {
                    title = "Overlay Template Created",
                    text = {
                        "Template created with tracking points.",
                        "1. Draw your overlay on the 'Overlay' layer",
                        "2. Keep tracking points visible but on a separate layer",
                        "3. Save the sprite when done"
                    }
                }
            end)
            
            dlg:close()
        end
    }
    
    dlg:button { id = "cancel", text = "Cancel" }
    dlg:show()
end


--- Opens a DMI file as a spritesheet for direct editing
--- @param editor Editor The DMI editor instance (optional)
--- @param dmiPath string The path to the DMI file
--- @return Sprite|nil sprite The opened sprite, or nil if opening failed
function MDFunctions.openAsSpritesheet(editor, dmiPath)
    -- Attempt to open file directly as a sprite
    -- This will load it as a normal PNG file without special DMI handling
    if app.fs.isFile(dmiPath) then
        -- We need to tell main.lua to not intercept this with the editor
        opening_dmi_noeditor = true
        
        local success = false
        local sprite = nil
        
        app.transaction(function()
            sprite = Sprite{ fromFile = dmiPath }
            -- Set a metadata flag to indicate this is a DMI spritesheet
            if sprite then
                sprite.data = sprite.data .. ";dmi_spritesheet=true;dmi_source=" .. dmiPath
                success = true
            end
        end)
        
        if success then
            return sprite
        end
    end
    
    app.alert("Failed to open DMI file as spritesheet: " .. dmiPath)
    return nil
end

--- Extracts the zTXt metadata chunk from a DMI file
--- @param dmiPath string Path to the DMI file
--- @return string|nil metadata The extracted metadata chunk including length, type, data, and CRC
function MDFunctions.extractMetadataChunk(dmiPath)
    -- Read the file directly as binary
    local file = io.open(dmiPath, "rb")
    if not file then
        app.alert("Could not open DMI file: " .. dmiPath)
        return nil
    end
    
    local fileData = file:read("*all")
    file:close()
    
    -- Find the zTXt chunk by searching for the keyword
    local ztxtPos = fileData:find("zTXtDescription", 1, true)
    if not ztxtPos then
        ztxtPos = fileData:find("zTXt", 1, true)
    end
    
    if not ztxtPos then
        app.alert("Could not find DMI metadata in file")
        return nil
    end
    
    -- Go back 4 bytes to get the length
    if ztxtPos < 5 then
        app.alert("Invalid zTXt chunk position")
        return nil
    end
    
    local lengthStart = ztxtPos - 4
    local b1 = string.byte(fileData, lengthStart)
    local b2 = string.byte(fileData, lengthStart + 1)
    local b3 = string.byte(fileData, lengthStart + 2)
    local b4 = string.byte(fileData, lengthStart + 3)
    
    -- Calculate chunk length
    local chunkLength = (b1 * 16777216) + (b2 * 65536) + (b3 * 256) + b4
    
    -- Extract the entire chunk including length, type, data, and CRC
    local ztxtChunk = fileData:sub(lengthStart, ztxtPos + 3 + chunkLength + 4)
    
    if ztxtChunk then
        return ztxtChunk
    end
    
    return nil
end

--- Saves a spritesheet back to DMI format
--- This requires preserving the zTXt chunk with DMI metadata
--- @param sprite Sprite The sprite to save
--- @param dmiPath string The path where to save the DMI file
--- @return boolean success Whether the operation was successful
function MDFunctions.saveSpritesheet(sprite, dmiPath)
    -- First, save the sprite as a temporary PNG file
    local tempPath = app.fs.joinPath(app.fs.tempPath, TEMP_NAME, "temp_spritesheet.png")
    
    -- Make sure the temp directory exists
    if not app.fs.isDirectory(app.fs.joinPath(app.fs.tempPath, TEMP_NAME)) then
        app.fs.makeDirectory(app.fs.joinPath(app.fs.tempPath, TEMP_NAME))
    end
    
    -- Save sprite to the temporary file
    local saved = false
    app.transaction(function()
        sprite:saveAs(tempPath)
        saved = true
    end)
    
    if not saved then
        app.alert("Failed to save temporary spritesheet")
        return false
    end
    
    -- Original file path to extract metadata from
    local origPath = sprite.filename
    
    -- Try to extract the source DMI path from sprite metadata
    if sprite.data and sprite.data:find("dmi_source=") then
        local start = sprite.data:find("dmi_source=") + 11
        local endPos = sprite.data:find(";", start) or sprite.data:len() + 1
        local sourcePath = sprite.data:sub(start, endPos - 1)
        if app.fs.isFile(sourcePath) then
            origPath = sourcePath
        end
    end
    
    if not app.fs.isFile(origPath) or not origPath:ends_with(".dmi") then
        app.alert("Cannot save DMI spritesheet: original DMI file not found")
        return false
    end
    
    -- Ensure the library is loaded
    if not libdmi then
        local pluginPath = app.fs.joinPath(app.fs.appPath, "extensions", "aseprite-dmi")
        loadlib(pluginPath)
    end
    
    -- Use the native function if available, otherwise fall back to Lua implementation
    local success = false
    local error = nil
    
    -- The native merge_spritesheet function should return a boolean success and optional error string
    if libdmi and libdmi.merge_spritesheet then
        success, error = libdmi.merge_spritesheet(tempPath, origPath, dmiPath)
    else
        success = MDFunctions.fallbackMergeSpritesheet(tempPath, origPath, dmiPath)
    end
    
    -- Clean up temporary file
    MDFunctions.safeCleanupFile(tempPath)
    
    -- Report result
    if success then
        app.alert("DMI file saved successfully to: " .. dmiPath)
        return true
    else
        app.alert("Failed to save DMI spritesheet: " .. (error or "Unknown error"))
        return false
    end
end

--- Fallback implementation for merging a spritesheet with DMI metadata
--- @param pngPath string Path to the PNG file (spritesheet)
--- @param origDmiPath string Path to the original DMI file (for metadata)
--- @param outputPath string Path where to save the resulting DMI file
--- @return boolean success Whether the operation was successful
function MDFunctions.fallbackMergeSpritesheet(pngPath, origDmiPath, outputPath)
    -- Read the PNG file
    local pngFile = io.open(pngPath, "rb")
    if not pngFile then
        app.alert("Could not open temporary PNG file")
        return false
    end
    local pngData = pngFile:read("*all")
    pngFile:close()
    
    -- Extract metadata chunk from the original DMI file
    local ztxtChunk = MDFunctions.extractMetadataChunk(origDmiPath)
    if not ztxtChunk then
        return false
    end
    
    -- Find the first IDAT chunk in the PNG
    local idatPos = pngData:find("IDAT", 1, true)
    if not idatPos then
        app.alert("Could not find IDAT chunk in PNG")
        return false
    end
    
    -- Go back 4 bytes to the start of the chunk
    idatPos = idatPos - 4
    
    -- Insert the zTXt chunk before the first IDAT chunk
    local outputData = pngData:sub(1, idatPos - 1) .. ztxtChunk .. pngData:sub(idatPos)
    
    -- Write the output file
    local outFile = io.open(outputPath, "wb")
    if not outFile then
        app.alert("Could not create output file: " .. outputPath)
        return false
    end
    
    outFile:write(outputData)
    outFile:close()
    
    return true
end

--- Get DMI metadata from a sprite in spritesheet mode
--- Uses the existing DMI extension's functionality to get state information
--- @param sprite Sprite The sprite to analyze
--- @return table|nil dmiInfo Information about the DMI including states, grid size, etc.
function MDFunctions.getDmiMetadata(sprite)
    if not sprite then return nil end
    
    -- Try to get the source DMI file path
    local dmiPath = ""
    if sprite.data and sprite.data:find("dmi_source=") then
        local start = sprite.data:find("dmi_source=") + 11
        local endPos = sprite.data:find(";", start) or sprite.data:len() + 1
        dmiPath = sprite.data:sub(start, endPos - 1)
    end
    
    if not app.fs.isFile(dmiPath) then
        return nil
    end
    
    -- Ensure libdmi is loaded
    if not libdmi then
        local pluginPath = app.fs.joinPath(app.fs.appPath, "extensions", "aseprite-dmi")
        loadlib(pluginPath)
    end
    
    -- Create a temporary directory for DMI processing
    local tempDir = app.fs.joinPath(app.fs.tempPath, TEMP_NAME, "temp_metadata")
    if not app.fs.isDirectory(tempDir) then
        app.fs.makeDirectory(tempDir)
    end
    
    -- Use the extension's existing functionality to open the DMI file and extract metadata
    local dmi, error = libdmi.open_file(dmiPath, tempDir)
    if error then
        if app.fs.isDirectory(tempDir) then
            libdmi.remove_dir(tempDir, true)
        end
        return nil
    end
    
    -- Create a metadata object with the extracted information
    local metadata = {
        width = dmi.width,
        height = dmi.height,
        states = dmi.states,
        gridInfo = {}
    }
    
    -- Calculate grid dimensions
    local columns = sprite.width / dmi.width
    local rows = sprite.height / dmi.height
    
    metadata.gridInfo = {
        columns = columns,
        rows = rows,
        totalCells = columns * rows
    }
    
    -- Clean up
    libdmi.remove_dir(tempDir, true)
    
    return metadata
end

--- Mirrors East-facing sprites to West-facing positions
--- @param sprite Sprite The sprite to process
--- @param cellWidth number|nil The width of each icon cell (optional)
--- @param cellHeight number|nil The height of each icon cell (optional)
--- @param activeFrameOnly boolean|nil Whether to only modify the active frame
--- @return boolean success Whether the operation was successful
function MDFunctions.mirrorEastToWest(sprite, cellWidth, cellHeight, activeFrameOnly)
    if not sprite then
        app.alert("No sprite open to process")
        return false
    end
    
    local width = sprite.width
    local height = sprite.height
    
    -- Check if we're in spritesheet mode and use the appropriate function
    local isSpritesheetMode = sprite.data and sprite.data:find("dmi_spritesheet=true")
    if isSpritesheetMode then
        return MDFunctions.mirrorEastToWestSpritesheet(sprite)
    end
    
    -- If cell dimensions weren't provided, ask the user
    if not cellWidth or not cellHeight then
        local dlg = Dialog("Mirror East to West")
        dlg:number{ id = "cellWidth", label = "Frame Width:", text = tostring(MDFunctions.detectIconSize(sprite) or 32), decimals = 0 }
        dlg:number{ id = "cellHeight", label = "Frame Height:", text = tostring(MDFunctions.detectIconSize(sprite) or 32), decimals = 0 }
        dlg:check{ id = "activeFrameOnly", label = "Apply to active frame only:", selected = true }
        dlg:button{ id = "ok", text = "OK" }
        dlg:button{ id = "cancel", text = "Cancel" }
        dlg:show()
        
        if not dlg.data.ok then
            return false
        end
        
        cellWidth = dlg.data.cellWidth
        cellHeight = dlg.data.cellHeight
        activeFrameOnly = dlg.data.activeFrameOnly
    end
    
    -- Ensure sprite dimensions are multiples of the cell size
    if width % cellWidth ~= 0 or height % cellHeight ~= 0 then
        app.alert("Sprite dimensions must be multiples of the frame size")
        return false
    end
    
    -- Calculate grid dimensions
    local columns = width / cellWidth
    local rows = height / cellHeight
    local totalCells = columns * rows
    
    -- Frames to process
    local frameStart = app.activeFrame.frameNumber
    local frameEnd = frameStart
    
    if not activeFrameOnly then
        frameStart = 1
        frameEnd = #sprite.frames
    end
    
    -- Count how many sprites we'll process
    local totalProcessed = 0
    
    -- Start transaction for undo support
    app.transaction("Mirror East to West", function()
        for frameNumber = frameStart, frameEnd do
            -- Create a new image for the entire sprite
            local fullImage = Image(sprite.width, sprite.height, sprite.colorMode)
            
            -- Make the entire image transparent
            fullImage:clear()
            
            -- Draw the current frame of the sprite onto the image
            for _, layer in ipairs(sprite.layers) do
                if layer.isVisible then
                    local cel = layer:cel(frameNumber)
                    if cel then
                        fullImage:drawImage(cel.image, cel.position)
                    end
                end
            end
            
            -- Process all cells
            local modified = false
            
            -- Detect if this is a 4-direction or 8-direction DMI
            local directions = 4  -- Default to 4 directions
            
            -- Check if the number of cells is divisible by 8
            if columns % 8 == 0 and rows % 8 == 0 then
                -- Check if the number of cells is divisible by 8
                local possibleStates = totalCells / 8
                if math.floor(possibleStates) == possibleStates then
                    directions = 8
                end
            end
            
            -- Determine the specific indices for East and West
            local eastIndex = 2  -- East is typically at index 2 (0-based)
            local westIndex = 3  -- West is typically at index 3 (0-based)
            
            -- Process each state/direction set
            local statesCount = totalCells / directions
            for state = 0, statesCount - 1 do
                -- Calculate the base index for this state
                local baseIndex = state * directions
                
                -- Calculate the East position
                local eastCellIndex = baseIndex + eastIndex
                local eastCol = eastCellIndex % columns
                local eastRow = math.floor(eastCellIndex / columns)
                local eastX = eastCol * cellWidth
                local eastY = eastRow * cellHeight
                
                -- Calculate the West position
                local westCellIndex = baseIndex + westIndex
                local westCol = westCellIndex % columns
                local westRow = math.floor(westCellIndex / columns)
                local westX = westCol * cellWidth
                local westY = westRow * cellHeight
                
                -- Copy the east sprite to a temporary buffer
                local eastImage = Image(cellWidth, cellHeight, sprite.colorMode)
                eastImage:clear()
                
                -- Copy east sprite pixels to the buffer
                for py = 0, cellHeight - 1 do
                    for px = 0, cellWidth - 1 do
                        local pixelColor = fullImage:getPixel(eastX + px, eastY + py)
                        eastImage:putPixel(px, py, pixelColor)
                    end
                end
                
                -- Clear the west area
                for py = 0, cellHeight - 1 do
                    for px = 0, cellWidth - 1 do
                        fullImage:putPixel(westX + px, westY + py, app.pixelColor.rgba(0, 0, 0, 0))
                    end
                end
                
                -- Copy the flipped east image to the west position
                for py = 0, cellHeight - 1 do
                    for px = 0, cellWidth - 1 do
                        local pixelColor = eastImage:getPixel(px, py)
                        fullImage:putPixel(westX + (cellWidth - 1 - px), westY + py, pixelColor)
                    end
                end
                
                totalProcessed = totalProcessed + 1
                modified = true
            end
            
            -- Apply changes to the sprite
            if modified then
                for _, layer in ipairs(sprite.layers) do
                    if layer.isVisible then
                        -- Make layer editable if needed
                        local wasEditable = layer.isEditable
                        if not wasEditable then
                            layer.isEditable = true
                        end
                        
                        -- Create a new cel with the modified image
                        sprite:newCel(layer, sprite.frames[frameNumber], fullImage:clone(), Point(0, 0))
                        
                        -- Restore editability
                        if not wasEditable then
                            layer.isEditable = false
                        end
                        
                        -- Only need to modify one layer
                        break
                    end
                end
            end
        end
    end)
    
    if totalProcessed > 0 then
        app.alert("Mirrored " .. totalProcessed .. " east-facing sprites to west-facing positions")
        MDFunctions.refreshDisplay(sprite)
        return true
    else
        app.alert("No east-facing sprites were found to process")
        return false
    end
end

--- Mirrors East-facing sprites to West-facing positions in spritesheet mode
--- Uses the DMI metadata extracted from the original file
--- @param sprite Sprite The sprite to process
--- @return boolean success Whether the operation was successful
function MDFunctions.mirrorEastToWestSpritesheet(sprite)
    if not sprite then
        app.alert("No sprite open to process")
        return false
    end
    
    -- Get DMI metadata using the extension's existing functionality
    local metadata = MDFunctions.getDmiMetadata(sprite)
    if not metadata then
        -- Fall back to the manual method if metadata can't be extracted
        local dlg = Dialog("Mirror East to West")
        dlg:number{ id = "cellWidth", label = "Frame Width:", text = tostring(MDFunctions.detectIconSize(sprite) or 32), decimals = 0 }
        dlg:number{ id = "cellHeight", label = "Frame Height:", text = tostring(MDFunctions.detectIconSize(sprite) or 32), decimals = 0 }
        dlg:check{ id = "activeFrameOnly", label = "Apply to active frame only:", selected = true }
        dlg:button{ id = "ok", text = "OK" }
        dlg:button{ id = "cancel", text = "Cancel" }
        dlg:show()
        
        if not dlg.data.ok then
            return false
        end
        
        return MDFunctions.mirrorEastToWest(sprite, dlg.data.cellWidth, dlg.data.cellHeight, dlg.data.activeFrameOnly)
    end
    
    -- Use the extracted metadata to perform the mirroring
    local cellWidth = metadata.width
    local cellHeight = metadata.height
    local columns = metadata.gridInfo.columns
    
    -- Count how many sprites we'll process
    local totalProcessed = 0
    
    -- Start transaction for undo support
    app.transaction("Mirror East to West", function()
        -- Create a new image for the entire sprite
        local fullImage = Image(sprite.width, sprite.height, sprite.colorMode)
        
        -- Make the entire image transparent
        fullImage:clear()
        
        -- Draw the current frame of the sprite onto the image
        for _, layer in ipairs(sprite.layers) do
            if layer.isVisible then
                local cel = layer:cel(app.activeFrame.frameNumber)
                if cel then
                    fullImage:drawImage(cel.image, cel.position)
                end
            end
        end
        
        -- Process each state
        for stateIndex, state in ipairs(metadata.states) do
            -- For each state, calculate starting cell index
            local stateOffset = 0
            for i = 1, stateIndex - 1 do
                stateOffset = stateOffset + (metadata.states[i].frame_count * metadata.states[i].dirs)
            end
            
            -- Process each frame of this state
            for frame = 0, state.frame_count - 1 do
                -- For each frame, process directions
                -- In DMI, the order is typically: South, North, East, West, ...
                local eastIndex = 2  -- East is typically at index 2 (0-based)
                local westIndex = 3  -- West is typically at index 3 (0-based)
                
                if state.dirs >= 4 then -- Only process if we have enough directions
                    -- Calculate cell indices
                    local baseIndex = stateOffset + (frame * state.dirs)
                    local eastCellIndex = baseIndex + eastIndex
                    local westCellIndex = baseIndex + westIndex
                    
                    -- Calculate grid positions
                    local eastCol = eastCellIndex % columns
                    local eastRow = math.floor(eastCellIndex / columns)
                    local westCol = westCellIndex % columns
                    local westRow = math.floor(westCellIndex / columns)
                    
                    -- Calculate pixel coordinates
                    local eastX = eastCol * cellWidth
                    local eastY = eastRow * cellHeight
                    local westX = westCol * cellWidth
                    local westY = westRow * cellHeight
                    
                    -- Copy the east sprite to a temporary buffer
                    local eastImage = Image(cellWidth, cellHeight, sprite.colorMode)
                    eastImage:clear()
                    
                    -- Copy east sprite pixels to the buffer
                    for py = 0, cellHeight - 1 do
                        for px = 0, cellWidth - 1 do
                            local pixelColor = fullImage:getPixel(eastX + px, eastY + py)
                            eastImage:putPixel(px, py, pixelColor)
                        end
                    end
                    
                    -- Clear the west area
                    for py = 0, cellHeight - 1 do
                        for px = 0, cellWidth - 1 do
                            fullImage:putPixel(westX + px, westY + py, app.pixelColor.rgba(0, 0, 0, 0))
                        end
                    end
                    
                    -- Copy the flipped east image to the west position
                    for py = 0, cellHeight - 1 do
                        for px = 0, cellWidth - 1 do
                            local pixelColor = eastImage:getPixel(px, py)
                            fullImage:putPixel(westX + (cellWidth - 1 - px), westY + py, pixelColor)
                        end
                    end
                    
                    totalProcessed = totalProcessed + 1
                end
            end
        end
        
        -- Apply changes to the sprite
        for _, layer in ipairs(sprite.layers) do
            if layer.isVisible then
                -- Make layer editable if needed
                local wasEditable = layer.isEditable
                if not wasEditable then
                    layer.isEditable = true
                end
                
                -- Create a new cel with the modified image
                sprite:newCel(layer, sprite.frames[app.activeFrame.frameNumber], fullImage:clone(), Point(0, 0))
                
                -- Restore editability
                if not wasEditable then
                    layer.isEditable = false
                end
                
                -- Only need to modify one layer
                break
            end
        end
    end)
    
    if totalProcessed > 0 then
        app.alert("Mirrored " .. totalProcessed .. " east-facing sprites to west-facing positions")
        MDFunctions.refreshDisplay(sprite)
        return true
    else
        app.alert("No east-facing sprites were found to process")
        return false
    end
end

--- Deletes all West-facing frames in the sprite
--- @param sprite Sprite The sprite to process
--- @param cellWidth number|nil The width of each icon cell (optional)
--- @param cellHeight number|nil The height of each icon cell (optional)
--- @param activeFrameOnly boolean|nil Whether to only modify the active frame
--- @return boolean success Whether the operation was successful
function MDFunctions.deleteWestFrames(sprite, cellWidth, cellHeight, activeFrameOnly)
    if not sprite then
        app.alert("No sprite open to process")
        return false
    end
    
    -- Check if we're in spritesheet mode and use the appropriate function
    local isSpritesheetMode = sprite.data and sprite.data:find("dmi_spritesheet=true")
    if isSpritesheetMode then
        return MDFunctions.deleteWestFramesSpritesheet(sprite)
    end
    
    local width = sprite.width
    local height = sprite.height
    
    -- If cell dimensions weren't provided, ask the user
    if not cellWidth or not cellHeight then
        local dlg = Dialog("Delete West Frames")
        dlg:number{ id = "cellWidth", label = "Frame Width:", text = tostring(MDFunctions.detectIconSize(sprite) or 32), decimals = 0 }
        dlg:number{ id = "cellHeight", label = "Frame Height:", text = tostring(MDFunctions.detectIconSize(sprite) or 32), decimals = 0 }
        dlg:check{ id = "activeFrameOnly", label = "Apply to active frame only:", selected = true }
        dlg:button{ id = "ok", text = "OK" }
        dlg:button{ id = "cancel", text = "Cancel" }
        dlg:show()
        
        if not dlg.data.ok then
            return false
        end
        
        cellWidth = dlg.data.cellWidth
        cellHeight = dlg.data.cellHeight
        activeFrameOnly = dlg.data.activeFrameOnly
    end
    
    -- Ensure sprite dimensions are multiples of the cell size
    if width % cellWidth ~= 0 or height % cellHeight ~= 0 then
        app.alert("Sprite dimensions must be multiples of the frame size")
        return false
    end
    
    -- Calculate grid dimensions
    local columns = width / cellWidth
    local rows = height / cellHeight
    local totalCells = columns * rows
    
    -- Frames to process
    local frameStart = app.activeFrame.frameNumber
    local frameEnd = frameStart
    
    if not activeFrameOnly then
        frameStart = 1
        frameEnd = #sprite.frames
    end
    
    -- Count how many west frames we'll delete
    local totalDeleted = 0
    
    -- Start transaction for undo support
    app.transaction("Delete West Frames", function()
        for frameNumber = frameStart, frameEnd do
            -- Create a new image for the entire sprite
            local fullImage = Image(sprite.width, sprite.height, sprite.colorMode)
            
            -- Make the entire image transparent
            fullImage:clear()
            
            -- Draw the current frame of the sprite onto the image
            for _, layer in ipairs(sprite.layers) do
                if layer.isVisible then
                    local cel = layer:cel(frameNumber)
                    if cel then
                        fullImage:drawImage(cel.image, cel.position)
                    end
                end
            end
            
            -- Process all cells
            local modified = false
            
            -- Detect if this is a 4-direction or 8-direction DMI
            local directions = 4  -- Default to 4 directions
            
            -- Check if the number of cells is divisible by 8
            if columns % 8 == 0 and rows % 8 == 0 then
                -- Check if the number of cells is divisible by 8
                local possibleStates = totalCells / 8
                if math.floor(possibleStates) == possibleStates then
                    directions = 8
                end
            end
            
            -- For 4-direction, the west index is 3 (SNEW)
            -- For 8-direction, the west index is 3 (S,N,E,W,SE,SW,NE,NW)
            local westIndex = 3
            
            -- Process each state/direction set
            local statesCount = totalCells / directions
            for state = 0, statesCount - 1 do
                -- Calculate the base index for this state
                local baseIndex = state * directions
                
                -- Calculate the West position
                local westCellIndex = baseIndex + westIndex
                local westCol = westCellIndex % columns
                local westRow = math.floor(westCellIndex / columns)
                local westX = westCol * cellWidth
                local westY = westRow * cellHeight
                
                -- Clear the west frame
                for py = 0, cellHeight - 1 do
                    for px = 0, cellWidth - 1 do
                        fullImage:putPixel(westX + px, westY + py, app.pixelColor.rgba(0, 0, 0, 0))
                    end
                end
                
                totalDeleted = totalDeleted + 1
                modified = true
            end
            
            -- Apply changes to the sprite
            if modified then
                for _, layer in ipairs(sprite.layers) do
                    if layer.isVisible then
                        -- Make layer editable if needed
                        local wasEditable = layer.isEditable
                        if not wasEditable then
                            layer.isEditable = true
                        end
                        
                        -- Create a new cel with the modified image
                        sprite:newCel(layer, sprite.frames[frameNumber], fullImage:clone(), Point(0, 0))
                        
                        -- Restore editability
                        if not wasEditable then
                            layer.isEditable = false
                        end
                        
                        -- Only need to modify one layer
                        break
                    end
                end
            end
        end
    end)
    
    if totalDeleted > 0 then
        app.alert("Deleted " .. totalDeleted .. " west-facing frames")
        MDFunctions.refreshDisplay(sprite)
        return true
    else
        app.alert("No west-facing frames were found to delete")
        return false
    end
end

--- Deletes all West-facing frames in spritesheet mode
--- Uses the DMI metadata extracted from the original file
--- @param sprite Sprite The sprite to process
--- @return boolean success Whether the operation was successful
function MDFunctions.deleteWestFramesSpritesheet(sprite)
    if not sprite then
        app.alert("No sprite open to process")
        return false
    end
    
    -- Get DMI metadata using the extension's existing functionality
    local metadata = MDFunctions.getDmiMetadata(sprite)
    if not metadata then
        -- Fall back to the manual method if metadata can't be extracted
        local dlg = Dialog("Delete West Frames")
        dlg:number{ id = "cellWidth", label = "Frame Width:", text = tostring(MDFunctions.detectIconSize(sprite) or 32), decimals = 0 }
        dlg:number{ id = "cellHeight", label = "Frame Height:", text = tostring(MDFunctions.detectIconSize(sprite) or 32), decimals = 0 }
        dlg:check{ id = "activeFrameOnly", label = "Apply to active frame only:", selected = true }
        dlg:button{ id = "ok", text = "OK" }
        dlg:button{ id = "cancel", text = "Cancel" }
        dlg:show()
        
        if not dlg.data.ok then
            return false
        end
        
        return MDFunctions.deleteWestFrames(sprite, dlg.data.cellWidth, dlg.data.cellHeight, dlg.data.activeFrameOnly)
    end
    
    -- Use the extracted metadata to perform the deletion
    local cellWidth = metadata.width
    local cellHeight = metadata.height
    local columns = metadata.gridInfo.columns
    
    -- Count how many frames we'll delete
    local totalDeleted = 0
    
    -- Start transaction for undo support
    app.transaction("Delete West Frames", function()
        -- Create a new image for the entire sprite
        local fullImage = Image(sprite.width, sprite.height, sprite.colorMode)
        
        -- Make the entire image transparent
        fullImage:clear()
        
        -- Draw the current frame of the sprite onto the image
        for _, layer in ipairs(sprite.layers) do
            if layer.isVisible then
                local cel = layer:cel(app.activeFrame.frameNumber)
                if cel then
                    fullImage:drawImage(cel.image, cel.position)
                end
            end
        end
        
        -- Process each state using the metadata from the original DMI
        for stateIndex, state in ipairs(metadata.states) do
            -- For each state, calculate starting cell index
            local stateOffset = 0
            for i = 1, stateIndex - 1 do
                stateOffset = stateOffset + (metadata.states[i].frame_count * metadata.states[i].dirs)
            end
            
            -- Process each frame of this state
            for frame = 0, state.frame_count - 1 do
                -- For each frame, process directions
                -- In DMI, the order is typically: South, North, East, West, ...
                local westIndex = 3  -- West is typically at index 3 (0-based)
                
                if state.dirs >= 4 then -- Only process if we have enough directions
                    -- Calculate cell indices
                    local baseIndex = stateOffset + (frame * state.dirs)
                    local westCellIndex = baseIndex + westIndex
                    
                    -- Calculate grid positions
                    local westCol = westCellIndex % columns
                    local westRow = math.floor(westCellIndex / columns)
                    
                    -- Calculate pixel coordinates
                    local westX = westCol * cellWidth
                    local westY = westRow * cellHeight
                    
                    -- Clear the west frame
                    for py = 0, cellHeight - 1 do
                        for px = 0, cellWidth - 1 do
                            fullImage:putPixel(westX + px, westY + py, app.pixelColor.rgba(0, 0, 0, 0))
                        end
                    end
                    
                    totalDeleted = totalDeleted + 1
                end
            end
        end
        
        -- Apply changes to the sprite
        for _, layer in ipairs(sprite.layers) do
            if layer.isVisible then
                -- Make layer editable if needed
                local wasEditable = layer.isEditable
                if not wasEditable then
                    layer.isEditable = true
                end
                
                -- Create a new cel with the modified image
                sprite:newCel(layer, sprite.frames[app.activeFrame.frameNumber], fullImage:clone(), Point(0, 0))
                
                -- Restore editability
                if not wasEditable then
                    layer.isEditable = false
                end
                
                -- Only need to modify one layer
                break
            end
        end
    end)
    
    if totalDeleted > 0 then
        app.alert("Deleted " .. totalDeleted .. " west-facing frames")
        MDFunctions.refreshDisplay(sprite)
        return true
    else
        app.alert("No west-facing frames were found to delete")
        return false
    end
end

--- Try to detect the icon size in a DMI spritesheet
--- @param sprite Sprite The sprite to analyze
--- @return number|nil size The detected icon size, or nil if it couldn't be determined
function MDFunctions.detectIconSize(sprite)
    if not sprite then return nil end
    
    -- Common DMI icon sizes
    local commonSizes = {32, 48, 64, 16, 96, 128}
    
    -- Check if width or height is divisible by common sizes
    for _, size in ipairs(commonSizes) do
        if sprite.width % size == 0 and sprite.height % size == 0 then
            -- Both dimensions are divisible by this size
            return size
        end
    end
    
    -- If no common size found, guess based on greatest common divisor
    local function gcd(a, b)
        while b ~= 0 do
            a, b = b, a % b
        end
        return a
    end
    
    local iconSize = gcd(sprite.width, sprite.height)
    
    -- Only return if it's a reasonable size (at least 8px)
    if iconSize >= 8 then
        return iconSize
    end
    
    return nil
end

--- Toggles the debug mode
--- @param enable boolean Whether to enable or disable debug mode
function MDFunctions.setDebugMode(enable)
    settings.debugMode = enable
    MDFunctions.debugMode = enable
end

return MDFunctions
