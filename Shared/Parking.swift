import Foundation

struct Point: Codable, Equatable {
    var x: Double
    var y: Double

    func meters(to other: Point) -> Double {
        hypot((other.x-x)*88_000, (other.y-y)*111_000)
    }

    func nearest(on line: [Point]) -> (point: Point, distance: Double) {
        var best = (self, Double.infinity)
        for (a,b) in zip(line, line.dropFirst()) {
            let dx = (b.x-a.x)*88_000, dy = (b.y-a.y)*111_000
            let t = min(1, max(0, ((x-a.x)*88_000*dx + (y-a.y)*111_000*dy) / max(dx*dx+dy*dy, 0.000001)))
            let p = Point(x: a.x+t*(b.x-a.x), y: a.y+t*(b.y-a.y))
            let d = meters(to: p)
            if d < best.1 { best = (p,d) }
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
        ["N":"North","S":"South","E":"East","W":"West","NE":"Northeast","NW":"Northwest","SE":"Southeast","SW":"Southwest"][side] ?? side
    }
    var title: String { "\(sideName) side of \(street.capitalized)" }
    var crossStreets: String { [cross1, cross2].filter { !$0.isEmpty }.map(\.capitalized).joined(separator:" and ") }
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
}
struct Verdict {
    var event: Event
    var caution: String?
    var sweep: Event?
    var paid = false
    func title(at now: Date) -> String {
        if event.date <= now { return "Move now" }
        return caution == nil ? "Move by" : "Check signs"
    }
}
enum Parking {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier:"America/Los_Angeles")!
        return c
    }()
    static func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year,.month,.day], from:date)
        return String(format:"%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    static func day(_ date: Date, plus n: Int) -> Date {
        calendar.date(byAdding:.day,value:n,to:calendar.startOfDay(for:date))!
    }
    static func clock(_ minutes: Int, on date: Date) -> Date {
        if minutes == 1440 { return day(date,plus:1) }
        return calendar.date(bySettingHour:minutes/60,minute:minutes%60,second:0,of:date)!
    }
    static func evaluate(_ session: Session, now: Date, permit: String = "", holidays: [String:Set<String>] = [:], stale: Bool = false, lookAhead: Int = 100, assumePaymentOnArrival: Bool = false) -> Verdict {
        var result = Verdict(event:Event(date:session.arrival.addingTimeInterval(72*3600),reason:"72-hour street parking limit"))
        if session.curb == nil || session.curb?.rules.isEmpty == true { result.caution = "Curb rules unavailable" }
        if stale { result.caution = "City data needs an update" }
        func consider(_ date: Date, _ reason: String) {
            if date < result.event.date || (date == result.event.date && reason != result.event.reason && reason == "Street cleaning") {
                result.event = Event(date:date,reason:reason)
            }
        }
        if let minutes = session.postedLimit { consider(session.arrival.addingTimeInterval(Double(minutes)*60),"Posted sign limit") }
        if let a=session.postedStart, let b=session.postedEnd, b>now { consider(a,"Posted no-parking window") }
        if let paid=session.paidUntil { consider(paid,"Meter payment expires") }
        let rules=session.curb?.rules ?? []
        for rule in rules {
            let samePermit = !permit.isEmpty && rule.permit?.uppercased()==permit.uppercased()
            if samePermit && ["park","paid"].contains(rule.kind) { continue }
            if rule.kind == "park" && (rule.limit ?? 4320) >= 4320 { continue }
            let horizon = rule.kind=="sweep" ? lookAhead : 4
            var intervals: [(Date, Date)] = []
            for offset in -1...horizon {
                let date = day(now,plus:offset)
                let c=calendar.dateComponents([.weekday,.day,.month],from:date)
                guard rule.days?.contains(c.weekday!-1) != false,
                      rule.weeks?.contains((c.day!-1)/7+1) != false, rule.months?.contains(c.month!) != false,
                      rule.dates?.contains(c.day!) != false else { continue }
                let key = dayKey(date)
                if let first=rule.first, key<first { continue }
                if let last=rule.last, key>last { continue }
                let start=rule.start ?? 0, end=rule.end ?? 1440
                let exception: String
                switch rule.kind {
                case "sweep": exception = start < 360 ? "nightSweep" : "daySweep"
                case "park": exception = rule.permit != nil || rule.reason.contains("Residential") ? "residential" : "limit"
                default: exception = rule.kind
                }
                if holidays[key]?.contains(exception)==true { continue }
                let a=clock(start,on:date), b=clock(end,on:end<=start ? day(date,plus:1):date)
                if let previous=intervals.last, previous.1 == a {
                    intervals[intervals.count-1].1=b
                } else { intervals.append((a,b)) }
            }
            for (a,b) in intervals where b>now {
                switch rule.kind {
                case "unknown":
                    if a<=now { result.caution=rule.reason }
                case "sweep","ban":
                    if rule.kind=="sweep", result.sweep == nil || a<result.sweep!.date { result.sweep=Event(date:a,reason:rule.reason) }
                    consider(a,rule.reason)
                case "park","paid":
                    if rule.kind=="paid" {
                        if a<=now { result.paid=true }
                        if !(assumePaymentOnArrival && a <= now), session.paidUntil == nil || session.paidUntil! < a { consider(max(session.arrival,a),"Meter payment required") }
                    }
                    if let limit=rule.limit, limit<4320, session.postedLimit == nil || rule.kind=="paid" {
                        let expiry=max(session.arrival,a).addingTimeInterval(Double(limit)*60)
                        if expiry<b { consider(expiry,rule.kind=="paid" ? "Meter time limit" : rule.reason) }
                    }
                default: result.caution="Unrecognized curb policy"
                }
                if rule.kind != "unknown" { break }
            }
        }
        return result
    }

    static func reminders(_ verdict: Verdict, arrival: Date, now: Date) -> [String: Date] {
        let deadline=verdict.event.date
        var times=["deadline":max(now,deadline)]
        let lead=deadline.addingTimeInterval(-900)
        if lead>now { times["advance"]=lead }
        if let sweep=verdict.sweep, sweep.date>now, calendar.component(.hour,from:sweep.date)<9 {
            let evening=clock(1200,on:day(sweep.date,plus:-1))
            if evening>=arrival && evening>now && evening<deadline { times["evening"]=evening }
        }
        return times
    }
    static func confident(_ point: Point, accuracy: Double, curbs: [Curb]) -> Bool {
        guard let first=curbs.first, accuracy>0, accuracy<=10 else { return false }
        let d=point.nearest(on:first.line).distance
        let other=curbs.dropFirst().map { point.nearest(on:$0.line).distance }.min() ?? .infinity
        return d<=max(5,accuracy) && other-d>2*accuracy
    }
}

struct Glance: Codable {
    static let group = "group.com.danogutierrez.parkify"
    static var defaults: UserDefaults? { UserDefaults(suiteName:group) }
    var deadline: Date
    var reason: String
    var caution: Bool
    var arrival: Date
}
