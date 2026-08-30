import AppKit
import CryptoKit
import Darwin
import Foundation
import Network

private let dashboardPort: UInt16 = 8765
private let dashboardHost = "127.0.0.1"
private let expectedHostHeader = "\(dashboardHost):\(dashboardPort)"
private let expectedOrigin = "http://\(expectedHostHeader)"
private let maximumRequestSize = 4_194_304
private let maximumHeaderSize = 65_536

private struct HTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
}

private struct HTTPResponse {
    let status: Int
    let reason: String
    var headers: [String: String]
    let body: Data

    static func json(status: Int, reason: String, object: Any, headers: [String: String] = [:]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        var resultHeaders = headers
        resultHeaders["Content-Type"] = "application/json; charset=utf-8"
        return HTTPResponse(status: status, reason: reason, headers: resultHeaders, body: data)
    }

    static func error(status: Int, reason: String, message: String) -> HTTPResponse {
        json(status: status, reason: reason, object: ["error": message])
    }
}

private enum StoreError: Error {
    case invalid(String)
    case conflict
    case missingPrecondition
}

private struct LoadedDocument {
    let data: Data
    let etag: String
}

private final class PoolStore {
    let fileURL: URL
    private let fileManager = FileManager.default
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: fileURL.path) {
            let empty: [String: Any] = [
                "version": 1,
                "updatedAt": isoFormatter.string(from: Date()),
                "pools": []
            ]
            try encode(empty).write(to: fileURL, options: .atomic)
        }
        // 自动池名单由已校验快照动态投影，stock-pools.json 仅保存自定义池。
        try migrateAutomaticPools()
    }

    func load() throws -> LoadedDocument {
        let raw = try Data(contentsOf: fileURL)
        let normalized = try normalize(raw)
        return LoadedDocument(data: try encode(normalized), etag: makeETag(raw))
    }

    func save(_ requestData: Data, expectedETag: String?) throws -> LoadedDocument {
        guard let expectedETag, !expectedETag.isEmpty else { throw StoreError.missingPrecondition }
        let currentRaw = try Data(contentsOf: fileURL)
        guard makeETag(currentRaw) == expectedETag else { throw StoreError.conflict }

        let current = try normalize(currentRaw)
        var normalized = try normalize(requestData)
        try validateAutomaticPoolsUnchanged(current: current, requested: normalized)
        normalized["updatedAt"] = isoFormatter.string(from: Date())
        let encoded = try encode(normalized)
        try encoded.write(to: fileURL, options: .atomic)
        return LoadedDocument(data: encoded, etag: makeETag(encoded))
    }

    private func validateAutomaticPoolsUnchanged(current: [String: Any], requested: [String: Any]) throws {
        let currentPools = current["pools"] as? [[String: Any]] ?? []
        let requestedPools = requested["pools"] as? [[String: Any]] ?? []
        for currentPool in currentPools where (currentPool["kind"] as? String) == "automatic" {
            guard let id = currentPool["id"] as? String,
                  let requestedPool = requestedPools.first(where: { ($0["id"] as? String) == id }) else {
                throw StoreError.invalid("自动个股池不能被删除")
            }
            guard (requestedPool["name"] as? String) == (currentPool["name"] as? String),
                  (requestedPool["rule"] as? String) == (currentPool["rule"] as? String),
                  (requestedPool["dataDate"] as? String) == (currentPool["dataDate"] as? String),
                  stockIDs(from: requestedPool) == stockIDs(from: currentPool) else {
                throw StoreError.invalid("自动个股池只能通过自动刷新更新")
            }
        }
    }

    private func stockIDs(from pool: [String: Any]) -> [String] {
        let stocks = pool["stocks"] as? [[String: Any]] ?? []
        return stocks.compactMap { $0["secid"] as? String }
    }

    private func migrateAutomaticPools() throws {
        let raw = try Data(contentsOf: fileURL)
        var normalized = try normalize(raw)
        guard let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let oldPools = root["pools"] as? [[String: Any]],
              let newPools = normalized["pools"] as? [[String: Any]] else { return }
        if oldPools.count != newPools.count {
            normalized["updatedAt"] = isoFormatter.string(from: Date())
            try encode(normalized).write(to: fileURL, options: .atomic)
        }
    }

    private func normalize(_ data: Data) throws -> [String: Any] {
        let rawObject: Any
        do {
            rawObject = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            let nsError = error as NSError
            let detail = (nsError.userInfo["NSDebugDescription"] as? String) ?? nsError.localizedDescription
            throw StoreError.invalid("JSON 格式错误：\(detail)")
        }

        guard let root = rawObject as? [String: Any] else {
            throw StoreError.invalid("JSON 顶层必须是对象")
        }
        let version = (root["version"] as? NSNumber)?.intValue ?? 1
        guard version == 1 else {
            throw StoreError.invalid("不支持的数据版本：\(version)")
        }
        guard let rawPools = root["pools"] as? [Any] else {
            throw StoreError.invalid("pools 必须是数组")
        }

        var normalizedPools: [[String: Any]] = []
        var poolIDs = Set<String>()
        var poolNames = Set<String>()
        let nowMilliseconds = Int64(Date().timeIntervalSince1970 * 1000)

        for (poolIndex, rawPool) in rawPools.enumerated() {
            guard let pool = rawPool as? [String: Any] else {
                throw StoreError.invalid("第 \(poolIndex + 1) 个个股池必须是对象")
            }
            // 旧客户端可能仍携带 automatic 条目；读取/保存时忽略，避免自动池再次回写文件。
            if (pool["kind"] as? String) == "automatic" { continue }
            guard let rawName = pool["name"] as? String, !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StoreError.invalid("第 \(poolIndex + 1) 个个股池缺少有效名称")
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !poolNames.contains(name) else {
                throw StoreError.invalid("个股池名称重复：\(name)")
            }
            poolNames.insert(name)

            var id = (pool["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if id.isEmpty || poolIDs.contains(id) { id = "pool_\(UUID().uuidString.lowercased())" }
            poolIDs.insert(id)

            let createdAt: Int64
            if let number = pool["createdAt"] as? NSNumber {
                createdAt = number.int64Value
            } else {
                createdAt = nowMilliseconds + Int64(poolIndex)
            }

            let rawStocks = pool["stocks"] as? [Any] ?? []
            var stocks: [[String: Any]] = []
            var stockIDs = Set<String>()
            for (stockIndex, rawStock) in rawStocks.enumerated() {
                guard let stock = rawStock as? [String: Any] else {
                    throw StoreError.invalid("个股池「\(name)」的第 \(stockIndex + 1) 只股票必须是对象")
                }
                guard let rawCode = stock["code"] as? String,
                      let rawSecid = stock["secid"] as? String else {
                    throw StoreError.invalid("个股池「\(name)」的第 \(stockIndex + 1) 只股票缺少 code 或 secid")
                }
                let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
                let secid = rawSecid.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !code.isEmpty, !secid.isEmpty else {
                    throw StoreError.invalid("个股池「\(name)」包含空的 code 或 secid")
                }
                guard !stockIDs.contains(secid) else {
                    throw StoreError.invalid("个股池「\(name)」中的股票重复：\(secid)")
                }
                stockIDs.insert(secid)
                let stockName = ((stock["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? code
                stocks.append(["code": code, "name": stockName, "secid": secid])
            }

            var normalizedPool: [String: Any] = [
                "id": id,
                "name": name,
                "createdAt": createdAt,
                "stocks": stocks
            ]
            let kind = (pool["kind"] as? String) == "automatic" ? "automatic" : "manual"
            normalizedPool["kind"] = kind
            if kind == "automatic" {
                normalizedPool["rule"] = (pool["rule"] as? String) ?? ""
                normalizedPool["dataDate"] = (pool["dataDate"] as? String) ?? ""
                if let generatedAt = pool["generatedAt"] as? NSNumber {
                    normalizedPool["generatedAt"] = generatedAt.int64Value
                }
            }
            normalizedPools.append(normalizedPool)
        }

        return [
            "version": 1,
            "updatedAt": (root["updatedAt"] as? String) ?? isoFormatter.string(from: Date()),
            "pools": normalizedPools
        ]
    }

    private func encode(_ object: Any) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    private func makeETag(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let value = digest.map { String(format: "%02x", $0) }.joined()
        return "\"\(value)\""
    }
}

private final class HTTPServer {
    private let queue = DispatchQueue(label: "local.stock-dashboard.http")
    private let store: PoolStore
    private let historyStore: LimitUpHistoryStore?
    private let htmlTemplate: String
    private let coreScript: Data
    private let marketData: MarketDataService
    private let automaticManager: AutomaticLimitUpManager
    private let sessionToken: String
    private let scriptNonce: String
    private var listener: NWListener?
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?

    init(store: PoolStore, historyStore: LimitUpHistoryStore?, htmlTemplate: String, coreScript: Data, marketData: MarketDataService, automaticManager: AutomaticLimitUpManager) {
        self.store = store
        self.historyStore = historyStore
        self.htmlTemplate = htmlTemplate
        self.coreScript = coreScript
        self.marketData = marketData
        self.automaticManager = automaticManager
        self.sessionToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        self.scriptNonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    func start() throws {
        guard let port = NWEndpoint.Port(rawValue: dashboardPort) else {
            throw NSError(domain: "StockDashboard", code: 1, userInfo: [NSLocalizedDescriptionKey: "无效的服务端口"])
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(dashboardHost), port: port)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async { self.onReady?() }
            case .failed(let error):
                DispatchQueue.main.async { self.onFailure?("本地服务启动失败：\(error.localizedDescription)") }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if accumulated.count > maximumRequestSize {
                self.send(.error(status: 413, reason: "Payload Too Large", message: "请求数据过大"), on: connection)
                return
            }
            if let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                if headerEnd.lowerBound > maximumHeaderSize {
                    self.send(.error(status: 431, reason: "Request Header Fields Too Large", message: "请求头过大"), on: connection)
                    return
                }
            } else if accumulated.count > maximumHeaderSize {
                self.send(.error(status: 431, reason: "Request Header Fields Too Large", message: "请求头过大"), on: connection)
                return
            }
            if let request = self.parseRequest(accumulated) {
                self.handleRequest(request, on: connection)
            } else if error == nil && !isComplete {
                self.receive(on: connection, buffer: accumulated)
            } else {
                connection.cancel()
            }
        }
    }

    private func parseRequest(_ data: Data) -> HTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        guard let contentLength = Int(headers["content-length"] ?? "0"),
              contentLength >= 0,
              contentLength <= maximumRequestSize else { return nil }
        let bodyStart = headerRange.upperBound
        guard bodyStart <= data.count, contentLength <= data.count - bodyStart else { return nil }
        let body = contentLength > 0 ? data.subdata(in: bodyStart..<(bodyStart + contentLength)) : Data()
        return HTTPRequest(
            method: String(requestParts[0]).uppercased(),
            target: String(requestParts[1]),
            headers: headers,
            body: body
        )
    }

    private func handleRequest(_ request: HTTPRequest, on connection: NWConnection) {
        let path = request.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.target
        if path == "/api/quotes" && request.method == "POST" {
            guard isAuthorized(request, requireOrigin: true) else {
                send(.error(status: 403, reason: "Forbidden", message: "请求来源或会话令牌无效"), on: connection)
                return
            }
            guard let root = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let secids = root["secids"] as? [String] else {
                send(.error(status: 400, reason: "Bad Request", message: "行情请求格式无效"), on: connection)
                return
            }
            marketData.fetchQuotes(secids: secids) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    switch result {
                    case .success(let object):
                        self.send(.json(status: 200, reason: "OK", object: object, headers: ["Cache-Control": "no-store"]), on: connection)
                    case .failure(let error):
                        self.send(.error(status: 502, reason: "Bad Gateway", message: error.localizedDescription), on: connection)
                    }
                }
            }
            return
        }
        if path == "/api/search" && request.method == "GET" {
            guard isAuthorized(request, requireOrigin: false) else {
                send(.error(status: 403, reason: "Forbidden", message: "会话令牌无效"), on: connection)
                return
            }
            guard let components = URLComponents(string: "http://local\(request.target)"),
                  let keyword = components.queryItems?.first(where: { $0.name == "q" })?.value else {
                send(.error(status: 400, reason: "Bad Request", message: "缺少搜索关键词"), on: connection)
                return
            }
            marketData.searchStocks(keyword: keyword) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    switch result {
                    case .success(let object):
                        self.send(.json(status: 200, reason: "OK", object: object, headers: ["Cache-Control": "no-store"]), on: connection)
                    case .failure(let error):
                        self.send(.error(status: 502, reason: "Bad Gateway", message: error.localizedDescription), on: connection)
                    }
                }
            }
            return
        }
        if path == "/api/first-limit-up" && request.method == "GET" {
            guard isAuthorized(request, requireOrigin: false) else {
                send(.error(status: 403, reason: "Forbidden", message: "会话令牌无效"), on: connection)
                return
            }
            send(.json(status: 200, reason: "OK", object: automaticManager.responseObject(), headers: ["Cache-Control": "no-store"]), on: connection)
            return
        }
        if path == "/api/first-limit-up" && request.method == "POST" {
            guard isAuthorized(request, requireOrigin: true) else {
                send(.error(status: 403, reason: "Forbidden", message: "请求来源或会话令牌无效"), on: connection)
                return
            }
            automaticManager.requestLive { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    switch result {
                    case .failure(let error):
                        self.send(.error(status: 502, reason: "Bad Gateway", message: error.localizedDescription), on: connection)
                    case .success(let object):
                        self.send(.json(status: 200, reason: "OK", object: object, headers: ["Cache-Control": "no-store"]), on: connection)
                    }
                }
            }
            return
        }
        if path == "/api/limit-up-history/dates" && request.method == "GET" {
            guard isAuthorized(request, requireOrigin: false) else {
                send(.error(status: 403, reason: "Forbidden", message: "会话令牌无效"), on: connection)
                return
            }
            guard let historyStore else {
                send(.error(status: 503, reason: "Service Unavailable", message: "历史数据服务不可用"), on: connection)
                return
            }
            do {
                let dates = try historyStore.dates()
                send(.json(
                    status: 200,
                    reason: "OK",
                    object: ["dates": dates, "latest": dates.last.map { $0 as Any } ?? NSNull()],
                    headers: ["Cache-Control": "no-store"]
                ), on: connection)
            } catch HistoryStoreError.invalid(let message) {
                send(.error(status: 422, reason: "Unprocessable Content", message: message), on: connection)
            } catch {
                send(.error(status: 500, reason: "Internal Server Error", message: "历史日期读取失败：\(error.localizedDescription)"), on: connection)
            }
            return
        }
        if path == "/api/limit-up-history" && request.method == "GET" {
            guard isAuthorized(request, requireOrigin: false) else {
                send(.error(status: 403, reason: "Forbidden", message: "会话令牌无效"), on: connection)
                return
            }
            guard let historyStore else {
                send(.error(status: 503, reason: "Service Unavailable", message: "历史数据服务不可用"), on: connection)
                return
            }
            guard let components = URLComponents(string: "http://local\(request.target)"),
                  let date = components.queryItems?.first(where: { $0.name == "date" })?.value,
                  date.range(of: #"^\d{8}$"#, options: .regularExpression) != nil else {
                send(.error(status: 400, reason: "Bad Request", message: "缺少有效日期参数（YYYYMMDD）"), on: connection)
                return
            }
            handleLimitUpHistory(date: date, historyStore: historyStore, on: connection)
            return
        }
        send(routeLocal(request), on: connection)
    }

    private func handleLimitUpHistory(date: String, historyStore: LimitUpHistoryStore, on connection: NWConnection) {
        let records: [[String: Any]]
        do {
            records = try historyStore.loadRecords()
        } catch HistoryStoreError.invalid(let message) {
            send(.error(status: 422, reason: "Unprocessable Content", message: message), on: connection)
            return
        } catch {
            send(.error(status: 500, reason: "Internal Server Error", message: "历史数据读取失败：\(error.localizedDescription)"), on: connection)
            return
        }
        let dates = records.compactMap { $0["date"] as? String }
        guard let index = dates.firstIndex(of: date) else {
            send(.error(status: 404, reason: "Not Found", message: "交易日 \(date) 没有历史快照"), on: connection)
            return
        }
        let record = records[index]
        let stocks = record["stocks"] as? [[String: Any]] ?? []
        let previousDate = index > 0 ? dates[index - 1] : nil
        let nextDate = index < dates.count - 1 ? dates[index + 1] : nil

        if let nextDate {
            // 历史定版：与下一实际交易日快照对比，D 日 N 板且 D+1 日 N+1 板记为晋级
            let nextStocks = records[index + 1]["stocks"] as? [[String: Any]] ?? []
            var nextStreakByCode: [String: Int] = [:]
            for stock in nextStocks {
                if let code = stock["code"] as? String, let streak = stock["streak"] as? Int {
                    nextStreakByCode[code] = streak
                }
            }
            var statuses: [String: String] = [:]
            for stock in stocks {
                guard let secid = stock["secid"] as? String,
                      let code = stock["code"] as? String,
                      let streak = stock["streak"] as? Int else { continue }
                statuses[secid] = nextStreakByCode[code] == streak + 1 ? "yes" : "no"
            }
            send(.json(
                status: 200,
                reason: "OK",
                object: buildHistoryResponse(record: record, previousDate: previousDate, nextDate: nextDate, statuses: statuses, dataStatus: "final"),
                headers: ["Cache-Control": "no-store"]
            ), on: connection)
            return
        }

        // 最新交易日：用实时行情评估下一交易日晋级状态
        marketData.evaluatePromotions(stocks: stocks, dataDate: date) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .failure:
                    // 行情不可用时降级为待确认，不伪造晋级结果
                    self.send(.json(
                        status: 200,
                        reason: "OK",
                        object: self.buildHistoryResponse(record: record, previousDate: previousDate, nextDate: nil, statuses: [:], dataStatus: "pending"),
                        headers: ["Cache-Control": "no-store"]
                    ), on: connection)
                case .success(let evaluation):
                    let statuses = evaluation["statuses"] as? [String: String] ?? [:]
                    let hasNextDayQuotes = (evaluation["hasNextDayQuotes"] as? Bool) ?? false
                    let dataStatus = hasNextDayQuotes
                        ? (MarketDataService.isTradingSessionNow() ? "live" : "final")
                        : "pending"
                    self.send(.json(
                        status: 200,
                        reason: "OK",
                        object: self.buildHistoryResponse(record: record, previousDate: previousDate, nextDate: nil, statuses: statuses, dataStatus: dataStatus),
                        headers: ["Cache-Control": "no-store"]
                    ), on: connection)
                }
            }
        }
    }

    private func buildHistoryResponse(
        record: [String: Any],
        previousDate: String?,
        nextDate: String?,
        statuses: [String: String],
        dataStatus: String
    ) -> [String: Any] {
        let stocks = record["stocks"] as? [[String: Any]] ?? []
        var tiersByStreak: [Int: (count: Int, promoted: Int, evaluable: Int)] = [:]
        var outStocks: [[String: Any]] = []
        for stock in stocks {
            let secid = stock["secid"] as? String ?? ""
            let streak = (stock["streak"] as? Int) ?? 0
            let promotion = statuses[secid] ?? "pending"
            var tier = tiersByStreak[streak] ?? (0, 0, 0)
            tier.count += 1
            if promotion == "yes" { tier.promoted += 1; tier.evaluable += 1 }
            else if promotion == "no" { tier.evaluable += 1 }
            tiersByStreak[streak] = tier
            outStocks.append([
                "code": stock["code"] ?? "",
                "name": stock["name"] ?? "",
                "secid": secid,
                "streak": streak,
                "close": stock["close"] ?? NSNull(),
                "changePct": stock["changePct"] ?? NSNull(),
                "promotion": promotion
            ])
        }
        let tiers: [[String: Any]] = tiersByStreak.keys.sorted().map { streak in
            let tier = tiersByStreak[streak] ?? (0, 0, 0)
            return [
                "streak": streak,
                "count": tier.count,
                "promoted": tier.promoted,
                "evaluable": tier.evaluable,
                "rate": tier.evaluable > 0 ? Double(tier.promoted) / Double(tier.evaluable) * 100 : NSNull()
            ]
        }
        return [
            "date": record["date"] ?? "",
            "status": dataStatus,
            "finalized": (record["finalized"] as? Bool) ?? false,
            "prevDate": previousDate ?? NSNull(),
            "nextDate": nextDate ?? NSNull(),
            "generatedAt": record["generatedAt"] ?? NSNull(),
            "source": record["source"] ?? "",
            "total": outStocks.count,
            "tiers": tiers,
            "stocks": outStocks
        ]
    }

    private func routeLocal(_ request: HTTPRequest) -> HTTPResponse {
        guard request.headers["host"] == expectedHostHeader else {
            return .error(status: 403, reason: "Forbidden", message: "请求来源不允许")
        }
        let path = request.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.target

        if request.method == "GET" && (path == "/" || path == "/index.html") {
            let html = htmlTemplate
                .replacingOccurrences(of: "__DASHBOARD_TOKEN__", with: sessionToken)
                .replacingOccurrences(of: "__DASHBOARD_NONCE__", with: scriptNonce)
            return HTTPResponse(
                status: 200,
                reason: "OK",
                headers: [
                    "Content-Type": "text/html; charset=utf-8",
                    "Cache-Control": "no-store",
                    "Content-Security-Policy": "default-src 'none'; script-src 'self' 'nonce-\(scriptNonce)'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
                ],
                body: Data(html.utf8)
            )
        }
        if request.method == "GET" && path == "/dashboard-core.js" {
            return HTTPResponse(
                status: 200,
                reason: "OK",
                headers: ["Content-Type": "text/javascript; charset=utf-8", "Cache-Control": "no-store"],
                body: coreScript
            )
        }
        if request.method == "GET" && path == "/api/health" {
            return .json(status: 200, reason: "OK", object: ["ok": true])
        }
        if request.method == "GET" && (path == "/favicon.ico" || path.hasPrefix("/apple-touch-icon")) {
            return HTTPResponse(status: 204, reason: "No Content", headers: [:], body: Data())
        }
        if path == "/api/pools" && request.method == "GET" {
            guard isAuthorized(request, requireOrigin: false) else {
                return .error(status: 403, reason: "Forbidden", message: "会话令牌无效")
            }
            do {
                let document = try store.load()
                if request.headers["if-none-match"] == document.etag {
                    return HTTPResponse(status: 304, reason: "Not Modified", headers: ["ETag": document.etag, "Cache-Control": "no-store"], body: Data())
                }
                return HTTPResponse(
                    status: 200,
                    reason: "OK",
                    headers: ["Content-Type": "application/json; charset=utf-8", "ETag": document.etag, "Cache-Control": "no-store"],
                    body: combinedPoolData(manualData: document.data)
                )
            } catch StoreError.invalid(let message) {
                return .error(status: 422, reason: "Unprocessable Content", message: message)
            } catch {
                return .error(status: 500, reason: "Internal Server Error", message: "读取清单文件失败：\(error.localizedDescription)")
            }
        }
        if path == "/api/pools" && request.method == "PUT" {
            guard isAuthorized(request, requireOrigin: true) else {
                return .error(status: 403, reason: "Forbidden", message: "请求来源或写入令牌无效")
            }
            do {
                let document = try store.save(request.body, expectedETag: request.headers["if-match"])
                return HTTPResponse(
                    status: 200,
                    reason: "OK",
                    headers: ["Content-Type": "application/json; charset=utf-8", "ETag": document.etag, "Cache-Control": "no-store"],
                    body: combinedPoolData(manualData: document.data)
                )
            } catch StoreError.conflict {
                return .error(status: 409, reason: "Conflict", message: "清单文件已被外部修改")
            } catch StoreError.missingPrecondition {
                return .error(status: 428, reason: "Precondition Required", message: "缺少文件版本信息")
            } catch StoreError.invalid(let message) {
                return .error(status: 422, reason: "Unprocessable Content", message: message)
            } catch {
                return .error(status: 500, reason: "Internal Server Error", message: "保存清单文件失败：\(error.localizedDescription)")
            }
        }
        return .error(status: 404, reason: "Not Found", message: "请求路径不存在")
    }

    private func combinedPoolData(manualData: Data) -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: manualData)) as? [String: Any] else { return manualData }
        let autoPools = automaticManager.responseObject()["pools"] as? [[String: Any]] ?? []
        root["automaticStatus"] = automaticManager.responseObject()["status"] ?? [:]
        let manualPools = root["pools"] as? [[String: Any]] ?? []
        root["pools"] = autoPools + manualPools
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? manualData
    }

    private func isAuthorized(_ request: HTTPRequest, requireOrigin: Bool) -> Bool {
        guard request.headers["host"] == expectedHostHeader,
              request.headers["x-dashboard-token"] == sessionToken else { return false }
        if requireOrigin { return request.headers["origin"] == expectedOrigin }
        return true
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["X-Content-Type-Options"] = "nosniff"
        headers["X-Frame-Options"] = "DENY"
        headers["Referrer-Policy"] = "no-referrer"
        headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for key in headers.keys.sorted() {
            head += "\(key): \(headers[key]!)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var server: HTTPServer?
    private var marketData: MarketDataService?
    private var didOpenOnLaunch = false
    private let dashboardURL = URL(string: "http://\(expectedHostHeader)/")!
    private lazy var dataFileURL: URL = {
        if let overridePath = ProcessInfo.processInfo.environment["DASHBOARD_DATA_PATH"], !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("看盘面板", isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("stock-pools.json", isDirectory: false)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        do {
            let store = try PoolStore(fileURL: dataFileURL)
            let historyStore = try LimitUpHistoryStore(
                fileURL: dataFileURL.deletingLastPathComponent().appendingPathComponent("limit-up-history.json")
            )
            guard let htmlURL = Bundle.main.url(forResource: "stock-dashboard", withExtension: "html") else {
                throw NSError(domain: "StockDashboard", code: 2, userInfo: [NSLocalizedDescriptionKey: "应用内缺少 stock-dashboard.html"])
            }
            guard let coreScriptURL = Bundle.main.url(forResource: "dashboard-core", withExtension: "js") else {
                throw NSError(domain: "StockDashboard", code: 3, userInfo: [NSLocalizedDescriptionKey: "应用内缺少 dashboard-core.js"])
            }
            let html = try String(contentsOf: htmlURL, encoding: .utf8)
            let coreScript = try Data(contentsOf: coreScriptURL)
            let marketData = MarketDataService(
                cacheURL: dataFileURL.deletingLastPathComponent().appendingPathComponent("quote-cache.json")
            )
            self.marketData = marketData
            let automaticManager = AutomaticLimitUpManager(marketData: marketData, historyStore: historyStore)
            if ProcessInfo.processInfo.arguments.contains("--auto-refresh") {
                runAutomaticLimitUpRefresh(manager: automaticManager)
                return
            }
            let server = HTTPServer(store: store, historyStore: historyStore, htmlTemplate: html, coreScript: coreScript, marketData: marketData, automaticManager: automaticManager)
            self.server = server
            server.onReady = { [weak self] in
                guard let self else { return }
                if !self.didOpenOnLaunch {
                    self.didOpenOnLaunch = true
                    if ProcessInfo.processInfo.environment["DASHBOARD_NO_BROWSER"] != "1" {
                        self.openDashboard()
                    }
                }
            }
            server.onFailure = { [weak self] message in
                self?.showFatalError(message + "\n\n请确认 8765 端口未被其他程序占用。")
            }
            try server.start()
            installAutomaticRefreshAgent()
            // 启动后只补齐缺失/待回补交易日；不会用工作日历伪造非交易日快照。
            automaticManager.backfill(from: "20260810") { _, failures in
                if !failures.isEmpty { FileHandle.standardError.write(Data(("历史回补待重试：" + failures.joined(separator: "；") + "\n").utf8)) }
            }
        } catch {
            showFatalError(error.localizedDescription)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDashboard()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        marketData?.flushCacheIfNeeded()
        server?.stop()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: "看盘面板")
            button.image?.isTemplate = true
            button.toolTip = "A股看盘面板"
        }
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "打开看盘面板", action: #selector(openDashboard), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        let folderItem = NSMenuItem(title: "打开数据文件夹", action: #selector(openDataFolder), keyEquivalent: "d")
        folderItem.target = self
        menu.addItem(folderItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    private func runAutomaticLimitUpRefresh(manager: AutomaticLimitUpManager) {
        manager.backfill(from: "20260810") { success, failures in
            manager.finalizeLatest { result in
                switch result {
                case .success(let snapshot): print("连板池定版成功：\(snapshot.date)，\(snapshot.stocks.count) 只，回补 \(success.count) 日")
                case .failure(let error): FileHandle.standardError.write(Data("连板池定版失败：\(error.localizedDescription)，待回补\n".utf8))
                }
                if !failures.isEmpty { FileHandle.standardError.write(Data(("回补失败：" + failures.joined(separator: "；") + "\n").utf8)) }
                exit(0)
            }
        }
    }

    private func installAutomaticRefreshAgent() {
        guard let executablePath = Bundle.main.executableURL?.path else { return }
        let fileManager = FileManager.default
        let agentsDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let label = "local.stock-dashboard.first-limit-up"
        let plistURL = agentsDirectory.appendingPathComponent(label + ".plist")
        let logURL = dataFileURL.deletingLastPathComponent().appendingPathComponent("auto-refresh.log")
        let schedule: [[String: Int]] = (2...6).flatMap { weekday in
            stride(from: 10, through: 60, by: 5).map { offset in ["Weekday": weekday, "Hour": 15 + offset / 60, "Minute": offset % 60] }
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath, "--auto-refresh"],
            "StartCalendarInterval": schedule,
            "ThrottleInterval": 30,
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path
        ]
        do {
            try fileManager.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            runLaunchctl(arguments: ["bootout", "gui/\(getuid())/\(label)"])
            _ = runLaunchctl(arguments: ["bootstrap", "gui/\(getuid())", plistURL.path])
        } catch {
            // 自动任务安装失败不阻断面板启动；用户仍可使用面板内手动刷新。
        }
    }

    @discardableResult
    private func runLaunchctl(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    @objc private func openDashboard() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let chromeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            NSWorkspace.shared.open([dashboardURL], withApplicationAt: chromeURL, configuration: configuration) { _, error in
                if let error {
                    DispatchQueue.main.async {
                        self.showAlert(title: "打开面板失败", message: error.localizedDescription)
                    }
                }
            }
        } else {
            // 未安装 Chrome 时回退系统默认浏览器
            NSWorkspace.shared.open(dashboardURL, configuration: configuration) { _, error in
                if let error {
                    DispatchQueue.main.async {
                        self.showAlert(title: "打开面板失败", message: error.localizedDescription)
                    }
                }
            }
        }
    }

    @objc private func openDataFolder() {
        NSWorkspace.shared.open(dataFileURL.deletingLastPathComponent())
    }

    @objc private func quitApplication() {
        server?.stop()
        NSApp.terminate(nil)
    }

    private func showFatalError(_ message: String) {
        showAlert(title: "看盘面板无法启动", message: message)
        NSApp.terminate(nil)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
