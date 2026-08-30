import Foundation

enum MarketDataError: LocalizedError {
    case invalidRequest(String)
    case upstream(String)
    case invalidResponse(String)
    var errorDescription: String? { switch self { case .invalidRequest(let s), .upstream(let s), .invalidResponse(let s): return s } }
}

/// 东方财富单源客户端。自动池使用指定日期的涨停专题池，不再全市场扫描后逐只请求 K 线。
final class MarketDataService {
    private let quoteEndpoint = URL(string: "https://push2.eastmoney.com/api/qt/ulist.np/get")!
    private let quoteFallbackEndpoint = URL(string: "https://push2delay.eastmoney.com/api/qt/ulist.np/get")!
    private let ztEndpoint = URL(string: "https://push2ex.eastmoney.com/getTopicZTPool")!
    private let searchEndpoint = URL(string: "https://searchapi.eastmoney.com/api/suggest/get")!
    private let searchToken = "D43BF722C8E33BDC906FB84D85E326E8"
    private let cacheURL: URL
    private let session: URLSession
    private let workQueue = DispatchQueue(label: "local.stock-dashboard.market-data", qos: .userInitiated)
    private let cacheQueue = DispatchQueue(label: "local.stock-dashboard.quote-cache")
    private var quoteCache: [String: [String: Any]] = [:]
    private var cacheDirty = false
    private var lastCachePersistedAt: Int64?
    private var limitUpInFlight = false
    private var limitUpWaiters: [(Result<LimitUpSnapshot, Error>) -> Void] = []

    init(cacheURL: URL) {
        self.cacheURL = cacheURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: configuration)
        self.quoteCache = Self.loadCache(from: cacheURL)
    }

    func fetchQuotes(secids: [String], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let unique = Array(Set(secids)).sorted()
        guard unique.count <= 20_000 else { completion(.failure(MarketDataError.invalidRequest("单次行情请求股票数量过多"))); return }
        guard unique.allSatisfy(Self.isValidSecID) else { completion(.failure(MarketDataError.invalidRequest("行情请求包含无效证券代码"))); return }
        guard !unique.isEmpty else { completion(.success(emptyQuoteResponse())); return }
        let batches = stride(from: 0, to: unique.count, by: 80).map { Array(unique[$0..<min($0 + 80, unique.count)]) }
        fetchQuoteBatches(batches, index: 0, rows: [], failures: 0) { [weak self] rows, failures in
            guard let self else { return }
            let response = self.mergeQuotes(requested: unique, rows: rows, failures: failures)
            if response["receivedCount"] as? Int == 0 && failures == batches.count { completion(.failure(MarketDataError.upstream("行情服务暂时不可用，且没有可用缓存"))) }
            else { completion(.success(response)) }
        }
    }

    func flushCacheIfNeeded() { cacheQueue.sync { persistCacheIfNeededLocked(updatedAt: nowMilliseconds(), force: true) } }

    static func isTradingSessionNow() -> Bool {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: Date())
        guard let w = c.weekday, (2...6).contains(w), let h = c.hour, let m = c.minute else { return false }
        let value = h * 60 + m
        return (555...690).contains(value) || (780...905).contains(value)
    }

    /// 单飞：重叠调用合并为同一次东方财富专题请求，避免 5 秒刷新产生并发重算。
    func fetchLimitUpSnapshot(for requestedDate: String? = nil, completion: @escaping (Result<LimitUpSnapshot, Error>) -> Void) {
        workQueue.async {
            self.limitUpWaiters.append(completion)
            guard !self.limitUpInFlight else { return }
            self.limitUpInFlight = true
            self.fetchLimitUpSnapshotPage(requestedDate: requestedDate, page: 0, pageSize: 100, collected: []) { result in
                self.workQueue.async {
                    let waiters = self.limitUpWaiters
                    self.limitUpWaiters.removeAll()
                    self.limitUpInFlight = false
                    waiters.forEach { $0(result) }
                }
            }
        }
    }

    private func fetchLimitUpSnapshotPage(requestedDate: String?, page: Int, pageSize: Int, collected: [[String: Any]], completion: @escaping (Result<LimitUpSnapshot, Error>) -> Void) {
        var components = URLComponents(url: ztEndpoint, resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "ut", value: "7eea3edcaed734bea9cbfc24409ed989"), URLQueryItem(name: "dpt", value: "wz.ztzt"), URLQueryItem(name: "Pageindex", value: String(page)), URLQueryItem(name: "pagesize", value: String(pageSize)), URLQueryItem(name: "sort", value: "fbt:asc")]
        if let requestedDate { items.append(URLQueryItem(name: "date", value: requestedDate)) }
        components.queryItems = items
        guard let url = components.url else { completion(.failure(MarketDataError.invalidRequest("无法构造东方财富涨停池请求"))); return }
        performRequest(url: url) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let data):
                do {
                    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], (root["rc"] as? NSNumber)?.intValue == 0, let payload = root["data"] as? [String: Any], let qdate = Self.normalizedDate(payload["qdate"]), let total = (payload["tc"] as? NSNumber)?.intValue, let rawPool = payload["pool"] as? [[String: Any]] else { throw MarketDataError.invalidResponse("东方财富涨停池返回缺少完整 data/qdate/tc/pool") }
                    if let requestedDate, let requestedInt = Int(requestedDate), let qdateInt = Int(qdate), requestedInt > qdateInt { throw MarketDataError.invalidResponse("东方财富尚未形成目标日期 \(requestedDate) 的收盘数据") }
                    let merged = collected + rawPool
                    if let requestedDate, total == 0 { throw MarketDataError.invalidResponse("东方财富未返回目标交易日 \(requestedDate) 的涨停池") }
                    if merged.count < total {
                        guard !rawPool.isEmpty else { throw MarketDataError.invalidResponse("东方财富涨停池分页提前结束") }
                        self.fetchLimitUpSnapshotPage(requestedDate: requestedDate, page: page + 1, pageSize: pageSize, collected: merged, completion: completion)
                        return
                    }
                    guard merged.count == total else { throw MarketDataError.invalidResponse("东方财富涨停池总数校验失败：声明 \(total)，采集 \(merged.count)") }
                    let effectiveDate = requestedDate ?? qdate
                    let stocks = try self.normalizeLimitUpRows(merged, date: effectiveDate)
                    completion(.success(LimitUpSnapshot(date: effectiveDate, generatedAt: self.nowMilliseconds(), source: "东方财富", finalized: false, validated: true, stocks: stocks, completeness: ["upstreamTotal": total, "collected": merged.count, "accepted": stocks.count, "pagesComplete": true])))
                } catch { completion(.failure(error)) }
            }
        }
    }

    private func normalizeLimitUpRows(_ rows: [[String: Any]], date: String) throws -> [LimitUpStock] {
        var seen = Set<String>(); var result: [LimitUpStock] = []
        for row in rows {
            guard let code = Self.stringValue(row["c"]), code.range(of: #"^\d{6}$"#, options: .regularExpression) != nil, let market = (row["m"] as? NSNumber)?.intValue, market == 0 || market == 1 else { throw MarketDataError.invalidResponse("东方财富涨停池存在字段不完整或市场字段异常") }
            if code.hasPrefix("4") || code.hasPrefix("8") || code.hasPrefix("920") { continue }
            guard let name = Self.stringValue(row["n"]), !name.isEmpty, let rawPrice = Self.doubleValue(row["p"]), rawPrice > 0, let changePct = Self.doubleValue(row["zdp"]), changePct.isFinite, let upstreamStreak = (row["lbc"] as? NSNumber)?.intValue, upstreamStreak >= 1 else { throw MarketDataError.invalidResponse("东方财富涨停池存在字段不完整或无法归一化的股票") }
            guard let secid = Self.secid(for: code, market: market), !seen.contains(secid) else { throw MarketDataError.invalidResponse("东方财富涨停池存在重复代码或非法市场映射") }
            seen.insert(secid)
            // 专题池 p 的单位为厘；zdp 已是百分比，不能再次缩放。
            result.append(LimitUpStock(code: code, name: name, secid: secid, market: market, dataDate: date, close: rawPrice / 1000.0, changePct: changePct, streak: upstreamStreak))
        }
        return result.sorted { $0.code < $1.code }
    }

    func evaluatePromotions(stocks: [[String: Any]], dataDate: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        fetchQuotes(secids: stocks.compactMap { $0["secid"] as? String }) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let response):
                let rows = response["quotes"] as? [[String: Any]] ?? []
                var byID: [String: [String: Any]] = [:]; rows.forEach { if let id = $0["secid"] as? String { byID[id] = $0 } }
                let dayInt = Int(dataDate) ?? 0; var statuses: [String: String] = [:]; var hasNextDayQuotes = false
                for stock in stocks {
                    guard let id = stock["secid"] as? String else { continue }
                    guard let quote = byID[id], let quoteDate = Self.intValue(quote["quoteDate"]), quoteDate > dayInt else { statuses[id] = "pending"; continue }
                    hasNextDayQuotes = true
                    let code = quote["code"] as? String ?? stock["code"] as? String ?? ""; let name = quote["name"] as? String ?? stock["name"] as? String ?? ""
                    guard let price = (quote["price"] as? NSNumber)?.doubleValue, let previousClose = (quote["prevClose"] as? NSNumber)?.doubleValue, price > 0, previousClose > 0, (quote["isSuspended"] as? Bool) != true else { statuses[id] = "unknown"; continue }
                    statuses[id] = Self.isLimitPrice(price, previousClose: previousClose, code: code, name: name) ? "yes" : "no"
                }
                completion(.success(["statuses": statuses, "hasNextDayQuotes": hasNextDayQuotes]))
            }
        }
    }

    func searchStocks(keyword: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let normalized = keyword.trimmingCharacters(in: .whitespacesAndNewlines); guard !normalized.isEmpty, normalized.count <= 40 else { completion(.failure(MarketDataError.invalidRequest("搜索关键词无效"))); return }
        var c = URLComponents(url: searchEndpoint, resolvingAgainstBaseURL: false)!; c.queryItems = [URLQueryItem(name: "input", value: normalized), URLQueryItem(name: "type", value: "14"), URLQueryItem(name: "token", value: searchToken)]
        guard let url = c.url else { completion(.failure(MarketDataError.invalidRequest("无法构造搜索请求"))); return }
        performRequest(url: url) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let data):
                do {
                    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]; let rows = ((root?["QuotationCodeTable"] as? [String: Any])?["Data"] as? [[String: Any]]) ?? []; var stocks: [[String: String]] = []
                    for row in rows { guard let code = Self.stringValue(row["Code"]), let name = Self.stringValue(row["Name"]), Self.isAShareCode(code) else { continue }; let secid = Self.stringValue(row["QuoteID"]) ?? "\(Self.market(for: code)).\(code)"; guard Self.isValidSecID(secid) else { continue }; stocks.append(["code": code, "name": name, "secid": secid]); if stocks.count == 20 { break } }
                    completion(.success(["stocks": stocks, "source": "东方财富"]))
                } catch { completion(.failure(MarketDataError.invalidResponse("股票搜索返回了无效数据"))) }
            }
        }
    }

    private func fetchQuoteBatches(_ batches: [[String]], index: Int, rows: [[String: Any]], failures: Int, completion: @escaping ([[String: Any]], Int) -> Void) {
        guard index < batches.count else { completion(rows, failures); return }; let group = DispatchGroup(); let lock = NSLock(); var all = rows; var failed = failures
        for batch in batches[index..<min(index + 3, batches.count)] { group.enter(); fetchQuoteBatch(batch) { result in lock.lock(); switch result { case .success(let values): all.append(contentsOf: values); case .failure: failed += 1 }; lock.unlock(); group.leave() } }
        group.notify(queue: workQueue) { self.fetchQuoteBatches(batches, index: min(index + 3, batches.count), rows: all, failures: failed, completion: completion) }
    }

    private func fetchQuoteBatch(_ secids: [String], completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
        var c = URLComponents(url: quoteEndpoint, resolvingAgainstBaseURL: false)!; c.queryItems = [URLQueryItem(name: "fltt", value: "2"), URLQueryItem(name: "invt", value: "2"), URLQueryItem(name: "secids", value: secids.joined(separator: ",")), URLQueryItem(name: "fields", value: "f1,f2,f3,f4,f5,f6,f12,f13,f14,f15,f16,f17,f18,f21,f26,f62,f124,f297")]; guard let url = c.url else { completion(.failure(MarketDataError.invalidRequest("无法构造行情请求"))); return }
        performRequest(url: url) { [weak self] result in
            guard let self else { return }; switch result { case .success(let data): self.parseQuoteData(data, completion: completion); case .failure:
                var fallback = URLComponents(url: self.quoteFallbackEndpoint, resolvingAgainstBaseURL: false)!; fallback.queryItems = c.queryItems; guard let fallbackURL = fallback.url else { completion(.failure(MarketDataError.upstream("行情请求失败"))); return }; self.performRequest(url: fallbackURL) { self.parseQuoteResponse($0, completion: completion) }
            }
        }
    }
    private func parseQuoteResponse(_ result: Result<Data, Error>, completion: @escaping (Result<[[String: Any]], Error>) -> Void) { switch result { case .failure(let e): completion(.failure(e)); case .success(let d): parseQuoteData(d, completion: completion) } }
    private func parseQuoteData(_ data: Data, completion: @escaping (Result<[[String: Any]], Error>) -> Void) { do { guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let payload = root["data"] as? [String: Any] else { throw MarketDataError.invalidResponse("行情服务返回了无效数据") }; let raw = payload["diff"] as? [[String: Any]] ?? ((payload["diff"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []); completion(.success(raw.compactMap(Self.normalizeQuote))) } catch { completion(.failure(error)) } }
    private func mergeQuotes(requested: [String], rows: [[String: Any]], failures: Int) -> [String: Any] { let fresh = rows.filter(Self.hasUsableMarketData); let ids = Set(fresh.compactMap { $0["secid"] as? String }); let fetchedAt = nowMilliseconds(); cacheQueue.sync { fresh.forEach { if let id = $0["secid"] as? String { quoteCache[id] = $0 } }; let wanted = Set(requested); quoteCache = quoteCache.filter { wanted.contains($0.key) }; if !fresh.isEmpty { cacheDirty = true; persistCacheIfNeededLocked(updatedAt: fetchedAt, force: false) } }; let visible = fresh.map { var q = $0; q["isCached"] = false; return q }; return ["quotes": visible, "requestedCount": requested.count, "receivedCount": visible.count, "freshCount": ids.count, "cachedCount": 0, "failedBatches": failures, "partial": failures > 0 || ids.count < requested.count, "liveUnavailable": ids.isEmpty, "fetchedAt": fetchedAt, "source": "东方财富"] }
    private func emptyQuoteResponse() -> [String: Any] { ["quotes": [], "requestedCount": 0, "receivedCount": 0, "freshCount": 0, "cachedCount": 0, "failedBatches": 0, "partial": false, "liveUnavailable": false, "fetchedAt": nowMilliseconds(), "source": "东方财富"] }
    private func performRequest(url: URL, completion: @escaping (Result<Data, Error>) -> Void) { var request = URLRequest(url: url); request.httpMethod = "GET"; request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/131.0 Safari/537.36", forHTTPHeaderField: "User-Agent"); request.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer"); session.dataTask(with: request) { data, response, error in if let error { completion(.failure(MarketDataError.upstream("东方财富网络请求失败：\(error.localizedDescription)"))); return }; guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else { completion(.failure(MarketDataError.upstream("东方财富服务暂时不可用"))); return }; completion(.success(data)) }.resume() }
    private func persistCacheIfNeededLocked(updatedAt: Int64, force: Bool) { guard cacheDirty, force || Self.isPollingTime(updatedAt), force || lastCachePersistedAt == nil || updatedAt - lastCachePersistedAt! >= 600_000 else { return }; do { try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true); var data = try JSONSerialization.data(withJSONObject: ["version": 1, "updatedAt": updatedAt, "quotes": quoteCache], options: [.prettyPrinted, .sortedKeys]); data.append(0x0A); try data.write(to: cacheURL, options: .atomic); lastCachePersistedAt = updatedAt; cacheDirty = false } catch {} }
    private static func normalizeQuote(_ row: [String: Any]) -> [String: Any]? { guard let code = stringValue(row["f12"]), let market = intValue(row["f13"]), market == 0 || market == 1 else { return nil }; var q: [String: Any] = ["secid": "\(market).\(code)", "code": code, "name": stringValue(row["f14"]) ?? "", "isSuspended": doubleValue(row["f2"]) == nil || doubleValue(row["f3"]) == nil]; ["price": "f2", "changePct": "f3", "change": "f4", "volume": "f5", "amount": "f6", "high": "f15", "low": "f16", "open": "f17", "prevClose": "f18", "circulatingMarketCap": "f21", "fundFlow": "f62"].forEach { q[$0] = doubleValue(row[$1]) ?? NSNull() }; if let v = int64Value(row["f124"]), v > 0 { q["timestamp"] = v * 1000 }; if let v = intValue(row["f26"]), v > 0 { q["listingDate"] = v }; if let v = intValue(row["f297"]), v > 0 { q["quoteDate"] = v }; return q }
    private static func hasUsableMarketData(_ q: [String: Any]) -> Bool { q["price"] is NSNumber && q["changePct"] is NSNumber && (q["isSuspended"] as? Bool) != true }
    private static func loadCache(from url: URL) -> [String: [String: Any]] { guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], (root["version"] as? NSNumber)?.intValue == 1, let quotes = root["quotes"] as? [String: [String: Any]] else { return [:] }; return quotes.filter { hasUsableMarketData($0.value) } }
    private static func stringValue(_ value: Any?) -> String? { if let s = value as? String { return s }; if let n = value as? NSNumber { return n.stringValue }; return nil }
    private static func doubleValue(_ value: Any?) -> Double? { if let n = value as? NSNumber { return n.doubleValue }; if let s = value as? String, s != "-" { return Double(s) }; return nil }
    private static func intValue(_ value: Any?) -> Int? { if let n = value as? NSNumber { return n.intValue }; if let s = value as? String { return Int(s) }; return nil }
    private static func int64Value(_ value: Any?) -> Int64? { if let n = value as? NSNumber { return n.int64Value }; if let s = value as? String { return Int64(s) }; return nil }
    private static func normalizedDate(_ value: Any?) -> String? { guard let v = intValue(value), v > 0 else { return nil }; let s = String(format: "%08d", v); return s.range(of: #"^\d{8}$"#, options: .regularExpression) != nil ? s : nil }
    static func normalizedBusinessDate(_ value: String) -> String? { let digits = value.replacingOccurrences(of: "-", with: ""); return digits.range(of: #"^\d{8}$"#, options: .regularExpression) != nil ? digits : nil }
    private static func market(for code: String) -> Int { code.hasPrefix("6") ? 1 : 0 }
    private static func secid(for code: String, market: Int) -> String? { guard isAShareCode(code), market == self.market(for: code) else { return nil }; return "\(market).\(code)" }
    private static func isValidSecID(_ value: String) -> Bool { value.range(of: #"^[01]\.\d{6}$"#, options: .regularExpression) != nil }
    private static func isAShareCode(_ value: String) -> Bool { value.range(of: #"^(000|001|002|003|300|301|600|601|603|605|688|689)\d{3}$"#, options: .regularExpression) != nil }
    private static func limitRate(code: String, name: String) -> Double { if code.hasPrefix("300") || code.hasPrefix("301") || code.hasPrefix("688") || code.hasPrefix("689") { return 0.20 }; return (name.uppercased().hasPrefix("ST") || name.uppercased().hasPrefix("*ST")) ? 0.05 : 0.10 }
    private static func isLimitPrice(_ price: Double, previousClose: Double, code: String, name: String) -> Bool { abs(price - (previousClose * (1 + limitRate(code: code, name: name)) * 100).rounded() / 100) < 0.005 }
    private static func nowMilliseconds() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private func nowMilliseconds() -> Int64 { Self.nowMilliseconds() }
    private static func isPollingTime(_ timestamp: Int64) -> Bool { let c = Calendar(identifier: .gregorian).dateComponents([.weekday, .hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)); guard let w = c.weekday, let h = c.hour, let m = c.minute, (2...6).contains(w) else { return false }; let v = h * 60 + m; return (570...690).contains(v) || (780...905).contains(v) }
}
