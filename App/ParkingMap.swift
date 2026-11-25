import MapKit
import SwiftUI

let parkInk = Color(red: 0.035, green: 0.25, blue: 0.24)
private let defaultPoint = Point(x: -122.4257, y: 37.7765)
private enum Panel: String, Identifiable {
  case settings, edit
  var id: String { rawValue }
}

struct ParkingMap: View {
  @EnvironmentObject private var store: ParkingStore
  @State private var camera: MapCameraPosition = .region(
    .init(center: defaultPoint.coordinate, latitudinalMeters: 380, longitudinalMeters: 380))
  @State private var center = defaultPoint
  @State private var sheet: Panel?
  @State private var cardHeight: CGFloat = 150
  @State private var expanded = false
  @State private var browsing = false
  @State private var fittedOffers = false
  @State private var inspectedID: String?
  @State private var followNextFix = false
  @State private var confirmEnd = false

  private func focus(_ p: Point) {
    camera = .region(.init(center: p.coordinate, latitudinalMeters: 250, longitudinalMeters: 250))
  }
  private var freshFix: Point? {
    guard let f = store.fix, abs(f.timestamp.timeIntervalSinceNow) < 60 else { return nil }
    return Point(f.coordinate)
  }
  private func locate() {
    if let freshFix {
      focus(freshFix)
      if store.selecting { store.select(freshFix) }
    } else {
      followNextFix = true
      store.drive.locate()
    }
  }
  var body: some View {
    GeometryReader { geometry in
      ZStack {
        CurbMap(
          camera: $camera, center: $center, inspectedID: $inspectedID,
          followNextFix: $followNextFix, browsing: browsing
        )
        .ignoresSafeArea()
        VStack {
          HStack {
            Label("Parkify", systemImage: "parkingsign.circle.fill")
              .font(.system(.headline, design: .rounded, weight: .bold))
              .padding(.horizontal, 13).frame(height: 42).background(.regularMaterial, in: .capsule)
            Spacer()
            HStack(spacing: 2) {
              icon("Settings", "slider.horizontal.3") { sheet = .settings }
              icon("Find my location", "location.fill") { locate() }
            }.padding(.horizontal, 3).background(.regularMaterial, in: .capsule)
          }.padding(.horizontal, 14)
          Spacer()
          ScrollView {
            VStack(alignment: .leading, spacing: 12) {
              if store.selecting {
                selection
              } else if browsing {
                nearby
              } else if let session = store.session, let v = store.verdict {
                parked(session, v)
              } else {
                idle
              }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
              .onGeometryChange(for: CGFloat.self) {
                $0.size.height
              } action: {
                cardHeight = $0
              }
          }
          .scrollBounceBehavior(.basedOnSize)
          .frame(height: min(cardHeight, geometry.size.height * (expanded ? 0.57 : 0.40)))
          .background(.regularMaterial, in: .rect(cornerRadius: 24))
          .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.quaternary) }
          .shadow(color: .black.opacity(0.10), radius: 9, y: 3)
          .padding(.horizontal, 10).padding(.bottom, 2)
        }
      }
    }
    .onAppear {
      if let s = store.session {
        focus(s.point)
      } else if [.authorizedAlways, .authorizedWhenInUse].contains(
        store.drive.location.authorizationStatus)
      {
        locate()
      }
    }
    .onChange(of: store.fix?.timestamp) { _, _ in
      if followNextFix, let freshFix {
        followNextFix = false
        focus(freshFix)
        if store.selecting { store.select(freshFix) }
      }
    }
    .onChange(of: store.selecting) { _, selecting in
      inspectedID = nil
      if selecting, let p = store.selected {
        browsing = false
        focus(p)
      } else {
        followNextFix = false
      }
    }
    .onChange(of: store.session?.id) { _, _ in
      browsing = false
      inspectedID = nil
    }
    .onChange(of: store.alternatives.map(\.id)) { _, _ in fitOffers() }
    .task(id: browsing) { if browsing { await store.findAlternatives() } }
    .sheet(item: $sheet) { p in
      switch p {
      case .settings: SettingsView()
      case .edit: if let session = store.session { EditView(session: session) }
      }
    }
    .confirmationDialog("End this parking session?", isPresented: $confirmEnd) {
      Button("End session", role: .destructive) {
        store.end()
        expanded = false
      }
    }
  }

  private func fitOffers() {
    guard browsing, !fittedOffers, let s = store.session, !store.alternatives.isEmpty else {
      return
    }
    fittedOffers = true
    var rect = MKMapRect.null
    for point in [s.point] + store.alternatives.map(\.point) {
      let p = MKMapPoint(point.coordinate)
      rect = rect.union(.init(x: p.x, y: p.y, width: 1, height: 1))
    }
    let padding = max(
      65 * MKMapPointsPerMeterAtLatitude(s.point.y), max(rect.width, rect.height) * 0.35)
    camera = .rect(rect.insetBy(dx: -padding, dy: -padding))
  }

  @ViewBuilder private var idle: some View {
    if store.candidate != nil {
      Text("Did you park here?").font(.title3.bold())
      HStack {
        primary("Choose side", "arrow.left.arrow.right") { store.chooseCandidate() }
        Button("Dismiss") { store.dismissCandidate() }.padding(.horizontal, 8)
      }
    } else {
      CurbLegend()
      primary("Park here", "parkingsign.circle.fill") {
        inspectedID = nil
        store.begin(at: freshFix ?? center)
        if freshFix == nil {
          followNextFix = true
          store.drive.locate()
        }
      }
    }
  }

  private var selection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(store.chosen?.title ?? "Place your pin").font(.headline)
          Text("Drag the pin or tap a curb").font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer()
        icon("Cancel pin adjustment", "xmark") { store.cancelSelection() }
      }
      HStack(spacing: 8) {
        if !store.options.isEmpty {
          Menu {
            ForEach(store.options) { c in
              Button("\(c.title) · \(Int(store.selected?.nearest(on: c.line).distance ?? 0)) m") {
                guard let point = store.selected else { return }
                followNextFix = false
                store.selected = point.nearest(on: c.line).point
                store.chosen = c
              }
            }
          } label: {
            Image(systemName: "arrow.left.arrow.right").frame(width: 44, height: 44)
          }
          .accessibilityLabel("Change curb")
        }
        icon("Use map center", "scope") {
          followNextFix = false
          store.select(center)
        }
        primary("Save parking", "checkmark") {
          store.saveSelection()
          expanded = false
        }
      }
    }
  }

  private var nearby: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Nearby curbs").font(.title3.bold())
          if store.finding && store.alternatives.isEmpty {
            HStack {
              ProgressView().controlSize(.small)
              Text("Checking rules…")
            }
          } else if store.alternatives.isEmpty {
            Text("No verified alternatives nearby")
          } else {
            Text("Tap a numbered curb for directions")
          }
        }.font(.subheadline)
        Spacer()
        icon("Close nearby curbs", "xmark") {
          browsing = false
          inspectedID = nil
          if let s = store.session { focus(s.point) }
        }
      }
      CurbLegend()
    }
  }

  @ViewBuilder private func parked(_ s: Session, _ v: Verdict) -> some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      let due = v.event.date <= context.date
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          if due {
            Label("Move now", systemImage: "exclamationmark.octagon.fill").font(.title2.bold())
              .foregroundStyle(.red)
          } else {
            Text("Move by").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text(v.event.date, format: .dateTime.weekday(.abbreviated).hour().minute())
              .font(.system(.title, design: .rounded, weight: .bold)).monospacedDigit()
          }
          if v.event.reason == "Street cleaning" {
            SweepingSign()
          } else {
            Text(
              v.event.reason == "72-hour street parking limit" ? "72-hour limit" : v.event.reason
            ).font(.subheadline)
          }
        }
        Spacer()
        icon(
          expanded ? "Collapse parking details" : "Expand parking details",
          expanded ? "chevron.down" : "chevron.up"
        ) {
          expanded.toggle()
        }
      }
    }
    HStack(spacing: 5) {
      Image(systemName: "mappin").accessibilityHidden(true)
      Text(s.curb?.title ?? "Saved pin")
      if v.caution != nil {
        Spacer()
        Label("Check signs", systemImage: "exclamationmark.triangle")
      }
    }.font(.caption.weight(.medium)).foregroundStyle(.secondary)
    if expanded {
      Divider()
      if let c = s.curb, !c.crossStreets.isEmpty {
        Text("Between \(c.crossStreets)").font(.subheadline)
      }
      if let sweep = v.sweep {
        HStack(spacing: 10) {
          SweepingSign()
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 1) {
              Text(
                sweep.date, format: .dateTime.weekday(.abbreviated).month().day().hour().minute())
              if let end = sweep.until {
                Text("–")
                Text(end, format: .dateTime.hour().minute())
              }
            }.font(.subheadline.bold())
            if let recurrence = sweep.recurrence, !recurrence.isEmpty {
              Text(recurrence).font(.caption)
            }
          }
        }
      }
      if let warning = v.caution { Text(warning).font(.caption).foregroundStyle(.secondary) }
      if store.city?.towCoverage == false {
        Text("Check posted tow-away signs").font(.caption).foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        icon("Edit sign or time", "pencil") { sheet = .edit }
        icon("Adjust pin", "mappin.and.ellipse") {
          store.begin(at: s.point, editing: true, time: s.arrival)
        }
        Spacer()
        icon("End parking", "trash", tint: .red) { confirmEnd = true }
      }
      if !store.alertStatus.isEmpty { Text(store.alertStatus).font(.caption) }
    }
    HStack(spacing: 8) {
      primary("Find another curb", "arrow.triangle.turn.up.right.diamond") {
        expanded = false
        inspectedID = nil
        fittedOffers = false
        store.alternatives = []
        store.finding = true
        browsing = true
      }
      if v.event.date > .now || s.alarm {
        icon(s.alarm ? "Remove alarm" : "Add alarm", s.alarm ? "alarm.fill" : "alarm") {
          store.toggleAlarm()
        }
        .accessibilityHint("Suggested move reminder")
      }
    }
    if expanded, !s.alarm, v.event.date > Date() {
      Text(
        "Suggested alarm \(Parking.suggestedAlarm(for: v.event.date, now: .now), format: .dateTime.hour().minute())"
      ).font(.caption)
    }
    if !store.alarmStatus.isEmpty { Text(store.alarmStatus).font(.caption) }
    if store.candidate != nil { Button("Review detected stop") { store.chooseCandidate() } }
  }

  private func icon(
    _ label: String, _ symbol: String, tint: Color = .primary, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(tint)
        .frame(width: 44, height: 44).background(.quaternary.opacity(0.65), in: .circle)
    }.buttonStyle(.plain).accessibilityLabel(label)
  }
  private func primary(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View
  {
    Button(action: action) {
      Label(title, systemImage: symbol).font(.headline).frame(maxWidth: .infinity, minHeight: 46)
        .background(parkInk, in: .rect(cornerRadius: 14)).foregroundStyle(.white)
    }.buttonStyle(.plain)
  }
}
