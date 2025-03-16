------------------- EDITOR -------------------

--- Editor is a class representing a DMI editor.
--- It provides functionality for editing DMI files.
--- @class Editor
--- @field title string The title of the editor.
--- @field canvas_width number The width of the canvas.
--- @field canvas_height number The height of the canvas.
--- @field max_in_a_row number The maximum number of states in a row.
--- @field max_in_a_column number The maximum number of states in a column.
--- @field focused_widget AnyWidget Widget The currently focused widget.
--- @field hovering_widgets AnyWidget[] A table containing all widgets that are currently being hovered by the mouse.
--- @field scroll number The current scroll position.
--- @field mouse Editor.Mouse The current mouse state.
--- @field dmi Dmi The currently opened DMI file.
--- @field open_sprites (StateSprite)[] A table containing all open sprites.
--- @field widgets (AnyWidget)[] A table containing all state widgets.
--- @field context_widget ContextWidget|nil The state that is currently being right clicked
--- @field beforecommand number The event object for the "beforecommand" event.
--- @field aftercommand number The event object for the "aftercommand" event.
--- @field dialog Dialog The dialog object.
--- @field save_path string|nil The path of the file to be saved.
--- @field open_path string|nil The path of the file to be opened.
--- @field image_cache ImageCache The image cache object.
--- @field loading boolean Whether the editor is currently loading a file.
--- @field modified boolean Whether a state has been modified.
--- @field closed boolean Whether the editor has been closed.
--- @field spritesheet_mode boolean Whether we're in spritesheet editing mode.
--- @field spritesheet_sprite Sprite|nil The sprite object for spritesheet editing.
Editor = {}
Editor.__index = Editor

--- @class Editor.Mouse
--- @field position Point The current mouse position.
--- @field leftClick boolean Whether the left mouse button is pressed.
--- @field rightClick boolean Whether the right mouse button is pressed.

--- Creates a new instance of the Editor class.
--- @param title string The title of the editor.
--- @param dmi string|Dmi The path of the file to be opened or the Dmi object to be opened.
--- @return Editor editor  The newly created Editor instance.
function Editor.new(title, dmi)
	local self            = setmetatable({}, Editor)

	local is_filename     = type(dmi) == "string"

	self.title            = title
	self.focused_widget   = nil
	self.hovering_widgets = {}
	self.scroll           = 0
	self.mouse            = { position = Point(0, 0), leftClick = false, rightClick = false }
	self.dmi              = nil
	self.open_sprites     = {}
	self.widgets          = {}
	self.context_widget   = nil
	self.save_path        = nil
	self.open_path        = is_filename and dmi --[[@as string]] or nil

    -- Initialize spritesheet mode properties
    self.spritesheet_mode = false
    self.spritesheet_sprite = nil

	self.canvas_width     = 185
	self.canvas_height    = 215
	self.max_in_a_row     = 1
	self.max_in_a_column  = 1

	self.loading          = true
	self.modified         = false

	self.image_cache      = ImageCache.new()

	self.beforecommand    = app.events:on("beforecommand", function(ev) self:onbeforecommand(ev) end)

	self.aftercommand     = app.events:on("aftercommand", function(ev) self:onaftercommand(ev) end)

	self:new_dialog(title)
	self:show()

	self:open_file(not is_filename and dmi --[[@as Dmi]] or nil)

	table.insert(open_editors, self)

	return self
end

--- Creates a new dialog for the editor with the specified title.
--- @param title string The title of the dialog.
function Editor:new_dialog(title)
	self.dialog = Dialog {
		title = title,
		onclose = function() self:close(true) end
	}

    -- Add the View Mode toggle button
    self.dialog:button {
        id = "toggle_view",
        text = "View Spritesheet",
        onclick = function() self:toggle_view_mode() end
    }

	self.dialog:canvas {
		width = self.canvas_width,
		height = self.canvas_height,
		onpaint = function(ev) self:onpaint(ev.context) end,
		onmousedown = function(ev) self:onmousedown(ev) end,
		onmouseup = function(ev) self:onmouseup(ev) end,
		onmousemove = function(ev) self:onmousemove(ev) end,
		onwheel = function(ev) self:onwheel(ev) end
	}

	self.dialog:button {
		text = "Save",
		onclick = function() self:save() end
	}
end

--- Toggles between state view and spritesheet view modes
function Editor:toggle_view_mode()
    if not self.dmi then return end
    
    -- Save any pending changes in the current mode
    if self.spritesheet_mode then
        -- Coming from spritesheet mode back to state mode
        if self.spritesheet_sprite then
            -- Only apply changes if the sprite exists
            self:apply_spritesheet_changes()
            
            -- Clean up the spritesheet sprite
            self.spritesheet_sprite = nil
        end
    else
        -- Going from state mode to spritesheet mode
        -- Save any open state sprites
        for _, state_sprite in ipairs(self.open_sprites) do
            if state_sprite.sprite and state_sprite.sprite.isModified then
                state_sprite:save()
            end
        end
    end
    
    -- Toggle the mode
    self.spritesheet_mode = not self.spritesheet_mode
    
    if self.spritesheet_mode then
        -- Enter spritesheet mode
        self:enter_spritesheet_mode()
    else
        -- Return to state mode - sprite cleanup already done above
        self:exit_spritesheet_mode()
    end
    
    -- Update the button text
    self.dialog:modify {
        id = "toggle_view",
        text = self.spritesheet_mode and "View States" or "View Spritesheet"
    }
    
    -- Update the view
    self:repaint_states()
end
--- Enter spritesheet editing mode
function Editor:enter_spritesheet_mode()
    if not self.dmi then return end
    
    -- Create a spritesheet sprite from all the states
    self.spritesheet_sprite = self:create_spritesheet()
end

--- Exit spritesheet editing mode and return to state view
function Editor:exit_spritesheet_mode()
    -- We already applied changes in toggle_view_mode
    -- Here we just need to make sure we've cleaned up properly
    self.spritesheet_sprite = nil
    
    -- Update the state view
    self:repaint_states()
end

--- Displays the editor dialog.
function Editor:show()
	self.dialog:show { wait = false }
end

--- Opens a DMI file and displays it in the editor.
--- @param dmi? Dmi The DMI object to be opened if not passed `Editor.open_path` will be used.
function Editor:open_file(dmi)
	if self.dmi then
		libdmi.remove_dir(self.dmi.temp, false)
	end

	for _, state_sprite in ipairs(self.open_sprites) do
		state_sprite.sprite:close()
	end

	self.image_cache:clear()

	self.scroll = 0
	self.dmi = nil
	self.widgets = {}
	self.open_sprites = {}
	self.save_path = nil
    self.spritesheet_mode = false
    if self.spritesheet_sprite then
        self.spritesheet_sprite:close()
        self.spritesheet_sprite = nil
    end

	self:repaint()

	if not dmi then
		local dmi, error = libdmi.open_file(self.open_path, TEMP_DIR)
		if not error then
			self.dmi = dmi --[[@as Dmi]]
			self.image_cache:load_previews(self.dmi)
		else
			app.alert { title = "Error", text = { "Failed to open the DMI file", error } }
		end

		self.loading = false
		self:repaint_states()
	else
		self.dmi = dmi
		self.loading = false
		self.image_cache:load_previews(self.dmi)
		self:repaint_states()
	end
end

--- Saves the current DMI file.
--- If the DMI file is not set, the function returns without doing anything.
--- Displays a success or failure message using the Aseprite app.alert function.
--- @param no_dialog boolean|nil If true, skips the save dialog and overwrites the current file
--- @return boolean success Whether the DMI file has been saved. May still return true even if the file has not been saved successfully.
function Editor:save(no_dialog)
	if not self.dmi then return false end

    -- If in spritesheet mode, apply changes back to states first
    if self.spritesheet_mode and self.spritesheet_sprite then
        self:apply_spritesheet_changes()
    end

	local path = self:path()
	local filename = path
	local error

	if not no_dialog then
		local result = libdmi.save_dialog("Save File", app.fs.fileTitle(path), app.fs.filePath(path))
		filename, error = result or "", nil
	end

	if (#filename > 0) and not error then
		self.save_path = filename
		local _, err = libdmi.save_file(self.dmi, filename --[[@as string]])
		if not err then
			self.modified = false
		end
		return true
	end
	return false
end

--- Returns the path of the file to be saved.
--- If `save_path` is set, it returns that path.
--- Otherwise, if `open_path` is set, it returns that path.
--- If neither `save_path` nor `open_path` is set, it returns the path to a default file named "untitled.dmi" in the user's documents folder.
--- @return string path The path of the file to be saved.
function Editor:path()
	return self.save_path or self.open_path or app.fs.joinPath(app.fs.userDocsPath, "untitled.dmi")
end

--- @type string|nil
local save_file_as = nil

--- This function is called before executing a command in the Aseprite editor. It checks the event name and performs specific actions based on the event type.
--- @param ev table The event object containing information about the event.
function Editor:onbeforecommand(ev)
	if ev.name == "SaveFile" then
		for _, state_sprite in ipairs(self.open_sprites) do
			if app.sprite == state_sprite.sprite then
				if not state_sprite:save() then
					ev.stopPropagation()
				end
				if Preferences.getAutoOverwrite and Preferences.getAutoOverwrite() then
					self:save(true)
				end
				break
			end
		end
	elseif ev.name == "SaveFileAs" then
		for _, state_sprite in ipairs(self.open_sprites) do
			if app.sprite == state_sprite.sprite then
				if save_file_as == nil then
					save_file_as = app.sprite.filename
				end
				break
			end
		end
	end
end

--- Callback function called after a Aseprite command is executed.
--- @param ev table The event object containing information about the command.
function Editor:onaftercommand(ev)
	if ev.name == "SaveFileAs" then
		for i, state_sprite in ipairs(self.open_sprites) do
			if app.sprite == state_sprite.sprite then
				if save_file_as ~= nil and save_file_as ~= app.sprite.filename then
					table.remove(self.open_sprites, i)
				end
				save_file_as = nil
				break
			end
		end
	end
end

--- Removes unused statesprites from the open_sprites.
function Editor:gc_open_sprites()
	local open_sprites = {} --[[@type StateSprite[] ]]
	for _, state_sprite in ipairs(self.open_sprites) do
		if self.is_sprite_open(state_sprite.sprite) then
			table.insert(open_sprites, state_sprite)
		end
	end
	self.open_sprites = open_sprites
end

--- Switches the tab to the sprite containing the state.
--- @param sprite Sprite The sprite to be opened.
function Editor.switch_tab(sprite)
	local tries = 0
	local max_tries = #app.sprites + 1
	while app.sprite ~= sprite and tries <= max_tries do
		tries = tries + 1
		app.command.GotoNextTab()
	end
end

--- Checks if the DMI file has been modified.
--- @return boolean modified Whether the DMI file has been modified.
function Editor:is_modified()
	if self.modified then return true end
	
	for _, state_sprite in ipairs(self.open_sprites) do
		if state_sprite.sprite.isModified then
			return true
		end
	end
	
	-- Also check spritesheet modifications
    if self.spritesheet_mode and self.spritesheet_sprite and self.spritesheet_sprite.isModified then
        return true
    end
	
	return false
end

--- Checks if the sprite is open in the Aseprite editor.
--- @param sprite Sprite The sprite to be checked.
function Editor.is_sprite_open(sprite)
	for _, sprite_ in ipairs(app.sprites) do
		if sprite == sprite_ then
			return true
		end
	end
	return false
end

--- Function to handle the "onclose" event of the Editor class.
--- Cleans up resources and closes sprites when the editor is closed.
--- @param event boolean True if the event is triggered by the user closing the dialog, false otherwise.
--- @param force? boolean True if the editor should be closed without asking the user to save changes, false otherwise.
--- @return boolean closed Whether the editor has been closed.
function Editor:close(event, force)
	if self.closed then
		return true
	end

	if self:is_modified() and not force then
		if event then
			local bounds = self.dialog.bounds
			self:new_dialog(self.title)
			self.dialog:show { wait = false, bounds = bounds }
		end

		for _, state_sprite in ipairs(self.open_sprites) do
			if state_sprite.sprite.isModified then
				if state_sprite:save_warning() == 0 then
					return false
				end
			end
		end

		if self.modified and self:save_warning() == 0 then
			return false
		end
	end

	self.closed = true
	self.dialog:close()

	for i, editor in ipairs(open_editors) do
		if editor == self then
			table.remove(open_editors, i)
			break
		end
	end

	if self.dmi then
		libdmi.remove_dir(self.dmi.temp, false)
	end

	for _, state_sprite in ipairs(self.open_sprites) do
		if state_sprite.sprite then
			state_sprite.sprite:close()
		end
	end
	
	-- Clean up spritesheet resources if needed
    if self.spritesheet_sprite then
        self.spritesheet_sprite:close()
        self.spritesheet_sprite = nil
    end

	app.events:off(self.beforecommand)
	app.events:off(self.aftercommand)

	self.mouse = nil
	self.focused_widget = nil
	self.dialog = nil
	self.widgets = nil
	self.dmi = nil
	self.open_sprites = nil
	self.beforecommand = nil
	self.aftercommand = nil

	return true
end

--- Displays a warning dialog asking the user to save changes to the sprite before closing.
--- @return 0|1|2 result 0 if the user cancels the operation, 1 if the user saves the file, 2 if the user doesn't save the file.
function Editor:save_warning()
	local result = 0

	local dialog = Dialog {
		title = "DMI Editor - Warning",
	}

	dialog:label {
		text = "Save changes to the DMI",
		focus = true
	}

	dialog:newrow()

	dialog:label {
		text = '"' .. app.fs.fileName(self:path()) .. '" before closing?',
	}

	dialog:canvas { height = 1 }

	dialog:button {
		text = "&Save",
		focus = true,
		onclick = function()
			if self:save() then
				result = 1
				dialog:close()
			end
		end
	}

	dialog:button {
		text = "Do&n't Save",
		onclick = function()
			result = 2
			dialog:close()
		end
	}

	dialog:button {
		text = "&Cancel",
		onclick = function()
			dialog:close()
		end
	}

	dialog:show()

	return result
end

-- Remove all debug printing in create_spritesheet
function Editor:create_spritesheet()
    if not self.dmi then return nil end
    
    -- Calculate total frames and grid size
    local total_frames = 0
    for _, state in ipairs(self.dmi.states) do
        total_frames = total_frames + (state.frame_count * state.dirs)
    end
    
    -- Calculate grid dimensions for a roughly square arrangement
    local grid_size = math.ceil(math.sqrt(total_frames))
    local width = grid_size * self.dmi.width
    local height = math.ceil(total_frames / grid_size) * self.dmi.height
    
    -- Create a new sprite with all states
    local sprite = Sprite(ImageSpec {
        width = width,
        height = height,
        colorMode = ColorMode.RGB
    })
    
    app.transaction("Create Spritesheet", function()
        -- First, rename the default layer
        if #sprite.layers > 0 then
            sprite.layers[1].name = "States"
        end
        
        -- If no layers exist, create the main layer
        local mainLayer = nil
        if #sprite.layers == 0 then
            mainLayer = sprite:newLayer()
            mainLayer.name = "States"
        else
            mainLayer = sprite.layers[1]
        end
        
        -- Create a single large image containing all cells properly positioned
        local compositeImage = Image(width, height, ColorMode.RGB)
        compositeImage:clear() -- Make sure it's transparent
        
        -- Create a grid layer for reference
        local grid_layer = sprite:newLayer()
        grid_layer.name = "Grid"
        grid_layer.opacity = 128
        
        -- Create a grid image
        local gridImage = Image(width, height, ColorMode.RGB)
        gridImage:clear() -- Make sure it's transparent
        
        -- Draw all states to the composite image
        local index = 0
        for _, state in ipairs(self.dmi.states) do
            for frame = 0, state.frame_count - 1 do
                for dir = 0, state.dirs - 1 do
                    local frame_index = frame * state.dirs + dir
                    local path = app.fs.joinPath(self.dmi.temp, state.frame_key .. "." .. frame_index .. ".bytes")
                    
                    -- Make sure the file exists
                    if not app.fs.isFile(path) then
                        goto continue
                    end
                    
                    local cellImage = load_image_bytes(path)
                    
                    -- Calculate position in grid
                    local col = index % grid_size
                    local row = math.floor(index / grid_size)
                    local x = col * self.dmi.width
                    local y = row * self.dmi.height
                    
                    -- Draw the cell image onto the composite image at the correct position
                    compositeImage:drawImage(cellImage, Point(x, y))
                    
                    -- Draw grid cell outline
                    for i = 0, self.dmi.width - 1 do
                        gridImage:putPixel(x + i, y, app.pixelColor.rgba(128, 128, 128, 128))
                        gridImage:putPixel(x + i, y + self.dmi.height - 1, app.pixelColor.rgba(128, 128, 128, 128))
                    end
                    for i = 0, self.dmi.height - 1 do
                        gridImage:putPixel(x, y + i, app.pixelColor.rgba(128, 128, 128, 128))
                        gridImage:putPixel(x + self.dmi.width - 1, y + i, app.pixelColor.rgba(128, 128, 128, 128))
                    end
                    
                    index = index + 1
                    ::continue::
                end
            end
        end
        
        -- Create a single cel with the composite image
        sprite:newCel(mainLayer, 1, compositeImage, Point(0, 0))
        
        -- Create a single cel with the grid image
        sprite:newCel(grid_layer, 1, gridImage, Point(0, 0))
    end)
    
    -- Save the sprite with metadata to indicate it's a DMI spritesheet
    sprite.data = sprite.data .. ";dmi_spritesheet=true;dmi_source=" .. self:path() .. ";grid_size=" .. grid_size
    
    -- Save the sprite to a temporary file so it can be reopened properly
    local temp_path = app.fs.joinPath(app.fs.tempPath, TEMP_NAME, "spritesheet_temp.ase")
    sprite:saveAs(temp_path)
    
    -- Ensure the display refreshes correctly
    if MDFunctions and MDFunctions.refreshDisplay then
        MDFunctions.refreshDisplay(sprite)
    end
    
    -- Set view to show the entire spritesheet
    app.command.Zoom { action = "fit" }
    
    return sprite
end

-- Update apply_spritesheet_changes to remove debug output
function Editor:apply_spritesheet_changes()
    if not self.dmi or not self.spritesheet_sprite then return end
    
    -- Get the cell dimensions from sprite data or use default
    local cellWidth = self.dmi.width
    local cellHeight = self.dmi.height
    
    -- Get grid size from metadata or calculate it
    local grid_size = nil
    if self.spritesheet_sprite.data and self.spritesheet_sprite.data:find("grid_size=") then
        local start = self.spritesheet_sprite.data:find("grid_size=") + 10
        local endPos = self.spritesheet_sprite.data:find(";", start) or self.spritesheet_sprite.data:len() + 1
        grid_size = tonumber(self.spritesheet_sprite.data:sub(start, endPos - 1))
    end
    
    if not grid_size then
        -- Calculate grid size
        local total_frames = 0
        for _, state in ipairs(self.dmi.states) do
            total_frames = total_frames + (state.frame_count * state.dirs)
        end
        grid_size = math.ceil(math.sqrt(total_frames))
    end
    
    -- Start a transaction to apply all changes at once
    app.transaction("Apply Spritesheet Changes", function()
        -- Find the "States" layer (the main content layer)
        local mainLayer = nil
        for _, l in ipairs(self.spritesheet_sprite.layers) do
            if l.isVisible and l.name == "States" then
                mainLayer = l
                break
            end
        end
        
        -- If we couldn't find the "States" layer, try the first visible layer that's not the grid
        if not mainLayer then
            for _, l in ipairs(self.spritesheet_sprite.layers) do
                if l.isVisible and l.name ~= "Grid" then
                    mainLayer = l
                    break
                end
            end
        end
        
        if not mainLayer then
            return
        end
        
        -- Get the full image from the spritesheet
        local fullImage = Image(self.spritesheet_sprite.width, self.spritesheet_sprite.height, ColorMode.RGB)
        fullImage:clear()
        
        -- Get the current frame of the sprite
        local frameNumber = app.activeFrame.frameNumber
        
        -- Draw the current frame of the spritesheet onto the full image
        for _, cel in ipairs(mainLayer.cels) do
            if cel.frameNumber == frameNumber then
                fullImage:drawImage(cel.image, cel.position)
                break -- Only need the first matching cel
            end
        end
        
        -- Process each state
        local index = 0
        for _, state in ipairs(self.dmi.states) do
            -- For each frame and direction of this state
            for frame = 0, state.frame_count - 1 do
                for dir = 0, state.dirs - 1 do
                    -- Calculate grid position
                    local col = index % grid_size
                    local row = math.floor(index / grid_size)
                    
                    -- Calculate pixel coordinates
                    local x = col * cellWidth
                    local y = row * cellHeight
                    
                    -- Make sure we're within the image bounds
                    if x >= fullImage.width or y >= fullImage.height then
                        goto continue
                    end
                    
                    -- Extract the cell image from the spritesheet
                    local cellImage = Image(cellWidth, cellHeight, ColorMode.RGB)
                    cellImage:clear()
                    
                    -- Copy the pixels from the main image
                    for py = 0, cellHeight - 1 do
                        for px = 0, cellWidth - 1 do
                            if x + px < fullImage.width and y + py < fullImage.height then
                                local color = fullImage:getPixel(x + px, y + py)
                                cellImage:putPixel(px, py, color)
                            end
                        end
                    end
                    
                    -- Save the updated cell image back to the temporary directory
                    local frameIndex = frame * state.dirs + dir
                    local path = app.fs.joinPath(self.dmi.temp, state.frame_key .. "." .. frameIndex .. ".bytes")
                    
                    -- Use error handling when saving the image
                    local success, err = pcall(function()
                        save_image_bytes(cellImage, path)
                    end)
                    
                    if success then
                        -- Update the preview image in the cache if this is the first frame/direction
                        if frame == 0 and dir == 0 then
                            self.image_cache:set(state.frame_key, cellImage)
                        end
                    end
                    
                    index = index + 1
                    ::continue::
                end
            end
        end
        
        -- Mark the DMI as modified
        self.modified = true
    end)
    
    -- Refresh the display
    self:repaint_states()
end
-- Opens the entire DMI file as a spritesheet for direct editing
function Editor:edit_spritesheet()
    if not self.dmi then return end
    
    -- Save any pending changes
    if self:is_modified() then
        local result = self:save_warning()
        if result == 0 then -- User canceled
            return
        end
    end
    
    -- Get the full path of the current DMI file
    local dmiPath = self:path()
    
    -- Important: Set the global flag before doing anything else
    -- This needs to be a global variable, not just a local in Editor
    _G.opening_dmi_noeditor = true
    
    -- Close the editor window without triggering save dialogs again
    self.closed = true
    self.dialog:close()
    
    for i, editor in ipairs(open_editors) do
        if editor == self then
            table.remove(open_editors, i)
            break
        end
    end
    
    -- Close any current file
    if app.sprite then
        app.command.CloseFile { ui = false }
    end
    
    -- Open the file directly using MDFunctions (if available) or the direct command
    local sprite = nil
    if MDFunctions and MDFunctions.openAsSpritesheet then
        sprite = MDFunctions.openAsSpritesheet(nil, dmiPath)
    end
    
    -- If MDFunctions failed, use the direct approach
    if not sprite then
        app.command.OpenFile { filename = dmiPath }
        sprite = app.sprite
    end
    
    -- Add metadata to the opened sprite
    if sprite then
        -- Set the data property if not already set
        if not sprite.data:find("dmi_spritesheet=true") then
            sprite.data = sprite.data .. ";dmi_spritesheet=true;dmi_source=" .. dmiPath
        end
        
        -- Make sure we see the entire spritesheet
        app.command.FitScreen()
        
        -- Display a helpful message
        app.alert {
            title = "DMI Spritesheet Mode",
            text = {
                "You are now editing the entire DMI as a spritesheet.",
                "When finished, use 'File > DMI Editor > Save Spritesheet as DMI'",
                "to preserve all state metadata."
            }
        }
    else
        app.alert("Failed to open the DMI file as a spritesheet")
    end
end
