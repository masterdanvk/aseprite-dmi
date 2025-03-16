local TEXT_HEIGHT = 0
local CONTEXT_BUTTON_HEIGHT = 0
local BOX_BORDER = 4
local BOX_PADDING = 5

--- Repaints the editor.
function Editor:repaint()
	self.dialog:repaint()
end

--- This function is called when the editor needs to repaint its contents.
--- @param ctx GraphicsContext The drawing context used to draw on the editor canvas.
function Editor:onpaint(ctx)
    if self.loading then
        local size = ctx:measureText("Loading file...")
        ctx.color = app.theme.color.text
        ctx:fillText("Loading file...", (ctx.width - size.width) / 2, (ctx.height - size.height) / 2)
        return
    end

    local min_width = self.dmi and (self.dmi.width + BOX_PADDING) or 1
    local min_height = self.dmi and (self.dmi.height + BOX_BORDER + BOX_PADDING * 2 + TEXT_HEIGHT) or 1

    self.canvas_width = math.max(ctx.width, min_width)
    self.canvas_height = math.max(ctx.height, min_height)

    if TEXT_HEIGHT == 0 then
        TEXT_HEIGHT = ctx:measureText("A").height
    end

    if CONTEXT_BUTTON_HEIGHT == 0 then
        CONTEXT_BUTTON_HEIGHT = TEXT_HEIGHT + BOX_PADDING * 2
    end

    local max_row = self.dmi and math.floor(self.canvas_width / min_width) or 1
    local max_column = self.dmi and math.floor(self.canvas_height / min_height) or 1

    if max_row ~= self.max_in_a_row or max_column ~= self.max_in_a_column then
        self.max_in_a_row = math.max(max_row, 1)
        self.max_in_a_column = math.max(max_column, 1)
        self:repaint_states()
        return
    end
    
    -- Check if we're in spritesheet mode and render accordingly
    if self.spritesheet_mode and self.spritesheet_sprite then
        self:render_spritesheet(ctx)
        return
    end
	

	local hovers = {} --[[ @as (string)[] ]]
	for _, widget in ipairs(self.widgets) do
		local state = COMMON_STATE.normal

		if widget == self.focused_widget then
			state = COMMON_STATE.focused or state
		end

		local is_mouse_over = not self.context_widget and widget.bounds:contains(self.mouse.position)

		if is_mouse_over then
			state = COMMON_STATE.hot or state

			if self.mouse.leftClick then
				state = COMMON_STATE.selected or state
			end
		end

		if widget.type == "IconWidget" then
			local widget = widget --[[ @as IconWidget ]]

			ctx:drawThemeRect(state.part, widget.bounds)
			ctx:drawImage(
				widget.icon,
				widget.icon.bounds,
				Rectangle(widget.bounds.x + (widget.bounds.width - self.dmi.width) / 2,
					widget.bounds.y + (widget.bounds.height - self.dmi.height) / 2, widget.icon.bounds.width,
					widget.icon.bounds.height)
			)
		elseif widget.type == "TextWidget" then
			local widget = widget --[[ @as TextWidget ]]

			local text = self.fit_text(widget.text, ctx, widget.bounds.width)
			local size = ctx:measureText(text)

			ctx.color = widget.text_color or app.theme.color[state.color]
			ctx:fillText(
				text,
				widget.bounds.x + (widget.bounds.width - size.width) / 2,
				widget.bounds.y + (widget.bounds.height - size.height) / 2
			)

			if is_mouse_over and widget.hover_text then
				table.insert(hovers, widget.hover_text)
			end
		elseif widget.type == "ThemeWidget" then
			local widget = widget --[[ @as ThemeWidget ]]

			ctx:drawThemeRect(state.part, widget.bounds)

			if widget.partId then
				ctx:drawThemeImage(widget.partId,
					Rectangle(widget.bounds.x, widget.bounds.y, widget.bounds.width, widget.bounds.height))
			end
		end
	end

	-- Add dragging overlay
	if self.dragging and self.drag_widget then
		local widget = self.drag_widget --[[ @as IconWidget ]]
		local drag_bounds = Rectangle(
			self.mouse.position.x - widget.bounds.width/2,
			self.mouse.position.y - widget.bounds.height/2,
			widget.bounds.width,
			widget.bounds.height
		)

		ctx.opacity = 128
		ctx:drawThemeRect(COMMON_STATE.hot.part, drag_bounds)
		ctx:drawImage(
			widget.icon,
			widget.icon.bounds,
			Rectangle(drag_bounds.x + (drag_bounds.width - self.dmi.width) / 2,
				drag_bounds.y + (drag_bounds.height - self.dmi.height) / 2,
				widget.icon.bounds.width,
				widget.icon.bounds.height)
		)
		ctx.opacity = 255

		-- Draw insert indicator
		if self.drop_index then
			local drop_bounds = self:box_bounds(self.drop_index)
			ctx:drawThemeRect("selected", Rectangle(drop_bounds.x - 2, drop_bounds.y - 2, 4, drop_bounds.height + 4))
		end
	end

	if self.context_widget then
		local widget = self.context_widget --[[ @as ContextWidget ]]

		if not widget.drawn then
			local width = 0
			local height = #widget.buttons * CONTEXT_BUTTON_HEIGHT

			for _, button in ipairs(widget.buttons) do
				local text_size = ctx:measureText(button.text)
				if text_size.width > width then
					width = text_size.width
				end
			end

			width = width + BOX_PADDING * 2

			local mouse_x = widget.bounds.x
			local mouse_y = widget.bounds.y

			local x = mouse_x + width >= ctx.width and mouse_x - width or mouse_x + 1
			local y = mouse_y - height >= 0 and mouse_y - height or mouse_y + 1

			local bounds = Rectangle(x, y, width, height)

			widget.bounds = bounds
			widget.drawn = true
		end

		ctx.color = app.theme.color.button_normal_text
		ctx:drawThemeRect("sunken_normal", widget.bounds)

		for i, button in ipairs(widget.buttons) do
			local button_bounds = Rectangle(widget.bounds.x, widget.bounds.y + (i - 1) * CONTEXT_BUTTON_HEIGHT,
				widget.bounds.width,
				CONTEXT_BUTTON_HEIGHT)
			local contains_mouse = button_bounds:contains(self.mouse.position)

			ctx.color = app.theme.color.button_normal_text
			if contains_mouse then
				ctx.color = app.theme.color.button_hot_text
				ctx:drawThemeRect(
					contains_mouse and "sunken_focused" or "sunken_normal", button_bounds)
			end
			ctx:fillText(button.text, button_bounds.x + BOX_PADDING, button_bounds.y + BOX_PADDING)
		end

		return
	end

	for _, text in ipairs(hovers) do
		local text_size = ctx:measureText(text)
		local size = Size(text_size.width + BOX_PADDING * 2, text_size.height + BOX_PADDING * 2)

		local x = self.mouse.position.x - size.width / 2

		if x < 0 then
			x = 0
		elseif x + size.width > ctx.width then
			x = ctx.width - size.width
		end

		ctx.color = app.theme.color.button_normal_text
		ctx:drawThemeRect("sunken_normal", Rectangle(x, self.mouse.position.y - size.height, size.width, size.height))
		ctx:fillText(text, x + BOX_PADDING, self.mouse.position.y - (text_size.height + size.height) / 2)
	end
end

function Editor:render_spritesheet(ctx)
    if not self.dmi then return end
    
    -- Draw a preview of the spritesheet and a message with instructions
    ctx.color = app.theme.color.text
    
    -- Draw title
    local title = "Spritesheet View"
    local title_size = ctx:measureText(title)
    ctx:fillText(title, (ctx.width - title_size.width) / 2, 10)
    
    -- Draw instructions
    local instructions = "Click 'Edit Spritesheet' to open for editing"
    local instr_size = ctx:measureText(instructions)
    ctx:fillText(instructions, (ctx.width - instr_size.width) / 2, 30)
    
    -- Add an edit button
    local edit_button_width = 120
    local edit_button_height = 30
    local edit_button_x = (ctx.width - edit_button_width) / 2
    local edit_button_y = 50
    
    local edit_button_bounds = Rectangle(edit_button_x, edit_button_y, edit_button_width, edit_button_height)
    
    -- Create button widgets if they don't exist
    local found = false
    for _, widget in ipairs(self.widgets) do
        if widget.type == "ThemeWidget" and widget.bounds and widget.bounds.x == edit_button_x then
            found = true
            break
        end
    end
    
    if not found then
        -- Add button background
        table.insert(self.widgets, ThemeWidget.new(
            self,
            edit_button_bounds,
            "button_normal",
            function() self:edit_spritesheet() end
        ))
        
        -- Add button text
        table.insert(self.widgets, TextWidget.new(
            self,
            Rectangle(edit_button_x, edit_button_y + 5, edit_button_width, 20),
            "Edit Spritesheet",
            nil,
            nil,
            function() self:edit_spritesheet() end
        ))
    end
    
    -- Calculate the number of cells in the spritesheet
    local total_frames = 0
    for _, state in ipairs(self.dmi.states) do
        total_frames = total_frames + (state.frame_count * state.dirs)
    end
    
    -- Calculate grid dimensions
    local grid_size = math.ceil(math.sqrt(total_frames))
    local actual_width = grid_size * self.dmi.width
    local actual_height = math.ceil(total_frames / grid_size) * self.dmi.height
    
    -- Draw a thumbnail of the spritesheet
    local max_thumbnail_width = math.min(ctx.width - 20, 300)
    local max_thumbnail_height = ctx.height - 120
    
    -- Calculate scale to fit the thumbnail within the available space
    local scale_width = max_thumbnail_width / actual_width
    local scale_height = max_thumbnail_height / actual_height
    local scale = math.min(scale_width, scale_height)
    
    -- Calculate thumbnail dimensions with the appropriate scale
    local thumbnail_width = actual_width * scale
    local thumbnail_height = actual_height * scale
    
    local thumbnail_x = (ctx.width - thumbnail_width) / 2
    local thumbnail_y = 90
    
    -- Draw a border for the thumbnail
    ctx.color = app.theme.color.button_normal_text
    ctx:strokeRect(Rectangle(thumbnail_x - 2, thumbnail_y - 2, thumbnail_width + 4, thumbnail_height + 4))
    
    -- Draw a simple grid to represent the spritesheet
    local cellWidth = self.dmi.width * scale
    local cellHeight = self.dmi.height * scale
    
    -- Draw a checkerboard pattern for the thumbnail background
    ctx.color = app.theme.color.grid
    
    -- Draw horizontal grid lines
    for y = 0, math.ceil(thumbnail_height / cellHeight) do
        local y_pos = thumbnail_y + y * cellHeight
        if y_pos < thumbnail_y + thumbnail_height then
            ctx:strokeRect(Rectangle(thumbnail_x, y_pos, thumbnail_width, 1))
        end
    end
    
    -- Draw vertical grid lines
    for x = 0, math.ceil(thumbnail_width / cellWidth) do
        local x_pos = thumbnail_x + x * cellWidth
        if x_pos < thumbnail_x + thumbnail_width then
            ctx:strokeRect(Rectangle(x_pos, thumbnail_y, 1, thumbnail_height))
        end
    end
    
    -- Draw some sample cells to indicate content
    -- (this provides a visual even if we can't load the actual content)
    ctx.color = app.theme.color.button_normal_text
    local sampleCount = math.min(10, total_frames)
    for i = 1, sampleCount do
        -- Calculate position
        local col = (i-1) % grid_size
        local row = math.floor((i-1) / grid_size)
        local x = thumbnail_x + col * cellWidth
        local y = thumbnail_y + row * cellHeight
        
        -- Draw a simple icon representation (a face)
        local centerX = x + cellWidth/2
        local centerY = y + cellHeight/2
        local radius = math.min(cellWidth, cellHeight) * 0.3
        
        -- Draw circle for head
        ctx:strokeRect(Rectangle(centerX - radius, centerY - radius, radius*2, radius*2))
        
        -- Draw eyes
        local eyeRadius = radius * 0.2
        ctx:strokeRect(Rectangle(centerX - radius*0.5 - eyeRadius, centerY - radius*0.3 - eyeRadius, eyeRadius*2, eyeRadius*2))
        ctx:strokeRect(Rectangle(centerX + radius*0.5 - eyeRadius, centerY - radius*0.3 - eyeRadius, eyeRadius*2, eyeRadius*2))
        
        -- Draw smile
        local smileWidth = radius * 1.2
        ctx:strokeRect(Rectangle(centerX - smileWidth/2, centerY + radius*0.3, smileWidth, 1))
    end
    
    -- Draw metadata info
    local info_y = thumbnail_y + thumbnail_height + 10
    
    ctx.color = app.theme.color.text
    ctx:fillText("States: " .. #self.dmi.states, thumbnail_x, info_y)
    ctx:fillText("Total frames: " .. total_frames, thumbnail_x, info_y + 20)
    ctx:fillText("Size: " .. self.dmi.width .. "x" .. self.dmi.height .. " px", thumbnail_x, info_y + 40)
    ctx:fillText("Spritesheet dimensions: " .. actual_width .. "x" .. actual_height .. " px", thumbnail_x, info_y + 60)
end

--- Repaints the states in the editor.
--- Creates state widgets for each state in the DMI file and positions them accordingly.
--- Only creates state widgets for states that are currently visible based on the scroll position.
--- Calls the repaint function to update the editor display.
function Editor:repaint_states()
    self.widgets = {}
    local duplicates = {}
    local min_index = (self.max_in_a_row * self.scroll)
    local max_index = min_index + self.max_in_a_row * (self.max_in_a_column + 1)
    
    for index, state in ipairs(self.dmi.states) do
        if index > min_index and index <= max_index then
            local bounds = self:box_bounds(index)
            local text_color = nil

            if not (#state.name > 0) then
                text_color = Color { red = 230, green = 223, blue = 69, alpha = 255 }
            end

            if duplicates[state.name] then
                text_color = Color { red = 230, green = 69, blue = 69, alpha = 255 }
            else
                for _, state_ in ipairs(self.dmi.states) do
                    if state.name == state_.name then
                        duplicates[state.name] = true
                        break
                    end
                end
            end

            local name = #state.name > 0 and state.name or "no name"

            -- Create a fallback icon in case image loading fails
            local fallback_icon = Image(self.dmi.width, self.dmi.height)
            fallback_icon:clear()
            
            -- Draw a border on the fallback icon
            for x = 0, self.dmi.width-1 do
                for y = 0, self.dmi.height-1 do
                    if (x == 0 or x == self.dmi.width-1 or y == 0 or y == self.dmi.height-1) then
                        fallback_icon:putPixel(x, y, app.pixelColor.rgba(128, 128, 128, 255))
                    end
                end
            end
            
            -- Try to load the actual icon
            local icon = fallback_icon
            
            if self.image_cache then
                local cached_image = self.image_cache:get(state.frame_key)
                if cached_image and cached_image.width > 0 and cached_image.height > 0 then
                    -- Try to create the actual icon, with error handling
                    local success, result = pcall(function()
                        local bytes = string.char(libdmi.overlay_color(
                            app.theme.color.face.red, 
                            app.theme.color.face.green,
                            app.theme.color.face.blue, 
                            cached_image.width, 
                            cached_image.height, 
                            string.byte(cached_image.bytes, 1, #cached_image.bytes)
                        ))
                        local real_icon = Image(cached_image.width, cached_image.height)
                        real_icon.bytes = bytes
                        return real_icon
                    end)
                    
                    if success then
                        icon = result
                    end
                end
            end

            table.insert(self.widgets, IconWidget.new(
                self,
                bounds,
                icon,
                function() self:open_state(state) end,
                function(ev) self:state_context(state, ev) end
            ))

            table.insert(self.widgets, TextWidget.new(
                self,
                Rectangle(
                    bounds.x,
                    bounds.y + bounds.height + BOX_PADDING,
                    bounds.width,
                    TEXT_HEIGHT
                ),
                name,
                text_color,
                name,
                function() self:state_properties(state) end,
                function(ev) self:state_context(state, ev) end
            ))
        end
    end

    if #self.dmi.states < max_index then
        local index = #self.dmi.states + 1
        local bounds = self:box_bounds(index)

        table.insert(self.widgets, ThemeWidget.new(
            self,
            bounds,
            nil,
            function() self:new_state() end
        ))

        table.insert(self.widgets, TextWidget.new(
            self,
            Rectangle(
                bounds.x,
                bounds.y + bounds.height / 2 - 3,
                bounds.width,
                TEXT_HEIGHT
            ),
            "+"
        ))
    end

    self:repaint()
end

function Editor:box_bounds(index)
	local row_index = index - self.max_in_a_row * self.scroll

	return Rectangle(
		(self.dmi.width + BOX_PADDING) * ((row_index - 1) % self.max_in_a_row),
		(self.dmi.height + BOX_BORDER + BOX_PADDING * 2 + TEXT_HEIGHT) * math.floor((row_index - 1) / self.max_in_a_row) +
		BOX_PADDING,
		self.dmi.width + BOX_BORDER,
		self.dmi.height + BOX_BORDER
	)
end

--- Handles the mouse down event in the editor and triggers a repaint.
--- @param ev MouseEvent The mouse event object.
function Editor:onmousedown(ev)
	if ev.button == MouseButton.LEFT then
		self.mouse.leftClick = true
		self.focused_widget = nil

		-- Only start drag if we're not clicking on a context menu
		if not self.context_widget then
			-- Start potential drag
			for _, widget in ipairs(self.widgets) do
				if widget.type == "IconWidget" and widget.bounds:contains(Point(ev.x, ev.y)) then
					self.drag_widget = widget
					self.drag_start_time = os.clock()
					break
				end
			end
		end
	elseif ev.button == MouseButton.RIGHT then
		self.mouse.rightClick = true
		self.focused_widget = nil
		self.context_widget = nil
	end
	self:repaint()
end

--- Handles the mouse up event in the editor and triggers a repaint.
--- @param ev MouseEvent The mouse event object.
function Editor:onmouseup(ev)
	local repaint = true
	if ev.button == MouseButton.LEFT or ev.button == MouseButton.RIGHT then
		if self.context_widget then
			for i, button in ipairs(self.context_widget.buttons) do
				local button_bounds = Rectangle(self.context_widget.bounds.x,
					self.context_widget.bounds.y + (i - 1) * CONTEXT_BUTTON_HEIGHT,
					self.context_widget.bounds.width, CONTEXT_BUTTON_HEIGHT)
				if button_bounds:contains(self.mouse.position) then
					self.context_widget = nil
					repaint = false
					self:repaint()
					button.onclick()
					break
				end
			end
			self.context_widget = nil
		else
			local triggered = false
			for _, widget in ipairs(self.widgets) do
				local is_mouse_over = widget.bounds:contains(self.mouse.position)
				if is_mouse_over then
					if ev.button == MouseButton.LEFT and widget.onleftclick then
						triggered = true
						widget.onleftclick(ev)
					elseif ev.button == MouseButton.RIGHT and widget.onrightclick then
						triggered = true
						widget.onrightclick(ev)
					end
					self.focused_widget = widget
				end
			end
			if not triggered then
				if ev.button == MouseButton.RIGHT then
					self.context_widget = ContextWidget.new(
						Rectangle(ev.x, ev.y, 0, 0),
						{
							{ text = "Paste", onclick = function() self:clipboard_paste_state() end },
						}
					)
				end
			end
		end
		if ev.button == MouseButton.LEFT then
			if self.dragging and self.drag_widget and self.drop_index then
				-- Find source state index using widget index and scroll offset
				local source_index = nil
				local min_index = self.max_in_a_row * self.scroll

				for i, widget in ipairs(self.widgets) do
					if widget == self.drag_widget then
						-- Calculate actual state index from widget position
						local widget_pos = math.floor((i - 1) / 2) + 1  -- Account for text widgets
						source_index = widget_pos + min_index
						break
					end
				end

				-- Ensure we don't drop past the last valid position
				local target_index = math.min(self.drop_index or #self.dmi.states, #self.dmi.states)

				if source_index and source_index <= #self.dmi.states then
					-- Only move if target is different and valid
					if source_index ~= target_index then
						local state = table.remove(self.dmi.states, source_index)
						table.insert(self.dmi.states, target_index, state)

						-- Calculate new scroll position to keep the moved item visible
						local target_row = math.floor((target_index - 1) / self.max_in_a_row)
						local visible_rows = self.max_in_a_column

						-- Adjust scroll to ensure target row is visible
						if target_row < self.scroll then
							self.scroll = target_row
						elseif target_row >= self.scroll + visible_rows then
							self.scroll = target_row - visible_rows + 1
						end

						self:repaint_states()
					end
				end
			elseif self.drag_widget and not self.dragging then
				-- Handle as normal click
				if self.drag_widget.onleftclick then
					self.drag_widget.onleftclick(ev)
				end
			end

			-- Reset drag state
			self.dragging = false
			self.drag_widget = nil
			self.drag_start_time = nil
			self.drop_index = nil
			self.mouse.leftClick = false
		elseif ev.button == MouseButton.RIGHT then
			self.mouse.rightClick = false
		end
	end
	if repaint then
		self:repaint()
	end
end

--- Updates the mouse position and triggers a repaint.
--- @param ev table The mouse event containing the x and y coordinates.
function Editor:onmousemove(ev)
	local mouse_position = Point(ev.x, ev.y)
	local should_repaint = false
	local hovering_widgets = {} --[[@type AnyWidget[] ]]

	-- Always repaint if dragging to ensure smooth preview updates
	if self.dragging then
		should_repaint = true
	end

	for _, widget in ipairs(self.widgets) do
		if widget.bounds:contains(mouse_position) then
			table.insert(hovering_widgets, widget)
		end
	end

	-- Handle dragging
	if self.mouse.leftClick and self.drag_widget and not self.dragging then
		-- Start drag after small delay/movement
		if os.clock() - self.drag_start_time > 0.1 then
			self.dragging = true
			should_repaint = true
		end
	end

	if self.dragging then
		-- Find potential drop location
		local closest_index = nil
		local closest_dist = math.huge

		-- Limit to valid positions (not beyond the last state + 1)
		for i = 1, #self.dmi.states + 1 do
			local bounds = self:box_bounds(i)
			local center = Point(bounds.x + bounds.width/2, bounds.y + bounds.height/2)
			local dist = math.abs(mouse_position.x - center.x) + math.abs(mouse_position.y - center.y)

			if dist < closest_dist then
				closest_dist = dist
				closest_index = i
			end
		end

		if self.drop_index ~= closest_index then
			self.drop_index = closest_index
		end
	end

	if self.context_widget then
		local focus = 0
		for i, _ in ipairs(self.context_widget.buttons) do
			local button_bounds = Rectangle(self.context_widget.bounds.x,
				self.context_widget.bounds.y + (i - 1) * CONTEXT_BUTTON_HEIGHT,
				self.context_widget.bounds.width, CONTEXT_BUTTON_HEIGHT)
			if button_bounds:contains(mouse_position) then
				focus = i
				break
			end
		end
		if self.context_widget.focus ~= focus then
			self.context_widget.focus = focus
			should_repaint = true
		end
	end

	if not should_repaint then
		for _, widget in ipairs(self.hovering_widgets) do
			if table.index_of(hovering_widgets, widget) == 0 or widget.hover_text then
				should_repaint = true
				break
			end
		end
	end

	if not should_repaint then
		for _, widget in ipairs(hovering_widgets) do
			if table.index_of(self.hovering_widgets, widget) == 0 or widget.hover_text then
				should_repaint = true
				break
			end
		end
	end

	self.mouse.position = mouse_position
	self.hovering_widgets = hovering_widgets

	if should_repaint then
		self:repaint()
	end
end

--- Handles the mouse wheel event for scrolling through DMI states.
--- @param ev table The mouse wheel event object.
function Editor:onwheel(ev)
	if not self.dmi then return end

	local overflow = (#self.dmi.states + 1) - self.max_in_a_row * self.max_in_a_column

	if overflow <= 0 then return end

	local last_digit = overflow % self.max_in_a_row
	local rounded = overflow - last_digit

	if last_digit > 0 then
		rounded = rounded + self.max_in_a_row
	end

	local max_scroll = math.floor(rounded / self.max_in_a_row)
	local new_scroll = math.min(math.max(self.scroll + (ev.deltaY > 0 and 1 or -1), 0), max_scroll)

	if new_scroll ~= self.scroll then
		self.scroll = new_scroll
		self:repaint_states()
	end
end

--- Fits the given text within the specified maximum width by truncating it with ellipsis if necessary.
--- @param text string The text to fit.
--- @param ctx GraphicsContext The context object used for measuring the text width.
--- @param maxWidth number The maximum width allowed for the text.
--- @return string text The fitted text.
function Editor.fit_text(text, ctx, maxWidth)
	local width = ctx:measureText(text).width
	while width >= maxWidth do
		if text:ends_with("...") then
			text = text:sub(1, text:len() - 4) .. "..."
		else
			text = text:sub(1, text:len() - 1) .. "..."
		end
		width = ctx:measureText(text).width
	end
	return text
end