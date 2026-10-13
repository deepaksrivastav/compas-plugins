# R1 USB DAC Mode

R1 USB DAC Mode prepares a HiBy R1 for use as a USB DAC with an iPhone or
Android device. It changes the USB role to Sink/device mode and disables
battery charging while the phone is connected.

## What it does

The plugin provides three actions:

- **Prepare for iPhone** — sets the USB role to `Sink` and disables charging.
- **Restore normal USB mode** — returns the USB role to `NormalDRP` and
  enables charging.
- **About** — displays the connection instructions.

It changes the R1's local USB and charging settings. It does not configure the
phone or install a USB audio driver.

## Installation

From the repository root, pass the Compás SD-card root to the installer:

```sh
./install_r1_usb_dac_mode.sh /path/to/compas-sd-card
```

Refresh plugins in Compás or restart the player afterward.

## Usage

1. Open **Settings → System → R1 iPhone USB DAC**.
2. Select **Prepare for iPhone**.
3. Wait for the success message.
4. Connect the phone to the R1.
5. When finished, disconnect the phone and select **Restore normal USB mode**.

Connect the phone only after preparation succeeds. Restoring normal mode is
recommended when finished so ordinary USB and charging behavior is returned.

For Lightning iPhones, use Apple's Lightning-to-USB 3 Camera Adapter with
power. Android phones may require a suitable USB-C OTG/data cable and may
present their own USB-audio permission prompt.

## Limitations

- The plugin targets the HiBy R1's USB role and battery paths. It is not a
  general USB-DAC tool for other players.
- The underlying system files must be writable by the plugin.
- If either setting cannot be changed, the plugin reports which part failed;
  do not assume the DAC connection is ready unless preparation succeeds.
