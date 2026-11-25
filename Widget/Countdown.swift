import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
    let date: Date
    let glance: Glance?
}
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date:.now,glance:Glance(deadline:.now.addingTimeInterval(3600),reason:"Street cleaning",caution:false,arrival:.now)) }
    func getSnapshot(in context: Context,completion:@escaping (Entry)->Void) { completion(context.isPreview ? placeholder(in:context) : entry()) }
    private func entry() -> Entry {
        let saved=Glance.defaults?.data(forKey:"glance").flatMap { try? JSONDecoder().decode(Glance.self,from:$0) }
        return Entry(date:.now,glance:saved)
    }
    func getTimeline(in context: Context,completion:@escaping (Timeline<Entry>)->Void) {
        let current=entry()
        var entries=[current]
        if let g=current.glance, g.deadline>current.date { entries.append(Entry(date:g.deadline,glance:g)) }
        completion(Timeline(entries:entries,policy:.never))
    }
}
@main struct Countdown: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind:"ParkifyCountdown",provider:Provider()) { entry in
            VStack(alignment:.leading,spacing:2) {
                if let g=entry.glance {
                    if g.deadline<=entry.date { Label("Move now",systemImage:"exclamationmark.octagon.fill").font(.headline) }
                    else {
                        HStack { Image(systemName:g.caution ? "exclamationmark.triangle":"parkingsign.circle.fill")
                            Text(timerInterval:min(entry.date,g.deadline)...g.deadline,countsDown:true).font(.headline.monospacedDigit())
                        }
                    }
                    Text(g.caution && g.deadline>entry.date ? "Check signs · \(g.reason)" : g.reason).font(.caption).lineLimit(2)
                } else { Label("Parkify",systemImage:"parkingsign.circle").font(.headline); Text("No parked car").font(.caption) }
            }.containerBackground(.fill.tertiary,for:.widget).widgetURL(URL(string:"parkify://parking"))
        }.configurationDisplayName("Parking countdown").description("Time to move your car and the reason.").supportedFamilies([.accessoryRectangular])
    }
}
