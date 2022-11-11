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
--- @type st.zwave.CommandClass.Meter
local Meter = (require "st.zwave.CommandClass.Meter")({version=3})

local PRESET_LEVEL = 25

local SHUTTER_LAST_DIRECTION_EVENT = "shutter_last_direction_event"
local SHUTTER_TARGET_LEVEL = "shutter_target_level"

local function added_handler(driver, device)
  -- Turn off energy reporting - by wattage by time (42), as it's not useful info.
  device:send(Configuration:Set({ parameter_number = 42, size = 1, configuration_value = 0 }))
  -- Get wattage reports, so we can get the level when it moves
  device:send(Configuration:Set({ parameter_number = 40, size = 1, configuration_value = 1 }))
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

local function info_changed_handler(driver, device, event, args)
  local preferences = {
    motorOperationDetection = { parameter_number = 76, size = 1 },
    forcedCalibration = { parameter_number = 78, size = 1 }
  }

  -- Get wattage reports, so we can get the level when it moves
  device:send(Configuration:Set({ parameter_number = 40, size = 1, configuration_value = 1 }))

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

local function multilevel_set_handler(driver, device, cmd)
  local targetLevel = cmd.args.value
  local currentLevel = device:get_latest_state("main",  capabilities.windowShadeLevel.ID, capabilities.windowShadeLevel.shadeLevel.NAME) or 0

  if currentLevel > targetLevel then
    device:emit_event(capabilities.windowShade.windowShade.closing())
  else
    device:emit_event(capabilities.windowShade.windowShade.opening())
  end

  device.thread:call_with_delay(4,
    function()
      device:send(Meter:Get({scale = Meter.scale.electric_meter.WATTS}))
    end
  )
end

-- When there's wattage, then the shutter is on the move - emit what's happening
local function meter_report_handler(driver, device, cmd)
  if cmd.args.scale == Meter.scale.electric_meter.WATTS then
    device:send(SwitchMultilevel:Get({}))
  end
end


--------------------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------------------

local function send_level(driver, device, level, cmd)
  device:send_to_component(SwitchMultilevel:Set({ value = level }), cmd.component)

  if cmd.component ~= "main" then
    device.thread:call_with_delay(1.5,
      function()
        device:send_to_component(SwitchMultilevel:Get({}), cmd.component)
      end
    )
  end
end

local function set_preset_level(driver, device, cmd)
  local preset_level = device.preferences.presetPosition or PRESET_LEVEL
  send_level(driver, device, preset_level, cmd)
end

local function set_level(driver, device, cmd)
  local level = math.max(math.min(cmd.args.shadeLevel, 99), 0)
  send_level(driver, device, level, cmd)
end

local function open(driver, device, cmd)
  send_level(driver, device, 99, cmd)
end

local function close(driver, device, cmd)
  send_level(driver, device, 0, cmd)
end

local driver_template = {
  NAME = "Qubino flush shutter",
  supported_capabilities = {
    capabilities.windowShade,
    capabilities.windowShadeLevel,
    capabilities.windowShadePreset,
    capabilities.statelessCurtainPowerButton,
  },
  zwave_handlers = {
    [cc.SWITCH_MULTILEVEL] = {
      [SwitchMultilevel.SET] = multilevel_set_handler,
    },
    [cc.METER] = {
      [Meter.REPORT] = meter_report_handler
    }
  },
  capability_handlers = {
    [capabilities.windowShadeLevel.ID] = {
      [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = set_level
    },
    [capabilities.windowShadePreset.ID] = {
      [capabilities.windowShadePreset.commands.presetPosition.NAME] = set_preset_level
    },
    [capabilities.windowShade.ID] = {
      [capabilities.windowShade.commands.open.NAME] = open,
      [capabilities.windowShade.commands.close.NAME] = close
    },
  },
  lifecycle_handlers = {
    added = added_handler,
    infoChanged = info_changed_handler
  },
}

defaults.register_for_default_handlers(driver_template, driver_template.supported_capabilities)
--- @type st.zwave.Driver
local qubino_flush_shutter = ZwaveDriver("qubino-flush-shutter", driver_template)
qubino_flush_shutter:run()
