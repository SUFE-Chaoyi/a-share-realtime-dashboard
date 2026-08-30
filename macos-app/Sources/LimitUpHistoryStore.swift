import Foundation

enum HistoryStoreError: LocalizedError {
    case invalid(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .notFound(let message):
            return message
        }
    }
}

/// 历史涨停梯队快照存储（data/limit-up-history.json，version 2）。
/// 每个交易日保留一份完整快照；写入一律原子替换；文件损坏时拒绝覆盖并报错。
final class LimitUpHistoryStore {
    let fileURL: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: fileURL.path) {
            let empty: [String: Any] = [
                "version": 2,
                "updatedAt": Int64(Date().timeIntervalSince1970 * 1000),
                "records": [Any]()
            ]
            try encode(empty).write(to: fileURL, options: .atomic)
        }
    }

    /// 读取并校验全部快照（按日期升序）。文件损坏时抛出 invalid，绝不修改原文件。
    func loadRecords() throws -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return try loadRecordsLocked()
    }

    func dates() throws -> [String] {
        try loadRecords().compactMap { $0["date"] as? String }
    }

    /// 只接受已校验的收盘定版快照。盘中暂态由内存投影承载，绝不进入历史文件。
    func upsertSnapshot(snapshot: LimitUpSnapshot) throws {
        guard snapshot.validated, snapshot.finalized else {
            throw HistoryStoreError.invalid("仅允许写入已校验的收盘定版快照")
        }
        lock.lock()
        defer { lock.unlock() }
        let record = try Self.normalizeRecord([
            "date": snapshot.date,
            "source": snapshot.source,
            "generatedAt": snapshot.generatedAt,
            "finalized": true,
            "validated": true,
            "stocks": snapshot.stocks.map { $0.dictionary() }
        ], context: "交易日 \(snapshot.date) 快照")
        var merged: [String: [String: Any]] = [:]
        for existing in try loadRecordsLocked() {
            if let d = existing["date"] as? String { merged[d] = existing }
        }
        // 已定版记录只有在新的完整、已校验定版到达时才允许替换；失败/部分结果没有写入口。
        merged[snapshot.date] = record
        try writeRecordsLocked(Array(merged.values))
    }

    func latestSnapshot() throws -> LimitUpSnapshot? {
        try loadRecords().last.flatMap(Self.snapshot(from:))
    }

    func previousSnapshot(before date: String) throws -> LimitUpSnapshot? {
        try loadRecords().filter { ($0["date"] as? String ?? "") < date }.last.flatMap(Self.snapshot(from:))
    }

    // MARK: - 内部实现

    private func loadRecordsLocked() throws -> [[String: Any]] {
        let raw: Data
        do {
            raw = try Data(contentsOf: fileURL)
        } catch {
            throw HistoryStoreError.invalid("历史文件读取失败：\(error.localizedDescription)")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: raw, options: [])
        } catch {
            throw HistoryStoreError.invalid("历史文件 JSON 格式错误，请修复或删除后重新导入（原文件未被修改）")
        }
        guard let root = object as? [String: Any] else {
            throw HistoryStoreError.invalid("历史文件顶层必须是对象（原文件未被修改）")
        }
        guard (root["version"] as? NSNumber)?.intValue == 2 else {
            throw HistoryStoreError.invalid("历史文件版本不受支持（原文件未被修改）")
        }
        guard let rawRecords = root["records"] as? [Any] else {
            throw HistoryStoreError.invalid("历史文件 records 必须是数组（原文件未被修改）")
        }
        var records: [[String: Any]] = []
        var seenDates = Set<String>()
        for (index, rawRecord) in rawRecords.enumerated() {
            let record = try Self.normalizeRecord(rawRecord, context: "历史文件第 \(index + 1) 条记录")
            let date = record["date"] as? String ?? ""
            guard !seenDates.contains(date) else {
                throw HistoryStoreError.invalid("历史文件中日期 \(date) 重复（原文件未被修改）")
            }
            seenDates.insert(date)
            records.append(record)
        }
        records.sort { ($0["date"] as? String ?? "") < ($1["date"] as? String ?? "") }
        return records
    }

    private func writeRecordsLocked(_ records: [[String: Any]]) throws {
        let sorted = records.sorted { ($0["date"] as? String ?? "") < ($1["date"] as? String ?? "") }
        let payload: [String: Any] = [
            "version": 2,
            "updatedAt": Int64(Date().timeIntervalSince1970 * 1000),
            "records": sorted
        ]
        let data = try encode(payload)
        // 原子写入：先写临时文件再替换，防止写入中断损坏历史文件
        let temporaryURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".limit-up-history.\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            // 目标文件可能尚不存在，退化为原子重命名
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch let writeError {
                throw HistoryStoreError.invalid("历史文件写入失败：\(writeError.localizedDescription)")
            }
        }
    }

    static func normalizeRecord(_ raw: Any, context: String) throws -> [String: Any] {
        guard let record = raw as? [String: Any] else {
            throw HistoryStoreError.invalid("\(context)：必须是对象")
        }
        guard let date = (record["date"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              date.range(of: #"^\d{8}$"#, options: .regularExpression) != nil else {
            throw HistoryStoreError.invalid("\(context)：日期必须是 YYYYMMDD 格式")
        }
        let today = todayString()
        guard date <= today else {
            throw HistoryStoreError.invalid("\(context)：拒绝未来日期 \(date)")
        }
        guard let rawStocks = record["stocks"] as? [Any] else {
            throw HistoryStoreError.invalid("\(context)：stocks 必须是数组（日期 \(date)）")
        }
        var stocks: [[String: Any]] = []
        var seenCodes = Set<String>()
        for (index, rawStock) in rawStocks.enumerated() {
            guard let stock = rawStock as? [String: Any] else {
                throw HistoryStoreError.invalid("\(context)：第 \(index + 1) 只股票必须是对象（日期 \(date)）")
            }
            guard let code = (stock["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  code.range(of: #"^\d{6}$"#, options: .regularExpression) != nil else {
                throw HistoryStoreError.invalid("\(context)：第 \(index + 1) 只股票代码无效（日期 \(date)）")
            }
            guard let secid = secid(for: code) else {
                throw HistoryStoreError.invalid("\(context)：代码 \(code) 不属于沪深市场（日期 \(date)）")
            }
            if let rawSecid = stock["secid"] as? String, !rawSecid.isEmpty, rawSecid != secid {
                throw HistoryStoreError.invalid("\(context)：代码 \(code) 的 secid 与市场不符（日期 \(date)）")
            }
            guard !seenCodes.contains(code) else {
                throw HistoryStoreError.invalid("\(context)：同一日期 \(date) 出现重复代码 \(code)")
            }
            seenCodes.insert(code)
            let name = ((stock["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? code
            guard let streak = (stock["streak"] as? NSNumber)?.intValue, streak >= 1 else {
                throw HistoryStoreError.invalid("\(context)：代码 \(code) 板位无效（日期 \(date)）")
            }
            guard let close = (stock["close"] as? NSNumber)?.doubleValue, close > 0 else {
                throw HistoryStoreError.invalid("\(context)：代码 \(code) 收盘价无效（日期 \(date)）")
            }
            guard let changePct = (stock["changePct"] as? NSNumber)?.doubleValue else {
                throw HistoryStoreError.invalid("\(context)：代码 \(code) 涨跌幅无效（日期 \(date)）")
            }
            stocks.append([
                "code": code,
                "name": name,
                "secid": secid,
                "streak": streak,
                "close": close,
                "changePct": changePct
            ])
        }
        stocks.sort { lhs, rhs in
            let lStreak = (lhs["streak"] as? Int) ?? 0
            let rStreak = (rhs["streak"] as? Int) ?? 0
            if lStreak != rStreak { return lStreak > rStreak }
            return (lhs["code"] as? String ?? "") < (rhs["code"] as? String ?? "")
        }
        let source = ((record["source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "东方财富"
        return [
            "date": date,
            "source": source,
            "generatedAt": (record["generatedAt"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000),
            "finalized": (record["finalized"] as? Bool) ?? false,
            "stocks": stocks
        ]
    }

    private static func snapshot(from record: [String: Any]) -> LimitUpSnapshot? {
        guard let date = record["date"] as? String, let rawStocks = record["stocks"] as? [[String: Any]] else { return nil }
        let stocks = rawStocks.compactMap { raw -> LimitUpStock? in
            guard let code = raw["code"] as? String, let name = raw["name"] as? String, let secid = raw["secid"] as? String,
                  let streak = (raw["streak"] as? NSNumber)?.intValue, let close = (raw["close"] as? NSNumber)?.doubleValue,
                  let changePct = (raw["changePct"] as? NSNumber)?.doubleValue else { return nil }
            let market = secid.hasPrefix("1.") ? 1 : 0
            return LimitUpStock(code: code, name: name, secid: secid, market: market, dataDate: date, close: close, changePct: changePct, streak: streak)
        }
        guard stocks.count == rawStocks.count else { return nil }
        return LimitUpSnapshot(date: date, generatedAt: (record["generatedAt"] as? NSNumber)?.int64Value ?? 0, source: record["source"] as? String ?? "东方财富", finalized: (record["finalized"] as? Bool) ?? true, validated: (record["validated"] as? Bool) ?? true, stocks: stocks, completeness: ["stored": true])
    }

    /// 沪深代码推导 secid；北交所及其他市场返回 nil（历史梯队口径为沪深、剔除北交所）
    static func secid(for code: String) -> String? {
        if code.hasPrefix("000") || code.hasPrefix("001") || code.hasPrefix("002") ||
           code.hasPrefix("003") || code.hasPrefix("300") || code.hasPrefix("301") {
            return "0.\(code)"
        }
        if code.hasPrefix("600") || code.hasPrefix("601") || code.hasPrefix("603") ||
           code.hasPrefix("605") || code.hasPrefix("688") || code.hasPrefix("689") {
            return "1.\(code)"
        }
        return nil
    }

    private static func todayString() -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let components = calendar.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d%02d%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func encode(_ object: Any) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }
}
