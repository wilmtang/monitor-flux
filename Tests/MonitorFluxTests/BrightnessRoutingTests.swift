import XCTest
@testable import MonitorFlux

final class BrightnessRoutingTests: XCTestCase {
    private func kind(
        isVirtual: Bool = false,
        isBuiltIn: Bool = false,
        canUseNativeBrightness: Bool = false,
        canUseDDC: Bool = false,
        dimmingMode: DimmingMode = .automatic
    ) -> BrightnessControlKind {
        BrightnessRouting.controlKind(
            isVirtual: isVirtual,
            isBuiltIn: isBuiltIn,
            canUseNativeBrightness: canUseNativeBrightness,
            canUseDDC: canUseDDC,
            dimmingMode: dimmingMode
        )
    }

    func testVirtualIsAlwaysShade() {
        // A virtual display routes to the overlay regardless of every other capability.
        XCTAssertEqual(kind(isVirtual: true, isBuiltIn: true, canUseNativeBrightness: true, canUseDDC: true), .shade)
        XCTAssertEqual(kind(isVirtual: true, dimmingMode: .software), .shade)
    }

    func testBuiltInWithBacklightIsHardwareUnlessSoftwareOptIn() {
        XCTAssertEqual(kind(isBuiltIn: true, canUseNativeBrightness: true, dimmingMode: .hardware), .hardwareOnly)
        // A stored .automatic resolves to .hardware before it reaches here, but even if it slips
        // through, the built-in is never hybrid.
        XCTAssertEqual(kind(isBuiltIn: true, canUseNativeBrightness: true, dimmingMode: .automatic), .hardwareOnly)
        XCTAssertEqual(kind(isBuiltIn: true, canUseNativeBrightness: true, dimmingMode: .software), .softwareOnly)
    }

    func testBuiltInWithoutBacklightIsSoftwareOnly() {
        XCTAssertEqual(kind(isBuiltIn: true, canUseNativeBrightness: false, dimmingMode: .hardware), .softwareOnly)
        XCTAssertEqual(kind(isBuiltIn: true, canUseNativeBrightness: false, dimmingMode: .software), .softwareOnly)
    }

    func testExternalAutomatic() {
        XCTAssertEqual(kind(canUseDDC: true, dimmingMode: .automatic), .hybrid)
        // No DDC: Automatic falls back to software dimming rather than a dead slider.
        XCTAssertEqual(kind(canUseDDC: false, dimmingMode: .automatic), .softwareOnly)
    }

    func testExternalMonitorHardware() {
        XCTAssertEqual(kind(canUseDDC: true, dimmingMode: .hardware), .hardwareOnly)
        // Monitor-hardware mode with no DDC has no working path — a disabled slider + hint.
        XCTAssertEqual(kind(canUseDDC: false, dimmingMode: .hardware), .unavailable)
    }

    func testExternalSoftwareIsAlwaysSoftwareOnly() {
        XCTAssertEqual(kind(canUseDDC: true, dimmingMode: .software), .softwareOnly)
        XCTAssertEqual(kind(canUseDDC: false, dimmingMode: .software), .softwareOnly)
    }
}
