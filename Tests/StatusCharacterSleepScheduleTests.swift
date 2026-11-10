import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main
private enum StatusCharacterSleepScheduleTests {
    static func main() {
        var timeline = CharacterMotionTimeline()
        timeline.setState(.rest, at: 0)
        let start = StatusCharacterSleepSchedule.pose(timeline: timeline, time: 0, frameCount: 6)
        let settling = StatusCharacterSleepSchedule.pose(timeline: timeline, time: 0.4, frameCount: 6)
        expect(start.sleepStep == 0 && settling.sleepStep == 4, "initial sleep transition stays smooth")
        expect(StatusCharacterSleepSchedule.pose(timeline: timeline, time: 2, frameCount: 6).zFrame >= 0,
               "initial burst preserves the Z effect")
        let resting = StatusCharacterSleepSchedule.pose(timeline: timeline, time: 4, frameCount: 6)
        for time in [5.0, 12, 19.9] {
            expect(StatusCharacterSleepSchedule.pose(timeline: timeline, time: time, frameCount: 6) == resting,
                   "quiet period reuses one sleeping image")
        }
        let nextBurst = StatusCharacterSleepSchedule.pose(timeline: timeline, time: 20.2, frameCount: 6)
        expect(nextBurst.sleepStep == 8 && nextBurst.zFrame >= 0, "periodic effects never wake the character")
        var time = 0.0
        var ticks = 0
        while time < 60 {
            let delay = max(0.01, StatusCharacterSleepSchedule.nextDelay(elapsed: time))
            expect(delay > 0, "the scheduler must not spin at a floating-point boundary")
            time += delay
            ticks += 1
        }
        expect(ticks < 125, "one minute of rest needs at least 79% fewer wakeups than the 600-tick loop")
        timeline.setState(.active, at: 5)
        expect(timeline.pose(at: 5.25).frame == 2, "activity immediately restores normal cadence")
        print("StatusCharacterSleepScheduleTests: PASS (\(ticks) ticks / 60s)")
    }
}
