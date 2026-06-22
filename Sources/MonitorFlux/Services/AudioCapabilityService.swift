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

    /// Whether a display with this name has a matching display-audio output device. Uses
    /// exact (normalized) name equality rather than substring matching — a substring match
    /// wrongly flags one monitor as having audio when its name is contained in a sibling's
    /// audio-device name (e.g. "DELL U2720" vs "DELL U2720Q"). The duplicate-name suffix
    /// macOS adds ("… (1)") is stripped first so it still matches the bare display name.
    func displayHasAudio(named displayName: String, deviceNames: [String]) -> Bool {
        let target = Self.normalize(displayName)
        guard !target.isEmpty else {
            return false
        }
        return deviceNames.contains { audioName in
            Self.normalize(Self.strippingDuplicateSuffix(audioName)) == target
        }
    }

    /// Drop a trailing " (1)", " (2)", … that macOS appends to disambiguate duplicate
    /// device names, leaving the underlying monitor name.
    static func strippingDuplicateSuffix(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else {
            return name
        }
        let inside = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        guard !inside.isEmpty, inside.allSatisfy(\.isNumber) else {
            return name
        }
        return String(trimmed[trimmed.startIndex..<open]).trimmingCharacters(in: .whitespaces)
    }

    /// Lowercase, alphanumerics only — so "DELL U2720Q" and "DELL-U2720Q" compare equal.
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
