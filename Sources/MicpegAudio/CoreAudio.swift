// MicpegAudio — read-only CoreAudio helpers, shared by the daemon and the app.
//
// Extracted verbatim from the daemon's main.swift so there is exactly one place where
// the subtle parts live: takeRetainedValue() on every CFString getter,
// kAudioObjectPropertyElementMain rather than ...Master, and the input-scope
// kAudioDevicePropertyStreams query. Duplicating them into the app would create a
// second place to get them wrong.
//
// Two things are deliberately absent, and CI greps for both:
//   - setDefaultInputDevice: the single CoreAudio write in the project stays in the
//     daemon target, which is what keeps "the app writes nothing to CoreAudio" provable.
//   - anything naming the default OUTPUT: the app has to read it in order to display it,
//     but that read belongs to the app target, not here. See docs/app-design.md.

import CoreAudio
import Foundation

public let systemObject = AudioObjectID(kAudioObjectSystemObject)

public func addr(_ selector: AudioObjectPropertySelector,
                 _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    // kAudioObjectPropertyElementMain, not the deprecated ...Master.
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

public func fourCC(_ v: UInt32) -> String {
    if v == 0 { return "none" }
    let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                 UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    guard let s = String(bytes: bytes, encoding: .ascii),
          s.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) else {
        return String(v)
    }
    return s
}

public func osStatusText(_ st: OSStatus) -> String {
    "\(st) (\(fourCC(UInt32(bitPattern: st))))"
}

public func defaultInputDevice() -> AudioDeviceID? {
    var a = addr(kAudioHardwarePropertyDefaultInputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let st = AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &id)
    return (st == noErr && id != 0) ? id : nil
}

/// Resolve a UID straight to a device. Cheaper than enumerating, and we never
/// cache the resulting AudioDeviceID — it changes across replug and HAL resets.
public func deviceID(forUID uid: String) -> AudioDeviceID? {
    var a = addr(kAudioHardwarePropertyTranslateUIDToDevice)
    var cf = uid as CFString
    var out = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let st = withUnsafeMutablePointer(to: &cf) { p -> OSStatus in
        AudioObjectGetPropertyData(systemObject, &a,
                                   UInt32(MemoryLayout<CFString>.size), p,
                                   &size, &out)
    }
    return (st == noErr && out != 0) ? out : nil
}

/// CFString getters hand back a +1 reference — the caller owns it.
public func deviceString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var a = addr(selector)
    var unmanaged: Unmanaged<CFString>? = nil
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &unmanaged)
    guard st == noErr, let u = unmanaged else { return nil }
    return u.takeRetainedValue() as String
}

public func deviceUID(_ id: AudioDeviceID) -> String? {
    deviceString(id, kAudioDevicePropertyDeviceUID)
}

public func deviceName(_ id: AudioDeviceID) -> String {
    deviceString(id, kAudioObjectPropertyName) ?? "device \(id)"
}

public func transportType(_ id: AudioDeviceID) -> UInt32 {
    var a = addr(kAudioDevicePropertyTransportType)
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let st = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v)
    return st == noErr ? v : 0
}

/// The Wave:1 is 1-in / 2-out, so the scope discrimination here decides the answer.
/// Size-only query: no allocation.
public func hasInput(_ id: AudioDeviceID) -> Bool {
    var a = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    let st = AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size)
    return st == noErr && size > 0
}

public func allDevices() -> [AudioDeviceID] {
    var a = addr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &a, 0, nil, &size) == noErr else { return [] }
    let capacity = Int(size) / MemoryLayout<AudioDeviceID>.size
    guard capacity > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: capacity)
    // Trust the byte count the fetch reports, not the earlier size query: a device
    // unplugged between the two calls would otherwise leave trailing zero IDs.
    var written = size
    guard AudioObjectGetPropertyData(systemObject, &a, 0, nil, &written, &ids) == noErr else { return [] }
    let n = min(capacity, Int(written) / MemoryLayout<AudioDeviceID>.size)
    return ids.prefix(n).filter { $0 != 0 }
}

public let transportNames = ["bluetooth", "bluetoothle", "usb", "builtin",
                             "virtual", "aggregate", "displayport"]

public func transportCode(_ name: String) -> UInt32? {
    switch name.lowercased() {
    case "bluetooth":   return kAudioDeviceTransportTypeBluetooth
    case "bluetoothle": return kAudioDeviceTransportTypeBluetoothLE
    case "usb":         return kAudioDeviceTransportTypeUSB
    case "builtin":     return kAudioDeviceTransportTypeBuiltIn
    case "virtual":     return kAudioDeviceTransportTypeVirtual
    case "aggregate":   return kAudioDeviceTransportTypeAggregate
    case "displayport": return kAudioDeviceTransportTypeDisplayPort
    default:            return nil
    }
}
