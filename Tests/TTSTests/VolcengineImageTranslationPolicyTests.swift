@testable import TTS
import Foundation

@MainActor
func runVolcengineImageTranslationPolicyChecks() {
    checkHundredthSubmissionIsAllowedAndHundredFirstIsRejected()
    checkAccountUsageIsReconciledBeforeReservation()
    checkUsageResetsWhenTheNaturalMonthChanges()
    checkUploadConsentVersionAndRevocation()
}

@MainActor
private func checkHundredthSubmissionIsAllowedAndHundredFirstIsRejected() {
    let fixture = makeDefaults()
    defer {
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
    }

    let calendar = makeCalendar()
    let date = makeDate(year: 2026, month: 7, day: 29, calendar: calendar)
    let store = VolcengineImageTranslationPolicyStore(
        userDefaults: fixture.defaults,
        calendar: calendar,
        now: { date }
    )

    for _ in 0..<99 {
        try! store.reserveSubmission()
    }
    precondition(store.snapshot.submittedCount == 99)
    precondition(store.snapshot.remainingCount == 1)

    let hundredth = try! store.reserveSubmission()
    precondition(hundredth.submittedCount == 100)
    precondition(hundredth.remainingCount == 0)

    do {
        _ = try store.reserveSubmission()
        preconditionFailure("The 101st submission should be rejected")
    } catch let error as VolcengineImageTranslationPolicyStore.ReservationError {
        precondition(error == .monthlyLimitReached)
    } catch {
        preconditionFailure("Unexpected reservation error: \(error)")
    }

    precondition(store.snapshot.submittedCount == 100)
    precondition(store.snapshot.remainingCount == 0)
}

@MainActor
private func checkAccountUsageIsReconciledBeforeReservation() {
    let fixture = makeDefaults()
    defer {
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
    }

    let store = VolcengineImageTranslationPolicyStore(
        userDefaults: fixture.defaults
    )
    let reservation = try! store.reserveSubmission(accountSubmittedCount: 98)
    precondition(reservation.submittedCount == 99)
    precondition(reservation.remainingCount == 1)

    do {
        _ = try store.reserveSubmission(accountSubmittedCount: 100)
        preconditionFailure("Account usage at the free limit should be rejected")
    } catch let error as VolcengineImageTranslationPolicyStore.ReservationError {
        precondition(error == .monthlyLimitReached)
    } catch {
        preconditionFailure("Unexpected reservation error: \(error)")
    }

    precondition(store.snapshot.submittedCount == 100)
}

@MainActor
private func checkUsageResetsWhenTheNaturalMonthChanges() {
    let fixture = makeDefaults()
    defer {
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
    }

    let calendar = makeCalendar()
    var date = makeDate(year: 2026, month: 7, day: 31, calendar: calendar)
    let store = VolcengineImageTranslationPolicyStore(
        userDefaults: fixture.defaults,
        calendar: calendar,
        now: { date }
    )

    try! store.reserveSubmission()
    try! store.reserveSubmission()
    precondition(store.snapshot.submittedCount == 2)

    date = makeDate(year: 2026, month: 8, day: 1, calendar: calendar)
    precondition(store.snapshot.submittedCount == 0)
    precondition(store.snapshot.remainingCount == 100)

    let firstAugustSubmission = try! store.reserveSubmission()
    precondition(firstAugustSubmission.submittedCount == 1)
    precondition(firstAugustSubmission.remainingCount == 99)
}

@MainActor
private func checkUploadConsentVersionAndRevocation() {
    let fixture = makeDefaults()
    defer {
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
    }

    let versionOneStore = VolcengineImageTranslationPolicyStore(
        userDefaults: fixture.defaults,
        uploadConsentVersion: 1
    )
    precondition(!versionOneStore.hasUploadConsent)

    versionOneStore.grantUploadConsent()
    precondition(versionOneStore.hasUploadConsent)

    let versionTwoStore = VolcengineImageTranslationPolicyStore(
        userDefaults: fixture.defaults,
        uploadConsentVersion: 2
    )
    precondition(!versionTwoStore.hasUploadConsent)

    versionTwoStore.grantUploadConsent()
    precondition(versionTwoStore.hasUploadConsent)
    precondition(!versionOneStore.hasUploadConsent)

    versionTwoStore.revokeUploadConsent()
    precondition(!versionTwoStore.hasUploadConsent)
}

@MainActor
private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "VolcengineImageTranslationPolicyTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

private func makeCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func makeDate(
    year: Int,
    month: Int,
    day: Int,
    calendar: Calendar
) -> Date {
    calendar.date(
        from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        )
    )!
}
