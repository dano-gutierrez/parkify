import MapKit
import SwiftUI

private let ink = Color(red: 0.035, green: 0.25, blue: 0.24)
private let mint = Color(red: 0.70, green: 0.96, blue: 0.78)
private let defaultPoint = Point(x: -122.4257, y: 37.7765)
private enum Panel: String, Identifiable {
  case settings, edit, alternatives
  var id: String { rawValue }
}

struct ParkingMap: View {
  @EnvironmentObject private var store: ParkingStore
  @State private var camera: MapCameraPosition = .region(
    .init(center: defaultPoint.coordinate, latitudinalMeters: 480, longitudinalMeters: 480))
  @State private var center = defaultPoint
  @State private var sheet: Panel?
  @State private var cardHeight: CGFloat = 154
  @State private var detail = false
  @State private var followNextFix = false
  @State private var confirmEnd = false
  private var activeCurb: Curb? { store.selecting ? store.chosen : store.session?.curb }
  private func focus(_ p: Point) {
    camera = .region(.init(center: p.coordinate, latitudinalMeters: 240, longitudinalMeters: 240))
  }
  var body: some View {
    GeometryReader { geometry in
      ZStack {
        MapReader { proxy in
          Map(position: $camera) {
            UserAnnotation()
            if store.selecting {
              ForEach(store.options) { c in
                MapPolyline(coordinates: c.line.map(\.coordinate)).stroke(
                  .secondary.opacity(0.6), lineWidth: 4)
              }
            }
            if let c = activeCurb {
              MapPolyline(coordinates: c.line.map(\.coordinate)).stroke(.white, lineWidth: 11)
              MapPolyline(coordinates: c.line.map(\.coordinate)).stroke(ink, lineWidth: 6)
            }
            if let p = store.selecting ? store.selected : store.session?.point {
              Annotation(
                store.selecting ? "Selected spot" : "Your car", coordinate: p.coordinate,
                anchor: .bottom
              ) {
                Image(systemName: "parkingsign").font(.system(size: 24, weight: .bold))
                  .foregroundStyle(mint).padding(12).background(ink, in: .rect(cornerRadius: 15))
                  .overlay { RoundedRectangle(cornerRadius: 15).stroke(.white, lineWidth: 2) }
                  .shadow(radius: 3, y: 2).accessibilityLabel("Parking pin")
              }.annotationTitles(.hidden)
            }
          }
          .mapStyle(
            .standard(
              elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll,
              showsTraffic: false)
          )
          .mapControls { MapScaleView() }
          .onMapCameraChange(frequency: .onEnd) { center = Point($0.region.center) }
          .onTapGesture(coordinateSpace: .local) { position in
            if store.selecting, let c = proxy.convert(position, from: .local) {
              store.select(Point(c))
            }
          }
        }
        .ignoresSafeArea()
        VStack {
          HStack {
            HStack(spacing: 8) {
              Image(systemName: "parkingsign").font(.system(size: 14, weight: .black)).frame(
                width: 27, height: 27
              ).background(ink, in: .rect(cornerRadius: 8)).foregroundStyle(mint)
              Text("Parkify").font(.system(.headline, design: .rounded, weight: .bold))
            }.padding(.leading, 7).padding(.trailing, 15).frame(height: 42).background(
              .regularMaterial, in: .capsule)
            Spacer()
            roundButton("Settings", "slider.horizontal.3") { sheet = .settings }
            roundButton("Find my location", "location.fill") {
              if let f = store.fix, abs(f.timestamp.timeIntervalSinceNow) < 60 {
                focus(Point(f.coordinate))
              } else {
                followNextFix = true
                store.drive.locate()
              }
            }
          }.padding(.horizontal, 16)
          Spacer()
          ScrollView {
            VStack(alignment: .leading, spacing: 13) {
              if store.selecting {
                selection
              } else if let session = store.session, let v = store.verdict {
                parked(session, v)
              } else {
                idle
              }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
              .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
          }
          .scrollBounceBehavior(.basedOnSize)
          .frame(height: min(cardHeight, geometry.size.height * (detail ? 0.62 : 0.46)))
          .background(.regularMaterial, in: .rect(cornerRadius: 28))
          .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(.primary.opacity(0.08)) }
          .shadow(color: .black.opacity(0.12), radius: 16, y: 5)
          .padding(.horizontal, 12).padding(.bottom, 3)
        }
      }
    }
    .onAppear { if let s = store.session { focus(s.point) } }
    .onChange(of: store.fix?.timestamp) { _, _ in
      if followNextFix, let fix = store.fix {
        let point = Point(fix.coordinate)
        focus(point)
        if store.selecting { store.select(point) }
        followNextFix = false
      }
    }
    .onChange(of: store.selecting) { _, selected in if selected, let p = store.selected { focus(p) }
    }
    .sheet(item: $sheet) { p in
      switch p {
      case .settings: SettingsView()
      case .edit: if let session = store.session { EditView(session: session) }
      case .alternatives: AlternativesView().task { await store.findAlternatives() }
      }
    }
    .confirmationDialog("End this parking session?", isPresented: $confirmEnd) {
      Button("End parking", role: .destructive) {
        store.end()
        detail = false
      }
    }
  }
  func roundButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).frame(width: 44, height: 44).background(
        .regularMaterial, in: .circle)
    }
    .buttonStyle(.plain).accessibilityLabel(title)
  }
  @ViewBuilder var idle: some View {
    if store.candidate != nil {
      Text("Did you park here?").font(.title2.bold())
      Text("Confirm the curb to start reminders.").foregroundStyle(.secondary)
      HStack {
        primary("Choose side", "point.topleft.down.to.point.bottomright.curvepath") {
          store.chooseCandidate()
        }
        Button("Dismiss") { store.dismissCandidate() }
      }
    } else {
      Label("SAN FRANCISCO", systemImage: "location.fill").font(.caption2.bold()).tracking(1.3)
        .foregroundStyle(.secondary)
      Text("Where did you park?").font(.system(.title, design: .rounded, weight: .bold))
      primary("Park here", "parkingsign.circle.fill") {
        let fresh = store.fix.flatMap {
          abs($0.timestamp.timeIntervalSinceNow) < 60 ? Point($0.coordinate) : nil
        }
        store.begin(at: fresh ?? center)
        if fresh == nil {
          followNextFix = true
          store.drive.locate()
        }
      }
    }
  }
  @ViewBuilder var selection: some View {
    HStack {
      Text("Choose your curb").font(.title2.bold())
      Spacer()
      Button("Cancel") { store.cancelSelection() }
    }
    if let c = store.chosen {
      Text(c.title).font(.headline)
      if !c.crossStreets.isEmpty {
        Text("Between \(c.crossStreets)").font(.subheadline).foregroundStyle(.secondary)
      }
      Menu {
        ForEach(store.options) { option in
          Button(
            "\(option.title) · \(Int(store.selected?.nearest(on:option.line).distance ?? 0)) m"
          ) { store.chosen = option }
        }
      } label: {
        Label("Change curb", systemImage: "arrow.left.arrow.right")
      }
    } else {
      Text("Tap the map to place the pin. Check the posted signs for this spot.").font(.subheadline)
    }
    HStack {
      Button("Use map center") { store.select(center) }
      Spacer()
      Button("Use my location") {
        if let fix = store.fix, abs(fix.timestamp.timeIntervalSinceNow) < 60 {
          let p = Point(fix.coordinate)
          store.select(p)
          focus(p)
        } else {
          followNextFix = true
          store.drive.locate()
        }
      }
    }.font(.subheadline)
    primary("Save parking", "checkmark") { store.saveSelection() }
  }
  @ViewBuilder func parked(_ s: Session, _ v: Verdict) -> some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      let due = v.event.date <= context.date
      HStack {
        Label(
          v.title(at: context.date),
          systemImage: due
            ? "exclamationmark.octagon.fill"
            : v.caution != nil ? "exclamationmark.triangle.fill" : "clock.fill"
        )
        .font(.headline).foregroundStyle(due ? Color.red : .primary)
        Spacer()
        roundButton(
          detail ? "Collapse parking details" : "Expand parking details",
          detail ? "chevron.down" : "chevron.up"
        ) { detail.toggle() }
      }
      HStack(alignment: .firstTextBaseline) {
        Text(v.event.date, format: .dateTime.hour().minute()).font(
          .system(.largeTitle, design: .rounded, weight: .bold)
        ).monospacedDigit()
        Text(v.event.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day()).font(
          .subheadline
        ).foregroundStyle(.secondary)
      }
    }
    Text(v.event.reason).font(.headline)
    Text(s.curb?.title ?? "Manually marked spot").font(.subheadline).foregroundStyle(.secondary)
    if let warning = v.caution { Text(warning).font(.footnote).foregroundStyle(.secondary) }
    if store.city?.towCoverage == false {
      Text("Temporary tow postings unavailable. Check curb signs.").font(.footnote).foregroundStyle(
        .secondary)
    }
    if detail {
      if let c = s.curb { Text("Between \(c.crossStreets)").font(.subheadline) }
      if store.city?.towCoverage == true {
        Text("Check posted temporary tow signs at the curb.").font(.footnote).foregroundStyle(.secondary)
      }
      if let sweep = v.sweep {
        VStack(alignment: .leading, spacing: 3) {
          Label("Street cleaning", systemImage: "calendar").font(.subheadline.bold())
          HStack(spacing: 3) {
            Text(sweep.date, format: .dateTime.weekday().month().day().hour().minute())
            if let end = sweep.until {
              Text("–")
              Text(end, format: .dateTime.hour().minute())
            }
          }.font(.subheadline)
          if let recurrence = sweep.recurrence, !recurrence.isEmpty {
            Text(recurrence).font(.footnote).foregroundStyle(.secondary)
          }
        }
      }
      if !store.alertStatus.isEmpty { Text(store.alertStatus).font(.footnote) }
      if !store.alarmStatus.isEmpty { Text(store.alarmStatus).font(.footnote) }
      HStack {
        Button("Edit sign or time") { sheet = .edit }
        Spacer()
        Button("Adjust pin") { store.begin(at: s.point, editing: true, time: s.arrival) }
      }
      Button("End parking", role: .destructive) { confirmEnd = true }
    }
    HStack {
      primary("Find another curb", "arrow.triangle.turn.up.right.diamond.fill") {
        sheet = .alternatives
      }
      Button {
        store.toggleAlarm()
      } label: {
        Image(systemName: s.alarm ? "alarm.waves.left.and.right.fill" : "alarm").font(.title3)
          .frame(width: 48, height: 48)
          .background(.quaternary, in: .rect(cornerRadius: 16))
      }.accessibilityLabel(s.alarm ? "Remove alarm" : "Add alarm").accessibilityHint(
        "15 minutes before you need to move")
    }
    if !detail && !store.alarmStatus.isEmpty { Text(store.alarmStatus).font(.caption) }
    if store.candidate != nil { Button("Review a newly detected stop") { store.chooseCandidate() } }
  }
}
private func primary(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View
{
  Button(action: action) {
    Label(title, systemImage: symbol).font(.headline).frame(maxWidth: .infinity, minHeight: 48)
      .background(ink, in: .rect(cornerRadius: 16)).foregroundStyle(.white)
  }.buttonStyle(.plain)
}
