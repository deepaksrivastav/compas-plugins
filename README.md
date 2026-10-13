# My Compás Plugins

This repository contains personal plugins for [Compás Player](https://github.com/Starnished66/compas-player).

## License and copyright

Copyright (C) 2026 Deepak Srivastav.

Unless a file says otherwise, the source code and accompanying materials in
this repository are licensed under the GNU General Public License, version 3
or later. See [LICENSE](LICENSE).

You may copy, modify, and redistribute the work under that license, but
redistributed versions must preserve the copyright and license notices and
provide the corresponding source code as required by the GPL.

## Plugins

- **Audiobookshelf** — a download-only client for my self-hosted Audiobookshelf
  library. It stores books as `Audiobooks/Author/Book/` or
  `Audiobooks/Author/Series/Book/` and does not launch playback or synchronize
  listening positions.
- **R1 USB DAC Mode** — prepares the HiBy R1 USB-C port for iPhone/Android USB
  DAC use and can restore normal USB behavior.

Detailed documentation:

- [Audiobookshelf](docs/Audiobookshelf.md)
- [R1 USB DAC Mode](docs/R1UsbDacMode.md)

## Installation

Run the installer for the plugin you want, passing the root of the Compás SD
card as its only argument:

```sh
./install_audiobookshelf.sh /path/to/compas-sd-card
./install_r1_usb_dac_mode.sh /path/to/compas-sd-card
```

The scripts create the required `.plugins` and `.plugin-assets` directories.
After copying, use **Settings → More → Plugin Manager → Refresh Plugins**, or
restart the player.

