import CoreFoundation
import Darwin
import Foundation
import IOKit

private typealias HIDCreate = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
private typealias HIDCreateWithType = @convention(c) (CFAllocator?, Int32, CFDictionary?) -> UnsafeMutableRawPointer?
private typealias HIDSetMatching = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Void
private typealias HIDCopyServices = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
private typealias HIDCopyProperty = @convention(c) (UnsafeMutableRawPointer, CFString) -> UnsafeMutableRawPointer?
private typealias HIDCopyEvent = @convention(c) (UnsafeMutableRawPointer, Int64, Int64, Int64) -> UnsafeMutableRawPointer?
private typealias HIDGetFloatValue = @convention(c) (UnsafeMutableRawPointer, UInt32) -> Double

private final class HIDSymbols {
    let handle: UnsafeMutableRawPointer
    let create: HIDCreate
    let createWithType: HIDCreateWithType
    let setMatching: HIDSetMatching
    let copyServices: HIDCopyServices
    let copyProperty: HIDCopyProperty
    let copyEvent: HIDCopyEvent
    let getFloatValue: HIDGetFloatValue

    init?() {
        let path = "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        guard
            let create: HIDCreate = load(handle, "IOHIDEventSystemClientCreate"),
            let createWithType: HIDCreateWithType = load(handle, "IOHIDEventSystemClientCreateWithType"),
            let setMatching: HIDSetMatching = load(handle, "IOHIDEventSystemClientSetMatching"),
            let copyServices: HIDCopyServices = load(handle, "IOHIDEventSystemClientCopyServices"),
            let copyProperty: HIDCopyProperty = load(handle, "IOHIDServiceClientCopyProperty"),
            let copyEvent: HIDCopyEvent = load(handle, "IOHIDServiceClientCopyEvent"),
            let getFloatValue: HIDGetFloatValue = load(handle, "IOHIDEventGetFloatValue")
        else {
            dlclose(handle)
            return nil
        }
        self.handle = handle
        self.create = create
        self.createWithType = createWithType
        self.setMatching = setMatching
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.getFloatValue = getFloatValue
    }

    deinit {
        dlclose(handle)
    }
}

private func load<T>(_ handle: UnsafeMutableRawPointer, _ name: String) -> T? {
    guard let pointer = dlsym(handle, name) else { return nil }
    return unsafeBitCast(pointer, to: T.self)
}

private struct CachedHIDService {
    let object: AnyObject
    let displayName: String
    let identity: String
}

public final class HIDTemperatureCollector {
    private let symbols: HIDSymbols?
    private var client: AnyObject?
    private var services: [CachedHIDService] = []
    private var freshnessCache = HIDTemperatureFreshnessCache()
    private var nextServiceIndex = 0
    private let temperatureType: Int64 = 15
    private static let servicesPerWarmRead = 8

    static func maximumCacheAge(serviceCount: Int) -> Int {
        max(1, (max(0, serviceCount) + servicesPerWarmRead - 1) / servicesPerWarmRead)
    }

    public init() {
        symbols = HIDSymbols()
    }

    public func read() -> NativeCollectorResult<[TemperatureReading]> {
        guard let symbols else {
            return .unavailable(reason: "IOHID temperature symbols unavailable")
        }
        if let readings = readCurrentServices(using: symbols, fullScan: false), !readings.isEmpty {
            return .value(readings)
        }
        client = nil
        services = []
        freshnessCache.reset()
        nextServiceIndex = 0
        var sawReachableEmptyClient = false
        var sawAnyServices = false
        for clientType in Int32(0)...Int32(3) {
            guard let pointer = clientType == 0
                ? symbols.create(kCFAllocatorDefault)
                : symbols.createWithType(kCFAllocatorDefault, clientType, nil)
            else {
                continue
            }
            let candidate = Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue()
            let matching = [
                "PrimaryUsagePage": 0xFF00,
                "PrimaryUsage": 5,
            ] as CFDictionary
            symbols.setMatching(pointer, matching)
            guard let arrayPointer = symbols.copyServices(pointer) else { continue }
            let array = Unmanaged<CFArray>.fromOpaque(arrayPointer).takeRetainedValue()
            let candidateServices = (array as [AnyObject]).map { service in
                cachedService(service, using: symbols)
            }
            if candidateServices.isEmpty {
                sawReachableEmptyClient = true
                continue
            }
            sawAnyServices = true
            client = candidate
            services = candidateServices
            freshnessCache.reset()
            nextServiceIndex = 0
            if let readings = readCurrentServices(using: symbols, fullScan: true), !readings.isEmpty {
                return .value(readings)
            }
            client = nil
            services = []
            freshnessCache.reset()
            nextServiceIndex = 0
        }
        return HIDDiscoveryOutcome.finish(
            sawReachableEmptyClient: sawReachableEmptyClient,
            sawAnyServices: sawAnyServices
        )
    }

    private func readCurrentServices(
        using symbols: HIDSymbols,
        fullScan: Bool
    ) -> [TemperatureReading]? {
        guard client != nil, !services.isEmpty else { return nil }
        if !fullScan { freshnessCache.beginWarmRead() }
        let count = fullScan ? services.count : min(Self.servicesPerWarmRead, services.count)
        var indices: [Int] = []
        indices.reserveCapacity(count)
        for offset in 0..<count {
            indices.append(fullScan ? offset : (nextServiceIndex + offset) % services.count)
        }
        if !fullScan { nextServiceIndex = (nextServiceIndex + count) % services.count }

        var updateCount = 0
        let field = UInt32(temperatureType) << 16
        for index in indices {
            let service = services[index]
            let servicePointer = Unmanaged.passUnretained(service.object).toOpaque()
            guard let eventPointer = symbols.copyEvent(servicePointer, temperatureType, 0, 0) else {
                continue
            }
            let event = Unmanaged<AnyObject>.fromOpaque(eventPointer).takeRetainedValue()
            let value = symbols.getFloatValue(Unmanaged.passUnretained(event).toOpaque(), field)
            if value.isFinite, value > 0, value < 150 {
                freshnessCache.record(
                    identity: service.identity,
                    displayName: service.displayName,
                    celsius: value
                )
                updateCount += 1
            }
        }
        guard updateCount > 0 else { return nil }
        return freshnessCache.readings(maximumAge: Self.maximumCacheAge(serviceCount: services.count))
    }

    private func cachedService(_ service: AnyObject, using symbols: HIDSymbols) -> CachedHIDService {
        let pointer = Unmanaged.passUnretained(service).toOpaque()
        let name: String = {
            guard let value = symbols.copyProperty(pointer, "Product" as CFString) else {
                return "Unknown"
            }
            return Unmanaged<AnyObject>.fromOpaque(value).takeRetainedValue() as? String ?? "Unknown"
        }()
        let location: String = {
            guard let value = symbols.copyProperty(pointer, "LocationID" as CFString) else {
                return ""
            }
            let object = Unmanaged<AnyObject>.fromOpaque(value).takeRetainedValue()
            return (object as? NSNumber).map { "@\($0.uint64Value)" } ?? ""
        }()
        let displayName = name.replacingOccurrences(of: "|", with: "/")
        return CachedHIDService(object: service, displayName: displayName, identity: displayName + location)
    }
}

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private struct SMCFrame {
    let type: String
    let bytes: [UInt8]
}

public final class AppleSMCFanCollector {
    private var connection: io_connect_t = 0
    private var confirmedFanless = false

    public init() {}

    deinit {
        closeConnection()
    }

    public func read() -> NativeCollectorResult<FanCollection> {
        if confirmedFanless { return .value(.fanless) }
        guard ensureConnection() else {
            return .unavailable(reason: "AppleSMC unavailable")
        }
        guard let fanCountFrame = readKey("FNum") else {
            closeConnection()
            return .unavailable(reason: "AppleSMC fan count unavailable")
        }
        guard let fanCount = SMCFanCountDecoder.decode(
            type: fanCountFrame.type,
            bytes: fanCountFrame.bytes
        ) else {
            closeConnection()
            return .unavailable(reason: "AppleSMC fan count invalid")
        }
        if fanCount == 0 {
            confirmedFanless = true
            return .value(.fanless)
        }
        var fans: [FanReading] = []
        for index in 0..<fanCount {
            guard
                let current = readKey("F\(index)Ac"),
                let maximum = readKey("F\(index)Mx"),
                let rpm = SMCNumericDecoder.decode(type: current.type, bytes: current.bytes),
                let maximumRPM = SMCNumericDecoder.decode(type: maximum.type, bytes: maximum.bytes),
                rpm.isFinite,
                maximumRPM.isFinite,
                rpm >= 0,
                maximumRPM > 0
            else {
                continue
            }
            fans.append(FanReading(index: index, rpm: rpm, maximumRPM: maximumRPM))
        }
        guard fans.count == fanCount else {
            // A stale AppleSMC user client commonly survives sleep while its
            // fan keys stop responding. Reopen on the next accepted sample.
            closeConnection()
            return .unavailable(reason: "AppleSMC fan readings unavailable")
        }
        return .value(.fans(fans))
    }

    private func ensureConnection() -> Bool {
        if connection != 0 { return true }
        connection = 0
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess
    }

    private func closeConnection() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    private func readKey(_ text: String) -> SMCFrame? {
        let structureSize = MemoryLayout<SMCParamStruct>.stride
        var input = SMCParamStruct()
        input.key = fourCharacterCode(text)
        input.data8 = 9
        var output = SMCParamStruct()
        var outputSize = structureSize
        var result = IOConnectCallStructMethod(
            connection,
            UInt32(2),
            &input,
            structureSize,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess else { return nil }
        let keyInfo = output.keyInfo

        input.keyInfo = keyInfo
        input.data8 = 5
        output = SMCParamStruct()
        outputSize = structureSize
        result = IOConnectCallStructMethod(
            connection,
            UInt32(2),
            &input,
            structureSize,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess else { return nil }
        return SMCFrame(
            type: fourCharacterString(keyInfo.dataType),
            bytes: withUnsafeBytes(of: output.bytes) { Array($0.prefix(32)) }
        )
    }
}

private func fourCharacterCode(_ text: String) -> UInt32 {
    text.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
}

private func fourCharacterString(_ value: UInt32) -> String {
    String(bytes: [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ], encoding: .ascii) ?? ""
}
