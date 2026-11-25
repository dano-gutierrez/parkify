import CoreLocation
import CoreMotion
import Foundation

struct Stop: Codable {
  var point: Point
  var time: Date
  var accuracy: Double
  var clearDrive: Bool
}
final class DriveDetector: NSObject, CLLocationManagerDelegate {
  let location = CLLocationManager()
  let motion = CMMotionActivityManager()
  var onStop: ((Stop) -> Void)?
  var onFix: ((CLLocation) -> Void)?
  var onPermission: (() -> Void)?
  private var drivingSince: Date?
  private var lastCarFix: CLLocation?
  private var stationarySince: Date?
  private var driving = false
  private var requestedMotion = false
  private var enabled: Bool { UserDefaults.standard.bool(forKey: "autoParking") }

  override init() {
    super.init()
    location.delegate = self
    location.desiredAccuracy = kCLLocationAccuracyBest
    location.activityType = .automotiveNavigation
    location.distanceFilter = 7
    if enabled { observe() }
  }
  func locate() {
    if location.authorizationStatus == .notDetermined {
      location.requestWhenInUseAuthorization()
    } else {
      location.requestLocation()
    }
  }
  func change(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: "autoParking")
    if enabled {
      if location.authorizationStatus == .notDetermined {
        location.requestWhenInUseAuthorization()
      } else if location.authorizationStatus == .authorizedWhenInUse {
        location.requestAlwaysAuthorization()
      }
      observe()
    } else {
      motion.stopActivityUpdates()
      requestedMotion = false
      location.stopMonitoringSignificantLocationChanges()
      stopTracking()
    }
  }
  private func observe() {
    guard enabled else { return }
    let auth = location.authorizationStatus
    guard auth == .authorizedAlways || auth == .authorizedWhenInUse else { return }
    if auth == .authorizedAlways {
      location.startMonitoringSignificantLocationChanges()
    }
    guard CMMotionActivityManager.isActivityAvailable(), !requestedMotion else { return }
    requestedMotion = true
    motion.startActivityUpdates(to: .main) { [weak self] activity in
      guard let self, let activity, self.enabled, activity.confidence != .low else { return }
      if activity.automotive {
        self.beginDrive(at: activity.startDate)
      } else if activity.walking || activity.running {
        self.finishDrive(at: activity.startDate)
      } else if activity.stationary && self.driving {
        self.stationarySince = self.stationarySince ?? activity.startDate
      }
    }
  }
  private func beginDrive(at date: Date) {
    if !driving {
      drivingSince = date
      stationarySince = nil
      driving = true
    }
    location.allowsBackgroundLocationUpdates = location.authorizationStatus == .authorizedAlways
    location.pausesLocationUpdatesAutomatically = false
    location.startUpdatingLocation()
  }
  private func stopTracking() {
    driving = false
    drivingSince = nil
    lastCarFix = nil
    stationarySince = nil
    location.stopUpdatingLocation()
    location.allowsBackgroundLocationUpdates = false
  }
  private func finishDrive(at date: Date) {
    guard driving, let start = drivingSince, let fix = lastCarFix else { return }
    defer { stopTracking() }
    let age = date.timeIntervalSince(fix.timestamp)
    guard date.timeIntervalSince(start) > 45, age >= -12, age < 120, fix.horizontalAccuracy > 0
    else { return }
    let clear =
      date.timeIntervalSince(start) >= 120 && (fix.speed >= 0 && fix.speed < 2.2) && age < 40
    onStop?(
      Stop(
        point: Point(x: fix.coordinate.longitude, y: fix.coordinate.latitude),
        time: stationarySince.map { min(date, max(fix.timestamp.addingTimeInterval(-30), $0)) }
          ?? fix.timestamp,
        accuracy: fix.horizontalAccuracy, clearDrive: clear))
  }
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    if [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus) {
      manager.requestLocation()
      observe()
    } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
      stopTracking()
    }
    onPermission?()
  }
  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let fix = locations.last, abs(fix.timestamp.timeIntervalSinceNow) < 90,
      fix.horizontalAccuracy > 0
    else { return }
    onFix?(fix)
    guard enabled else { return }
    if fix.speed > 5 {
      stationarySince = nil
      if !driving { beginDrive(at: fix.timestamp) }
    }
    if driving, fix.horizontalAccuracy < 50 {
      // Once stopped, retain the fix at the car while the motion classifier catches up.
      if fix.speed >= 2.2 || lastCarFix == nil || stationarySince == nil {
        lastCarFix = fix
        if fix.speed >= 0 && fix.speed < 2.2 { stationarySince = fix.timestamp }
      } else if fix.speed >= 0 && fix.speed < 0.6
        && fix.horizontalAccuracy < (lastCarFix?.horizontalAccuracy ?? 100)
      {
        lastCarFix = fix
      }
    }
    if let since = stationarySince, fix.timestamp.timeIntervalSince(since) > 300 { stopTracking() }
  }
  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    onPermission?()
  }
}
