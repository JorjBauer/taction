import Foundation
import IOKit
import IOKit.hid
import TactionKit

/// Watches for the panel by USB vendor and product ID through IOHIDManager.
///
/// Uses the classic run loop scheduling. Devices enumerated by the manager are scheduled on
/// the same run loop, so `PanelDevice` callbacks arrive there too. Everything downstream
/// therefore runs on one thread, which is what the gesture engine expects.
public final class PanelWatcher {
    public var onMatch: ((PanelDevice) -> Void)?
    public var onRemove: ((PanelDevice) -> Void)?

    public let manager: IOHIDManager
    public private(set) var devices: [PanelDevice] = []
    private var runLoop: CFRunLoop?

    public init(vendorID: UInt32 = TactionConfig.vendorID, productID: UInt32 = TactionConfig.productID,
                usagePage: UInt32? = nil, usage: UInt32? = nil) {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        var matching: [String: Any] = [
            kIOHIDVendorIDKey: Int(vendorID),
            kIOHIDProductIDKey: Int(productID),
        ]
        if let usagePage = usagePage { matching[kIOHIDPrimaryUsagePageKey] = Int(usagePage) }
        if let usage = usage { matching[kIOHIDPrimaryUsageKey] = Int(usage) }
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
    }

    /// Synchronous snapshot of currently attached matching devices, without scheduling.
    public func currentDevices() -> [PanelDevice] {
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return set.map { PanelDevice($0) }.sorted { ($0.locationID ?? 0) < ($1.locationID ?? 0) }
    }

    /// Begin delivering match and removal callbacks on `runLoop`. Already attached devices
    /// produce a match callback shortly after this returns.
    public func start(runLoop: CFRunLoop = CFRunLoopGetMain()) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, PanelWatcher.matched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, PanelWatcher.removed, context)
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        self.runLoop = runLoop
        // Opening the manager is not required to receive reports from devices we open
        // individually, and opening it would claim every matching device at once.
    }

    public func stop() {
        if let rl = runLoop {
            IOHIDManagerUnscheduleFromRunLoop(manager, rl, CFRunLoopMode.defaultMode.rawValue)
            runLoop = nil
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        for d in devices { d.close() }
        devices = []
    }

    private static let matched: IOHIDDeviceCallback = { context, result, _, device in
        guard result == kIOReturnSuccess, let context = context else { return }
        let me = Unmanaged<PanelWatcher>.fromOpaque(context).takeUnretainedValue()
        if me.devices.contains(where: { $0.device === device }) { return }
        let pd = PanelDevice(device)
        me.devices.append(pd)
        me.onMatch?(pd)
    }

    private static let removed: IOHIDDeviceCallback = { context, _, _, device in
        guard let context = context else { return }
        let me = Unmanaged<PanelWatcher>.fromOpaque(context).takeUnretainedValue()
        guard let idx = me.devices.firstIndex(where: { $0.device === device }) else { return }
        let pd = me.devices.remove(at: idx)
        me.onRemove?(pd)
        pd.close()
    }
}

/// Input Monitoring (TCC service "ListenEvent") state for this process.
public enum InputMonitoring {
    public enum Status: String { case granted, denied, unknown }

    public static func status() -> Status {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user has not decided yet. Returns the new status.
    @discardableResult
    public static func request() -> Status {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        return status()
    }
}
