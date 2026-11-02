import Foundation
import IOKit

// Мінімальний читач SMC — лише щоб дістати температуру батареї (у ioreg її більше немає).
private struct SMCVersion { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
private struct SMCPLimitData { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
private struct SMCKeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, attributes: UInt8 = 0 }
private struct SMCParam {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimit = SMCPLimitData()
    var keyInfo = SMCKeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

final class SMC {
    static let shared = SMC()
    private var conn: io_connect_t = 0

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
    }

    private func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private func call(_ input: inout SMCParam) -> SMCParam? {
        var output = SMCParam()
        var size = MemoryLayout<SMCParam>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCParam>.stride, &output, &size)
        return (r == kIOReturnSuccess && output.result == 0) ? output : nil
    }

    /// Тип і розмір ключа; nil — ключа на цьому Mac немає.
    func info(_ key: String) -> (type: UInt32, size: UInt32)? {
        guard conn != 0 else { return nil }
        var p = SMCParam(); p.key = fourCC(key); p.data8 = 9
        guard let i = call(&p) else { return nil }
        return (i.keyInfo.dataType, i.keyInfo.dataSize)
    }

    func readBytes(_ key: String) -> [UInt8]? {
        guard let i = info(key) else { return nil }
        var q = SMCParam(); q.key = fourCC(key); q.keyInfo.dataSize = i.size; q.data8 = 5
        guard let out = call(&q) else { return nil }
        return withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(i.size))) }
    }

    /// Запис ключа. Працює лише від root (для звичайного користувача SMC відповідає «not privileged»).
    @discardableResult
    func write(_ key: String, _ bytes: [UInt8]) -> Bool {
        guard let i = info(key) else { return false }
        var p = SMCParam(); p.key = fourCC(key); p.data8 = 6; p.keyInfo.dataSize = i.size
        withUnsafeMutableBytes(of: &p.bytes) { buf in
            for (j, b) in bytes.prefix(Int(i.size)).enumerated() { buf[j] = b }
        }
        return call(&p) != nil
    }

    /// Значення ключа як Double (підтримує flt і sp78).
    func read(_ key: String) -> Double? {
        guard conn != 0 else { return nil }
        var p = SMCParam(); p.key = fourCC(key); p.data8 = 9
        guard let info = call(&p) else { return nil }
        var q = SMCParam(); q.key = fourCC(key); q.keyInfo.dataSize = info.keyInfo.dataSize; q.data8 = 5
        guard let out = call(&q) else { return nil }
        let b = out.bytes
        switch info.keyInfo.dataType {
        case fourCC("flt "):
            let bits = UInt32(b.0) | UInt32(b.1) << 8 | UInt32(b.2) << 16 | UInt32(b.3) << 24
            return Double(Float(bitPattern: bits))
        case fourCC("sp78"):
            return Double(Int16(bitPattern: UInt16(b.0) << 8 | UInt16(b.1))) / 256
        default:
            return nil
        }
    }

    /// Струм заряду просто зараз, мА (CHBI, ui32 у little-endian), читається без root.
    /// Перевірено лише на прошивках із межею (bfF0): на інших сенс ключа не підтверджений, тож там nil.
    func chargeCurrent() -> Int? {
        guard info("bfF0") != nil, let b = readBytes("CHBI"), b.count == 4 else { return nil }
        return Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
    }

    /// Температура батареї, °C — середнє з датчиків, що відповідають.
    func batteryTemperature() -> Double? {
        let vals = ["TB0T", "TB1T", "TB2T"].compactMap { read($0) }.filter { $0 > 0 && $0 < 90 }
        return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }
}
