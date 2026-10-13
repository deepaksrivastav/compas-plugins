-- Copyright (C) 2026 Deepak Srivastav
-- SPDX-License-Identifier: GPL-3.0-or-later

plugin.define({
    id = "compas.r1_usb_dac_mode",
    name = "R1 iPhone USB DAC",
    version = "1.0.0",
    api_min = 15,
})

-- The R1's TCS1421 starts in NormalDRP. For an iPhone to see the R1's
-- uac_sa gadget, the R1 must be the USB sink/device before the cable is
-- connected. Charging is disabled separately so the phone is not asked to
-- charge the R1's battery; the input path remains available to power it.
local ROLE_FILE = "/sys/devices/platform/tcs1421/tcs1421_cfg"
local CHARGER_FILE = "/sys/class/power_supply/axp_battery/charger"

local function write_file(path, value)
    local file, err = io.open(path, "w")
    if not file then return false, err or "open failed" end
    local ok, write_err = file:write(value, "\n")
    file:close()
    if not ok then return false, write_err or "write failed" end
    return true
end

local function prepare_for_iphone()
    local ok_role, role_err = write_file(ROLE_FILE, "Sink")
    local ok_charge, charge_err = write_file(CHARGER_FILE, "0")
    if ok_role and ok_charge then
        plugin.show_toast("R1 ready for iPhone USB DAC; connect the cable now")
    elseif ok_role then
        plugin.show_toast("R1 set to Sink, but charging could not be disabled")
    elseif ok_charge then
        plugin.show_toast("Charging disabled, but R1 role could not be set")
    else
        plugin.show_toast("Could not prepare R1 USB DAC")
    end
    return ok_role and ok_charge, role_err or charge_err
end

local function restore_normal_mode()
    local ok_role = write_file(ROLE_FILE, "NormalDRP")
    local ok_charge = write_file(CHARGER_FILE, "1")
    if ok_role and ok_charge then
        plugin.show_toast("R1 USB role and charging restored")
    elseif ok_role then
        plugin.show_toast("R1 role restored, but charging could not be enabled")
    elseif ok_charge then
        plugin.show_toast("Charging restored, but R1 role could not be restored")
    else
        plugin.show_toast("Could not restore R1 USB mode")
    end
    return ok_role and ok_charge
end

local function show_about()
    plugin.show_list("R1 iPhone USB DAC", {
        "Prepare sets the R1 USB-C port to Sink/device mode and disables battery charging.",
        "Connect the iPhone only after Prepare succeeds.",
        "Restore returns the port to NormalDRP and enables charging.",
        "For Lightning iPhones, use Apple's Lightning-to-USB 3 Camera Adapter with power.",
    }, function() end)
end

local function open_menu()
    plugin.show_settings_list("R1 iPhone USB DAC", {
        {
            type = "row",
            label = "Prepare for iPhone",
            on_select = prepare_for_iphone,
        },
        {
            type = "row",
            label = "Restore normal USB mode",
            on_select = restore_normal_mode,
        },
        {
            type = "row",
            label = "About",
            on_select = show_about,
        },
    })
end

-- The general settings destination is shown by the R1 firmware in its More
-- menu, and is available even when the audio-specific page is hidden.
plugin.register_list_item("system", "R1 iPhone USB DAC", open_menu)

if rawget(_G, "COMPAS_PLUGIN_TEST") then
    _G.COMPAS_PLUGIN_UNDER_TEST = {
        prepare_for_iphone = prepare_for_iphone,
        restore_normal_mode = restore_normal_mode,
    }
end
