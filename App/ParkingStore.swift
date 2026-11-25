import SwiftUI
import MapKit
import CoreMotion
import BackgroundTasks
import UserNotifications

extension Point {
    var coordinate: CLLocationCoordinate2D { .init(latitude:y,longitude:x) }
    init(_ coordinate: CLLocationCoordinate2D) { self.init(x:coordinate.longitude,y:coordinate.latitude) }
}
struct Alternative: Identifiable {
    var curb: Curb
    var point: Point
    var verdict: Verdict
    var distance: Double
    var routed=false
    var id: String { curb.id }
}
struct Departure: Codable {
    let zone: String
    let block: String
    let point: Point
    let until: Date
}
@MainActor final class ParkingStore: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var session: Session?
    @Published var candidate: Stop?
    @Published var verdict: Verdict?
    @Published var fix: CLLocation?
    @Published var dataStatus="Loading city data…"
    @Published var alertStatus=""
    @Published var alarmStatus=""
    @Published var locatingStatus=""
    @Published var selecting=false
    @Published var selected: Point?
    @Published var options: [Curb]=[]
    @Published var chosen: Curb?
    @Published var alternatives: [Alternative]=[]
    @Published var finding=false
    @Published var refreshing=false
    @Published var auto=UserDefaults.standard.bool(forKey:"autoParking")
    @Published var permit=UserDefaults.standard.string(forKey:"permit") ?? ""
    let drive=DriveDetector()
    var city=City()
    private var alertTask: Task<Void,Never>?
    private var selectionTime=Date()
    private var editingExisting=false
    private var departureHistory: [Departure] { Self.saved("departures") ?? [] }
    static let refreshID="com.danogutierrez.parkify.refresh"
    static func saved<T:Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey:key).flatMap { try? JSONDecoder().decode(T.self,from:$0) }
    }
    static func persist<T:Encodable>(_ value: T?,_ key: String) {
        if let value { UserDefaults.standard.set(try? JSONEncoder().encode(value),forKey:key) }
        else { UserDefaults.standard.removeObject(forKey:key) }
    }
    override init() {
        super.init()
        session=Self.saved("session"); candidate=Self.saved("candidate")
        Alerts.configure(); Alerts.center.delegate=self
        drive.onFix={ [weak self] location in self?.fix=location }
        drive.onPermission={ [weak self] in self?.permissionStatus() }
        drive.onStop={ [weak self] in self?.detected($0) }
        permissionStatus()
        dataStatus=city.map { "City rules updated \($0.generated)" } ?? "Download city rules"
        sync()
    }
    func permissionStatus() {
        let auth=drive.location.authorizationStatus
        if auth == .denied || auth == .restricted { locatingStatus="Location is off. Tap the map to mark a spot." }
        else if auto && auth != .authorizedAlways { locatingStatus="For background detection, allow Always Location in Settings." }
        else if auto && CMMotionActivityManager.authorizationStatus() == .denied { locatingStatus="Enable Motion & Fitness for automatic parking." }
        else { locatingStatus="" }
    }
    func setAuto(_ value: Bool) {
        auto=value; drive.change(value); permissionStatus()
        if value { Task { _=await Alerts.request() } }
    }
    func setPermit(_ value: String) {
        permit=value.uppercased().trimmingCharacters(in:.whitespacesAndNewlines)
        UserDefaults.standard.set(permit,forKey:"permit"); sync()
    }
    func refresh(force: Bool=false) async {
        guard !refreshing else { return }
        if !force, let last=UserDefaults.standard.object(forKey:"cityChecked") as? Date, Date().timeIntervalSince(last)<3600 {
            sync(); return
        }
        refreshing=true; defer { refreshing=false }
        dataStatus=city == nil ? "Downloading San Francisco curb rules…" : "Checking for city updates…"
        do {
            _=try await City.refresh()
            city=City()
            UserDefaults.standard.set(Date(),forKey:"cityChecked")
            dataStatus="City rules updated \(city?.generated ?? "recently")"
            if let id=session?.curb?.id { session?.curb=city?.curb(id:id) }
            if selecting, let selected { select(selected) }
        } catch {
            dataStatus=city == nil ? "City download unavailable. Enter the posted sign or retry." : "Using offline city rules · \(city!.generated)"
        }
        sync()
    }
    func scheduleRefresh() {
        let request=BGAppRefreshTaskRequest(identifier:Self.refreshID)
        request.earliestBeginDate=Date().addingTimeInterval(3*3600)
        try? BGTaskScheduler.shared.submit(request)
    }
    func begin(at p: Point, editing: Bool=false, time: Date = .now) {
        editingExisting=editing; selectionTime=time; selecting=true
        select(p)
        if editing, let same=options.first(where:{ $0.id==session?.curb?.id }) { chosen=same }
    }
    func select(_ point: Point) {
        selected=point; options=Array((city?.nearby(point,radius:35) ?? []).prefix(16))
        chosen=options.first
    }
    func cancelSelection() { selecting=false; selected=nil; chosen=nil; options=[] }
    func chooseCandidate() {
        guard let candidate else { return }
        begin(at:candidate.point,time:candidate.time)
    }
    func dismissCandidate() {
        candidate=nil; UserDefaults.standard.removeObject(forKey:"candidate")
        Alerts.center.removeDeliveredNotifications(withIdentifiers:["candidate"])
        Alerts.center.removePendingNotificationRequests(withIdentifiers:["candidate"])
    }
    func saveSelection() {
        guard let p=selected else { return }
        let point=chosen.map { p.nearest(on:$0.line).point } ?? p
        if editingExisting, session != nil { session?.point=point; session?.curb=chosen }
        else { recordDeparture(); session=Session(point:point,arrival:selectionTime,curb:chosen) }
        dismissCandidate(); cancelSelection()
        sync(requestPermission:true)
    }
    private func detected(_ stop: Stop) {
        guard (-122.53 ... -122.35).contains(stop.point.x), (37.70 ... 37.84).contains(stop.point.y) else { return }
        let curbs=city?.nearby(stop.point,radius:40) ?? []
        if let old=session, old.point.meters(to:stop.point)<25 { return }
        if stop.clearDrive, session == nil, city?.stale==false, Parking.confident(stop.point,accuracy:stop.accuracy,curbs:curbs), let curb=curbs.first {
            session=Session(point:stop.point.nearest(on:curb.line).point,arrival:stop.time,curb:curb)
            dismissCandidate(); sync()
        } else {
            candidate=stop; Self.persist(stop,"candidate")
            Task { await Alerts.candidate() }
        }
    }
    func end() { recordDeparture(); session=nil; alternatives=[]; sync() }
    private func recordDeparture() {
        guard let session, let curb=session.curb else { return }
        let minutes=curb.rules.compactMap(\.noReturn).max() ?? 0
        let recent=departureHistory.filter { $0.until > Date() }
        Self.persist(recent+[Departure(zone:curb.id,block:curb.block,point:session.point,until:Date().addingTimeInterval(Double(minutes)*60))],"departures")
    }
    func sync(requestPermission: Bool=false, askAlarm: Bool=false) {
        Self.persist(session,"session")
        let current=session
        let result=current.map { Parking.evaluate($0,now:.now,permit:permit,holidays:city?.holidays ?? [:],stale:city?.stale ?? true) }
        verdict=result; Alerts.widget(current,result)
        // Serialize system requests so a superseded edit cannot reinstall a cancelled reminder.
        let previous=alertTask
        alertTask=Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let allowed = requestPermission ? await Alerts.request() : (await Alerts.center.notificationSettings()).authorizationStatus == .authorized
            do {
                try await Alerts.update(allowed ? current : nil,verdict:result,now:.now)
                if current != nil { self.alertStatus=allowed ? "Reminders on" : "Enable notifications for move reminders" }
                else { self.alertStatus="" }
            } catch { self.alertStatus="Reminders couldn’t be scheduled. Retry in settings." }
            do { self.alarmStatus=try await Alerts.alarm(current,verdict:result,ask:askAlarm) ?? "" }
            catch { self.alarmStatus="Alarm wasn’t scheduled. Check Settings and retry." }
        }
    }
    func toggleAlarm() { session?.alarm = !(session?.alarm ?? false); sync(askAlarm:session?.alarm==true) }
    func findAlternatives() async {
        guard let session, let city, !city.stale, !finding else { alternatives=[]; return }
        finding=true; defer { finding=false }
        let now=Date(), history=departureHistory.filter { $0.until>now }
        let permit=self.permit
        var found:[Alternative]=[]
        let curbs=city.nearby(session.point,radius:430)
        for curb in curbs {
            let anchor=session.point.nearest(on:curb.line)
            guard anchor.distance>=161, curb.block != session.curb?.block, !curb.rules.isEmpty,
                  !history.contains(where:{ $0.zone==curb.id || $0.block==curb.block }) else { continue }
            // For comparisons, assume the driver pays at a metered candidate on arrival.
            var potential=Session(point:anchor.point,arrival:now,curb:curb)
            potential.paidUntil=now.addingTimeInterval(72*3600)
            let value=Parking.evaluate(potential,now:now,permit:permit,holidays:city.holidays,lookAhead:4)
            guard value.caution==nil, value.event.date>now.addingTimeInterval(900) else { continue }
            found.append(Alternative(curb:curb,point:anchor.point,verdict:value,distance:anchor.distance))
        }
        func ranked(_ a: Alternative,_ b: Alternative)->Bool {
            if a.verdict.paid != b.verdict.paid { return !a.verdict.paid }
            if a.verdict.event.date != b.verdict.event.date { return a.verdict.event.date>b.verdict.event.date }
            return a.distance<b.distance
        }
        var blocks=Set<String>()
        var shortlist=Array(found.sorted(by:ranked).filter { blocks.insert($0.curb.block).inserted }.prefix(5))
        for i in shortlist.indices {
            let req=MKDirections.Request()
            req.source=Self.mapItem(shortlist[i].point); req.destination=Self.mapItem(session.point); req.transportType = .walking
            if let route=try? await MKDirections(request:req).calculate().routes.first {
                shortlist[i].distance=route.distance; shortlist[i].routed=true
            }
        }
        if self.session?.id==session.id { alternatives=Array(shortlist.sorted(by:ranked).prefix(3)) }
    }
    static func mapItem(_ p: Point) -> MKMapItem { MKMapItem(location:CLLocation(latitude:p.y,longitude:p.x),address:nil) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner,.sound] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier=="candidate" else { return }
        await MainActor.run {
            if response.actionIdentifier=="dismiss" || response.actionIdentifier==UNNotificationDismissActionIdentifier { dismissCandidate() }
            else { chooseCandidate() }
        }
    }
}
