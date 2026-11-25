import MapKit
import SwiftUI

extension CurbStatus {
  var tint: Color {
    Color(
      uiColor: UIColor { traits in
        let dark = traits.userInterfaceStyle == .dark
        switch self {
        case .free:
          return dark ? .systemMint : UIColor(red: 0.03, green: 0.48, blue: 0.36, alpha: 1)
        case .metered:
          return dark ? .systemCyan : UIColor(red: 0.12, green: 0.42, blue: 0.80, alpha: 1)
        case .prohibited:
          return dark ? .systemRed : UIColor(red: 0.83, green: 0.25, blue: 0.21, alpha: 1)
        case .uncertain: return .systemGray
        }
      })
  }

  var symbol: String {
    switch self {
    case .free: "parkingsign.circle.fill"
    case .metered: "dollarsign.circle.fill"
    case .prohibited: "nosign"
    case .uncertain: "questionmark.circle"
    }
  }

  var stroke: StrokeStyle {
    StrokeStyle(lineWidth: 4, lineCap: .round, dash: self == .uncertain ? [2, 5] : [])
  }
}

// The photographed SF sign uses a red border and lettering on a white plate.
struct SweepingSign: View {
  var body: some View {
    VStack(spacing: 2) {
      Text("NO PARKING").font(.system(size: 8, weight: .heavy)).fontWidth(.condensed)
      Rectangle().frame(height: 1)
      Text("STREET\nSWEEPING").font(.system(size: 8, weight: .bold)).fontWidth(.condensed)
    }
    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    .padding(3).frame(width: 57)
    .foregroundStyle(Color(red: 0.62, green: 0.1, blue: 0.13))
    .background(.white, in: .rect(cornerRadius: 4))
    .overlay {
      RoundedRectangle(cornerRadius: 4).strokeBorder(Color(red: 0.62, green: 0.1, blue: 0.13))
    }
    .accessibilityElement(children: .ignore).accessibilityLabel("Street sweeping")
  }
}

struct CurbLegend: View {
  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) { entries }
      LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], alignment: .leading, spacing: 6)
      { entries }
    }
    .font(.caption.weight(.medium))
    .accessibilityElement(children: .combine).accessibilityLabel(
      "Curb rules: free, metered, no parking, check signs")
  }
  @ViewBuilder private var entries: some View {
    ForEach(CurbStatus.allCases, id: \.self) { status in
      HStack(spacing: 4) {
        Image(systemName: status.symbol).foregroundStyle(status.tint)
        Text(status.rawValue)
      }.fixedSize()
    }
  }
}

private struct CurbLayer: Identifiable {
  var item: Alternative
  var polyline: MKPolyline
  var status: CurbStatus
  var id: String { item.id }
}

private struct Neighborhood: Equatable {
  let latitude: Int
  let longitude: Int
  let minute: Int
  let permit: String
  let release: String
}

struct CurbMap: View {
  @EnvironmentObject private var store: ParkingStore
  @Binding var camera: MapCameraPosition
  @Binding var center: Point
  @Binding var inspectedID: String?
  @Binding var followNextFix: Bool
  let browsing: Bool

  @State private var layers: [CurbLayer] = []
  @State private var cameraPosition: MapCamera?
  @State private var dropOrigin: CGPoint?
  @State private var draggedPoint: CGPoint?
  @State private var tappedPoint: Point?
  @State private var minute = Int(Date.now.timeIntervalSince1970 / 60)
  @Environment(\.scenePhase) private var phase

  private var pin: Point? { store.selecting ? store.selected : store.session?.point }
  private var selectedCurb: Curb? { store.selecting ? store.chosen : store.session?.curb }
  private var offers: [Alternative] { browsing ? store.alternatives : [] }
  private var inspected: Alternative? {
    guard let inspectedID else { return nil }
    return offers.first { $0.id == inspectedID } ?? layers.first { $0.id == inspectedID }?.item
  }
  private var neighborhood: Neighborhood {
    Neighborhood(
      latitude: Int((center.y * 2400).rounded()), longitude: Int((center.x * 2000).rounded()),
      minute: minute, permit: store.permit, release: store.dataStatus)
  }

  var body: some View {
    MapReader { proxy in
      ZStack {
        Map(position: $camera) {
          UserAnnotation()
          ForEach(layers) { layer in
            MapPolyline(layer.polyline).stroke(
              layer.status.tint.opacity(browsing ? 0.4 : 1), style: layer.status.stroke)
          }
          ForEach(offers) { offer in
            MapPolyline(coordinates: offer.curb.line.map(\.coordinate)).stroke(
              .white, lineWidth: 10)
            MapPolyline(coordinates: offer.curb.line.map(\.coordinate))
              .stroke(offer.verdict.curbStatus(at: .now).tint, lineWidth: 6)
          }
          if let curb = inspected?.curb ?? selectedCurb {
            MapPolyline(coordinates: curb.line.map(\.coordinate)).stroke(.white, lineWidth: 10)
            MapPolyline(coordinates: curb.line.map(\.coordinate))
              .stroke(inspected?.verdict.curbStatus(at: .now).tint ?? parkInk, lineWidth: 6)
          }
          ForEach(Array(offers.enumerated()), id: \.element.id) { index, offer in
            Annotation(offer.curb.title, coordinate: offer.point.coordinate) {
              Button {
                inspect(offer, at: offer.point)
              } label: {
                Text("\(index + 1)").font(.subheadline.bold().monospacedDigit())
                  .foregroundStyle(.white).frame(width: 28, height: 28).background(
                    parkInk, in: .circle
                  )
                  .overlay { Circle().strokeBorder(.white, lineWidth: 2) }.shadow(radius: 2)
                  .frame(width: 44, height: 44).contentShape(.circle)
              }.buttonStyle(.plain).accessibilityLabel("Curb \(index + 1), \(offer.curb.title)")
                .accessibilityIdentifier("curb-option-\(index + 1)")
            }.annotationTitles(.hidden)
          }
          if let item = inspected {
            Annotation(
              item.curb.title, coordinate: (tappedPoint ?? item.point).coordinate, anchor: .bottom
            ) {
              CurbCallout(
                item: item, destination: tappedPoint ?? item.point,
                suggested: offers.contains { $0.id == item.id }
              ) {
                inspectedID = nil
              }
              .padding(.bottom, 18)
            }.annotationTitles(.hidden)
          }
        }
        .mapStyle(
          .standard(
            elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false
          )
        )
        .mapControls {}
        .onMapCameraChange(frequency: .continuous) { context in
          cameraPosition = context.camera
          center = Point(context.region.center)
        }
        .onTapGesture(coordinateSpace: .local) { position in tapped(position, proxy: proxy) }
        if let pin, let screen = proxy.convert(pin.coordinate, to: .named("curbMap")),
          cameraPosition != nil
        {
          parkingPin(at: screen, proxy: proxy).allowsHitTesting(!browsing)
        }
      }.coordinateSpace(name: "curbMap")
    }
    .task(id: neighborhood) { await loadNeighborhood() }
    .task(id: phase) {
      guard phase == .active else { return }
      while !Task.isCancelled {
        minute = Int(Date.now.timeIntervalSince1970 / 60)
        do {
          try await Task.sleep(
            for: .seconds(60 - Date.now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)))
        } catch { return }
      }
    }
    .onChange(of: browsing) { tappedPoint = nil }
    .onChange(of: inspectedID) { _, id in if id == nil { tappedPoint = nil } }
  }

  private func parkingPin(at screen: CGPoint, proxy: MapProxy) -> some View {
    let tip = draggedPoint ?? screen
    return VStack(spacing: -4) {
      Image(systemName: store.selecting ? "parkingsign" : "car.fill").font(
        .system(size: 18, weight: .bold)
      )
      .foregroundStyle(.white).frame(width: 38, height: 36).background(
        parkInk, in: .rect(cornerRadius: 12)
      )
      .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white, lineWidth: 2) }
      Image(systemName: "arrowtriangle.down.fill").font(.system(size: 12)).foregroundStyle(parkInk)
    }
    .frame(width: 48, height: 48).contentShape(.rect).shadow(radius: 2, y: 1)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Parking pin").accessibilityHint(
      "Drag to move the pin, or choose Adjust pin and tap the map."
    )
    .accessibilityIdentifier("parking-pin")
    .gesture(
      DragGesture(minimumDistance: 3, coordinateSpace: .named("curbMap"))
        .onChanged { value in
          if dropOrigin == nil {
            dropOrigin = screen
            inspectedID = nil
            followNextFix = false
          }
          if let origin = dropOrigin {
            draggedPoint = CGPoint(
              x: origin.x + value.translation.width, y: origin.y + value.translation.height)
          }
        }.onEnded { value in
          defer {
            dropOrigin = nil
            draggedPoint = nil
          }
          guard let origin = dropOrigin else { return }
          let drop = CGPoint(
            x: origin.x + value.translation.width, y: origin.y + value.translation.height)
          guard let coordinate = proxy.convert(drop, from: .named("curbMap")) else { return }
          if store.selecting {
            store.select(Point(coordinate))
          } else if let session = store.session {
            store.begin(at: Point(coordinate), editing: true, time: session.arrival)
          }
        }
    )
    .position(x: tip.x, y: tip.y - 22)
  }

  private func tapped(_ position: CGPoint, proxy: MapProxy) {
    guard let coordinate = proxy.convert(position, from: .local) else { return }
    let p = Point(coordinate)
    if store.selecting {
      followNextFix = false
      store.select(p)
      return
    }
    let edge = proxy.convert(CGPoint(x: position.x + 13, y: position.y), from: .local)
    let reach = min(22, max(3, edge.map { p.meters(to: Point($0)) } ?? 8))
    let choices = browsing ? offers : layers.map(\.item)
    let hits = choices.map { ($0, p.nearest(on: $0.curb.line)) }
    if let hit = hits.min(by: { $0.1.distance < $1.1.distance }), hit.1.distance <= reach {
      inspect(hit.0, at: hit.1.point)
    } else {
      inspectedID = nil
    }
  }

  private func inspect(_ item: Alternative, at point: Point) {
    tappedPoint = point
    inspectedID = item.id
    // Center the callout so both its text and Maps button fit on a narrow phone.
    let distance = min(max(cameraPosition?.distance ?? 330, 140), 1000)
    camera = .camera(MapCamera(centerCoordinate: point.coordinate, distance: distance))
  }

  private func loadNeighborhood() async {
    let p = center
    let permit = store.permit
    let now = Date()
    guard store.city != nil else {
      layers = []
      return
    }
    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
    let work = Task.detached(priority: .userInitiated) { () -> [CurbLayer] in
      guard !Task.isCancelled, let city = City() else { return [] }
      let stale = city.stale
      var cache: [[Rule]: Verdict] = [:]
      var result: [CurbLayer] = []
      for curb in city.nearby(p, radius: 165).prefix(240) {
        if Task.isCancelled { return [] }
        let anchor = p.nearest(on: curb.line)
        let verdict =
          cache[curb.rules]
          ?? Parking.evaluate(
            Session(point: anchor.point, arrival: now, curb: curb),
            now: now, permit: permit, holidays: city.holidays, stale: stale, lookAhead: 4,
            assumePaymentOnArrival: true)
        cache[curb.rules] = verdict
        let coords = curb.line.map(\.coordinate)
        let item = Alternative(
          curb: curb, point: anchor.point, verdict: verdict, distance: anchor.distance)
        result.append(
          CurbLayer(
            item: item, polyline: MKPolyline(coordinates: coords, count: coords.count),
            status: verdict.curbStatus(at: now)))
      }
      return result
    }
    let result = await withTaskCancellationHandler {
      await work.value
    } onCancel: {
      work.cancel()
    }
    if !Task.isCancelled { layers = result }
  }
}

private struct CurbCallout: View {
  let item: Alternative
  let destination: Point
  let suggested: Bool
  let close: () -> Void
  var body: some View {
    let status = item.verdict.curbStatus(at: .now)
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Label(status.rawValue, systemImage: status.symbol).font(.caption.bold())
        Spacer()
        Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
          .accessibilityLabel("Close curb details")
      }
      .frame(height: 32)
      Text(item.curb.title).font(.headline)
      if !item.curb.crossStreets.isEmpty {
        Text(item.curb.crossStreets).font(.caption).foregroundStyle(.secondary)
      }
      Divider()
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          if status != .prohibited {
            Text(
              "Move by \(item.verdict.event.date, format: .dateTime.weekday(.abbreviated).hour().minute())"
            ).font(.subheadline.bold())
          }
          if item.verdict.event.reason == "Street cleaning" {
            SweepingSign()
          } else {
            Text(
              item.verdict.event.reason == "72-hour street parking limit"
                ? "72-hour limit" : item.verdict.event.reason
            ).font(.caption)
          }
          if suggested {
            Text("\(Int(item.distance.rounded())) m \(item.routed ? "walk back" : "away")").font(
              .caption
            ).foregroundStyle(.secondary)
          }
        }
        Spacer()
        Button {
          let target = ParkingStore.mapItem(destination)
          target.name = item.curb.title
          target.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
          ])
        } label: {
          Image(systemName: "map.fill").font(.headline).foregroundStyle(.white)
            .frame(width: 44, height: 44).background(parkInk, in: .rect(cornerRadius: 14))
        }.accessibilityLabel("Driving directions in Apple Maps")
      }
    }.padding(12).frame(width: 250).background(.regularMaterial, in: .rect(cornerRadius: 18))
      .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary) }
      .shadow(color: .black.opacity(0.15), radius: 6, y: 3).buttonStyle(.plain)
  }
}
