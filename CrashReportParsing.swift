import Foundation

struct CrashReportDocument {
    let header: [String: Any]
    let body: [String: Any]
}

enum CrashReportParsing {
    /// modern `.ips`의 한 줄 header와 JSON body를 파싱하고 DiskOUT report인지 확인한다.
    static func document(from raw: String, expectedBundleID: String) -> CrashReportDocument? {
        guard let firstNewline = raw.firstIndex(of: "\n") else { return nil }
        let headerLine = String(raw[raw.startIndex..<firstNewline])
        let bodyText = String(raw[raw.index(after: firstNewline)...])

        guard let headerData = headerLine.data(using: .utf8),
              let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any] else {
            return nil
        }

        let bundleID = (header["bundleID"] as? String) ?? (header["bundleId"] as? String)
        guard bundleID == expectedBundleID else { return nil }

        guard let bodyData = bodyText.data(using: .utf8),
              let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
            return nil
        }

        return CrashReportDocument(header: header, body: body)
    }

    /// 크래시 스레드의 백트레이스를 (top 앱 심볼, "프레임 라인" 배열)로 추린다.
    static func backtrace(
        from body: [String: Any],
        topFrameLimit: Int
    ) -> (topAppSymbol: String?, frames: [String]) {
        let images = body["usedImages"] as? [[String: Any]] ?? []
        var appImageIndices = Set<Int>()
        for (index, image) in images.enumerated() {
            if let name = image["name"] as? String, name == "DiskOUT" {
                appImageIndices.insert(index)
            }
        }

        let threads = body["threads"] as? [[String: Any]] ?? []
        var crashThread = threads.first { ($0["triggered"] as? Bool) == true }
        if crashThread == nil,
           let faultingThread = body["faultingThread"] as? Int,
           faultingThread >= 0,
           faultingThread < threads.count {
            crashThread = threads[faultingThread]
        }
        if crashThread == nil {
            crashThread = threads.first
        }

        let frames = crashThread?["frames"] as? [[String: Any]] ?? []
        var lines: [String] = []
        var topAppSymbol: String?

        for frame in frames.prefix(topFrameLimit) {
            let imageIndex = frame["imageIndex"] as? Int
            let isAppFrame = imageIndex.map { appImageIndices.contains($0) } ?? false
            let binaryName: String
            if let imageIndex,
               imageIndex >= 0,
               imageIndex < images.count,
               let name = images[imageIndex]["name"] as? String {
                binaryName = name
            } else {
                binaryName = "?"
            }

            let symbol = (frame["symbol"] as? String).map { String($0.prefix(120)) }
            let offset = frame["imageOffset"] as? Int
            let symbolText: String
            if let symbol {
                symbolText = symbol
            } else if let offset {
                symbolText = "\(binaryName) + \(offset)"
            } else {
                symbolText = binaryName
            }

            if isAppFrame, topAppSymbol == nil {
                topAppSymbol = symbol ?? symbolText
            }
            lines.append("\(binaryName)  \(symbolText)")
        }

        return (topAppSymbol, lines)
    }
}
