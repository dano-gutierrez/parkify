import Foundation
import Testing
@testable import ParkifyRules

private let point=Point(x:-122.42,y:37.77)
private func at(_ year:Int,_ month:Int,_ day:Int,_ hour:Int,_ minute:Int=0)->Date {
    Parking.calendar.date(from:.init(year:year,month:month,day:day,hour:hour,minute:minute))!
}
private func curb(_ rules:[Rule],y:Double=37.77)->Curb {
    Curb(id:"A",block:"B",street:"HAYES ST",cross1:"OCTAVIA ST",cross2:"LAGUNA ST",side:"N",line:[.init(x:-122.421,y:y),.init(x:-122.419,y:y)],rules:rules)
}
@Test func oppositeCurbsNeedConfirmation() {
    let curbs=[curb([]),curb([],y:37.77015)]
    #expect(Parking.confident(point,accuracy:2,curbs:curbs))
    #expect(!Parking.confident(Point(x:point.x,y:37.770075),accuracy:7,curbs:curbs))
}
@Test func independentRestrictionsSurvivePermitAndPayment() {
    let now=at(2026,11,24,8)
    var s=Session(point:point,arrival:now,curb:curb([Rule(kind:"park",reason:"Permit time limit",limit:60,permit:"Q"),Rule(kind:"ban",reason:"Tow-away",days:[2],start:540,end:600)]))
    s.paidUntil=at(2026,11,24,12)
    #expect(Parking.evaluate(s,now:now,permit:"Q").event == Event(date:at(2026,11,24,9),reason:"Tow-away"))
    #expect(Parking.evaluate(s,now:at(2026,11,24,9,1),permit:"Q",stale:true).title(at:at(2026,11,24,9,1))=="Move now")
}
@Test func recurrenceHolidaysAndDaylightSaving() {
    let now=at(2026,3,7,14), sweep=Rule(kind:"sweep",reason:"Street cleaning",days:[0],start:420,end:540,weeks:[2,4])
    let s=Session(point:point,arrival:now,curb:curb([sweep]))
    #expect(Parking.evaluate(s,now:now).sweep?.date==at(2026,3,8,7))
    #expect(Parking.evaluate(s,now:now,holidays:["2026-03-08":["daySweep"]]).sweep?.date==at(2026,3,22,7))
}
@Test func editsReplaceObsoleteReminders() {
    let now=at(2026,11,23,16), morning=at(2026,11,24,7)
    let sweep=Event(date:morning,reason:"Street cleaning")
    let initial=Parking.reminders(.init(event:sweep,sweep:sweep),arrival:now,now:now)
    #expect(initial["evening"]==at(2026,11,23,20))
    #expect(initial["advance"]==at(2026,11,24,6,45))
    let expired=Parking.reminders(.init(event:.init(date:now,reason:"Tow-away")),arrival:now,now:now)
    #expect(Set(expired.keys)==["deadline"])
}
