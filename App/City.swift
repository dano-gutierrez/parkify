import CryptoKit
import Foundation

enum CityError: LocalizedError {
  case invalid(String)
  var errorDescription: String? {
    switch self {
    case .invalid(let message): return message
    }
  }
}
struct Part: Decodable {
  var name: String
  var bytes: Int
}
struct Manifest: Decodable {
  var schema: Int
  var sha256: String
  var bytes: Int
  var parts: [Part]
  var base: URL
  var zones: Int
}

final class City {
  static let manifestURL = URL(
    string: "https://github.com/dano-gutierrez/parkify/releases/latest/download/manifest.json")!
  static let directory = URL.applicationSupportDirectory.appending(
    path: "City", directoryHint: .isDirectory)
  static let database = directory.appending(path: "city.sqlite")
  private var db: OpaquePointer?
  let holidays: [String: Set<String>]
  let generated: String
  let towCoverage: Bool
  let curbAsOf: String
  var stale: Bool {
    generated < Parking.dayKey(Parking.day(.now, plus: -2))
      || curbAsOf < Parking.dayKey(Parking.day(.now, plus: -45))
  }
  init?(_ url: URL = City.database) {
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      sqlite3_close(db)
      return nil
    }
    var exceptions: [String: Set<String>] = [:]
    var dates: [String: String] = [:]
    City.query(db, "select day,exceptions from holiday") { row in
      exceptions[row(0)] = Set(
        (try? JSONDecoder().decode([String].self, from: Data(row(1).utf8))) ?? [])
    }
    City.query(db, "select name,value from meta") { dates[$0(0)] = $0(1) }
    towCoverage = (Int(dates["towRecords"] ?? "") ?? 0) > 0
    holidays = exceptions
    generated = dates["generated"] ?? ""
    curbAsOf = dates["curbAsOf"] ?? ""
    if generated.isEmpty || curbAsOf.isEmpty { return nil }
  }
  deinit { sqlite3_close(db) }

  private static func query(
    _ db: OpaquePointer?, _ sql: String, numbers: [Double] = [], text: String? = nil,
    _ body: ((_ col: Int32) -> String) -> Void
  ) {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    for (index, value) in numbers.enumerated() {
      sqlite3_bind_double(stmt, Int32(index + 1), value)
    }
    if let text {
      sqlite3_bind_text(stmt, 1, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    while sqlite3_step(stmt) == SQLITE_ROW {
      body { col in sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? "" }
    }
  }
  private func curbs(_ sql: String, numbers: [Double] = [], id: String? = nil) -> [Curb] {
    var values: [Curb] = []
    let decoder = JSONDecoder()
    Self.query(db, sql, numbers: numbers, text: id) { r in
      guard let row = Int(r(0)),
        let pairs = try? decoder.decode([[Double]].self, from: Data(r(8).utf8))
      else { return }
      let line = pairs.compactMap { $0.count == 2 ? Point(x: $0[0], y: $0[1]) : nil }
      guard line.count > 1 else { return }
      var rules: [Rule] = []
      Self.query(
        db, "select json from policy join applies on policy.id=applies.policy where zone=?",
        numbers: [Double(row)]
      ) { p in
        rules.append(
          (try? decoder.decode(Rule.self, from: Data(p(0).utf8)))
            ?? Rule(kind: "unknown", reason: "Unrecognized city rule"))
      }
      values.append(
        Curb(
          id: r(1), block: r(2), street: r(3), cross1: r(4), cross2: r(5), side: r(6), line: line,
          rules: rules))
    }
    return values
  }
  func nearby(_ p: Point, radius: Double) -> [Curb] {
    let sql =
      "select z.id,z.uuid,z.block,z.street,z.cross1,z.cross2,z.side,z.cnn,z.line from bounds b join zone z on z.id=b.id where b.minX<=? and b.maxX>=? and b.minY<=? and b.maxY>=?"
    return curbs(
      sql,
      numbers: [
        p.x + radius / 88000, p.x - radius / 88000, p.y + radius / 111000, p.y - radius / 111000,
      ]
    )
    .map { ($0, p.nearest(on: $0.line).distance) }.filter { $0.1 <= radius }.sorted { $0.1 < $1.1 }
    .map(\.0)
  }
  func curb(id: String) -> Curb? {
    curbs(
      "select z.id,z.uuid,z.block,z.street,z.cross1,z.cross2,z.side,z.cnn,z.line from zone z where uuid=?",
      id: id
    ).first
  }

  static func checkedDownload(_ url: URL) async throws -> URL {
    let (file, response) = try await URLSession.shared.download(from: url)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw CityError.invalid(
        "City data isn’t available yet. You can still mark a spot and enter a sign.")
    }
    return file
  }
  static func refresh() async throws -> Bool {
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let manifestFile = try await checkedDownload(manifestURL)
    defer { try? manager.removeItem(at: manifestFile) }
    let m = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestFile))
    let host = m.base.host ?? ""
    guard m.schema == 1, m.bytes > 0, m.bytes < 1_000_000_000, m.zones > 250000,
      m.base.scheme == "https", host == "github.com" || host.hasSuffix(".supabase.co"),
      !m.parts.isEmpty, m.parts.count <= 50
    else { throw CityError.invalid("Unrecognized city data release.") }
    if UserDefaults.standard.string(forKey: "citySHA") == m.sha256, City() != nil { return false }
    let scratch = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: scratch) }
    let archive = scratch.appending(path: "city.gz")
    let unpacked = scratch.appending(path: "city.sqlite")
    manager.createFile(atPath: archive.path, contents: nil)
    let out = try FileHandle(forWritingTo: archive)
    defer { try? out.close() }
    for part in m.parts {
      try Task.checkCancellation()
      guard part.name.range(of: "^[a-f0-9]{64}\\.gzpart$", options: .regularExpression) != nil,
        (1...22_000_000).contains(part.bytes)
      else { throw CityError.invalid("Invalid city data part.") }
      let file = try await checkedDownload(m.base.appending(path: part.name))
      defer { try? manager.removeItem(at: file) }
      let data = try Data(contentsOf: file, options: .mappedIfSafe)
      guard data.count == part.bytes, SHA256.hash(data: data).hex == String(part.name.prefix(64))
      else { throw CityError.invalid("City download was incomplete.") }
      try out.write(contentsOf: data)
    }
    try out.synchronize()
    guard let input = gzopen(archive.path, "rb") else {
      throw CityError.invalid("Couldn’t open city data.")
    }
    defer { gzclose(input) }
    manager.createFile(atPath: unpacked.path, contents: nil)
    let output = try FileHandle(forWritingTo: unpacked)
    defer { try? output.close() }
    var buffer = [UInt8](repeating: 0, count: 131072)
    var hash = SHA256()
    var size = 0
    while true {
      try Task.checkCancellation()
      let count = gzread(input, &buffer, 131072)
      if count == 0 { break }
      size += Int(count)
      guard count > 0, size <= m.bytes else { throw CityError.invalid("Damaged city database.") }
      let chunk = Data(buffer.prefix(Int(count)))
      hash.update(data: chunk)
      try output.write(contentsOf: chunk)
    }
    try output.synchronize()
    guard size == m.bytes, hash.finalize().hex == m.sha256, City(unpacked) != nil else {
      throw CityError.invalid("City database failed verification.")
    }
    if manager.fileExists(atPath: database.path) {
      _ = try manager.replaceItemAt(database, withItemAt: unpacked)
    } else {
      try manager.moveItem(at: unpacked, to: database)
    }
    var path = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? path.setResourceValues(values)
    UserDefaults.standard.set(m.sha256, forKey: "citySHA")
    return true
  }
}
extension SHA256.Digest {
  var hex: String { map { String(format: "%02x", $0) }.joined() }
}
