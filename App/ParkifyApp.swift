import SwiftUI

@main struct ParkifyApp: App {
  @StateObject private var store = ParkingStore()
  @Environment(\.scenePhase) private var phase
  var body: some Scene {
    WindowGroup {
      ParkingMap().environmentObject(store)
        .environment(\.timeZone, Parking.calendar.timeZone)
        .task { await store.refresh() }
        .onChange(of: phase) { _, p in
          if p == .active {
            store.permissionStatus()
            Task { await store.refresh() }
          }
          if p == .background { store.scheduleRefresh() }
        }
    }
    .backgroundTask(.appRefresh(ParkingStore.refreshID)) {
      await store.refresh(force: true)
      await store.scheduleRefresh()
    }
  }
}
