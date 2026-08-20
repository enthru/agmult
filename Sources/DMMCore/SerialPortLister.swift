import Foundation
import IOKit
import IOKit.serial

/// One entry in the port picker — the macOS equivalent of the Windows
/// "COM5 - USB-SERIAL CH340 (COM5)" list built from WMI in the original.
public struct SerialPortInfo: Identifiable, Hashable, Sendable {
    /// Callout device path, e.g. `/dev/cu.usbserial-1410`.
    public let path: String
    /// Human readable name pulled from the IORegistry, e.g. "USB-SERIAL CH340".
    public let name: String

    public var id: String { path }

    /// Short form shown in the list: `cu.usbserial-1410 — USB-SERIAL CH340`.
    public var display: String {
        let short = (path as NSString).lastPathComponent
        return name.isEmpty ? short : "\(short) — \(name)"
    }

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

public enum SerialPortLister {
    /// Enumerates callout (`/dev/cu.*`) serial devices.
    ///
    /// Callout devices are the right choice for instrument control: unlike the
    /// matching `/dev/tty.*` dial-in device they do not block waiting for DCD.
    public static func list() -> [SerialPortInfo] {
        var found = ioRegistryPorts()

        // Anything the IORegistry sweep missed (virtual ports, ptys handed to us
        // by the built-in simulator) still shows up as a device node.
        for path in devicePaths() where !found.contains(where: { $0.path == path }) {
            found.append(SerialPortInfo(path: path, name: ""))
        }

        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func devicePaths() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return entries
            .filter { $0.hasPrefix("cu.") }
            .map { "/dev/" + $0 }
    }

    private static func ioRegistryPorts() -> [SerialPortInfo] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        let dictionary = matching as NSMutableDictionary
        dictionary[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, dictionary as CFDictionary, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var ports: [SerialPortInfo] = []
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard let path = stringProperty(service, kIOCalloutDeviceKey) else { continue }
            ports.append(SerialPortInfo(path: path, name: friendlyName(for: service)))
        }
        return ports
    }

    /// Walks up the USB/serial device tree looking for a name a human recognises.
    private static func friendlyName(for service: io_object_t) -> String {
        let candidates = ["USB Product Name", "Product Name", kIOTTYDeviceKey]
        for key in candidates {
            if let value = searchProperty(service, key), !value.isEmpty {
                return value
            }
        }
        var name = [CChar](repeating: 0, count: Int(MemoryLayout<io_name_t>.size))
        if IORegistryEntryGetName(service, &name) == KERN_SUCCESS {
            return String(cString: name)
        }
        return ""
    }

    private static func stringProperty(_ service: io_object_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return value.takeRetainedValue() as? String
    }

    private static func searchProperty(_ service: io_object_t, _ key: String) -> String? {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options) else {
            return nil
        }
        return value as? String
    }
}
