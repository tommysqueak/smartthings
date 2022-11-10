local capabilities = require "st.capabilities"
--- @type st.zwave.defaults
local defaults = require "st.zwave.defaults"
--- @type st.zwave.Driver
local ZwaveDriver = require "st.zwave.driver"
--- @type st.zwave.CommandClass.Configuration
local Configuration = (require "st.zwave.CommandClass.Configuration")({ version = 4 })
--- @type st.zwave.CommandClass
local cc = (require "st.zwave.CommandClass")
--- @type st.zwave.CommandClass.SwitchMultilevel
local SwitchMultilevel = (require "st.zwave.CommandClass.SwitchMultilevel")({ version = 3 })
--- @type st.zwave.CommandClass.Basic
local Basic = (require "st.zwave.CommandClass.Basic")({ version = 1 })
local WindowShadeDefaults = require "st.zwave.defaults.windowShade"
local WindowShadeLevelDefaults = require "st.zwave.defaults.windowShadeLevel"


local function added_handler(self, device)
  -- Turn off energy reporting - by wattage (40) and by time (42), as it's not useful info.
  device:send(Configuration:Set({ parameter_number = 40, size = 1, configuration_value = 0 }))
  device:send(Configuration:Set({ parameter_number = 42, size = 1, configuration_value = 0 }))
  -- Default to shutter mode
  device:send(Configuration:Set({ parameter_number = 71, size = 1, configuration_value = 0 }))
  device:emit_event(capabilities.windowShade.supportedWindowShadeCommands({ "open", "close", "pause" },
    { visibility = { displayed = false } }))
  device:refresh()
end

local function to_numeric_value(new_value)
  local numeric = tonumber(new_value)
  if numeric == nil then -- in case the value is boolean
    numeric = new_value and 1 or 0
  end
  return numeric
end

local function info_changed(driver, device, event, args)
  local preferences = {
    motorOperationDetection = { parameter_number = 76, size = 1 },
    forcedCalibration = { parameter_number = 78, size = 1 }
  }

  for id, value in pairs(device.preferences) do
    if preferences[id] and args.old_st_store.preferences[id] ~= value then
      local new_parameter_value = to_numeric_value(device.preferences[id])
      device:send(Configuration:Set({ parameter_number = preferences[id].parameter_number, size = preferences[id].size,
        configuration_value = new_parameter_value }))
      device.thread:call_with_delay(1,
        function()
          device:send(Configuration:Get({ parameter_number = preferences[id].parameter_number }))
        end
      )
    end
  end
end

local function shade_event_handler(self, device, cmd)
  WindowShadeDefaults.zwave_handlers[cc.SWITCH_MULTILEVEL][SwitchMultilevel.REPORT](self, device, cmd)
  WindowShadeLevelDefaults.zwave_handlers[cc.SWITCH_MULTILEVEL][SwitchMultilevel.REPORT](self, device, cmd)
end

local function window_shade_level_change(self, device, level, cmd)
  device:send_to_component(SwitchMultilevel:Set({ value = level }), cmd.component)

  if cmd.component ~= "main" then
    device.thread:call_with_delay(1.5,
      function()
        device:send_to_component(SwitchMultilevel:Get({}), cmd.component)
      end
    )
  end
end

--------------------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------------------

local function set_shade_level(self, device, cmd)
  local level = math.max(math.min(cmd.args.shadeLevel, 99), 0)
  window_shade_level_change(self, device, level, cmd)
end

local function open(driver, device, cmd)
  window_shade_level_change(driver, device, 99, cmd)
end

local function close(driver, device, cmd)
  window_shade_level_change(driver, device, 0, cmd)
end

--------------------------------------------------------------------------------------------
-- Register message handlers and run driver
--------------------------------------------------------------------------------------------

local driver_template = {
  NAME = "Qubino flush shutter",
  supported_capabilities = {
    capabilities.windowShade,
    capabilities.windowShadeLevel,
    capabilities.windowShadePreset,
    capabilities.statelessCurtainPowerButton,
    capabilities.battery
  },
  zwave_handlers = {
    [cc.BASIC] = {
      [Basic.REPORT] = shade_event_handler
    },
    [cc.SWITCH_MULTILEVEL] = {
      [SwitchMultilevel.REPORT] = shade_event_handler
    },
  },
  capability_handlers = {
    [capabilities.windowShadeLevel.ID] = {
      [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = set_shade_level
    },
    [capabilities.windowShade.ID] = {
      [capabilities.windowShade.commands.open.NAME] = open,
      [capabilities.windowShade.commands.close.NAME] = close
    },
  },
  lifecycle_handlers = {
    added = added_handler,
    infoChanged = info_changed
  },
}

defaults.register_for_default_handlers(driver_template, driver_template.supported_capabilities)
--- @type st.zwave.Driver
local qubino_flush_shutter = ZwaveDriver("qubino-flush-shutter", driver_template)
qubino_flush_shutter:run()
