import AudioToolbox
import CoreAudio
import Foundation

/// Detects which displays can actually output sound, so we don't show a DDC volume slider
/// on a monitor with no speakers (e.g. many gaming/professional panels). A display that can
/// play audio shows up as a CoreAudio output device on the HDMI/DisplayPort transport,
/// usually named after the monitor. This is read from CoreAudio (not DDC), so it's reliable
/// even while the display is asleep.
struct AudioCapabilityService {
    /// Names of connected HDMI/DisplayPort audio outputs (i.e. monitor speakers).
    func displayAudioDeviceNames() -> [String] {
        deviceIDs()
            .filter { hasOutputStreams($0) && isDisplayTransport($0) }
            .compactMap { name(of: $0) }
    }

    /// Whether a display with this name has a matching display-audio output device.
    func displayHasAudio(named displayName: String, deviceNames: [String]) -> Bool {
        let target = Self.normalize(displayName)
        guard !target.isEmpty else {
            return false
        }
        return deviceNames.contains { audioName in
            let candidate = Self.normalize(audioName)
            guard !candidate.isEmpty else {
                return false
            }
            return candidate == target || candidate.contains(target) || target.contains(candidate)
        }
    }

    /// Lowercase, alphanumerics only — so "DELL U2720Q" and "DELL-U2720Q (1)" compare equal.
    static func normalize(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    // MARK: - CoreAudio plumbing

    private func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else {
            return []
        }
        return ids
    }

    private func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private func isDisplayTransport(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeHDMI
            || transport == kAudioDeviceTransportTypeDisplayPort
    }

    private func name(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        return status == noErr ? (value as String?) : nil
    }
}
