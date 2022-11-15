local capabilities = require "st.capabilities"
--- @type st.zwave.defaults
local defaults = require "st.zwave.defaults"
--- @type st.zwave.Driver
local ZwaveDriver = require "st.zwave.driver"
--- @type st.zwave.CommandClass
local cc = (require "st.zwave.CommandClass")
--- @type st.zwave.CommandClass.Configuration
local Configuration = (require "st.zwave.CommandClass.Configuration")({ version=1 })
--- @type st.zwave.CommandClass.ThermostatSetpoint
local ThermostatSetpoint = (require "st.zwave.CommandClass.ThermostatSetpoint")({ version = 1 })
--- @type st.zwave.CommandClass.ThermostatMode
local ThermostatMode = (require "st.zwave.CommandClass.ThermostatMode")({ version = 2 })
--- @type st.zwave.CommandClass.SensorMultilevel
local SensorMultilevel = (require "st.zwave.CommandClass.SensorMultilevel")({ version = 5 })
--- @type st.zwave.CommandClass.ThermostatOperatingState
local ThermostatOperatingState = (require "st.zwave.CommandClass.ThermostatOperatingState")({version=1})
--- @type st.zwave.CommandClass.Meter
local Meter = (require "st.zwave.CommandClass.Meter")({version=3})
--- @type st.zwave.CommandClass.SwitchBinary
local SwitchBinary = (require "st.zwave.CommandClass.SwitchBinary")({version=1})
--- @type st.zwave.CommandClass.Basic
local Basic = (require "st.zwave.CommandClass.Basic")({version=1})
local log = require "log"

local TemperatureMeasurementDefaults = require "st.zwave.defaults.temperatureMeasurement"

local function turn_radiator_on(device)
  device:send(Basic:Set({value = SwitchBinary.value.ON_ENABLE}))

  device.thread:call_with_delay(1,
    function()
      device:send(Basic:Get({}))
    end
  )
end

local function turn_radiator_off(device)
  device:send(Basic:Set({value = SwitchBinary.value.OFF_DISABLE}))

  device.thread:call_with_delay(1,
    function()
      device:send(Basic:Get({}))
    end
  )
end

local function get_thermostat_mode(device)
  local default_mode = capabilities.thermostatMode.thermostatMode.off.NAME
  return device:get_latest_state("main",  capabilities.thermostatMode.ID, capabilities.thermostatMode.thermostatMode.NAME, default_mode)
end

local function get_setpoint_temperature(device)
  local room_temperature = 21
  return device:get_latest_state("main",  capabilities.thermostatHeatingSetpoint.ID, capabilities.thermostatHeatingSetpoint.heatingSetpoint.NAME, room_temperature)
end

local function get_temperature(device)
  local room_temperature = 21
  return device:get_latest_state("main",  capabilities.temperatureMeasurement.ID, capabilities.temperatureMeasurement.temperature.NAME, room_temperature)
end

local function control_temperature(device, current_temperature, desired_temperature, thermostat_mode)
  local hysteresis_on = -0.4
  local hysteresis_off = 0.4
  local operating_state =  device:get_latest_state("main",  capabilities.thermostatOperatingState.ID, capabilities.thermostatOperatingState.thermostatOperatingState.NAME, capabilities.thermostatOperatingState.thermostatOperatingState.idle.NAME)

  log.debug("control_temperature", current_temperature, desired_temperature, thermostat_mode, operating_state)
  --  If we've set a temp, and we're turning the radiator on and off to keep the room at that temperature
  --  aka 'heat' mode
  if thermostat_mode == capabilities.thermostatMode.thermostatMode.heat.NAME then
    if desired_temperature > (current_temperature - hysteresis_on) and operating_state == capabilities.thermostatOperatingState.thermostatOperatingState.idle.NAME then
      log.debug("control_temperature", "Heating - Turning radiator ON")
      turn_radiator_on(device)
    elseif desired_temperature < (current_temperature - hysteresis_off) and operating_state == capabilities.thermostatOperatingState.thermostatOperatingState.heating.NAME then
      log.debug("control_temperature", "Heating - Turning radiator OFF")
      turn_radiator_off(device)
    end
  elseif thermostat_mode == capabilities.thermostatMode.thermostatMode.off.NAME then
    if operating_state == capabilities.thermostatOperatingState.thermostatOperatingState.heating.NAME then
      log.debug("control_temperature", "Off - Turning radiator OFF")
      turn_radiator_off(device)
    end
  end
end

--------------------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------------------

local function configure_handler(driver, device, event, args)

  -- initial defaults, different than the modules defaults
  -- In the event of a power failure turn off the radiator
  device:send(Configuration:Set({parameter_number = 30, size = 1, configuration_value = 1}))
  
  local supported_modes = { capabilities.thermostatMode.thermostatMode.off.NAME,  capabilities.thermostatMode.thermostatMode.heat.NAME}
  device:emit_event(capabilities.thermostatMode.supportedThermostatModes(supported_modes, { visibility = { displayed = false } }))

  -- initial state of thermostat
  device:emit_event(capabilities.thermostatMode.thermostatMode.off())
  device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({value = 21, unit = 'C' }))
end

local function set_preferences_handler(driver, device, event, args)

  --  Turn off after a set time, in seconds. Useful for something staying on too long eg radiator. Max value - 32535 seconds
  device:send(Configuration:Set({parameter_number = 11, size = 2, configuration_value = device.preferences.autoTurnOff * 60}))

  --  State of switch after a power failure. 0 - back to last known state, 1 - off
  local onOffState = device.preferences.saveStateAfterPowerFail and 0 or 1
  device:send(Configuration:Set({parameter_number = 30, size = 1, configuration_value = onOffState}))

  --  Temperature offset.
  --  32536 - default.
  --  1 to 100 - value from 0.1°C to 10.0°C is added to measured temperature.
  --  1001 to 1100 - value from -0.1 °C to -10.0 °C is subtracted from measured temperature.
  local temperatureOffsetConfig
  if device.preferences.temperatureOffset > 0 then
    temperatureOffsetConfig = math.floor(device.preferences.temperatureOffset * 10)
  elseif device.preferences.temperatureOffset < 0 then
    temperatureOffsetConfig = 1000 + math.abs(math.floor(device.preferences.temperatureOffset * 10))
  else
    --  32536 = 0°C - default.
    temperatureOffsetConfig = 32536
  end
  device:send(Configuration:Set({parameter_number = 110, size = 2, configuration_value = temperatureOffsetConfig}))

  --  When to report temperature.
  --  5 (0.5°C) - default
  --  0 - Reporting disabled
  --  1-127 = 0.1°C – 12.7°C, step is 0.1°C
  device:send(Configuration:Set({parameter_number = 120, size = 1, configuration_value = device.preferences.tempReportOnChange * 10}))

  device:refresh()
end

--------------------------------------------------------------------------------------------
-- Event handlers
--------------------------------------------------------------------------------------------

local function temperature_report_handler(driver, device, cmd)
  TemperatureMeasurementDefaults.zwave_handlers[cc.SENSOR_MULTILEVEL][SensorMultilevel.REPORT](driver, device, cmd)
  control_temperature(device, cmd.args.sensor_value, get_setpoint_temperature(device), get_thermostat_mode(device))
end

local function switch_state_handler(driver, device, cmd)
  if cmd.args.value == SwitchBinary.value.OFF_DISABLE then
    device:emit_event(capabilities.thermostatOperatingState.thermostatOperatingState.idle())
  else
    device:emit_event(capabilities.thermostatOperatingState.thermostatOperatingState.heating())
  end
end

--------------------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------------------

local function set_heating_setpoint(driver, device, command)
  device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({value = command.args.setpoint, unit = 'C' }))

  control_temperature(device, get_temperature(device), command.args.setpoint, get_thermostat_mode(device))
end
 
local function set_thermostat_mode(driver, device, command)
  local mode = command.args.mode

  log.debug("set_thermostat_mode", mode, capabilities.thermostatMode.thermostatMode.heat.NAME)

  if mode == capabilities.thermostatMode.thermostatMode.heat.NAME then
    device:emit_event(capabilities.thermostatMode.thermostatMode.heat())
    log.debug("set_thermostat_mode", get_temperature(device), get_setpoint_temperature(device), capabilities.thermostatMode.thermostatMode.heat())
    control_temperature(device, get_temperature(device), get_setpoint_temperature(device), capabilities.thermostatMode.thermostatMode.heat.NAME)
  else
    device:emit_event(capabilities.thermostatMode.thermostatMode.off())
    turn_radiator_off(device)
  end
end

local function heat(driver, device)
  set_thermostat_mode(driver, device, {args = {mode = "heat"}})
end

local function off(driver, device)
  set_thermostat_mode(driver, device, {args = {mode = "off"}})
end

local function refresh(driver, device)
  device:send(SwitchBinary:Get({}))
  device:send(Meter:Get({scale = Meter.scale.electric_meter.WATTS}))
  device:send(Meter:Get({scale = Meter.scale.electric_meter.KILOWATT_HOURS}))
  device:send(SensorMultilevel:Get({sensor_type = SensorMultilevel.sensor_type.TEMPERATURE}))
end

local function nothing()
-- Stubs for unused commands, to make sure defaults aren't set for the capabilities that we've declared
-- as these aren't supported
end

local driver_template = {
  NAME = "qubino r thermostat",
  supported_capabilities = {
    capabilities.thermostatHeatingSetpoint,
    capabilities.thermostatOperatingState,
    capabilities.thermostatMode,
    capabilities.temperatureMeasurement,
    capabilities.energyMeter,
    capabilities.powerMeter,
  },
  zwave_handlers = {
    [cc.SENSOR_MULTILEVEL] = {
      [SensorMultilevel.REPORT] = temperature_report_handler
    },
    [cc.BASIC] = {
      [Basic.REPORT] = switch_state_handler
    },
    [cc.SWITCH_BINARY] = {
      [SwitchBinary.REPORT] = switch_state_handler
    },
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh
    },
    [capabilities.thermostatMode.ID] = {
      [capabilities.thermostatMode.commands.setThermostatMode.NAME] = set_thermostat_mode,
      [capabilities.thermostatMode.commands.auto.NAME] = nothing,
      [capabilities.thermostatMode.commands.cool.NAME] = nothing,
      [capabilities.thermostatMode.commands.heat.NAME] = heat,
      [capabilities.thermostatMode.commands.emergencyHeat.NAME] = heat,
      [capabilities.thermostatMode.commands.off.NAME] = off
    },
    [capabilities.thermostatHeatingSetpoint.ID] = {
      [capabilities.thermostatHeatingSetpoint.commands.setHeatingSetpoint.NAME] = set_heating_setpoint,
    },
  },
  lifecycle_handlers = {
    added = configure_handler,
    infoChanged = set_preferences_handler
  },
}

defaults.register_for_default_handlers(driver_template, {capabilities.energyMeter, capabilities.powerMeter})
--- @type st.zwave.Driver
local qubino_relay_thermostat = ZwaveDriver("qubino-r-thermostat", driver_template)
qubino_relay_thermostat:run()
