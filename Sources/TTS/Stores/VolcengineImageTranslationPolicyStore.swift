import Foundation

@MainActor
final class VolcengineImageTranslationPolicyStore {
    nonisolated static let monthlySubmissionLimit = 100
    nonisolated static let currentUploadConsentVersion = 1

    struct Snapshot: Equatable {
        let submittedCount: Int
        let limit: Int
        let remainingCount: Int
        let resetsAt: Date?
        let hasUploadConsent: Bool
    }

    enum ReservationError: Error, Equatable, LocalizedError {
        case monthlyLimitReached

        var errorDescription: String? {
            "本月图片翻译安全计数已达到 100 次上限。"
        }
    }

    private struct MonthIdentifier: Codable, Equatable {
        let era: Int
        let year: Int
        let month: Int
    }

    private struct StoredUsage: Codable, Equatable {
        let month: MonthIdentifier
        var submittedCount: Int
    }

    private enum Keys {
        static let monthlyUsage = "volcengineImageTranslation.monthlyUsage.v1"
        static let uploadConsentVersion = "volcengineImageTranslation.uploadConsentVersion"
    }

    private let userDefaults: UserDefaults
    private let calendar: Calendar
    private let now: @MainActor () -> Date
    private let uploadConsentVersion: Int

    init(
        userDefaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        now: @escaping @MainActor () -> Date = { Date() },
        uploadConsentVersion: Int = currentUploadConsentVersion
    ) {
        precondition(uploadConsentVersion > 0)
        self.userDefaults = userDefaults
        self.calendar = calendar
        self.now = now
        self.uploadConsentVersion = uploadConsentVersion
    }

    var snapshot: Snapshot {
        snapshot(at: now())
    }

    var remainingCount: Int {
        snapshot.remainingCount
    }

    var hasUploadConsent: Bool {
        userDefaults.integer(forKey: Keys.uploadConsentVersion) == uploadConsentVersion
    }

    func grantUploadConsent() {
        userDefaults.set(uploadConsentVersion, forKey: Keys.uploadConsentVersion)
    }

    func revokeUploadConsent() {
        userDefaults.removeObject(forKey: Keys.uploadConsentVersion)
    }

    /// Reserve before starting a cloud request. A later request failure intentionally
    /// does not release this reservation. Account usage is reconciled conservatively
    /// so usage from another device cannot lower this machine's count.
    @discardableResult
    func reserveSubmission(accountSubmittedCount: Int? = nil) throws -> Snapshot {
        let date = now()
        var usage = normalizedUsage(at: date)
        if let accountSubmittedCount {
            usage.submittedCount = max(
                usage.submittedCount,
                min(max(accountSubmittedCount, 0), Self.monthlySubmissionLimit)
            )
        }
        guard usage.submittedCount < Self.monthlySubmissionLimit else {
            persist(usage)
            throw ReservationError.monthlyLimitReached
        }

        usage.submittedCount += 1
        persist(usage)
        return makeSnapshot(usage: usage, at: date)
    }

    private func snapshot(at date: Date) -> Snapshot {
        makeSnapshot(usage: normalizedUsage(at: date), at: date)
    }

    private func makeSnapshot(usage: StoredUsage, at date: Date) -> Snapshot {
        Snapshot(
            submittedCount: usage.submittedCount,
            limit: Self.monthlySubmissionLimit,
            remainingCount: Self.monthlySubmissionLimit - usage.submittedCount,
            resetsAt: calendar.dateInterval(of: .month, for: date)?.end,
            hasUploadConsent: hasUploadConsent
        )
    }

    private func normalizedUsage(at date: Date) -> StoredUsage {
        let currentMonth = monthIdentifier(for: date)
        guard
            let data = userDefaults.data(forKey: Keys.monthlyUsage),
            var usage = try? JSONDecoder().decode(StoredUsage.self, from: data),
            usage.month == currentMonth
        else {
            let usage = StoredUsage(month: currentMonth, submittedCount: 0)
            persist(usage)
            return usage
        }

        let normalizedCount = min(
            max(usage.submittedCount, 0),
            Self.monthlySubmissionLimit
        )
        if normalizedCount != usage.submittedCount {
            usage.submittedCount = normalizedCount
            persist(usage)
        }
        return usage
    }

    private func monthIdentifier(for date: Date) -> MonthIdentifier {
        let components = calendar.dateComponents([.era, .year, .month], from: date)
        return MonthIdentifier(
            era: components.era ?? 0,
            year: components.year ?? 0,
            month: components.month ?? 0
        )
    }

    private func persist(_ usage: StoredUsage) {
        guard let data = try? JSONEncoder().encode(usage) else {
            return
        }
        userDefaults.set(data, forKey: Keys.monthlyUsage)
    }
}
