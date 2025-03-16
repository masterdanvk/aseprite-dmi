--- Creates a new DMI file with the specified width and height.
--- Uses native new file dialog to get the dimensions.
--- If the file creation is successful, opens the DMI Editor with the newly created file.
--- @param plugin_path string Path where the extension is installed.
function Editor.new_file(plugin_path)
	local previous_sprite = app.sprite
	if app.command.NewFile { width = 32, height = 32 } then
		if previous_sprite ~= app.sprite then
			local width = app.sprite.width
			local height = app.sprite.height

			app.command.CloseFile { ui = false }

			if width < 3 or height < 3 then
				app.alert { title = "Warning", text = "Width and height must be at least 3 pixels", buttons = { "&OK" } }
				return
			end

			loadlib(plugin_path)

			local dmi, error = libdmi.new_file("untitled", width, height, TEMP_DIR)
			if not error then
				Editor.new(DIALOG_NAME, dmi --[[@as Dmi]])
			else
				app.alert { title = "Error", text = { "Failed to create new file", error } }
			end
		end
	end
end

--- Opens a state in the Aseprite editor by creating a new sprite and populating it with frames and layers based on the provided state.
---@param state State The state to be opened.
function Editor:open_state(state)
	for _, sprite in ipairs(app.sprites) do
		if sprite.filename == app.fs.joinPath(self.dmi.temp, state.frame_key .. ".ase") then
			self.switch_tab(sprite)
			return
		end
	end

	local preview_image = self.image_cache:get(state.frame_key)
	local transparentColor = transparent_color(preview_image)

	local sprite = Sprite(ImageSpec {
		width = self.dmi.width,
		height = self.dmi.height,
		colorMode = ColorMode.RGB,
		transparentColor = app.pixelColor.rgba(transparentColor.red, transparentColor.green, transparentColor.blue, transparentColor.alpha)
	})

	app.transaction("Load State", function()
		while #sprite.layers < state.dirs do
			local layer = sprite:newLayer()
			layer.isVisible = false
		end

		if state.frame_count > 1 then
			sprite:newFrame(state.frame_count - 1)
		end

		if #state.delays > 1 then
			for index, frame in ipairs(sprite.frames) do
				frame.duration = (state.delays[index] or 1) / 10
			end
		end

		sprite.layers[1].isVisible = false
		sprite.layers[#sprite.layers].isVisible = true

		local index = 1
		for frame = 1, #sprite.frames, 1 do
			for layer = #sprite.layers, 1, -1 do
				sprite.layers[layer].name = DIRECTION_NAMES[#sprite.layers - layer + 1]
				sprite:newCel(
					sprite.layers[layer],
					sprite.frames[frame],
					index == 1 and self.image_cache:get(state.frame_key) or
					load_image_bytes(app.fs.joinPath(self.dmi.temp, state.frame_key .. "." .. math.floor(index - 1) .. ".bytes")),
					Point(0, 0)
				)
				index = index + 1
			end
		end

		app.frame = 1

		local is_empty = true
		for _, cel in ipairs(sprite.cels) do
			if not cel.image:isEmpty() then
				is_empty = false
				app.command.ColorQuantization { ui = false, withAlpha = false }

				local palette = sprite.palettes[1]
				if palette:getColor(0).alpha == 0 then
					if #palette > 1 then
						local colors = {}
						for i = 1, #palette - 1, 1 do
							local color = palette:getColor(i)
							table.insert(colors, color)
						end
						local new_palette = Palette(#colors)
						for i, color in ipairs(colors) do
							new_palette:setColor(i - 1, color)
						end
						sprite:setPalette(new_palette)
					else
						app.command.LoadPalette { ui = false, preset = "default" }
					end
				end
				break
			end
		end

		if is_empty then
			app.command.LoadPalette { ui = false, preset = "default" }
		end
	end)

	sprite:saveAs(app.fs.joinPath(self.dmi.temp, state.frame_key .. ".ase"))
	app.command.FitScreen()

	self:gc_open_sprites()
	table.insert(self.open_sprites, StateSprite.new(self, self.dmi, state, sprite, transparentColor))
end

--- Opens a context menu for a state.
--- @param state State The state to be opened.
--- @param ev MouseEvent The mouse event object.
function Editor:state_context(state, ev)
	self.context_widget = ContextWidget.new(
		Rectangle(ev.x, ev.y, 0, 0),
		{
			{ text = "Properties", onclick = function() self:state_properties(state) end },
			{ text = "Open",       onclick = function() self:open_state(state) end },
			{ text = "Copy",       onclick = function() self:clipboard_copy_state(state) end },
			{ text = "Remove",     onclick = function() self:remove_state(state) end },
			{ text = "Split",      onclick = function() self:split_state(state) end },
		}
	)
	self:repaint()
end

--- Displays a dialog for editing the properties of a state.
--- @param state State The state object to edit.
function Editor:state_properties(state)
	local dialog = Dialog {
		title = "State Properties"
	}

	dialog:entry {
		id = "state_name",
		label = "State name:",
		text = state.name,
		focus = true,
	}

	local open = false
	for _, state_sprite_ in ipairs(self.open_sprites) do
		if state_sprite_.state == state then
			open = true
			break
		end
	end

	if open then
		dialog:combobox {
			id = "state_directions",
			label = "Directions:",
			option = tostring(math.floor(state.dirs)),
			options = { "1", "4", "8", },
		}
	else
		local direction = tostring(math.floor(state.dirs))
		dialog:combobox {
			id = "state_directions",
			label = "Directions:",
			option = direction,
			options = { direction, "--OPEN-STATE--" },
		}
	end

	dialog:number {
		id = "state_loop",
		label = "Loop:",
		text = tostring(math.floor(state.loop)),
		decimals = 0,
	}

	dialog:check {
		id = "state_movement",
		label = "Movement state:",
		selected = state.movement,
	}

	dialog:check {
		id = "state_rewind",
		label = "Rewind:",
		selected = state.rewind,
	}

	dialog:button {
		text = "&OK",
		focus = true,
		onclick = function()
			local state_name = dialog.data.state_name
			if #state_name > 0 and state.name ~= state_name then
				state.name = dialog.data.state_name
				self:repaint_states()
			end
			local direction = tonumber(dialog.data.state_directions)
			if (direction == 1 or direction == 4 or direction == 8) and state.dirs ~= direction then
				self:set_state_dirs(state, direction)
			end
			local loop = tonumber(dialog.data.state_loop)
			if loop then
				loop = math.floor(loop)
				if loop >= 0 then
					state.loop = loop
				end
			end
			state.movement = dialog.data.state_movement or false
			state.rewind = dialog.data.state_rewind or false
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
end

--- Sets the number of directions for a state.
--- @param state State
--- @param directions 1|4|8
function Editor:set_state_dirs(state, directions)
	local state_sprite = nil --[[@type StateSprite|nil]]
	for _, state_sprite_ in ipairs(self.open_sprites) do
		if state_sprite_.state == state then
			state_sprite = state_sprite_
			break
		end
	end

	if state_sprite then
		app.transaction("Change State Directions", function()
			local sprite = state_sprite.sprite
			if state.dirs > directions then
				for _, layer in ipairs(sprite.layers) do
					local index = table.index_of(DIRECTION_NAMES, layer.name)
					if index ~= 0 and index > directions then
						sprite:deleteLayer(layer)
					end
				end
				if #sprite.layers > 0 then
					local layer = sprite.layers[1]
					layer.isVisible = not layer.isVisible
					layer.isVisible = not layer.isVisible
				end
			else
				local primary_layer = nil --[[@type Layer|nil]]
				for _, layer in ipairs(sprite.layers) do
					if layer.name == DIRECTION_NAMES[1] then
						primary_layer = layer
						break
					end
				end

				for i = state.dirs + 1, directions, 1 do
					local layer_name = DIRECTION_NAMES[i]

					local exists = false
					for _, layer in ipairs(sprite.layers) do
						if layer.name == layer_name then
							exists = true
							break
						end
					end

					if not exists then
						local layer = sprite:newLayer()
						layer.stackIndex = 1
						layer.name = layer_name
						layer.isVisible = false

						if primary_layer then
							for _, frame in ipairs(sprite.frames) do
								local cel = primary_layer:cel(frame.frameNumber)
								local image = Image(ImageSpec {
									width = sprite.width,
									height = sprite.height,
									colorMode = ColorMode.RGB,
									transparentColor = app.pixelColor.rgba(state_sprite.transparentColor.red, state_sprite.transparentColor.green, state_sprite.transparentColor.blue, state_sprite.transparentColor.alpha)
								})

								if cel and cel.image then
									image:drawImage(cel.image, cel.position)
								else
									image:drawImage(self.image_cache:get(state.frame_key), Point(0, 0))
								end

								sprite:newCel(layer, frame, image, Point(0, 0))
							end
						end
					end
				end
				sprite:deleteLayer(sprite:newLayer())
			end
			state.dirs = directions
			state_sprite:save()
		end)
	end
end

-- Creates a new state for the editor.
function Editor:new_state()
	if not self.dmi then return end

	local state, error = libdmi.new_state(self.dmi.width, self.dmi.height, self.dmi.temp)
	if not error then
		self.modified = true
		table.insert(self.dmi.states, state)
		self.image_cache:load_state(self.dmi, state --[[@as State]])
		self:repaint_states()
		self:gc_open_sprites()
	else
		app.alert { title = "Error", text = { "Failed to create new state", error } }
	end
end

--- Removes a state from the DMI file.
--- @param state State The state to be removed.
function Editor:remove_state(state)
	for i, state_sprite in ipairs(self.open_sprites) do
		if state_sprite.state == state then
			state_sprite.sprite:close()
			table.remove(self.open_sprites, i)
			break
		end
	end

	table.remove(self.dmi.states, table.index_of(self.dmi.states, state))
	self.image_cache:remove(state.frame_key)
	self:repaint_states()
	self:gc_open_sprites()
end

--- Copies a state to the clipboard.
--- @param state State The state to be copied.
function Editor:clipboard_copy_state(state)
	for _, state_sprite in ipairs(self.open_sprites) do
		if state_sprite.state == state then
			if state_sprite.sprite.isModified then
				app.alert { title = self.title, text = "Save the open sprite first" }
				return
			end
			break
		end
	end

	libdmi.copy_state(state, self.dmi.temp)
end

--- Creates a new state in the DMI file copied from the clipboard.
function Editor:clipboard_paste_state()
	if not self.dmi then return end

	local state = libdmi.paste_state(self.dmi.width, self.dmi.height, self.dmi.temp)
	if state then
		self.modified = true
		table.insert(self.dmi.states, state)
		self.image_cache:load_state(self.dmi, state)
		self:repaint_states()
		self:gc_open_sprites()
	end
end

--- Shows a dialog to resize the DMI file.
function Editor:resize()
	if not self.dmi then return end

	local original_width = self.dmi.width
	local original_height = self.dmi.height
	local ratio = original_width / original_height

	local dialog = Dialog {
		title = "Resize"
	}

	dialog:separator { text = "Pixels:" }

	dialog:number {
		id = "width",
		focus = true,
		label = "Width:",
		text = tostring(original_width),
		decimals = 0,
		onchange = function()
			local width = dialog.data.width

			dialog:modify {
				id = "width_percentage",
				text = width / original_width * 100
			}

			if dialog.data.ratio_lock then
				local height = math.floor(width / ratio)

				dialog:modify {
					id = "height",
					text = height
				}
				dialog:modify {
					id = "height_percentage",
					text = height / original_height * 100
				}
			end
		end
	}

	dialog:number {
		id = "height",
		label = "Height:",
		text = tostring(original_height),
		decimals = 0,
		onchange = function()
			local height = dialog.data.height

			dialog:modify {
				id = "height_percentage",
				text = height / original_height * 100
			}

			if dialog.data.ratio_lock then
				local width = math.floor(height * ratio)

				dialog:modify {
					id = "width",
					text = width
				}
				dialog:modify {
					id = "width_percentage",
					text = width / original_width * 100
				}
			end
		end
	}

	dialog:check {
		id = "ratio_lock",
		label = "Lock Ratio",
		selected = true,
		onclick = function()
			if dialog.data.ratio_lock then
				local width = dialog.data.width
				local height = math.floor(width / ratio)

				dialog:modify {
					id = "height",
					text = height
				}
				dialog:modify {
					id = "height_percentage",
					text = height / original_height * 100
				}
			end
		end
	}

	dialog:separator { text = "Percentage:" }

	dialog:number {
		id = "width_percentage",
		label = "Width:",
		text = "100",
		onchange = function()
			local width = dialog.data.width_percentage
			width = math.floor(width * original_width / 100)

			dialog:modify {
				id = "width",
				text = width
			}

			if dialog.data.ratio_lock then
				local height = math.floor(width / ratio)

				dialog:modify {
					id = "height",
					text = height
				}
				dialog:modify {
					id = "height_percentage",
					text = height / original_height * 100
				}
			end
		end
	}

	dialog:number {
		id = "height_percentage",
		label = "Height:",
		text = "100",
		onchange = function()
			local height = dialog.data.height_percentage
			height = math.floor(height * original_height / 100)

			dialog:modify {
				id = "height",
				text = height
			}

			if dialog.data.ratio_lock then
				local width = math.floor(height * ratio)

				dialog:modify {
					id = "width",
					text = width
				}
				dialog:modify {
					id = "width_percentage",
					text = width / original_width * 100
				}
			end
		end
	}

	dialog:separator { text = "Interpolation:" }

	dialog:combobox {
		id = "method",
		label = "Method:",
		option = "Nearest-neighbor",
		options = { "Nearest-neighbor", "Triangle", "CatmullRom", "Gaussian", "Lanczos3" },
	}

	dialog:button {
		focus = true,
		text = "&OK",
		onclick = function()
			local width = dialog.data.width
			local height = dialog.data.height
			local method = dialog.data.method

			if width < 3 or height < 3 then
				app.alert { title = "Warning", text = "Width and height must be at least 3 pixels" }
				return
			end

			if width == original_width and height == original_height then
				app.alert { title = "Warning", text = "Width and height must be different from the original size" }
				return
			end

			local alert = app.alert {
				title = "Warning",
				text = {
					"Resizing the DMI will re-open all open states",
					"without saving and this is irreversible. Continue?"
				},
				buttons = { "&OK", "&Cancel" }
			}

			if alert == 2 then
				return
			end

			dialog:close()

			if method == "Nearest-neighbor" then
				method = "nearest"
			elseif method == "Triangle" then
				method = "triangle"
			elseif method == "CatmullRom" then
				method = "catmullrom"
			elseif method == "Gaussian" then
				method = "gaussian"
			elseif method == "Lanczos3" then
				method = "lanczos3"
			end

			local _, error = libdmi.resize(self.dmi, width, height, method)

			if not error then
				self.dmi.width = width
				self.dmi.height = height
				self:reload_open_states()
			else
				app.alert { title = "Error", text = { "Failed to resize", error } }
			end
		end
	}

	dialog:button {
		text = "&Cancel",
		onclick = function()
			dialog:close()
		end
	}

	dialog:show()
end

--- Shows a dialog to crop the DMI file.
function Editor:crop()
	if not self.dmi then return end

	local original_width = self.dmi.width
	local original_height = self.dmi.height

	local dialog = Dialog {
		title = "Crop"
	}

	dialog:separator { text = "Size:" }

	dialog:number {
		id = "width",
		focus = true,
		label = "Width:",
		text = tostring(original_width),
		decimals = 0,
		onchange = function()
			local width = dialog.data.width
			local left = dialog.data.left

			if width > original_width then
				return
			end

			if dialog.data.center then
				left = math.floor((original_width - width) / 2)

				dialog:modify {
					id = "left",
					value = left
				}
			elseif left > original_width - width then
				dialog:modify {
					id = "left",
					value = original_width - width
				}
			end

			dialog:modify {
				id = "left",
				max = original_width - width
			}
		end
	}

	dialog:number {
		id = "height",
		label = "Height:",
		text = tostring(original_height),
		decimals = 0,
		onchange = function()
			local height = dialog.data.height
			local top = dialog.data.top

			if height > original_height then
				return
			end

			if dialog.data.center then
				top = math.floor((original_height - height) / 2)

				dialog:modify {
					id = "top",
					value = top
				}
			elseif top > original_height - height then
				dialog:modify {
					id = "top",
					value = original_height - height
				}
			end

			dialog:modify {
				id = "top",
				max = original_height - height
			}
		end
	}

	dialog:separator { text = "Offset:" }

	dialog:slider {
		id = "top",
		label = "Top:",
		value = 0,
		min = 0,
		max = 0,
		onchange = function()
			dialog:modify {
				id = "center",
				selected = false
			}
		end
	}

	dialog:slider {
		id = "left",
		label = "Left:",
		value = 0,
		min = 0,
		max = 0,
		onchange = function()
			dialog:modify {
				id = "center",
				selected = false
			}
		end
	}

	dialog:check {
		id = "center",
		label = "Center:",
		selected = true,
		onclick = function()
			local width = dialog.data.width
			local height = dialog.data.height
			local left = dialog.data.left
			local top = dialog.data.top

			if dialog.data.center then
				left = math.floor((original_width - width) / 2)
				top = math.floor((original_height - height) / 2)
			end

			dialog:modify {
				id = "left",
				value = left
			}
			dialog:modify {
				id = "top",
				value = top
			}
		end
	}

	dialog:button {
		focus = true,
		text = "&OK",
		onclick = function()
			local width = dialog.data.width
			local height = dialog.data.height
			local left = dialog.data.left
			local top = dialog.data.top

			if width < 3 or height < 3 then
				app.alert { title = "Warning", text = "Width and height must be at least 3 pixels" }
				return
			end

			if width > original_width or height > original_height or (width == original_width and height == original_height) then
				app.alert { title = "Warning", text = "Width and height must be less than the original size" }
				return
			end

			if left > original_width - width or top > original_height - height then
				app.alert { title = "Warning", text = "Offset must fit within the size" }
				return
			end

			local alert = app.alert {
				title = "Warning",
				text = {
					"Cropping the DMI will re-open all open states",
					"without saving and this is irreversible. Continue?"
				},
				buttons = { "&OK", "&Cancel" }
			}

			if alert == 2 then
				return
			end

			dialog:close()

			local _, error = libdmi.crop(self.dmi, left, top, width, height)

			if not error then
				self.dmi.width = width
				self.dmi.height = height
				self:reload_open_states()
			else
				app.alert { title = "Error", text = { "Failed to crop", error } }
			end
		end
	}

	dialog:button {
		text = "&Cancel",
		onclick = function()
			dialog:close()
		end
	}

	dialog:show()
end

function Editor:expand()
	if not self.dmi then return end

	local original_width = self.dmi.width
	local original_height = self.dmi.height

	local dialog = Dialog {
		title = "Expand"
	}

	dialog:separator { text = "Size:" }

	dialog:number {
		id = "width",
		focus = true,
		label = "Width:",
		text = tostring(original_width),
		decimals = 0,
		onchange = function()
			local width = dialog.data.width
			if width >= original_width then
				local left = dialog.data.left

				if dialog.data.anchor ~= "Custom" then
					if string.find(dialog.data.anchor, "middle") or dialog.data.anchor == "Center" then
						left = math.floor((width - original_width) / 2)
					elseif string.find(dialog.data.anchor, "left") then
						left = 0
					elseif string.find(dialog.data.anchor, "right") then
						left = width - original_width
					end
				end

				dialog:modify {
					id = "left",
					max = width - original_width,
					value = left
				}
			end
		end
	}

	dialog:number {
		id = "height",
		label = "Height:",
		text = tostring(original_height),
		decimals = 0,
		onchange = function()
			local height = dialog.data.height
			if height >= original_height then
				local top = dialog.data.top

				if dialog.data.anchor ~= "Custom" then
					if string.find(dialog.data.anchor, "Middle") or dialog.data.anchor == "Center" then
						top = math.floor((height - original_height) / 2)
					elseif string.find(dialog.data.anchor, "Top") then
						top = 0
					elseif string.find(dialog.data.anchor, "Bottom") then
						top = height - original_height
					end
				end

				dialog:modify {
					id = "top",
					max = height - original_height,
					value = top
				}
			end
		end
	}

	dialog:separator { text = "Anchor:" }

	dialog:slider {
		id = "top",
		label = "Top:",
		value = 0,
		min = 0,
		max = 0,
		onchange = function()
			dialog:modify {
				id = "anchor",
				option = "Custom"
			}
		end
	}

	dialog:slider {
		id = "left",
		label = "Left:",
		value = 0,
		min = 0,
		max = 0,
		onchange = function()
			dialog:modify {
				id = "anchor",
				option = "Custom"
			}
		end
	}

	dialog:combobox {
		id = "anchor",
		label = "Align:",
		option = "Center",
		options = { "Top-left", "Top-middle", "Top-right", "Middle-left", "Center", "Middle-right", "Bottom-left", "Bottom-middle", "Bottom-right", "Custom" },
		onchange = function()
			if dialog.data.anchor ~= "Custom" then
				local width = dialog.data.width
				local height = dialog.data.height
				local left = dialog.data.left
				local top = dialog.data.top

				if string.find(dialog.data.anchor, "middle") or dialog.data.anchor == "Center" then
					left = math.floor((width - original_width) / 2)
				elseif string.find(dialog.data.anchor, "left") then
					left = 0
				elseif string.find(dialog.data.anchor, "right") then
					left = width - original_width
				end

				if string.find(dialog.data.anchor, "Middle") or dialog.data.anchor == "Center" then
					top = math.floor((height - original_height) / 2)
				elseif string.find(dialog.data.anchor, "Top") then
					top = 0
				elseif string.find(dialog.data.anchor, "Bottom") then
					top = height - original_height
				end

				dialog:modify {
					id = "left",
					value = left
				}
				dialog:modify {
					id = "top",
					value = top
				}
			end
		end
	}

	dialog:button {
		focus = true,
		text = "&OK",
		onclick = function()
			local width = dialog.data.width
			local height = dialog.data.height
			local left = dialog.data.left
			local top = dialog.data.top

			if width < 3 or height < 3 then
				app.alert { title = "Warning", text = "Width and height must be at least 3 pixels" }
				return
			end

			if width < original_width or height < original_height or (width == original_width and height == original_height) then
				app.alert { title = "Warning", text = "Width and height must be greater than the original size" }
				return
			end

			local alert = app.alert {
				title = "Warning",
				text = {
					"Expanding the DMI will re-open all open states",
					"without saving and this is irreversible. Continue?"
				},
				buttons = { "&OK", "&Cancel" }
			}

			if alert == 2 then
				return
			end

			dialog:close()

			local _, error = libdmi.expand(self.dmi, left, top, width, height)

			if not error then
				self.dmi.width = width
				self.dmi.height = height
				self:reload_open_states()
			else
				app.alert { title = "Error", text = { "Failed to expand", error } }
			end
		end
	}

	dialog:button {
		text = "&Cancel",
		onclick = function()
			dialog:close()
		end
	}

	dialog:show()
end

--- Reloads all open states in the editor.
function Editor:reload_open_states()
	local open_states = {} --[[@type State[] ]]
	for _, state_sprite in ipairs(self.open_sprites) do
		if state_sprite.sprite then
			state_sprite.sprite:close()
			table.insert(open_states, state_sprite.state)
		end
	end

	self.open_sprites = {}
	self.image_cache:load_previews(self.dmi)
	self:repaint_states()

	for _, state in ipairs(open_states) do
		self:open_state(state)
	end
end

--- Splits a multi-directional state into individual states, one for each direction.
--- @param state State The state to be split.
function Editor:split_state(state)
	if not self.dmi then return end
	if state.dirs == 1 then
		app.alert { title = "Warning", text = "Cannot split a state with only one direction" }
		return
	end

	-- Check if state is open and modified
	for _, state_sprite in ipairs(self.open_sprites) do
		if state_sprite.state == state then
			if state_sprite.sprite.isModified then
				app.alert { title = self.title, text = "Save the open sprite first" }
				return
			end
			break
		end
	end

	local original_name = state.name
	local direction_names = {
		[4] = { "S", "N", "E", "W" },
		[8] = { "S", "N", "E", "W", "SE", "SW", "NE", "NW" }
	}

	-- Create a new state for each direction
	for i = 1, state.dirs do
		local new_state, error = libdmi.new_state(self.dmi.width, self.dmi.height, self.dmi.temp)
		if error then
			app.alert { title = "Error", text = { "Failed to create new state", error } }
			return
		end

		if not new_state then
			app.alert { title = "Error", text = "Failed to create new state" }
			return
		end

		-- Set the new state properties
		new_state.name = original_name .. " - " .. direction_names[state.dirs][i]
		new_state.dirs = 1
		new_state.loop = state.loop
		new_state.rewind = state.rewind
		new_state.movement = state.movement
		new_state.delays = table.clone(state.delays)

		-- Copy the image data for this direction
		local frames_per_dir = state.frame_count
		local start_frame = (i - 1) * frames_per_dir

		for frame = 1, frames_per_dir do
			local src_path = app.fs.joinPath(self.dmi.temp, state.frame_key .. "." .. tostring(start_frame + frame - 1) .. ".bytes")
			local dst_path = app.fs.joinPath(self.dmi.temp, new_state.frame_key .. "." .. tostring(frame - 1) .. ".bytes")

			-- Copy the image file
			local src_file = io.open(src_path, "rb")
			if src_file then
				local content = src_file:read("*all")
				src_file:close()

				local dst_file = io.open(dst_path, "wb")
				if dst_file then
					dst_file:write(content)
					dst_file:close()
				end
			end
		end

		table.insert(self.dmi.states, new_state)
		self.image_cache:load_state(self.dmi, new_state)
	end

	-- Mark as modified and remove the original state
	self.modified = true
	self:remove_state(state)
	self:repaint_states()
end
--- Opens the entire DMI file as a spritesheet for direct editing
--- Function to create a spritesheet from all states
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
    
    -- Debug output
    print("Creating spritesheet with dimensions: " .. width .. "x" .. height)
    print("Total frames: " .. total_frames .. ", Grid size: " .. grid_size)
    
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
        for stateIdx, state in ipairs(self.dmi.states) do
            print("Processing state " .. stateIdx .. ": " .. state.name .. " (" .. state.frame_count .. " frames, " .. state.dirs .. " dirs)")
            
            for frame = 0, state.frame_count - 1 do
                for dir = 0, state.dirs - 1 do
                    local frame_index = frame * state.dirs + dir
                    local path = app.fs.joinPath(self.dmi.temp, state.frame_key .. "." .. frame_index .. ".bytes")
                    
                    -- Make sure the file exists
                    if not app.fs.isFile(path) then
                        print("Warning: File not found: " .. path)
                        goto continue
                    end
                    
                    local cellImage = load_image_bytes(path)
                    
                    -- Calculate position in grid
                    local col = index % grid_size
                    local row = math.floor(index / grid_size)
                    local x = col * self.dmi.width
                    local y = row * self.dmi.height
                    
                    print("Placing frame at position: " .. x .. "," .. y .. " (index: " .. index .. ", col: " .. col .. ", row: " .. row .. ")")
                    
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
    app.command.FitScreen()
    
    return sprite
end

-- Applies changes from the spritesheet back to the individual states
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
    
    -- Check if the spritesheet has been modified
    -- Note: We can't directly check isModified since we're about to exit spritesheet mode
    -- Just process the changes regardless
    
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
                    print("Using layer: " .. l.name .. " as the main content layer")
                    break
                end
            end
        end
        
        if not mainLayer then
            app.alert("Could not find a suitable content layer in the spritesheet")
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
        for stateIdx, state in ipairs(self.dmi.states) do
            print("Extracting state " .. stateIdx .. ": " .. state.name)
            
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
                        print("Warning: Position out of bounds: " .. x .. "," .. y)
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
                    save_image_bytes(cellImage, path)
                    
                    -- Update the preview image in the cache if this is the first frame/direction
                    if frame == 0 and dir == 0 then
                        self.image_cache:set(state.frame_key, cellImage)
                    end
                    
                    index = index + 1
                    ::continue::
                end
            end
        end
        
        -- Mark the DMI as modified
        self.modified = true
    end)
    
    -- We can't directly set isModified as it's a read-only property
    -- The spritesheet will be closed anyway when we toggle view modes
    
    -- Refresh the display
    self:repaint_states()
    
    app.alert("Changes from spritesheet applied to individual states")
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