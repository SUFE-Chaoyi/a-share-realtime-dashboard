import Foundation

struct LimitUpStock: Codable {
    let code: String
    let name: String
    let secid: String
    let market: Int
    let dataDate: String
    let close: Double
    let changePct: Double
    var streak: Int

    func dictionary() -> [String: Any] {
        ["code": code, "name": name, "secid": secid, "market": market, "dataDate": dataDate,
         "close": close, "changePct": changePct, "streak": streak]
    }
}

struct LimitUpSnapshot: Codable {
    let date: String
    let generatedAt: Int64
    let source: String
    var finalized: Bool
    let validated: Bool
    var stocks: [LimitUpStock]
    let completeness: [String: AnyCodableValue]
    var failureReason: String?

    init(date: String, generatedAt: Int64, source: String, finalized: Bool, validated: Bool, stocks: [LimitUpStock], completeness: [String: Any], failureReason: String? = nil) {
        self.date = date
        self.generatedAt = generatedAt
        self.source = source
        self.finalized = finalized
        self.validated = validated
        self.stocks = stocks
        self.completeness = completeness.mapValues(AnyCodableValue.init)
        self.failureReason = failureReason
    }

    func dictionary() -> [String: Any] {
        ["date": date, "generatedAt": generatedAt, "source": source, "finalized": finalized,
         "validated": validated, "stocks": stocks.map { $0.dictionary() },
         "completeness": completeness.mapValues { $0.value }, "failureReason": failureReason ?? NSNull()]
    }
}

struct AutoRefreshStatus {
    var state: String = "waiting"
    var dataDate: String?
    var lastValidDate: String?
    var failureReason: String?
    var pendingDates: [String] = []
    var retryCount: Int = 0
    var nextRetryAt: Int64?

    func dictionary() -> [String: Any] {
        ["state": state, "dataDate": dataDate ?? NSNull(), "lastValidDate": lastValidDate ?? NSNull(),
         "failureReason": failureReason ?? NSNull(), "pendingDates": pendingDates,
         "retryCount": retryCount, "nextRetryAt": nextRetryAt.map { $0 as Any } ?? NSNull()]
    }
}

/// JSON 中的完整性字段只允许有限的基础值，避免自动池模型退回 [String: Any]。
struct AnyCodableValue: Codable {
    let value: Any
    init(_ value: Any) { self.value = value }
    init(from decoder: Decoder) throws { value = (try? decoder.singleValueContainer().decode(Bool.self)) ?? (try? decoder.singleValueContainer().decode(Int.self)) ?? (try? decoder.singleValueContainer().decode(Double.self)) ?? (try? decoder.singleValueContainer().decode(String.self)) ?? NSNull() }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let v = value as? Bool { try c.encode(v) } else if let v = value as? Int { try c.encode(v) } else if let v = value as? Double { try c.encode(v) } else if let v = value as? String { try c.encode(v) } else { try c.encodeNil() }
    }
}

final class AutomaticLimitUpManager {
    private let marketData: MarketDataService
    private let historyStore: LimitUpHistoryStore
    private let lock = NSLock()
    private var liveSnapshot: LimitUpSnapshot?
    private var status = AutoRefreshStatus()
    private var operationInFlight = false

    init(marketData: MarketDataService, historyStore: LimitUpHistoryStore) {
        self.marketData = marketData
        self.historyStore = historyStore
        if let latest = try? historyStore.latestSnapshot() {
            liveSnapshot = latest
            status.lastValidDate = latest.date
            status.dataDate = latest.date
            status.state = "final"
        }
    }

    func responseObject() -> [String: Any] {
        lock.lock(); let current = liveSnapshot; let currentStatus = status; lock.unlock()
        let snapshot = current ?? (try? historyStore.latestSnapshot()) ?? nil
        return ["snapshot": snapshot?.dictionary() ?? NSNull(), "status": currentStatus.dictionary(), "pools": snapshot.map { Self.pools(from: $0) } ?? []]
    }

    func requestLive(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        runOnce(finalize: false, requestedDate: nil) { result in
            completion(result.map { ["snapshot": $0.dictionary(), "status": self.responseObject()["status"] ?? [:], "pools": Self.pools(from: $0)] })
        }
    }

    func finalizeLatest(completion: @escaping (Result<LimitUpSnapshot, Error>) -> Void) {
        runOnce(finalize: true, requestedDate: nil, completion: completion)
    }

    func backfill(from startDate: String, completion: @escaping ([String], [String]) -> Void) {
        guard let start = Self.date(from: startDate) else { completion([], ["起始日期无效：\(startDate)"]); return }
        let end = Date()
        let calendar = Self.calendar
        var date = start
        var success: [String] = []; var failures: [String] = []
        func next() {
            if date > end {
                self.lock.lock()
                self.status.pendingDates = failures.compactMap { $0.split(separator: ":", maxSplits: 1).first.map(String.init) }
                if !failures.isEmpty {
                    self.status.state = "pending"
                    self.status.failureReason = failures.joined(separator: "；")
                }
                self.lock.unlock()
                completion(success, failures)
                return
            }
            let current = Self.dateString(date); date = calendar.date(byAdding: .day, value: 1, to: date)!
            marketData.fetchLimitUpSnapshot(for: current) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    // 非交易日也会返回 data=null；此处记录为跳过而非伪造日期。
                    if !(error.localizedDescription.contains("返回缺少完整") || error.localizedDescription.contains("暂时不可用")) { failures.append("\(current)：\(error.localizedDescription)") }
                case .success(let raw):
                    do { let strict = try self.strictSnapshot(raw); try self.historyStore.upsertSnapshot(snapshot: strict); success.append(current) }
                    catch { failures.append("\(current)：\(error.localizedDescription)") }
                }
                next()
            }
        }
        next()
    }

    private func runOnce(finalize: Bool, requestedDate: String?, completion: @escaping (Result<LimitUpSnapshot, Error>) -> Void) {
        lock.lock()
        if operationInFlight { lock.unlock(); completion(.failure(MarketDataError.upstream("自动池刷新正在进行，已合并本次请求"))); return }
        operationInFlight = true; lock.unlock()
        marketData.fetchLimitUpSnapshot(for: requestedDate) { [weak self] result in
            guard let self else { return }
            let output: Result<LimitUpSnapshot, Error>
            switch result {
            case .failure(let error):
                self.lock.lock(); self.status.state = "failed"; self.status.failureReason = error.localizedDescription; self.status.retryCount += 1; self.status.nextRetryAt = Int64(Date().timeIntervalSince1970 * 1000) + 300_000; self.lock.unlock(); output = .failure(error)
            case .success(let raw):
                do {
                    var snapshot = try self.strictSnapshot(raw); snapshot.finalized = finalize
                    if finalize { try self.historyStore.upsertSnapshot(snapshot: snapshot) }
                    self.lock.lock(); self.liveSnapshot = snapshot; self.status = AutoRefreshStatus(state: finalize ? "final" : "live", dataDate: snapshot.date, lastValidDate: snapshot.date, failureReason: nil, pendingDates: [], retryCount: 0, nextRetryAt: nil); self.lock.unlock(); output = .success(snapshot)
                } catch { self.lock.lock(); self.status.state = "failed"; self.status.failureReason = error.localizedDescription; self.status.retryCount += 1; self.lock.unlock(); output = .failure(error) }
            }
            self.lock.lock(); self.operationInFlight = false; self.lock.unlock(); completion(output)
        }
    }

    private func strictSnapshot(_ raw: LimitUpSnapshot) throws -> LimitUpSnapshot {
        guard raw.validated, raw.date == raw.stocks.first?.dataDate || raw.stocks.isEmpty else { throw MarketDataError.invalidResponse("快照股票日期不一致") }
        let previous = try historyStore.previousSnapshot(before: raw.date)
        var stocks = raw.stocks
        if let previous {
            let priorByCode = Dictionary(uniqueKeysWithValues: previous.stocks.compactMap { ($0.code, $0.streak) })
            stocks = stocks.map { stock in var copy = stock; copy.streak = (priorByCode[stock.code] ?? 0) + 1; return copy }
        }
        return LimitUpSnapshot(date: raw.date, generatedAt: raw.generatedAt, source: raw.source, finalized: raw.finalized, validated: true, stocks: stocks, completeness: raw.completeness)
    }

    static func pools(from snapshot: LimitUpSnapshot) -> [[String: Any]] {
        let grouped = Dictionary(grouping: snapshot.stocks, by: { $0.streak })
        return grouped.keys.sorted().compactMap { streak in
            guard let stocks = grouped[streak], !stocks.isEmpty else { return nil }
            let name = streak == 1 ? "首板池" : "\(streak)板池"
            return ["id": "auto_limit_up_\(streak)", "name": name, "kind": "automatic", "rule": "limit_up_\(streak)", "dataDate": snapshot.date, "generatedAt": snapshot.generatedAt, "createdAt": Int64(streak), "stocks": stocks.map { ["code": $0.code, "name": $0.name, "secid": $0.secid] }]
        }
    }

    private static let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }()
    private static func date(from text: String) -> Date? { guard text.range(of: #"^\d{8}$"#, options: .regularExpression) != nil else { return nil }; return calendar.date(from: DateComponents(year: Int(text.prefix(4)), month: Int(text.dropFirst(4).prefix(2)), day: Int(text.suffix(2)))) }
    private static func dateString(_ date: Date) -> String { let c = calendar.dateComponents([.year, .month, .day], from: date); return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0) }
}
