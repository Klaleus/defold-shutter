--------------------------------------------------------------------------------
-- License
--------------------------------------------------------------------------------

-- Copyright (c) 2026 Klaleus
--
-- This software is provided "as-is", without any express or implied warranty.
-- In no event will the authors be held liable for any damages arising from the use of this software.
--
-- Permission is granted to anyone to use this software for any purpose, including commercial applications,
-- and to alter it and redistribute it freely, subject to the following restrictions:
--
--     1. The origin of this software must not be misrepresented; you must not claim that you wrote the original software.
--        If you use this software in a product, an acknowledgment in the product documentation would be appreciated but is not required.
--
--     2. Altered source versions must be plainly marked as such, and must not be misrepresented as being the original software.
--
--     3. This notice may not be removed or altered from any source distribution.

--------------------------------------------------------------------------------

-- GitHub: https://github.com/klaleus/defold-shutter

--------------------------------------------------------------------------------

local _shutter_module = {}

-- { [object] = { ... }, ... }
_shutter_module.camera_table = {}
local _camera_table = _shutter_module.camera_table

_shutter_module.center_behavior = hash("center")
_shutter_module.expand_behavior = hash("expand")
_shutter_module.stretch_behavior = hash("stretch")
local _center_behavior = _shutter_module.center_behavior
local _expand_behavior = _shutter_module.expand_behavior
local _stretch_behavior = _shutter_module.stretch_behavior

local _display_width = sys.get_config_int("display.width")
local _display_height = sys.get_config_int("display.height")
local _display_ratio = _display_width / _display_height

function _shutter_module.activate(object)
	local camera = _camera_table[object]
	assert(camera) 

	local viewport_x, viewport_y, viewport_width, viewport_height = _shutter_module.get_viewport(object)
	local projection = _shutter_module.get_projection(object)

	render.set_viewport(viewport_x, viewport_y, viewport_width, viewport_height)
	render.set_view(camera.view)
	render.set_projection(projection)

	local frustum = projection * camera.view
	return frustum
end

function _shutter_module.get_viewport(object)
	local camera = _camera_table[object]
	assert(camera)

	local window_width, window_height = window.get_size()
	local window_scale_x = window_width / _display_width
	local window_scale_y = window_height / _display_height
	local window_ratio = window_width / window_height

	-- The following viewport coordinates may be nonproportionally scaled.
	local viewport_x = camera.viewport_x * window_scale_x
	local viewport_y = camera.viewport_y * window_scale_y
	local viewport_width = camera.viewport_width * window_scale_x
	local viewport_height = camera.viewport_height * window_scale_y

	-- Proportionality doesn't matter to expand and stretch behaviors.
	-- Center behavior does require proportionality, but we can skip further math if this is already the case.
	if camera.behavior == _expand_behavior or camera.behavior == _stretch_behavior or window_ratio == _display_ratio then
		return viewport_x, viewport_y, viewport_width, viewport_height
	end

	-- We need to calculate how many pixels are in excess of the original aspect ratio.
	-- Only one axis must be translated and scaled down,
	-- which creates the "black bar" phenomenon, or "margins" as referred to here.

	-- If the current window ratio is less than the original aspect ratio,
	-- then the window was scaled more vertically than horizontally,
	-- so margins must be applied on the y axis.
	if window_ratio < _display_ratio then
		local proportional_window_height = _display_height * window_scale_x
		local margin = (window_height - proportional_window_height) * 0.5
		return viewport_x, viewport_y + margin, viewport_width, viewport_height - margin * 2
	end

	-- If the current window ratio is greater than the original aspect ratio,
	-- then the window was scaled more horizontally than vertically,
	-- so margins must be applied on the x axis.
	if window_ratio > _display_ratio then
		local proportional_window_width = _display_width * window_scale_y
		local margin = (window_width - proportional_window_width) * 0.5
		return viewport_x + margin, viewport_y, viewport_width - margin * 2, viewport_height
	end
end

function _shutter_module.get_projection(object)
	local camera = _camera_table[object]
	assert(camera)

	-- Center and stretch behaviors project to the same point in clip space regardless of window size.
	if camera.behavior == _center_behavior or camera.behavior == _stretch_behavior then
		local right = _display_width * 0.5 / camera.zoom
		local top = _display_height * 0.5 / camera.zoom
		return vmath.matrix4_orthographic(-right, right, -top, top, camera.near, camera.far)
	end

	-- Expand behavior projects more narrowly as window size increases, and more widely as window size decreases, in clip space.
	if camera.behavior == _expand_behavior then
		local window_width, window_height = window.get_size()
		local right = window_width * 0.5 / camera.zoom
		local top = window_height * 0.5 / camera.zoom
		return vmath.matrix4_orthographic(-right, right, -top, top, camera.near, camera.far)
	end
end

function _shutter_module.shake(object, parent, count, duration, radius, duration_scalar, radius_scalar)
	local camera = _camera_table[object]
	assert(camera)

	if camera.shake_origin then
		_shutter_module.cancel_shake(object, parent)
	end

	local shake_object = parent and go.get_parent(object) or object
	camera.shake_origin = go.get_position(shake_object)

	duration_scalar = duration_scalar or 1
	radius_scalar = radius_scalar or 1
	local recursive_count = 0

	local function recursive()
		-- Not sure if this is the best way to achieve randomness without a proper generator,
		-- but it seems to work fine for now.
		-- Suggestions welcome, please and thank you.
		local random = socket.gettime() * 1000
		local to = radius * vmath.vector3(math.cos(random), math.sin(random), 0)

		go.animate(shake_object, "position", go.PLAYBACK_ONCE_PINGPONG, to, go.EASING_LINEAR, duration, 0, function()
			assert(_camera_table[object])

			duration = duration * duration_scalar
			radius = radius * radius_scalar

			recursive_count = recursive_count + 1
			if recursive_count < count then
				recursive()
			else
				camera.shake_origin = nil
			end
		end)
	end

	recursive()
end

function _shutter_module.cancel_shake(object, parent)
	local camera = _camera_table[object]
	assert(camera)

	if not camera.shake_origin then return end

	local shake_object = parent and go.get_parent(object) or object
	go.cancel_animations(shake_object, "position")
	go.set_position(camera.shake_origin, shake_object)
	camera.shake_origin = nil
end

local function is_within_clip_space(x, y)
	return -1 <= x and x <= 1 and -1 <= y and y <= 1
end

-- Take `x` and `y` instead of a vector for compatibility with Defold's `action.screen_x` and `action.screen_y`.
function _shutter_module.screen_to_world(object, x, y, visible)
	local camera = _camera_table[object]
	assert(camera)

	-- screen space -> clip space [-1, 1]
	local viewport_x, viewport_y, viewport_width, viewport_height = _shutter_module.get_viewport(object)
	local clip_x = (x - viewport_x) / viewport_width * 2 - 1
	local clip_y = (y - viewport_y) / viewport_height * 2 - 1
	if visible and not is_within_clip_space(clip_x, clip_y) then return end

	-- clip space [-1, 1] -> (projection space -> view space) -> world space
	local inverse_frustum = vmath.inv(_shutter_module.get_projection(object) * camera.view)
	local world_position = inverse_frustum * vmath.vector4(clip_x, clip_y, 0, 1)

	return vmath.vector3(world_position.x, world_position.y, 0)
end

function _shutter_module.world_to_screen(object, position, visible)
	local camera = _camera_table[object]
	assert(camera)

	-- world space -> (view space -> projection space) -> clip space [-1, 1]
	local frustum = _shutter_module.get_projection(object) * camera.view
	local clip_position = frustum * vmath.vector4(position.x, position.y, 0, 1)
	if visible and not is_within_clip_space(clip_position.x, clip_position.y) then return end

	-- clip space [-1, 1] -> screen space
	local _, _, viewport_width, viewport_height = _shutter_module.get_viewport(object)
	local screen_x = (clip_position.x + 1) * 0.5 * viewport_width
	local screen_y = (clip_position.y + 1) * 0.5 * viewport_height

	-- Return a vector instead of its components because we're probably not going to feed this back into `screen_to_world()`.
	return vmath.vector3(screen_x, screen_y, 0)
end

return _shutter_module