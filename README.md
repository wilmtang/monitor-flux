# MonitorFlux

MonitorFlux is a macOS utility prototype for combining two jobs without letting
them fight over the display pipeline:

- f.lux-style warm color temperature scheduling through one owned gamma
  compositor.
- Optional gamma brightness and contrast per display, composed into the same
  transfer table as warmth so the features do not overwrite each other.
- MonitorControl-style per-monitor hardware brightness and contrast through
  DDC/CI where the display and GPU path support it.

Gamma can be disabled globally in the app settings. When gamma is disabled,
MonitorFlux restores the system color tables and hardware DDC controls can still
be used.

## Current Backend

The hardware DDC backend uses macOS IOKit I2C/DDC APIs directly. No Homebrew
tool is required. If `ddcctl` is already installed, MonitorFlux can use it as a
fallback, but it is not a prerequisite.

DDC/CI support still depends on the monitor, cable, dock, GPU path, and macOS
driver exposure. Built-in displays do not use DDC.

## Run

```sh
./script/build_and_run.sh
```
