import AlarmKit
import SwiftUI
import UserNotifications
import WidgetKit

struct ParkingAlarm: AlarmMetadata {}
enum Alerts {
  static let center = UNUserNotificationCenter.current()
  static let ids = ["deadline", "advance", "evening"]
  static func request() async -> Bool {
    (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
  }
  static func configure() {
    let choose = UNNotificationAction(
      identifier: "choose", title: "Choose side", options: .foreground)
    let dismiss = UNNotificationAction(identifier: "dismiss", title: "Dismiss", options: [])
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: "parking-candidate", actions: [choose, dismiss], intentIdentifiers: [],
        options: .customDismissAction)
    ])
  }
  static func candidate() async {
    let c = UNMutableNotificationContent()
    c.title = "Did you park here?"
    c.body = "Choose the curb to see its parking rules."
    c.categoryIdentifier = "parking-candidate"
    c.sound = .default
    try? await center.add(.init(identifier: "candidate", content: c, trigger: nil))
  }
  static func update(_ session: Session?, verdict: Verdict?, now: Date) async throws {
    center.removePendingNotificationRequests(withIdentifiers: ids)
    guard let session, let verdict else {
      center.removeDeliveredNotifications(withIdentifiers: ids)
      UserDefaults.standard.removeObject(forKey: "lastMoveAlert")
      return
    }
    let marker = "\(session.id):\(verdict.event.date.timeIntervalSince1970):\(verdict.event.reason)"
    let delivered = await center.deliveredNotifications().map(\.request)
    let obsolete = delivered.filter {
      ids.contains($0.identifier) && $0.content.userInfo["event"] as? String != marker
    }
    center.removeDeliveredNotifications(withIdentifiers: obsolete.map(\.identifier))
    let alreadyDelivered = delivered.contains {
      $0.identifier == "deadline" && $0.content.userInfo["event"] as? String == marker
    }
    for (id, date) in Parking.reminders(verdict, arrival: session.arrival, now: now) {
      if id == "deadline" && date <= now
        && (alreadyDelivered || UserDefaults.standard.string(forKey: "lastMoveAlert") == marker)
      {
        continue
      }
      let c = UNMutableNotificationContent()
      c.userInfo["event"] = marker
      let event = id == "evening" ? verdict.sweep ?? verdict.event : verdict.event
      c.title =
        id == "evening"
        ? "Street cleaning tomorrow" : id == "advance" ? "15 minutes to move" : "Move now"
      c.body = "\(event.reason) · \(session.curb?.title ?? "Saved parking spot")"
      c.sound = .default
      let delay = date.timeIntervalSince(now)
      let trigger =
        delay > 0
        ? UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false) : nil
      try await center.add(.init(identifier: id, content: c, trigger: trigger))
      if id == "deadline" && date <= now {
        UserDefaults.standard.set(marker, forKey: "lastMoveAlert")
      }
    }
  }
  static let alarmID = UUID(uuidString: "9A88FE73-0B48-4DED-9A40-B023F72D51E3")!
  static func alarm(_ session: Session?, verdict: Verdict?, ask: Bool) async throws -> String? {
    let manager = AlarmManager.shared
    let hasAlarm = (try? manager.alarms.contains { $0.id == alarmID }) ?? false
    guard session?.alarm == true, let event = verdict?.event, event.date > Date() else {
      if hasAlarm { try manager.cancel(id: alarmID) }
      UserDefaults.standard.removeObject(forKey: "alarmEvent")
      return nil
    }
    let state = ask ? try await manager.requestAuthorization() : manager.authorizationState
    guard state == .authorized else { return "Allow alarms in Settings to enable this alarm." }
    let date = Parking.suggestedAlarm(for: event.date, now: .now)
    let stamp = "\(date.timeIntervalSince1970):\(event.reason)"
    if hasAlarm && stamp == UserDefaults.standard.string(forKey: "alarmEvent") {
      return "Alarm set"
    }
    if hasAlarm { try manager.cancel(id: alarmID) }
    let alert = AlarmPresentation.Alert(
      title: "Move your car",
      stopButton: .init(text: "Stop", textColor: .white, systemImageName: "stop.fill"))
    let attrs = AlarmAttributes(
      presentation: AlarmPresentation(alert: alert), metadata: ParkingAlarm(), tintColor: Color.teal
    )
    _ = try await manager.schedule(
      id: alarmID, configuration: .alarm(schedule: .fixed(date), attributes: attrs))
    UserDefaults.standard.set(stamp, forKey: "alarmEvent")
    return "Alarm set"
  }
  static func widget(_ session: Session?, _ verdict: Verdict?) {
    if let s = session, let v = verdict {
      Glance.defaults?.set(
        try? JSONEncoder().encode(
          Glance(
            deadline: v.event.date, reason: v.event.reason, caution: v.caution != nil,
            arrival: s.arrival)), forKey: "glance")
    } else {
      Glance.defaults?.removeObject(forKey: "glance")
    }
    WidgetCenter.shared.reloadTimelines(ofKind: "ParkifyCountdown")
  }
}
