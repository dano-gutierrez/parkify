import Foundation

struct Point: Codable, Equatable {
  var x: Double
  var y: Double

  func meters(to other: Point) -> Double {
    hypot((other.x - x) * 88_000, (other.y - y) * 111_000)
  }

  func nearest(on line: [Point]) -> (point: Point, distance: Double) {
    var best = (self, Double.infinity)
    for (a, b) in zip(line, line.dropFirst()) {
      let dx = (b.x - a.x) * 88_000
      let dy = (b.y - a.y) * 111_000
      let t = min(
        1,
        max(
          0, ((x - a.x) * 88_000 * dx + (y - a.y) * 111_000 * dy) / max(dx * dx + dy * dy, 0.000001)
        ))
      let p = Point(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))
      let d = meters(to: p)
      if d < best.1 { best = (p, d) }
    }
    return best
  }
}

struct Rule: Codable, Hashable {
  var kind: String
  var reason: String
  var days: [Int]? = nil
  var start: Int? = nil
  var end: Int? = nil
  var weeks: [Int]? = nil
  var months: [Int]? = nil
  var dates: [Int]? = nil
  var first: String? = nil
  var last: String? = nil
  var limit: Int? = nil
  var noReturn: Int? = nil
  var permit: String? = nil
}

struct Curb: Codable, Identifiable {
  var id: String
  var block: String
  var street: String
  var cross1: String
  var cross2: String
  var side: String
  var line: [Point]
  var rules: [Rule]
  var sideName: String {
    [
      "N": "North", "S": "South", "E": "East", "W": "West", "NE": "Northeast", "NW": "Northwest",
      "SE": "Southeast", "SW": "Southwest",
    ][side] ?? side
  }
  var title: String { "\(sideName) side of \(street.capitalized)" }
  var crossStreets: String {
    [cross1, cross2].filter { !$0.isEmpty }.map(\.capitalized).joined(separator: " and ")
  }
}

struct Session: Codable, Identifiable {
  var id = UUID()
  var point: Point
  var arrival: Date
  var curb: Curb?
  var paidUntil: Date?
  var postedLimit: Int?
  var postedStart: Date?
  var postedEnd: Date?
  var alarm = false
}

struct Event: Codable, Equatable {
  var date: Date
  var reason: String
  var until: Date? = nil
  var recurrence: String? = nil
  var requiresBlockMove = false
}
enum CurbStatus: String, CaseIterable {
  case free = "Free"
  case metered = "Metered"
  case prohibited = "No parking"
  case uncertain = "Check signs"
}

struct Verdict {
  var event: Event
  var caution: String?
  var sweep: Event?
  var paid = false
  func curbStatus(at now: Date) -> CurbStatus {
    if event.date <= now { return .prohibited }
    if caution != nil { return .uncertain }
    return paid ? .metered : .free
  }
  func title(at now: Date) -> String {
    if event.date <= now { return "Move now" }
    return caution == nil ? "Move by" : "Check signs"
  }
}
enum Parking {
  static let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
  }()
  static func dayKey(_ date: Date) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }
  static func day(_ date: Date, plus n: Int) -> Date {
    calendar.date(byAdding: .day, value: n, to: calendar.startOfDay(for: date))!
  }
  static func clock(_ minutes: Int, on date: Date) -> Date {
    if minutes == 1440 { return day(date, plus: 1) }
    return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: date)!
  }
  private static func intervals(
    for rule: Rule, now: Date, holidays: [String: Set<String>], horizon: Int
  ) -> [(Date, Date)] {
    var intervals: [(Date, Date)] = []
    for offset in -1...horizon {
      let date = day(now, plus: offset)
      let c = calendar.dateComponents([.weekday, .day, .month], from: date)
      guard rule.days?.contains(c.weekday! - 1) != false,
        rule.weeks?.contains((c.day! - 1) / 7 + 1) != false,
        rule.months?.contains(c.month!) != false,
        rule.dates?.contains(c.day!) != false
      else { continue }
      let key = dayKey(date)
      if let first = rule.first, key < first { continue }
      if let last = rule.last, key > last { continue }
      let start = rule.start ?? 0
      let end = rule.end ?? 1440
      let exception: String
      switch rule.kind {
      case "sweep":
        exception =
          start < 360 && end <= 360
          ? "nightSweep"
          : ((2...6).contains(c.weekday!) && (360..<840).contains(start)
            ? "daySweep" : "otherSweep")
      case "park":
        exception =
          rule.permit != nil || rule.reason.contains("Residential") ? "residential" : "limit"
      default: exception = rule.kind
      }
      if holidays[key]?.contains(exception) == true { continue }
      let a = clock(start, on: date)
      let b = clock(end, on: end <= start ? day(date, plus: 1) : date)
      if let previous = intervals.last, previous.1 == a {
        intervals[intervals.count - 1].1 = b
      } else {
        intervals.append((a, b))
      }
    }
    return intervals
  }
  static func evaluate(
    _ session: Session, now: Date, permit: String = "", holidays: [String: Set<String>] = [:],
    stale: Bool = false, lookAhead: Int = 100, assumePaymentOnArrival: Bool = false
  ) -> Verdict {
    var result = Verdict(
      event: Event(
        date: session.arrival.addingTimeInterval(72 * 3600), reason: "72-hour street parking limit", requiresBlockMove: true)
    )
    if session.curb == nil || session.curb?.rules.isEmpty == true {
      result.caution = "Curb rules unavailable"
    }
    if stale { result.caution = "City data needs an update" }
    func consider(_ date: Date, _ reason: String, blockMove: Bool = false) {
      if date < result.event.date
        || (date == result.event.date && reason != result.event.reason
          && reason == "Street cleaning")
      {
        result.event = Event(date: date, reason: reason, requiresBlockMove: blockMove || (date == result.event.date && result.event.requiresBlockMove))
      } else if date == result.event.date && blockMove {
        result.event.requiresBlockMove = true
      }
    }
    if let minutes = session.postedLimit {
      consider(session.arrival.addingTimeInterval(Double(minutes) * 60), "Posted sign limit", blockMove: true)
    }
    if let a = session.postedStart, let b = session.postedEnd, b > now {
      consider(a, "Posted no-parking window")
    }
    if let paid = session.paidUntil { consider(paid, "Meter payment expires") }
    let rules = session.curb?.rules ?? []
    let confirmedParking = rules.contains { rule in
      guard rule.kind == "park" || rule.kind == "paid" || (rule.kind == "permit" && rule.permit == permit) else { return false }
      return intervals(for: rule, now: now, holidays: [:], horizon: 0).contains { $0.0 <= now && now < $0.1 }
    }
    if !confirmedParking && result.caution == nil {
      result.caution = "No general parking policy confirmed for this time"
    }
    let grants = rules.filter { $0.kind == "permit" && $0.permit == permit && !permit.isEmpty }
      .flatMap { intervals(for: $0, now: now, holidays: holidays, horizon: 4) }
    for rule in rules {
      if rule.kind == "permit" { continue }
      let samePermit = !permit.isEmpty && rule.permit?.uppercased() == permit.uppercased()
      if samePermit && ["park", "paid"].contains(rule.kind) { continue }
      if rule.kind == "park" && (rule.limit ?? 4320) >= 4320 { continue }
      let horizon = rule.kind == "sweep" ? lookAhead : 4
      let windows = intervals(for: rule, now: now, holidays: holidays, horizon: horizon)
      for (a, b) in windows where b > now {
        switch rule.kind {
        case "unknown":
          if a <= now { result.caution = rule.reason }
        case "sweep", "ban":
          if rule.kind == "sweep", result.sweep == nil || a < result.sweep!.date {
            let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let weekdays = (rule.days ?? []).compactMap { names.indices.contains($0) ? names[$0] : nil }
            let ordinals = ["1st", "2nd", "3rd", "4th", "5th"]
            let weeks = (rule.weeks ?? []).compactMap { (1...5).contains($0) ? ordinals[$0-1] : nil }
            let modifier = weeks.isEmpty || weeks.count == 5 ? "" : weeks.joined(separator: " & ") + " "
            result.sweep = Event(date: a, reason: rule.reason, until: b, recurrence: modifier + weekdays.joined(separator: ", "))
          }
          consider(a, rule.reason)
        case "park", "paid":
          if grants.contains(where: { $0.0 <= max(a, now) && $0.1 >= b }) { continue }
          if rule.kind == "paid" {
            if a <= now { result.paid = true }
            if !(assumePaymentOnArrival && a <= now),
              session.paidUntil == nil || session.paidUntil! < a
            {
              consider(max(session.arrival, a), "Meter payment required")
            }
          }
          if let limit = rule.limit, limit < 4320, session.postedLimit == nil || rule.kind == "paid"
          {
            let expiry = max(session.arrival, a).addingTimeInterval(Double(limit) * 60)
            if expiry < b {
              consider(expiry, rule.kind == "paid" ? "Meter time limit" : rule.reason, blockMove: true)
            }
          }
        default: result.caution = "Unrecognized curb policy"
        }
        if rule.kind != "unknown" { break }
      }
    }
    return result
  }

  static func canRelocate(from current: Curb?, to next: Curb, distance: Double, requiresBlockMove: Bool) -> Bool {
    guard distance >= 4, current?.id != next.id else { return false }
    guard requiresBlockMove && distance < 161 else { return true }
    guard let current, !current.cross1.isEmpty, !current.cross2.isEmpty,
          !next.cross1.isEmpty, !next.cross2.isEmpty else { return false }
    return current.street != next.street || Set([current.cross1,current.cross2]) != Set([next.cross1,next.cross2])
  }

  static func suggestedAlarm(for deadline: Date, now: Date) -> Date {
    let advance = deadline.addingTimeInterval(-900)
    return advance > now ? advance : deadline
  }

  static func reminders(_ verdict: Verdict, arrival: Date, now: Date) -> [String: Date] {
    let deadline = verdict.event.date
    var times = ["deadline": max(now, deadline)]
    let lead = deadline.addingTimeInterval(-900)
    if lead > now { times["advance"] = lead }
    if let sweep = verdict.sweep, sweep.date > now, calendar.component(.hour, from: sweep.date) < 9
    {
      let evening = clock(1200, on: day(sweep.date, plus: -1))
      if evening >= arrival && evening > now && evening < deadline { times["evening"] = evening }
    }
    return times
  }
  static func confident(_ point: Point, accuracy: Double, curbs: [Curb]) -> Bool {
    guard let first = curbs.first, accuracy > 0, accuracy <= 10 else { return false }
    let d = point.nearest(on: first.line).distance
    let other = curbs.dropFirst().map { point.nearest(on: $0.line).distance }.min() ?? .infinity
    return d <= max(5, accuracy) && other - d > 2 * accuracy
  }
}

struct Glance: Codable {
  static let group = "group.com.danogutierrez.parkify"
  static var defaults: UserDefaults? { UserDefaults(suiteName: group) }
  var deadline: Date
  var reason: String
  var caution: Bool
  var arrival: Date
}
