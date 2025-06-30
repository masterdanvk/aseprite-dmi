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
            self.spritesheet_sprite:close()
            self.spritesheet_sprite = nil
        end
    else
        -- Going from state mode to spritesheet mode
        self:gc_open_sprites() -- Clean up list before checking
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
        -- Return to state mode
        self:exit_spritesheet_mode()
    end

    -- Update the button text
    self.dialog:modify {
        id = "toggle_view",
        text = self.spritesheet_mode and "View States" or "View Spritesheet"
    }

    -- Update the view
    self:repaint()
end

--- Enter spritesheet editing mode
function Editor:enter_spritesheet_mode()
    if not self.dmi then return end

    -- Create a spritesheet sprite from all the states
    self.spritesheet_sprite = self:create_spritesheet()
    self:repaint()
end

--- Exit spritesheet editing mode and return to state view
function Editor:exit_spritesheet_mode()
    if self.spritesheet_sprite and self.is_sprite_open(self.spritesheet_sprite) then
        self.spritesheet_sprite:close()
    end
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

	self:gc_open_sprites()
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
		local dmi_data, error = libdmi.open_file(self.open_path, TEMP_DIR)
		if not error then
			self.dmi = dmi_data --[[@as Dmi]]
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
function Editor:save(no_dialog)
	if not self.dmi then return false end

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
function Editor:path()
	return self.save_path or self.open_path or app.fs.joinPath(app.fs.userDocsPath, "untitled.dmi")
end

--- @type string|nil
local save_file_as = nil

--- This function is called before executing a command in the Aseprite editor.
function Editor:onbeforecommand(ev)
	if ev.name == "SaveFile" then
		self:gc_open_sprites()
		for _, state_sprite in ipairs(self.open_sprites) do
			if app.sprite == state_sprite.sprite then

                -- ***** START FIX: Cache and release selection *****
                local cached_selection = nil
                if app.range and not app.range.isEmpty then
                    cached_selection = app.range
                    app.command.DeselectMask()
                end
                -- ***** END FIX *****

				if not state_sprite:save() then
					ev.stopPropagation()
				end

                -- ***** START FIX: Restore selection *****
                if cached_selection then
                    app.range = cached_selection
                end
                -- ***** END FIX *****

				if Preferences.getAutoOverwrite and Preferences.getAutoOverwrite() then
					self:save(true)
				end
				break
			end
		end
	elseif ev.name == "SaveFileAs" then
        self:gc_open_sprites()
		for _, state_sprite in ipairs(self.open_sprites) do
			if app.sprite == state_sprite.sprite then
				if save_file_as == nil then
					save_file_as = app.sprite.filename
				end
			end
		end
	end
end

--- Callback function called after a Aseprite command is executed.
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
        -- Ensure sprite is not nil before checking if it's open
		if state_sprite.sprite and self.is_sprite_open(state_sprite.sprite) then
			table.insert(open_sprites, state_sprite)
		end
	end
	self.open_sprites = open_sprites
end

--- Switches the tab to the sprite containing the state.
function Editor.switch_tab(sprite)
	local tries = 0
	local max_tries = #app.sprites + 1
	while app.sprite ~= sprite and tries <= max_tries do
		tries = tries + 1
		app.command.GotoNextTab()
	end
end

--- Checks if the DMI file has been modified.
function Editor:is_modified()
    self:gc_open_sprites() -- Clean up stale sprite references before checking them.

	if self.modified then return true end

	for _, state_sprite in ipairs(self.open_sprites) do
		if state_sprite.sprite.isModified then
			return true
		end
	end

    if self.spritesheet_mode and self.spritesheet_sprite and self.is_sprite_open(self.spritesheet_sprite) and self.spritesheet_sprite.isModified then
        return true
    end

	return false
end

--- Checks if the sprite is open in the Aseprite editor.
function Editor.is_sprite_open(sprite)
    if not sprite then return false end
	for _, sprite_ in ipairs(app.sprites) do
		if sprite == sprite_ then
			return true
		end
	end
	return false
end

--- Function to handle the "onclose" event of the Editor class.
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

        self:gc_open_sprites()
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
	if self.dialog then self.dialog:close() end

	for i, editor in ipairs(open_editors) do
		if editor == self then
			table.remove(open_editors, i)
			break
		end
	end

	if self.dmi then
		libdmi.remove_dir(self.dmi.temp, false)
	end

    self:gc_open_sprites()
	for _, state_sprite in ipairs(self.open_sprites) do
		if state_sprite.sprite then
			state_sprite.sprite:close()
		end
	end

    if self.spritesheet_sprite and self.is_sprite_open(self.spritesheet_sprite) then
        self.spritesheet_sprite:close()
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

function Editor:create_spritesheet()
    if not self.dmi then return nil end

    local total_frames = 0
    for _, state in ipairs(self.dmi.states) do
        total_frames = total_frames + (state.frame_count * state.dirs)
    end

    if total_frames == 0 then
        return Sprite(self.dmi.width, self.dmi.height, ColorMode.RGB)
    end

    local grid_size = math.ceil(math.sqrt(total_frames))
    local width = grid_size * self.dmi.width
    local height = math.ceil(total_frames / grid_size) * self.dmi.height

    local sprite = Sprite(ImageSpec {
        width = width,
        height = height,
        colorMode = ColorMode.RGB
    })

    app.transaction("Create Spritesheet", function()
        local mainLayer = sprite.layers[1] or sprite:newLayer()
        mainLayer.name = "States"

        local compositeImage = Image(width, height, ColorMode.RGB)
        compositeImage:clear()

        local index = 0
        for _, state in ipairs(self.dmi.states) do
            for frame = 0, state.frame_count - 1 do
                for dir = 0, state.dirs - 1 do
                    local frame_index = frame * state.dirs + dir
                    local path = app.fs.joinPath(self.dmi.temp, state.frame_key .. "." .. frame_index .. ".bytes")

                    if app.fs.isFile(path) then
                        local cellImage = load_image_bytes(path)
                        local col = index % grid_size
                        local row = math.floor(index / grid_size)
                        local x = col * self.dmi.width
                        local y = row * self.dmi.height
                        compositeImage:drawImage(cellImage, Point(x, y))
                    end

                    index = index + 1
                end
            end
        end

        sprite:newCel(mainLayer, 1, compositeImage, Point(0, 0))
    end)

    sprite.data = sprite.data .. ";dmi_spritesheet=true;dmi_source=" .. self:path() .. ";grid_size=" .. grid_size

    local temp_path = app.fs.joinPath(app.fs.tempPath, TEMP_NAME, "spritesheet_temp.ase")
    sprite:saveAs(temp_path)

    if MDFunctions and MDFunctions.refreshDisplay then
        MDFunctions.refreshDisplay(sprite)
    end

    app.command.FitScreen()

    return sprite
end

function Editor:apply_spritesheet_changes()
    if not self.dmi or not self.spritesheet_sprite or not self.is_sprite_open(self.spritesheet_sprite) then return end

    local cellWidth = self.dmi.width
    local cellHeight = self.dmi.height
    local grid_size

    if self.spritesheet_sprite.data and self.spritesheet_sprite.data:find("grid_size=") then
        local start_pos = self.spritesheet_sprite.data:find("grid_size=") + 10
        local end_pos = self.spritesheet_sprite.data:find(";", start_pos) or -1
        grid_size = tonumber(self.spritesheet_sprite.data:sub(start_pos, end_pos))
    end

    if not grid_size then
        local total_frames = 0
        for _, state in ipairs(self.dmi.states) do
            total_frames = total_frames + (state.frame_count * state.dirs)
        end
        grid_size = math.ceil(math.sqrt(total_frames))
    end

    app.transaction("Apply Spritesheet Changes", function()
        local mainLayer
        for _, l in ipairs(self.spritesheet_sprite.layers) do
            if l.isVisible and (l.name == "States" or l.name == "Layer 1") then
                mainLayer = l
                break
            end
        end
        if not mainLayer then return end

        local cel = mainLayer:cel(app.activeFrame)
        if not cel then return end
        local fullImage = cel.image

        local index = 0
        for _, state in ipairs(self.dmi.states) do
            for frame = 0, state.frame_count - 1 do
                for dir = 0, state.dirs - 1 do
                    local col = index % grid_size
                    local row = math.floor(index / grid_size)
                    local x = col * cellWidth
                    local y = row * cellHeight

                    if x < fullImage.width and y < fullImage.height then
                        local cellImage = Image(cellWidth, cellHeight, fullImage.colorMode)
                        cellImage:drawImage(fullImage, Point(0,0), Rectangle(x, y, cellWidth, cellHeight))
                        
                        local frameIndex = frame * state.dirs + dir
                        local path = app.fs.joinPath(self.dmi.temp, state.frame_key .. "." .. frameIndex .. ".bytes")
                        save_image_bytes(cellImage, path)

                        if frame == 0 and dir == 0 then
                            self.image_cache:set(state.frame_key, cellImage)
                        end
                    end
                    index = index + 1
                end
            end
        end
        self.modified = true
    end)
    self:repaint_states()
end

function Editor:edit_spritesheet()
    if not self.dmi then return end

    if self:is_modified() then
        local result = self:save_warning()
        if result == 0 then return end
    end

    local dmiPath = self:path()
    _G.opening_dmi_noeditor = true

    self:close(false, true) -- Force close the editor UI

    app.command.OpenFile { filename = dmiPath }
    local sprite = app.sprite

    if sprite then
        if not sprite.data:find("dmi_spritesheet=true") then
            sprite.data = (sprite.data or "") .. ";dmi_spritesheet=true;dmi_source=" .. dmiPath
        end

        for i = #sprite.layers, 1, -1 do
            if sprite.layers[i].name == "Grid" then
                sprite:deleteLayer(sprite.layers[i])
            end
        end

        app.command.FitScreen()
        app.alert {
            title = "DMI Spritesheet Mode",
            text = {
                "You are now editing the entire DMI as a spritesheet.",
                "When finished, use 'File > DMI Editor > Save Spritesheet as DMI'",
                "to preserve all state metadata."
            }
        }
    else
        app.alert("Failed to open the DMI file as a spritesheet.")
    end
end