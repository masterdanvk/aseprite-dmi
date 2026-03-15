--- @diagnostic disable: lowercase-global

--- Pure Lua image transform functions for live preview.
--- All transforms use nearest-neighbor interpolation, which is ideal for pixel art.
--- These run during interactive editing (drag/slider) for instant feedback.

LuaTransform = {}

--- Flip an image horizontally (mirror left-right).
--- @param srcImage Image
--- @return Image
function LuaTransform.flipH(srcImage)
    local w, h = srcImage.width, srcImage.height
    local dst = Image(w, h, ColorMode.RGB)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            dst:drawPixel(w - 1 - x, y, srcImage:getPixel(x, y))
        end
    end
    return dst
end

--- Flip an image vertically (mirror top-bottom).
--- @param srcImage Image
--- @return Image
function LuaTransform.flipV(srcImage)
    local w, h = srcImage.width, srcImage.height
    local dst = Image(w, h, ColorMode.RGB)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            dst:drawPixel(x, h - 1 - y, srcImage:getPixel(x, y))
        end
    end
    return dst
end

--- Scale an image using nearest-neighbor interpolation.
--- @param srcImage Image
--- @param newW number Target width
--- @param newH number Target height
--- @return Image
function LuaTransform.scale(srcImage, newW, newH)
    local sw, sh = srcImage.width, srcImage.height
    newW = math.max(1, math.floor(newW))
    newH = math.max(1, math.floor(newH))
    local dst = Image(newW, newH, ColorMode.RGB)
    for y = 0, newH - 1 do
        for x = 0, newW - 1 do
            local sx = math.min(math.floor(x * sw / newW), sw - 1)
            local sy = math.min(math.floor(y * sh / newH), sh - 1)
            dst:drawPixel(x, y, srcImage:getPixel(sx, sy))
        end
    end
    return dst
end

--- Rotate an image by the given angle (degrees) around its center.
--- Uses nearest-neighbor sampling. Output is same dimensions as input.
--- @param srcImage Image
--- @param angleDeg number Rotation angle in degrees (positive = clockwise)
--- @return Image
function LuaTransform.rotate(srcImage, angleDeg)
    if angleDeg % 360 == 0 then return srcImage:clone() end

    local w, h = srcImage.width, srcImage.height
    local dst = Image(w, h, ColorMode.RGB)

    local cx = w / 2
    local cy = h / 2
    local rad = -angleDeg * math.pi / 180 -- negative for inverse mapping
    local cosA = math.cos(rad)
    local sinA = math.sin(rad)

    for dy = 0, h - 1 do
        for dx = 0, w - 1 do
            local rx = (dx - cx) * cosA - (dy - cy) * sinA + cx
            local ry = (dx - cx) * sinA + (dy - cy) * cosA + cy

            local sx = math.floor(rx + 0.5)
            local sy = math.floor(ry + 0.5)

            if sx >= 0 and sx < w and sy >= 0 and sy < h then
                dst:drawPixel(dx, dy, srcImage:getPixel(sx, sy))
            end
        end
    end

    return dst
end

--- Apply a full transform pipeline to an image.
--- @param srcImage Image Source image
--- @param params table Transform params: { rotation, flip_h, flip_v, scale }
--- @param highQuality boolean If true, upscale 4x before rotation then downscale
--- @return Image Transformed image
function LuaTransform.transform(srcImage, params, highQuality)
    local img = srcImage:clone()

    -- Flip (before rotation so flips are in local space)
    if params.flip_h then
        img = LuaTransform.flipH(img)
    end
    if params.flip_v then
        img = LuaTransform.flipV(img)
    end

    -- Scale (supports independent X/Y)
    local sx = params.scale_x or params.scale or 1.0
    local sy = params.scale_y or params.scale or 1.0
    if sx ~= 1.0 or sy ~= 1.0 then
        local nw = math.max(1, math.floor(img.width * sx))
        local nh = math.max(1, math.floor(img.height * sy))
        img = LuaTransform.scale(img, nw, nh)
    end

    -- Rotation
    local rot = params.rotation or 0
    if rot % 360 ~= 0 then
        if highQuality then
            -- Upscale 4×, rotate at high res, downscale back
            local ow, oh = img.width, img.height
            img = LuaTransform.scale(img, ow * 4, oh * 4)
            img = LuaTransform.rotate(img, rot)
            img = LuaTransform.scale(img, ow, oh)
        else
            img = LuaTransform.rotate(img, rot)
        end
    end

    return img
end
