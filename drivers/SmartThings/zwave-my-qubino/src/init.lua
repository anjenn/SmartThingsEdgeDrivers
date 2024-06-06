local capabilities = require "st.capabilities"
--- @type st.zwave.defaults
local defaults = require "st.zwave.defaults"
--- @type st.zwave.Driver
local ZwaveDriver = require "st.zwave.driver"
local cc  = require "st.zwave.CommandClass"
local log = require "log"
local utils = require "st.utils"

local SwitchBinary = (require "st.zwave.CommandClass.SwitchBinary")({ version = 2 })
local SwitchMultilevel = (require "st.zwave.CommandClass.SwitchMultilevel")({ version=3 })
-- version: v3 -> the device supports v3, so we can use value instead of target value
local Meter = (require "st.zwave.CommandClass.Meter")({version=4})
--meter version in lib: 3, mine: 4

local Configuration = (require "st.zwave.CommandClass.Configuration")({ version = 4 })

--st/zwave/generated/Meter/init.lua
--local args = {}
--args.meter_type = self.args.meter_type or 0
--args.rate_type = self.args.rate_type or 0
--args.scale = self.args.scale or 0
--args.meter_value = self.args.meter_value or 0
--args.delta_time = self.args.delta_time or 0
--if self.args.scale == Meter.scale.electric_meter.MST then
--    args.scale_2 = self.args.scale_2 or 0
--end

local SensorMultilevel = require "st.zwave.CommandClass.SensorMultilevel"

local MultichannelAssociation = (require "st.zwave.CommandClass.MultiChannelAssociation")({ version = 3 })

--args.sensor_value

local POWER_UNIT_WATT = "W"
local ENERGY_UNIT_KWH = "kWh"



local function switch_set_on_handler(driver, device, command)
    --st/zwave/defaults/switch.lua
    log.info("switch_set_on_handler: "..utils.stringify_table(command, 'cmd', true))
    --  capability handler
    device:send(SwitchBinary:Set({
        target_value = SwitchBinary.value.ON_ENABLE,
        duration = 0
    }))
    --  qubino specifically doesn't send command (other devices mostly do)
    device.thread:call_with_delay(1,function()
        device:send(SwitchBinary:Get({}))
    end)
end

local function switch_set_off_handler(driver, device, command)
    log.info("switch_set_off_handler: "..utils.stringify_table(command, 'cmd', true))

    --  capability handler
    device:send(SwitchBinary:Set({
        target_value = SwitchBinary.value.OFF_DISABLE,
        duration = 0
    }))
    device.thread:call_with_delay(1,function()
        device:send(SwitchBinary:Get({}))
    end)
end

local function switch_set_level_handler(driver, device, command)
    --st/zwave/defaults/switchLevel.lua
    log.info("switch_set_level_handler: "..utils.stringify_table(command, 'cmd', true))
    -- mapping the value
    local level = utils.round(command.args.level)
    level = utils.clamp_value(level, 1, 99)

    device:send(
            SwitchMultilevel:Set({ value=level, duration=0 }))

    device.thread:call_with_delay(1,function()
        device:send(SwitchMultilevel:Get({}))
    end)
end

local do_refresh = function(self, device)
    --refresh for all capabilities

    device:send(SwitchMultilevel:Get({}))

    device:send(Meter:Get({scale = Meter.scale.electric_meter.KILOWATT_HOURS}))
    device:send(Meter:Get({scale = Meter.scale.electric_meter.WATTS}))

    device:send(SwitchBinary:Get({}))

--    simpler than what's in drivers/SmartThings/zwave-switch/src/qubino-switches/init.lua
--    because we know this switch supports it supports capability by id -> simpler
--    other send functions are required. (except for the temperature measurement which we dont have)

end

------------------
--zwave handler --
------------------

local function switch_binary_report_handler(driver, device, cmd)
    --  cmd == cap. command -> report
    --  st/zwave/defaults/switch.lua
    log.info("switch_binary_report_handler: "..utils.stringify_table(cmd, 'cmd', true))

    local event
    --   ~= == !=
    --  nil == null
    if cmd.args.value ~= nil then
        if cmd.args.value == SwitchBinary.value.OFF_DISABLE then
            event = capabilities.switch.switch.off()
        else
            event = capabilities.switch.switch.on()
        end
    end
    -- different components have different endpoints, in our case we don't
    device:emit_event(event)
end

local function switch_multilevel_report_handler(driver, device, cmd)
    log.info("switch_multilevel_report_handler: "..utils.stringify_table(cmd, 'cmd', true))
    -- this one above is concatenation
    local event
    --local value = cmd.args.value and cmd.args.value or cmd.args.target_value
    -- if (cmd.args.value ~= nil) then (cmd.args.value) else (cmd.args.target_value)
    local value = cmd.args.value

    --this below is crucial in leaving the level unchanged when toggling switch on and off.
    if value ~= nil and value > 0 then -- level 0 is switch off, not level set
        if value == 99 or value == 0xFF then
            -- Directly map 99 to 100 to avoid rounding issues remapping 0-99 to 0-100
            -- 0xFF is a (deprecated) reserved value that the spec requires be mapped to 100
            value = 100
        end
        event = capabilities.switchLevel.level(value)
    end

    -- different components have different endpoints, in our case we don't
    device:emit_event(event)
end

local function meter_report_handler(driver, device, cmd)
    log.info("!!!meter_report_handler: "..utils.stringify_table(cmd, 'cmd', true))

    --we make meter support both power and energy, we know it also supports kilowatt_hours an watts (in library there are more)
    -- if and else statement, as the only distinguisher between energy & power is the scale/.
    --https://developer.smartthings.com/docs/edge-device-drivers/zwave/generated/Meter/constants.html#st.zwave.CommandClass.Meter.meter_type

    if cmd.args.scale == Meter.scale.electric_meter.KILOWATT_HOURS then
        device:emit_event(capabilities.energyMeter.energy({
            value = cmd.args.meter_value,
            unit = ENERGY_UNIT_KWH
        }))
    elseif cmd.args.scale == Meter.scale.electric_meter.WATTS then
        device:emit_event(capabilities.powerMeter.power({
            value = cmd.args.meter_value,
            unit = POWER_UNIT_WATT
        }))
    end
end

-- not in the manual, won't be supported by the device & device won't send the sensortmultilevel cc report
local function sensor_multi_level_report_handler(driver, device, cmd)
    log.info("!!!sensor_multi_level_report_handler: "..utils.stringify_table(cmd, 'cmd', true))

    local event_arguments = {
        value = cmd.args.sensor_value,
        unit = POWER_UNIT_WATT
    }
    device:emit_event(capabilities.powerMeter.power(event_arguments))
end

local function do_configure(self, device)
    device:send(MultichannelAssociation:Remove({grouping_identifier = 1, node_ids = {}}))
    device:send(MultichannelAssociation:Set({grouping_identifier = 1, node_ids = {self.environment_info.hub_zwave_id}}))
end

--self==driver
local function device_added(self, device)
    do_refresh(self, device)
end

local function to_numeric_value(new_value)
    local numeric = tonumber(new_value)
    if numeric == nil then -- in case the value is boolean
        numeric = new_value and 1 or 0
    end
    return numeric
end

local function info_changed(driver, device, event, args)
    if args.old_st_store.preferences.dimmingDuration ~= device.preferences.dimmingDuration then
        local new_parameter_value = to_numeric_value(device.preferences.dimmingDuration)
        device:send(Configuration:Set({ parameter_number = 68, size = 1, configuration_value = new_parameter_value }))
    end
end


--some capabilities are handled by default. ex)st/zwave/defaults/switch.lua
--device specification is provided for devices (in manual), has common classes supported, fingerprint, how to pair, data/values being sent.

local driver_template = {
    NAME = "Jenn_0506",
    supported_capabilities = {
        capabilities.switch,
        capabilities.switchLevel,
        capabilities.powerMeter,
        capabilities.energyMeter
    },
    --generic cc not required -
    zwave_handlers = {
        [cc.SWITCH_BINARY] = {
            [SwitchBinary.REPORT] = switch_binary_report_handler
        },
        [cc.SWITCH_MULTILEVEL] = {
            [SwitchMultilevel.REPORT] = switch_multilevel_report_handler
        },
        [cc.METER] = {
            [Meter.REPORT] = meter_report_handler
        --    to be done
        },
        [cc.SENSOR_MULTILEVEL] = {
            [SensorMultilevel.REPORT] = sensor_multi_level_report_handler
        --    to be done
        }
    --    sensor multilevel cc is not supported by the mini dimmer according to the manual. We leave this handler as above, but it just won't be accessed.
    },
    capability_handlers = {
        [capabilities.switch.ID] = {
            [capabilities.switch.commands.on.NAME] = switch_set_on_handler,
            [capabilities.switch.commands.off.NAME] = switch_set_off_handler
        },
        [capabilities.switchLevel.ID] = {
            [capabilities.switchLevel.commands.setLevel.NAME] = switch_set_level_handler
        },
        [capabilities.refresh.ID] = {
            [capabilities.refresh.commands.refresh.NAME] = do_refresh
        }
        --[capabilities.powerMeter.ID] = {
        --    [capabilities.powerMeter.commands.setLevel.NAME] = switch_set_level_handler
        ----    to be done
        --},
        --[capabilities.energyMeter.ID] = {
        --    [capabilities.switchLevel.commands.setLevel.NAME] = switch_set_level_handler
        ----    to be done
        --}
        --capability_handlers = {
        --    [capabilities.energyMeter.commands.resetEnergyMeter] = capability_handlers.reset
        --}
    --     we don't need above capabilities. Even power meter and energy meter handlers dont have those..
    },
    lifecycle_handlers = {
        added = device_added,
        doConfigure = do_configure,
        infoChanged = info_changed

        --    added in the similar way as:
    --    drivers/SmartThings/zwave-switch/src/qubino-switches/qubino-dimmer/init.lua
    --    drivers/SmartThings/zwave-switch/src/qubino-switches/init.lua
    }
}

defaults.register_for_default_handlers(driver_template, driver_template.supported_capabilities)
--- @type st.zwave.Driver
local driver = ZwaveDriver("my_zwave_driver", driver_template)
driver:run()


--register_for_default_handlers // this covers the basic cc part (driver_template.supported_capabilities)
-- rewrites the implementation from default
--[cc.BASIC] = {
--    [Basic.REPORT] = zwave_handlers.switch_report
--},