import Foundation
import IOKit
import IOKit.hid
import TactionKit

public struct HIDError: Error, CustomStringConvertible {
    public let code: IOReturn
    public let operation: String

    public init(_ code: IOReturn, _ operation: String) {
        self.code = code
        self.operation = operation
    }

    public var description: String {
        "\(operation) failed: \(HIDError.name(for: code)) (0x\(String(UInt32(bitPattern: code), radix: 16)))"
    }

    public static func name(for code: IOReturn) -> String {
        switch code {
        case kIOReturnSuccess: return "kIOReturnSuccess"
        case kIOReturnNotPermitted: return "kIOReturnNotPermitted (Input Monitoring not granted?)"
        case kIOReturnExclusiveAccess: return "kIOReturnExclusiveAccess (another process holds the device)"
        case kIOReturnNotOpen: return "kIOReturnNotOpen"
        case kIOReturnNoDevice: return "kIOReturnNoDevice"
        case kIOReturnUnsupported: return "kIOReturnUnsupported"
        case kIOReturnBadArgument: return "kIOReturnBadArgument"
        case kIOReturnTimeout: return "kIOReturnTimeout"
        case kIOReturnNotResponding: return "kIOReturnNotResponding"
        case kIOReturnError: return "kIOReturnError"
        default: return "IOReturn"
        }
    }
}

public enum HostClock {
    /// Monotonic host time in nanoseconds, the same clock the fixtures use.
    public static func nowNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    public static func nowSeconds() -> Double { Double(nowNanoseconds()) / 1_000_000_000 }
}

/// One `IOHIDDevice` for the panel: properties, open and close, feature reports, and the
/// input report stream. The device must belong to a `PanelWatcher` that has been scheduled on
/// a run loop; IOHIDManager schedules its devices on the same run loop, so no per-device
/// scheduling call is made here.
public final class PanelDevice {
    public let device: IOHIDDevice
    private var buffer: UnsafeMutablePointer<UInt8>?
    private var bufferSize = 0
    private var handler: (([UInt8], Double) -> Void)?
    public private(set) var isOpen = false
    public private(set) var isSeized = false

    public init(_ device: IOHIDDevice) {
        self.device = device
    }

    deinit {
        stopReports()
        if isOpen { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
    }

    // MARK: Properties

    public func intProperty(_ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    public func stringProperty(_ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    public var vendorID: Int? { intProperty(kIOHIDVendorIDKey) }
    public var productID: Int? { intProperty(kIOHIDProductIDKey) }
    public var versionNumber: Int? { intProperty(kIOHIDVersionNumberKey) }
    public var locationID: Int? { intProperty(kIOHIDLocationIDKey) }
    public var product: String? { stringProperty(kIOHIDProductKey) }
    public var manufacturer: String? { stringProperty(kIOHIDManufacturerKey) }
    public var serialNumber: String? { stringProperty(kIOHIDSerialNumberKey) }
    public var transport: String? { stringProperty(kIOHIDTransportKey) }
    public var primaryUsagePage: Int? { intProperty(kIOHIDPrimaryUsagePageKey) }
    public var primaryUsage: Int? { intProperty(kIOHIDPrimaryUsageKey) }
    public var maxInputReportSize: Int? { intProperty(kIOHIDMaxInputReportSizeKey) }
    public var maxFeatureReportSize: Int? { intProperty(kIOHIDMaxFeatureReportSizeKey) }

    public var reportDescriptor: [UInt8]? {
        guard let data = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data else { return nil }
        return [UInt8](data)
    }

    public var registryPath: String? {
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { return nil }
        var path = [CChar](repeating: 0, count: 512)
        guard IORegistryEntryGetPath(service, kIOServicePlane, &path) == KERN_SUCCESS else { return nil }
        return String(cString: path)
    }

    public var summary: String {
        let vid = vendorID.map { String(format: "0x%04x", $0) } ?? "?"
        let pid = productID.map { String(format: "0x%04x", $0) } ?? "?"
        let loc = locationID.map { String(format: "0x%08x", $0) } ?? "?"
        let usage = "\(primaryUsagePage.map { String(format: "0x%02x", $0) } ?? "?")/\(primaryUsage.map { String(format: "0x%02x", $0) } ?? "?")"
        return "\(product ?? "(no product string)") vid=\(vid) pid=\(pid) loc=\(loc) usage=\(usage) maxInput=\(maxInputReportSize ?? -1)"
    }

    // MARK: Open / close

    public func open(seize: Bool) throws {
        let options = IOOptionBits(seize ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone)
        let r = IOHIDDeviceOpen(device, options)
        guard r == kIOReturnSuccess else { throw HIDError(r, seize ? "IOHIDDeviceOpen(seize)" : "IOHIDDeviceOpen") }
        isOpen = true
        isSeized = seize
    }

    public func close() {
        stopReports()
        guard isOpen else { return }
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = false
        isSeized = false
    }

    // MARK: Feature reports

    /// Send a feature report. `payload` excludes the report ID; this prepends it.
    ///
    /// Verified on the panel 2026-09-15: IOHIDFamily passes the buffer through as the USB
    /// SET_REPORT data stage, which per the HID spec begins with the report ID when the device
    /// uses IDs. A 2-byte `02 01` was silently ignored; the 3-byte `05 02 01` is required.
    public func setFeature(reportID: UInt8, payload: [UInt8]) throws {
        let report = [reportID] + payload
        let r = report.withUnsafeBufferPointer { buf in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), buf.baseAddress!, buf.count)
        }
        guard r == kIOReturnSuccess else { throw HIDError(r, "IOHIDDeviceSetReport(feature \(reportID))") }
    }

    /// Read a feature report. Returns the payload without the report ID byte.
    /// The device returns the ID as the first byte (observed `0e 0a 00` for report 0x0E); it is stripped here.
    public func getFeature(reportID: UInt8, maxLength: Int = 64) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: maxLength)
        var length = CFIndex(maxLength)
        let r = buf.withUnsafeMutableBufferPointer { p in
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), p.baseAddress!, &length)
        }
        guard r == kIOReturnSuccess else { throw HIDError(r, "IOHIDDeviceGetReport(feature \(reportID))") }
        let raw = Array(buf.prefix(Int(length)))
        if raw.first == reportID { return Array(raw.dropFirst()) }
        return raw
    }

    /// The one setup step the panel needs: switch to multi-input reporting.
    public func setMultiTouchMode() throws {
        try setFeature(reportID: DeviceMode.reportID, payload: DeviceMode.payload(mode: DeviceMode.multiInput))
    }

    // MARK: Input reports

    /// Start delivering input reports. Each callback gets the report bytes (report ID first)
    /// and the host arrival time in seconds. Delivered on the run loop the watcher is scheduled on.
    public func startReports(_ handler: @escaping ([UInt8], Double) -> Void) {
        stopReports()
        let size = max(maxInputReportSize ?? 64, ReportLayout.length)
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        buf.initialize(repeating: 0, count: size)
        buffer = buf
        bufferSize = size
        self.handler = handler
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buf, CFIndex(size), PanelDevice.reportCallback, context)
    }

    public func stopReports() {
        guard let buf = buffer else { return }
        // Passing a null callback unregisters.
        IOHIDDeviceRegisterInputReportCallback(device, buf, CFIndex(bufferSize), nil, nil)
        buf.deallocate()
        buffer = nil
        bufferSize = 0
        handler = nil
    }

    private static let reportCallback: IOHIDReportCallback = { context, result, _, _, _, report, length in
        guard result == kIOReturnSuccess, let context = context, length > 0 else { return }
        let me = Unmanaged<PanelDevice>.fromOpaque(context).takeUnretainedValue()
        let t = HostClock.nowSeconds()
        let bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
        me.handler?(bytes, t)
    }
}
