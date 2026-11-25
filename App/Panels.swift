import MapKit
import SwiftUI
import UIKit

struct EditView: View {
  @EnvironmentObject var store: ParkingStore
  @Environment(\.dismiss) var dismiss
  @State var session: Session
  @State private var limitText: String
  @State private var useMeter: Bool
  @State private var paid: Date
  @State private var useWindow: Bool
  @State private var from: Date
  @State private var until: Date
  init(session: Session) {
    _session = State(initialValue: session)
    _limitText = State(initialValue: session.postedLimit.map(String.init) ?? "")
    _useMeter = State(initialValue: session.paidUntil != nil)
    _paid = State(initialValue: session.paidUntil ?? Date().addingTimeInterval(3600))
    _useWindow = State(initialValue: session.postedStart != nil)
    _from = State(initialValue: session.postedStart ?? .now)
    _until = State(initialValue: session.postedEnd ?? Date().addingTimeInterval(3600))
  }
  var valid: Bool {
    (limitText.isEmpty || (1...4320).contains(Int(limitText) ?? 0)) && (!useWindow || until > from)
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("Parking session") {
          DatePicker("Arrival", selection: $session.arrival, in: ...Date())
        }
        Section("Posted sign") {
          TextField("Time limit in minutes", text: $limitText).keyboardType(.numberPad)
          Toggle("No-parking window", isOn: $useWindow)
          if useWindow {
            DatePicker("Starts", selection: $from)
            DatePicker("Ends", selection: $until)
          }
        }
        Section("Meter") {
          Toggle("Record a payment", isOn: $useMeter)
          if useMeter { DatePicker("Paid through", selection: $paid) }
        }
      }.navigationTitle("Sign and timing").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
              guard session.id == store.session?.id else {
                dismiss()
                return
              }
              store.session?.arrival = session.arrival
              store.session?.postedLimit = Int(limitText)
              store.session?.paidUntil = useMeter ? paid : nil
              store.session?.postedStart = useWindow ? from : nil
              store.session?.postedEnd = useWindow ? until : nil
              store.sync()
              dismiss()
            }.disabled(!valid)
          }
        }
    }.environment(\.timeZone, Parking.calendar.timeZone)
  }
}
struct SettingsView: View {
  @EnvironmentObject var store: ParkingStore
  @Environment(\.dismiss) var dismiss
  @Environment(\.openURL) var openURL
  @State private var permit = ""
  var body: some View {
    NavigationStack {
      Form {
        Section("Detection") {
          Toggle(
            "Detect parking after a drive",
            isOn: Binding(get: { store.auto }, set: { store.setAuto($0) }))
          if !store.locatingStatus.isEmpty { Text(store.locatingStatus).font(.footnote) }
          Button("iPhone permissions") {
            openURL(URL(string: UIApplication.openSettingsURLString)!)
          }
        }
        Section("Residential permit") {
          TextField("Permit area, e.g. Q", text: $permit).textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
        }
        Section("Reminders") {
          Text(
            "15 minutes before and when time expires. Early street cleaning also gets an 8 p.m. reminder the night before."
          )
          Button("Enable notifications") {
            Task {
              let allowed = await Alerts.request()
              store.sync()
              if !allowed { openURL(URL(string: UIApplication.openSettingsURLString)!) }
            }
          }
          Text("Add the Parkify countdown when customizing your Lock Screen.").font(.footnote)
        }
        Section("City data") {
          Text(store.dataStatus).font(.subheadline)
          Button(store.refreshing ? "Downloading…" : "Refresh city rules") {
            Task { await store.refresh(force: true) }
          }.disabled(store.refreshing)
          Link("SFMTA curb policies", destination: URL(string: "https://data.sf.gov/d/wntw-x37e")!)
        }
      }
      .navigationTitle("Settings").toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            store.setPermit(permit)
            dismiss()
          }
        }
      }.onAppear { permit = store.permit }
    }
  }
}
struct AlternativesView: View {
  @EnvironmentObject var store: ParkingStore
  @Environment(\.dismiss) var dismiss
  var body: some View {
    NavigationStack {
      List {
        if store.finding && store.alternatives.isEmpty {
          HStack {
            ProgressView()
            Text("Checking nearby curbs…")
          }
        } else if store.alternatives.isEmpty {
          ContentUnavailableView(
            "No verified curbs nearby", systemImage: "map",
            description: Text("Check posted signs or refresh city rules."))
        }
        ForEach(store.alternatives) { item in
          VStack(alignment: .leading, spacing: 8) {
            Text(item.curb.title).font(.headline)
            Text("Between \(item.curb.crossStreets)").font(.subheadline)
            Label(
              "\(item.verdict.paid ? "Metered" : "Free now") · \(Int(item.distance.rounded())) m \(item.routed ? "walk back" : "away")",
              systemImage: "figure.walk"
            ).font(.subheadline)
            Text(
              "\(item.verdict.event.reason) · \(item.verdict.event.date.formatted(.dateTime.weekday().hour().minute()))"
            ).font(.footnote)
            Button("Driving directions") {
              let mapItem = ParkingStore.mapItem(item.point)
              mapItem.name = item.curb.title
              mapItem.openInMaps(launchOptions: [
                MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
              ])
            }
          }.padding(.vertical, 5)
        }
        if !store.alternatives.isEmpty {
          Text("Check temporary signs at the curb. Space availability is unknown until you arrive.")
            .font(.footnote).foregroundStyle(.secondary)
        }
      }.navigationTitle("Nearby curbs").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
  }
}
