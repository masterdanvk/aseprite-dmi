--- @diagnostic disable: lowercase-global

--- Autotile module for creating 47-state autojoin tiles from a 3x4 template.
--- Based on Ter13's AutotileLib (https://www.byond.com/developer/Ter13/AutotileLib)
---
--- Template Layout (in Aseprite, top-to-bottom, matches BYOND visual order):
---   Row 0: Tiles  1,  2,  3   (top)
---   Row 1: Tiles  4,  5,  6
---   Row 2: Tiles  7,  8,  9
---   Row 3: Tiles 10, 11, 12   (bottom)
---
--- The cutter quarters each of the 12 source tiles into TL/TR/BL/BR quadrants,
--- then composites them into 47 unique joining states using lookup tables.
--- Supports animated templates (multiple Aseprite frames → animated DMI states).

Autotile = {}
Autotile.__index = Autotile

------------------- CONSTANTS -------------------

--- 47 unique bitmask state values used by AutotileLib.
--- These become the icon_state names in the output DMI.
Autotile.STATES = {
    0,   1,   2,   3,   4,   5,   6,   7,
    8,   9,  10,  11,  12,  13,  14,  15,
   21,  23,  29,  31,  38,  39,  46,  47,
   55,  63,  74,  75,  78,  79,  95, 110,
  111, 127, 137, 139, 141, 143, 157, 159,
  175, 191, 203, 207, 223, 239, 255
}

--- Quadrant lookup tables ported from Ter13's AutotileLib.dm.
--- For each of the 47 states, specifies which source tile (1-12)
--- provides the top-left, top-right, bottom-left, and bottom-right quadrant.
Autotile.TL = {
     1,  7,  4,  7,  4,  7,  4,  7,
     5,  3,  5,  3,  5,  3,  5,  3,
    10,  7,  3,  3,  4,  7,  5,  3,
     7,  3,  6,  3,  5,  3,  3,  5,
     3,  3, 12,  9, 11,  8, 11,  8,
     8,  8,  9,  8,  8,  8,  8
}

Autotile.TR = {
     1,  9,  6,  9,  5,  3,  5,  3,
     6,  9,  6,  9,  5,  3,  5,  3,
    10,  7,  8,  8,  4,  3,  5,  3,
     7,  8,  6,  9,  5,  3,  8,  5,
     3,  8, 12,  9,  3,  3, 11,  8,
     3,  8,  9,  3,  8,  3,  8
}

Autotile.BL = {
     1, 10,  7,  7, 10, 10,  7,  7,
    11, 11,  3,  3, 11, 11,  3,  3,
    10,  7, 11,  3,  4,  7,  3,  3,
     7,  3,  6,  8,  5,  8,  8,  5,
     8,  8, 12,  3, 11,  3, 11,  3,
     3,  3,  9,  8,  8,  8,  8
}

Autotile.BR = {
     1, 12,  9,  9, 11, 11,  3,  3,
    12, 12,  9,  9, 11, 11,  3,  3,
    10,  3, 11,  3,  4,  7,  8,  8,
     7,  8,  6,  9,  3,  3,  3,  5,
     8,  8, 12,  9, 11,  3, 11,  3,
     8,  8,  9,  3,  3,  8,  8
}

--- Sprite data key for storing tile size metadata.
Autotile.DATA_KEY = "autotile_tilesize"

--- 3x5 pixel font for digits 0-9.
--- Each row is a 3-bit bitmask: bit2=left, bit1=center, bit0=right.
local FONT = {
    [0] = {7,5,5,5,7},
    [1] = {2,6,2,2,7},
    [2] = {7,1,7,4,7},
    [3] = {7,1,7,1,7},
    [4] = {5,5,7,1,1},
    [5] = {7,4,7,1,7},
    [6] = {7,4,7,5,7},
    [7] = {7,1,1,1,1},
    [8] = {7,5,7,5,7},
    [9] = {7,5,7,1,7},
}

------------------- HELPER FUNCTIONS -------------------

--- Extract a rectangular region from a source image via pixel copy.
--- @param src Image Source image
--- @param sx number X offset in source
--- @param sy number Y offset in source
--- @param w number Width of region to extract
--- @param h number Height of region to extract
--- @return Image Extracted region
local function extractRegion(src, sx, sy, w, h)
    local dst = Image(w, h, ColorMode.RGB)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local srcX = sx + x
            local srcY = sy + y
            if srcX >= 0 and srcX < src.width and srcY >= 0 and srcY < src.height then
                dst:drawPixel(x, y, src:getPixel(srcX, srcY))
            end
        end
    end
    return dst
end

--- Copy a source image into a destination image at the given position via pixel copy.
--- Uses direct pixel transfer to avoid any blend mode issues with drawImage.
--- @param dst Image Destination image
--- @param src Image Source image
--- @param dx number X offset in destination
--- @param dy number Y offset in destination
local function blitRegion(dst, src, dx, dy)
    for y = 0, src.height - 1 do
        for x = 0, src.width - 1 do
            local dstX = dx + x
            local dstY = dy + y
            if dstX >= 0 and dstX < dst.width and dstY >= 0 and dstY < dst.height then
                dst:drawPixel(dstX, dstY, src:getPixel(x, y))
            end
        end
    end
end

--- Save an Image in the .bytes format used by libdmi's serialization pipeline.
--- Format: "{width}\n{height}\n{RGBA pixel data}"
--- Uses raw byte extraction from pixel values to match the Rust reader exactly.
--- @param image Image The Aseprite Image to save
--- @param path string File path to write to
--- @return boolean, string success and error message
local function saveImageAsBytes(image, path)
    local f = io.open(path, "wb")
    if not f then return false, "Could not open file: " .. path end

    local w = image.width
    local h = image.height
    local header = string.format("%d\n%d\n", w, h)
    f:write(header)

    -- Write RGBA pixel data in row-major order.
    -- Pixel values in RGBA ColorMode are packed as 0xAABBGGRR (little-endian ABGR).
    -- The Rust reader expects bytes in R, G, B, A order.
    local buf = {}
    local n = 0
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local v = image:getPixel(x, y)
            -- Extract RGBA components using bitwise ops (matches Aseprite's RGBA packing)
            local r = v & 0xFF
            local g = (v >> 8) & 0xFF
            local b = (v >> 16) & 0xFF
            local a = (v >> 24) & 0xFF
            n = n + 1
            buf[n] = string.char(r, g, b, a)
        end
    end
    f:write(table.concat(buf))
    f:close()

    -- Validate: check file size matches expected
    local expectedSize = #header + (w * h * 4)
    local actualFile = io.open(path, "rb")
    if actualFile then
        local content = actualFile:read("*a")
        actualFile:close()
        if #content ~= expectedSize then
            return false, string.format(
                "File size mismatch: expected %d, got %d for %s",
                expectedSize, #content, path)
        end
    end

    return true, nil
end

--- Draw a single digit from the pixel font onto an image.
--- @param image Image Target image
--- @param d number Digit 0-9
--- @param x number X position (top-left of digit)
--- @param y number Y position (top-left of digit)
--- @param color number Packed RGBA pixel color
local function drawDigit(image, d, x, y, color)
    local pattern = FONT[d]
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

--- Draw a multi-digit number onto an image.
--- @param image Image Target image
--- @param num number The number to draw
--- @param x number X position
--- @param y number Y position
--- @param color number Packed RGBA pixel color
local function drawNumber(image, num, x, y, color)
    local s = tostring(num)
    for i = 1, #s do
        local d = tonumber(s:sub(i, i))
        drawDigit(image, d, x + (i - 1) * 4, y, color)
    end
end

--- Get the Aseprite pixel position for a BYOND tile number (1-12).
--- Tiles are numbered left-to-right, top-to-bottom in visual space:
---   1  2  3
---   4  5  6
---   7  8  9
---  10 11 12
--- This matches BYOND's GenAutotile ordering (which reads top-down
--- due to y-up Crop math: iy = h - (floor(count/3)+1)*ih).
--- @param n number Tile number (1-12)
--- @param tw number Tile width
--- @param th number Tile height
--- @return number x, number y Top-left corner in Aseprite coordinates
local function tilePosition(n, tw, th)
    local row = math.floor((n - 1) / 3)  -- 0-3, top to bottom
    local col = (n - 1) % 3               -- 0-2, left to right
    return col * tw, row * th
end

------------------- REFERENCE IMAGE -------------------

--- Generate the reference layer image with grid lines and tile numbers.
--- Shows a subtle grid dividing the 12 tile regions with centered tile numbers
--- and faint colored fills to help identify each tile.
--- @param tw number Tile width
--- @param th number Tile height
--- @return Image The reference image
local function generateReferenceImage(tw, th)
    local canvasW = tw * 3
    local canvasH = th * 4
    local img = Image(canvasW, canvasH, ColorMode.RGB)

    -- Colors
    local gridColor = app.pixelColor.rgba(180, 180, 180, 100)
    local textColor = app.pixelColor.rgba(255, 255, 255, 180)
    local textShadow = app.pixelColor.rgba(0, 0, 0, 120)

    -- Subtle background fills for each tile region (helps identify tiles at a glance)
    local bgColors = {
        [ 1] = app.pixelColor.rgba(120,  80,  80, 25),  -- Isolated
        [ 2] = app.pixelColor.rgba( 80, 120,  80, 25),  -- H-Bar
        [ 3] = app.pixelColor.rgba( 80,  80, 120, 25),  -- Full
        [ 4] = app.pixelColor.rgba(120, 120,  60, 25),  -- TL Outer
        [ 5] = app.pixelColor.rgba(120,  60, 120, 25),  -- Top Edge
        [ 6] = app.pixelColor.rgba( 60, 120, 120, 25),  -- TR Outer
        [ 7] = app.pixelColor.rgba(100, 100,  60, 25),  -- Left Edge
        [ 8] = app.pixelColor.rgba( 60, 100, 100, 25),  -- Center
        [ 9] = app.pixelColor.rgba(100,  60, 100, 25),  -- Right Edge
        [10] = app.pixelColor.rgba( 90,  90,  60, 25),  -- BL Outer
        [11] = app.pixelColor.rgba( 60,  90,  90, 25),  -- Bot Edge
        [12] = app.pixelColor.rgba( 90,  60,  90, 25),  -- BR Outer
    }

    -- Fill each tile region with subtle background
    for n = 1, 12 do
        local x, y = tilePosition(n, tw, th)
        local bg = bgColors[n]
        for py = y + 1, y + th - 2 do
            for px = x + 1, x + tw - 2 do
                if px < canvasW and py < canvasH then
                    img:drawPixel(px, py, bg)
                end
            end
        end
    end

    -- Draw grid lines (vertical)
    for col = 0, 3 do
        local x = math.min(col * tw, canvasW - 1)
        for py = 0, canvasH - 1 do
            img:drawPixel(x, py, gridColor)
        end
    end

    -- Draw grid lines (horizontal)
    for row = 0, 4 do
        local y = math.min(row * th, canvasH - 1)
        for px = 0, canvasW - 1 do
            img:drawPixel(px, y, gridColor)
        end
    end

    -- Draw tile numbers centered in each tile (with shadow for readability)
    for n = 1, 12 do
        local x, y = tilePosition(n, tw, th)
        local numStr = tostring(n)
        local numWidth = #numStr * 4 - 1
        local numX = x + math.floor((tw - numWidth) / 2)
        local numY = y + math.floor((th - 5) / 2)

        -- Shadow (offset by 1 pixel)
        drawNumber(img, n, numX + 1, numY + 1, textShadow)
        -- Foreground
        drawNumber(img, n, numX, numY, textColor)
    end

    return img
end

------------------- TEMPLATE CREATION -------------------

--- Load the bundled template PNG and optionally scale it for non-32 tile sizes.
--- Falls back to the programmatic reference image if the PNG can't be loaded.
--- @param pluginPath string Plugin installation path
--- @param tw number Target tile width
--- @param th number Target tile height
--- @return Image The reference image (scaled template)
local function loadTemplateImage(pluginPath, tw, th)
    local canvasW = tw * 3
    local canvasH = th * 4
    local templatePath = app.fs.joinPath(pluginPath, "scripts", "assets", "autotiletemplate32.png")

    if app.fs.isFile(templatePath) then
        -- Load the base 32px template as its own temporary sprite so we can
        -- access its pixel data and scale it if needed.
        local tempSprite = Sprite { fromFile = templatePath }
        if tempSprite then
            -- Scale if tile size differs from the 32px base template
            if tw ~= 32 or th ~= 32 then
                tempSprite:resize(canvasW, canvasH)
            end

            -- Render the (possibly scaled) template into an Image
            local refImage = Image(canvasW, canvasH, ColorMode.RGB)
            refImage:drawSprite(tempSprite, 1)

            -- Close the temporary sprite without saving
            tempSprite:close()

            return refImage
        end
    end

    -- Fallback: generate a programmatic reference image
    return generateReferenceImage(tw, th)
end

--- Create a new autotile template sprite in Aseprite.
--- Sets up a 3×4 grid canvas with a locked reference layer (template PNG + tile numbers)
--- and an active "Art" layer for the user to paint on.
--- @param tileSize number The tile size (e.g., 32 for 32x32 tiles). Must be even and >= 8.
--- @param pluginPath string Plugin installation path (for locating template assets)
--- @return Sprite|nil The created sprite, or nil on error
function Autotile.newTemplate(tileSize, pluginPath)
    if tileSize < 8 then
        app.alert("Tile size must be at least 8 pixels")
        return nil
    end

    if tileSize % 2 ~= 0 then
        app.alert("Tile size must be even (e.g., 16, 32, 48, 64)")
        return nil
    end

    local tw = tileSize
    local th = tileSize
    local canvasW = tw * 3
    local canvasH = th * 4

    -- Create new RGBA sprite
    local sprite = Sprite(canvasW, canvasH, ColorMode.RGB)

    -- Rename the default layer to "Art" (this is where the user paints)
    local artLayer = sprite.layers[1]
    artLayer.name = "Art"

    -- Create reference layer
    local refLayer = sprite:newLayer()
    refLayer.name = "Reference"
    refLayer.opacity = 128

    -- Load template PNG as reference (with scaling and number overlay)
    local refImage = loadTemplateImage(pluginPath, tw, th)

    -- Place the reference image as a cel on frame 1
    sprite:newCel(refLayer, 1, refImage, Point(0, 0))

    -- Move reference layer to the bottom of the stack
    refLayer.stackIndex = 1

    -- Lock the reference layer so the user doesn't accidentally paint on it
    refLayer.isEditable = false

    -- Store tile size in sprite metadata for later detection
    sprite.data = Autotile.DATA_KEY .. "=" .. tileSize

    -- Set the active layer to Art so the user can start painting immediately
    app.activeLayer = sprite.layers[2]

    app.refresh()

    return sprite
end

------------------- TILE SIZE DETECTION -------------------

--- Detect tile size from a sprite, either via metadata or dimension analysis.
--- @param sprite Sprite The sprite to check
--- @return number|nil tileSize The detected tile size, or nil if not a valid template
function Autotile.detectTileSize(sprite)
    -- Try metadata first (most reliable)
    if sprite.data then
        local size = sprite.data:match(Autotile.DATA_KEY .. "=(%d+)")
        if size then return tonumber(size) end
    end

    -- Fall back to dimension analysis: width must be 3N, height must be 4N, N must be even
    local w = sprite.width
    local h = sprite.height
    if w % 3 == 0 and h % 4 == 0 then
        local tw = w / 3
        local th = h / 4
        if tw == th and tw >= 8 and tw % 2 == 0 then
            return tw
        end
    end

    return nil
end

------------------- EXPORT -------------------

--- Flatten visible layers of a sprite for a given frame, excluding the reference layer.
--- Composites all visible non-Reference layers by iterating cels directly.
--- This avoids modifying any sprite state (no layer visibility toggling).
--- @param sprite Sprite
--- @param frameIdx number Frame number (1-based)
--- @return Image Flattened RGBA image of the full canvas
local function flattenFrame(sprite, frameIdx)
    local img = Image(sprite.spec)

    -- Composite each visible non-Reference layer from bottom to top
    for _, layer in ipairs(sprite.layers) do
        if layer.name ~= "Reference" and layer.isVisible then
            local cel = layer:cel(frameIdx)
            if cel then
                -- Draw this layer's cel onto the composite
                img:drawImage(cel.image, cel.position)
            end
        end
    end

    return img
end

--- Export the current autotile template sprite as a 47-state DMI file.
--- Supports animated templates: multiple Aseprite frames produce animated DMI states.
---
--- Pipeline:
---   1. Flatten each frame (excluding reference layer)
---   2. Extract 12 source tiles from the 3×4 grid per frame
---   3. Quarter each tile into TL/TR/BL/BR quadrants
---   4. Composite 47 states using Ter13's lookup tables
---   5. Write .bytes files to temp directory
---   6. Call libdmi.save_file to produce the DMI
---
--- @param sprite Sprite The autotile template sprite
--- @param outputPath string Path for the output DMI file
--- @param pluginPath string Plugin installation path (needed for loadlib)
--- @param dmiName string|nil Optional internal DMI name (defaults to filename)
--- @return boolean success
function Autotile.exportDMI(sprite, outputPath, pluginPath, dmiName)
    -- Detect tile size
    local tileSize = Autotile.detectTileSize(sprite)
    if not tileSize then
        app.alert("Could not determine tile size. Is this an autotile template?")
        return false
    end

    local tw = tileSize
    local th = tileSize
    local hw = math.floor(tw / 2)
    local hh = math.floor(th / 2)
    local numFrames = #sprite.frames

    -- Ensure the DMI library is loaded
    loadlib(pluginPath)

    -- Create temp directory for .bytes files
    if not app.fs.isDirectory(TEMP_DIR) then
        app.fs.makeDirectory(TEMP_DIR)
    end
    local tempDir = app.fs.joinPath(TEMP_DIR, "autotile_" .. os.time())
    app.fs.makeDirectory(tempDir)

    -- ── Phase 1: Flatten all frames and pre-extract tiles + quadrants ──

    -- frame_tl[frameIdx][tileN] = TL quadrant Image of tile N on frame frameIdx
    local frame_tl = {}
    local frame_tr = {}
    local frame_bl = {}
    local frame_br = {}

    for frame_idx = 1, numFrames do
        local flatImage = flattenFrame(sprite, frame_idx)

        frame_tl[frame_idx] = {}
        frame_tr[frame_idx] = {}
        frame_bl[frame_idx] = {}
        frame_br[frame_idx] = {}

        for n = 1, 12 do
            local x, y = tilePosition(n, tw, th)
            local tile = extractRegion(flatImage, x, y, tw, th)

            frame_tl[frame_idx][n] = extractRegion(tile, 0,  0,  hw, hh)
            frame_tr[frame_idx][n] = extractRegion(tile, hw, 0,  hw, hh)
            frame_bl[frame_idx][n] = extractRegion(tile, 0,  hh, hw, hh)
            frame_br[frame_idx][n] = extractRegion(tile, hw, hh, hw, hh)
        end
    end

    -- ── Phase 2: Composite 47 states and write .bytes files ──

    -- Collect frame delays from Aseprite frame durations (convert seconds → DMI ticks)
    local delays = {}
    if numFrames > 1 then
        for f = 1, numFrames do
            delays[f] = sprite.frames[f].duration * 10
        end
    end

    local states = {}

    for state_idx = 1, 47 do
        local stateName = tostring(Autotile.STATES[state_idx])
        local frameKey = stateName .. ".1"

        -- Composite and save each animation frame for this state
        for frame_idx = 1, numFrames do
            -- Create blank transparent tile
            local composite = Image(tw, th, ColorMode.RGB)

            -- Assemble from 4 quadrants using pixel-level copy (avoids drawImage blend issues)
            blitRegion(composite, frame_tl[frame_idx][Autotile.TL[state_idx]], 0,  0)
            blitRegion(composite, frame_tr[frame_idx][Autotile.TR[state_idx]], hw, 0)
            blitRegion(composite, frame_bl[frame_idx][Autotile.BL[state_idx]], 0,  hh)
            blitRegion(composite, frame_br[frame_idx][Autotile.BR[state_idx]], hw, hh)

            -- Write .bytes file: {frameKey}.{index}.bytes
            local bytesIdx = frame_idx - 1
            local bytesPath = app.fs.joinPath(tempDir, frameKey .. "." .. bytesIdx .. ".bytes")
            local writeOk, writeErr = saveImageAsBytes(composite, bytesPath)
            if not writeOk then
                app.alert("Failed to write tile data for state " .. stateName ..
                          " frame " .. frame_idx .. "\n" .. (writeErr or ""))
                return false
            end
        end

        -- Build the serialized state table for libdmi
        table.insert(states, {
            name = stateName,
            dirs = 1,
            frame_key = frameKey,
            frame_count = numFrames,
            delays = numFrames > 1 and delays or {},
            loop = 0,
            rewind = false,
            movement = false,
            hotspots = {},
        })
    end

    -- ── Phase 3: Save DMI via libdmi ──

    local dmiTable = {
        name = dmiName or app.fs.fileTitle(outputPath),
        width = tw,
        height = th,
        states = states,
        temp = tempDir,
    }

    -- Note: libdmi functions use safe!() wrapper and never throw.
    -- They return (result, error_string) instead.
    local result, saveErr = libdmi.save_file(dmiTable, outputPath)

    -- Clean up temp directory
    local _, cleanErr = libdmi.remove_dir(tempDir, false)
    if cleanErr then
        print("[Autotile] cleanup warning: " .. cleanErr)
    end

    if saveErr then
        app.alert("Failed to save DMI:\n" .. tostring(saveErr))
        return false
    end

    app.alert("Autotile DMI exported successfully!\n\n" ..
        "States: 47\n" ..
        "Frames per state: " .. numFrames .. "\n" ..
        "Tile size: " .. tw .. "x" .. th .. "\n" ..
        "Output: " .. outputPath)

    return true
end
