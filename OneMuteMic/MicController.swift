import CoreAudio
import Foundation

final class MicController {
    enum Status {
        case live
        case muted
        case unsupported
    }

    private enum Mechanism {
        case mute
        case volume
        case none
    }

    private static let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    private static let volumeElements: [AudioObjectPropertyElement] = [
        kAudioObjectPropertyElementMain, 1, 2,
    ]

    private var deviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var mechanism: Mechanism = .none
    private var savedVolume: Float32 = 1
    private var registeredListeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress)] = []

    private(set) var status: Status = .unsupported
    var onChange: (() -> Void)?

    private lazy var listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.handleExternalChange()
    }

    init() {
        deviceID = Self.defaultInputDeviceID()
        mechanism = detectMechanism()
        refreshStatus()
        installListeners()
    }

    deinit {
        removeListeners()
    }

    @discardableResult
    func toggle() -> Bool {
        guard deviceID != kAudioObjectUnknown, let muted = currentMuted() else { return false }
        guard setMuted(!muted) else { return false }
        refreshStatus()
        return true
    }

    func reload() {
        deviceID = Self.defaultInputDeviceID()
        mechanism = detectMechanism()
        refreshStatus()
    }

    // MARK: - State

    private func currentMuted() -> Bool? {
        switch mechanism {
        case .mute:
            return readMuteProperty()
        case .volume:
            return (readVolumeProperty() ?? 1) <= 0.0001
        case .none:
            return nil
        }
    }

    private func setMuted(_ target: Bool) -> Bool {
        switch mechanism {
        case .mute:
            return writeMuteProperty(target)
        case .volume:
            if target {
                if let volume = readVolumeProperty(), volume > 0 {
                    savedVolume = volume
                }
                return writeVolumeProperty(0)
            }
            return writeVolumeProperty(savedVolume > 0 ? savedVolume : 1)
        case .none:
            return false
        }
    }

    private func refreshStatus() {
        if deviceID == kAudioObjectUnknown {
            status = .unsupported
        } else if let muted = currentMuted() {
            status = muted ? .muted : .live
        } else {
            status = .unsupported
        }
        onChange?()
    }

    // MARK: - Core Audio properties

    private func detectMechanism() -> Mechanism {
        guard deviceID != kAudioObjectUnknown else { return .none }
        var muteAddress = Self.inputAddress(kAudioDevicePropertyMute)
        if AudioObjectHasProperty(deviceID, &muteAddress) {
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceID, &muteAddress, &settable) == noErr,
               settable.boolValue {
                return .mute
            }
        }
        if readVolumeProperty() != nil { return .volume }
        return .none
    }

    private func readMuteProperty() -> Bool? {
        var address = Self.inputAddress(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value != 0
    }

    private func writeMuteProperty(_ muted: Bool) -> Bool {
        var address = Self.inputAddress(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private func readVolumeProperty() -> Float32? {
        for element in Self.volumeElements {
            var address = Self.inputAddress(kAudioDevicePropertyVolumeScalar, element: element)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }

    private func writeVolumeProperty(_ volume: Float32) -> Bool {
        var wrote = false
        for element in Self.volumeElements {
            var address = Self.inputAddress(kAudioDevicePropertyVolumeScalar, element: element)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var value = volume
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &value) == noErr {
                wrote = true
            }
        }
        return wrote
    }

    private static func inputAddress(_ selector: AudioObjectPropertySelector,
                                     element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeInput,
                                   mElement: element)
    }

    private static func defaultInputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let result = AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &size, &deviceID)
        return result == noErr ? deviceID : AudioDeviceID(kAudioObjectUnknown)
    }

    // MARK: - Listeners

    private func installListeners() {
        let defaultAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        addListener(object: Self.systemObjectID, address: defaultAddress)

        guard deviceID != kAudioObjectUnknown else { return }

        let muteAddress = Self.inputAddress(kAudioDevicePropertyMute)
        addListener(object: deviceID, address: muteAddress)

        for element in Self.volumeElements {
            let address = Self.inputAddress(kAudioDevicePropertyVolumeScalar, element: element)
            addListener(object: deviceID, address: address)
        }
    }

    private func addListener(object: AudioObjectID, address: AudioObjectPropertyAddress) {
        var address = address
        guard AudioObjectHasProperty(object, &address) || object == Self.systemObjectID else { return }
        AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, listenerBlock)
        registeredListeners.append((object, address))
    }

    private func removeListeners() {
        for entry in registeredListeners {
            var address = entry.address
            AudioObjectRemovePropertyListenerBlock(entry.object, &address,
                                                   DispatchQueue.main, listenerBlock)
        }
        registeredListeners.removeAll()
    }

    private func handleExternalChange() {
        let currentDefault = Self.defaultInputDeviceID()
        if currentDefault != deviceID {
            removeListeners()
            deviceID = currentDefault
            mechanism = detectMechanism()
            installListeners()
        }
        refreshStatus()
    }
}
