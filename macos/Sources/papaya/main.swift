import Foundation
import PapayaCore

// papaya — command-line reader, handy over SSH.
//   papaya              human summary
//   papaya --json       battery + UPS as JSON
//   papaya --raw        every IORegistry key of the battery
//   papaya --nut host[:port]   also read a NUT server
//   papaya --metrics    Prometheus exposition (what the app pushes)
//   papaya --ios        iPhone / iPad batteries (USB and Wi-Fi)
//   papaya --peers      other computers running PapayaPower (network key: PAPAYA_KEY env)

let args = CommandLine.arguments.dropFirst()
var nutHosts: [String] = []
var it = args.makeIterator()
var flags = Set<String>()
while let a = it.next() {
    if a == "--nut", let h = it.next() { nutHosts.append(h) } else { flags.insert(a) }
}

if flags.contains("--peers") {
    let b = PeerBrowser(ownName: "")
    b.start()
    RunLoop.main.run(until: Date().addingTimeInterval(4))
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var results: [String: Result<PeerReadings, Error>] = [:]
    let key = ProcessInfo.processInfo.environment["PAPAYA_KEY"] ?? ""
    Task { results = await b.fetchAll(key: key); sem.signal() }
    sem.wait()
    if results.isEmpty { print("No PapayaPower found on the local network.") }
    for (name, r) in results.sorted(by: { $0.key < $1.key }) {
        switch r {
        case .success(let p):
            print("== \(name) — \(p.platform), PapayaPower \(p.version)")
            for x in p.batteries {
                print("   \(x.deviceName): " + [x.chargePercent.map { Format.percent($0, digits: 0) },
                    x.health.map { "health " + Format.percent($0 * 100) }, x.cycleCount.map { "\($0) cycles" }]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            for u in p.ups { print("   UPS \(u.name): \(u.chargePercent.map { Format.percent($0, digits: 0) } ?? "?") \(u.status ?? "")") }
        case .failure(let e):
            print("== \(name) — unreachable: \(e.localizedDescription)")
        }
    }
    exit(0)
}

let battery = MacBattery.read()
var ups = LocalUPS.read()
for h in nutHosts {
    let parts = h.split(separator: ":")
    let client = NUTClient(host: String(parts[0]), port: parts.count > 1 ? UInt16(parts[1]) ?? 3493 : 3493)
    do { ups += try client.read() } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)) }
}
var ios: [BatterySnapshot] = []
if flags.contains("--ios") {
    ios = IOSDevices.shared.readAll(timeout: 8)
}

if flags.contains("--raw") {
    for (k, v) in (battery?.raw ?? [:]).sorted(by: { $0.key < $1.key }) { print("\(k) = \(v)") }
    exit(0)
}
if flags.contains("--json") {
    struct Out: Encodable { var battery: BatterySnapshot?; var ios: [BatterySnapshot]; var ups: [UPSSnapshot] }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    var b = battery
    b?.raw = [:]
    let iosSlim = ios.map { var x = $0; x.raw = [:]; return x }
    print(String(decoding: try enc.encode(Out(battery: b, ios: iosSlim, ups: ups)), as: UTF8.self))
    exit(0)
}
if flags.contains("--metrics") {
    print(Pushgateway.exposition(battery: [battery].compactMap { $0 } + ios, ups: ups), terminator: "")
    exit(0)
}

func line(_ k: String, _ v: String?) { if let v { print(k.padding(toLength: 24, withPad: " ", startingAt: 0) + v) } }

for b in [battery].compactMap({ $0 }) + ios {
    print("== \(b.deviceName) (\(b.marketingName ?? b.model ?? "?")) — \(b.osVersion ?? "")")
    line("Charge", b.chargePercent.map { Format.percent($0) })
    line("Current / full", b.currentCapacity.flatMap { c in b.fullChargeCapacity.map { "\(c) / \($0) mAh" } })
    line("Design capacity", b.designCapacity.map(Format.mah))
    line("Health", b.health.map { Format.percent($0 * 100) })
    line("Cycles", b.cycleCount.map { c in b.designCycleCount.map { "\(c) / \($0)" } ?? "\(c)" })
    line("Temperature", b.temperature.map(Format.temperature))
    line("Battery power", b.batteryWatts.map(Format.watts))
    line("Adapter", b.adapterWatts.map { "\($0) W \(b.adapterName ?? "")" })
    line("Time to empty", b.timeToEmpty.map(Format.minutes))
    line("Time to full", b.timeToFull.map(Format.minutes))
    line("Battery made", b.batteryManufactureDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none) })
    line("Battery manufacturer", b.batteryManufacturer)
    line("Battery serial", b.batterySerial)
    if let l = b.lifetime {
        line("Lifetime temp min/avg/max", [l.minimumTemperature, l.averageTemperature, l.maximumTemperature]
            .map { $0.map { String(format: "%.1f", $0) } ?? "?" }.joined(separator: " / ") + " °C")
        line("Lifetime operating time", l.totalOperatingTime.map { "\($0) h" })
    }
    print()
}
if battery == nil { print("No internal battery.\n") }
for u in ups {
    print("== UPS \(u.name) — \(u.source)")
    line("Charge", u.chargePercent.map { Format.percent($0) })
    line("Status", u.status)
    line("Runtime", u.runtimeSeconds.map { Format.minutes($0 / 60) })
    line("Load", u.loadPercent.map { Format.percent($0, digits: 0) })
    print()
}
