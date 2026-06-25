# Acknowledgements

## MonitorControl

MonitorFlux's low-level display-control code was developed by studying
[**MonitorControl**](https://github.com/MonitorControl/MonitorControl), which is
MIT-licensed. The implementations in this repository were written independently for
MonitorFlux, but the techniques and hardware/interop details are owed to MonitorControl:

- [`Sources/MonitorFlux/Services/Arm64DDCBackend.swift`](Sources/MonitorFlux/Services/Arm64DDCBackend.swift)
  follows MonitorControl's `Support/Arm64DDC.swift` for DDC/CI over `IOAVService` on
  Apple Silicon — the I²C addresses (`0x37` / `0x51`), the VCP write-packet byte layout
  and checksum, and the IORegistry walk that pairs framebuffers (`AppleCLCD2` /
  `IOMobileFramebufferShim`) with `DCPAVServiceProxy` services.
- [`Sources/MonitorFlux/Services/NativeBrightnessBackend.swift`](Sources/MonitorFlux/Services/NativeBrightnessBackend.swift)
  uses the same private DisplayServices brightness functions MonitorControl uses to
  control the built-in and Apple displays' backlight.
- [`Sources/MonitorFlux/Services/KeyboardControlService.swift`](Sources/MonitorFlux/Services/KeyboardControlService.swift)
  uses the same `NSSystemDefined` media-key event-tap technique to capture the
  brightness/volume keys.
- [`Sources/MonitorFlux/Services/NativeOSD.swift`](Sources/MonitorFlux/Services/NativeOSD.swift)
  drives the private `OSDManager` (OSD.framework) for the native brightness/volume bezel, as in
  MonitorControl's `Support/OSDUtils.swift` (the `showImage:onDisplayID:…:filledChiclets:totalChiclets:locked:`
  call and image codes).
- [`Sources/MonitorFlux/Services/ShadeController.swift`](Sources/MonitorFlux/Services/ShadeController.swift)
  and [`Sources/MonitorFlux/Services/CoreDisplayInfo.swift`](Sources/MonitorFlux/Services/CoreDisplayInfo.swift)
  follow MonitorControl's `DisplayManager` for AirPlay/virtual detection
  (`CoreDisplay_DisplayCreateInfoDictionary`, `kCGDisplayIsAirPlay`) and the overlay-window
  ("shade") dimming those displays use because they ignore gamma, plus the
  `CGDisplayMirrorsDisplay` effective-display resolution for mirror sets.

MonitorControl's license is reproduced below in full, per its terms.

### MonitorControl — MIT License

```
MIT License

Copyright © 2017

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
