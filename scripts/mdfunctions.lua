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

--- Debug message function
local function dbgMsg(msg)
    if settings.debugMode then
        app.alert("DEBUG: " .. msg)
    end
end
-- Add this helper function to MDFunctions module:

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
        dbgMsg("Extracted " .. #ztxtChunk .. " bytes of raw chunk data")
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
        dbgMsg("Using native merge_spritesheet implementation")
        success, error = libdmi.merge_spritesheet(tempPath, origPath, dmiPath)
    else
        dbgMsg("Falling back to Lua merge_spritesheet implementation")
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
        dbgMsg("Source DMI file not found")
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
        dbgMsg("Error opening DMI file: " .. error)
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
    
    -- Report results
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
    
    -- Report results
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
    
    -- Report results
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
    
    -- Report results
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
end

return MDFunctions