// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Doğrudan çok-kipli (Multimodal Vision) telefon ekranı analizi sonucu.
/// Klasik OCR yerine telefon kırpıntısının kendisi Claude / Gemini / OpenAI Vision'a gönderilir; model baloncuk
/// renklerini, sol/sağ hizayı, gelen kutusu / sohbet / banka / ana ekran ayrımını görerek tek hamlede Türkçe JSON döner.
public struct PhoneVisionResult: Equatable, Sendable {
    public enum Screen: String, Codable, Equatable, Sendable {
        /// Mesajlaşma / WhatUp sohbet ekranı (gelen sol, giden sağ baloncuklar).
        case chat
        /// Sohbet listesi / gelen kutusu (kişi/grup adı + tek satır önizleme kartları).
        case inbox
        /// Banka, e-posta, sosyal medya, bildirim veya uygulama kartı.
        case card
        /// Ana ekran simgeleri, kamera, boş/bulanık kare veya PS5/Xbox sistem menüsü: TV sessiz kalır.
        case quiet
    }

    public struct Item: Equatable, Sendable {
        public var side: PhoneContent.BubbleSide
        public var sender: String?
        public var time: String?
        public var date: String?
        public var text: String

        public init(side: PhoneContent.BubbleSide = .incoming, sender: String? = nil,
                    time: String? = nil, date: String? = nil, text: String) {
            self.side = side
            self.sender = sender
            self.time = time
            self.date = date
            self.text = text
        }
    }

    public var screen: Screen
    public var title: String?
    public var subtitle: String?
    public var clock: String?
    public var messages: [Item]

    public init(screen: Screen, title: String? = nil, subtitle: String? = nil,
                clock: String? = nil, messages: [Item] = []) {
        self.screen = screen
        self.title = title
        self.subtitle = subtitle
        self.clock = clock
        self.messages = messages
    }
}

/// Telefon görüntüsünü doğrudan görsel dil modeliyle okuyup Türkçeye çeviren arayüz (testlerde sahtesi kullanılır).
public protocol PhoneVisionReading: Sendable {
    func analyzePhone(_ image: CGImage, activeSubtitle: String?) async throws -> PhoneVisionResult
}

/// Claude / Gemini / OpenAI Vision uç noktalarıyla oyun içi telefonu tek adımda analiz edip Türkçeleştirir.
public final class PhoneVisionTranslator: PhoneVisionReading, @unchecked Sendable {
    /// Görüntü boyutu sınırı: küçük telefon yazıları jilet gibi okunur ama JPEG ~25-40 KB kalır (hızlı yükleme, düşük token).
    public static let maxDimension = 560
    public static let jpegQuality: CGFloat = 0.82
    public static let timeout: TimeInterval = 7.5
    public static let maxOutputTokens = 1024

    public let provider: AIProvider
    public let model: AIModel
    private let key: String
    private let session: URLSession
    private let game: (@Sendable () -> String?)?
    private let instruction: String?

    public init(provider: AIProvider, key: String, model: String? = nil,
                session: URLSession? = nil,
                game: (@Sendable () -> String?)? = nil,
                instruction: String? = nil) {
        self.provider = provider
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = provider.model(model)
        self.session = session ?? Self.makeSession()
        self.game = game
        self.instruction = AIRequest.instruction(instruction)
    }

    public static func makeSession(timeout: TimeInterval = PhoneVisionTranslator.timeout) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpMaximumConnectionsPerHost = 2
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    public static let systemPrompt = """
        You are an elite AAA video game localization engine viewing a cropped in-game smartphone screen (e.g. GTA VI WhatUp, banking apps, social media, emails, contacts). \
        Read the screen visually — use bubble colors, left/right alignment, headers, and layout — and translate ALL visible English content into natural, vivid, idiomatic spoken Turkish (informal "sen", authentic slang and tone, official studio patch quality).

        Classify "screen" strictly as one of:
        - "quiet": Phone home screen with only app icons, camera viewfinder, unreadable/blurry frame, already-Turkish PlayStation/Xbox console system menu (e.g. PS5 power menu, cloud save, game home tile), or no meaningful English text to translate. Return "messages": [].
        - "chat": An open messaging conversation. Output EVERY distinct chat bubble as its own object in "messages" in top-to-bottom order. NEVER merge two separate bubbles into one item! Use visual alignment & bubble color: right-aligned / colored player bubbles MUST have "side": "outgoing" and "sender": null; left-aligned bubbles MUST have "side": "incoming" with "sender" set if a sender name appears above/inside the bubble. Keep proper character/place names (Jason, Lucia, Brian, Vicki, Cal, Mia, Fleeca, WhatUp, etc.) untranslated. Extract bubble timestamps into "time" and translate date dividers ("Today" -> "Bugün", "Yesterday" -> "Dün") into "date".
        - "inbox": A chat list / contacts list showing multiple threads with previews. Output one item per visible row: set "side": "incoming", "sender" to the contact or group name (e.g. "Vicki, Jason, Lucia"), "tr" to the natural Turkish translation of that row's preview text, and "title": "Sohbetler".
        - "card": Banking app, email, social post, news, alert dialog, or other in-phone app. Put the app/screen heading in "title" and each distinct visible text section, transaction, perk, or prompt as an item in "messages" ("side": "incoming").

        Rules:
        - Ignore any main game subtitle accidentally bleeding into the bottom edge outside the phone screen.
        - Keep each Turkish translation concise so it fits cleanly inside a twin-phone overlay on TV.
        - Output ONLY raw valid JSON matching this exact schema (no markdown fences, no commentary):
        {"screen":"chat|inbox|card|quiet","title":string|null,"subtitle":string|null,"clock":string|null,"messages":[{"side":"incoming|outgoing","sender":string|null,"time":string|null,"date":string|null,"tr":string}]}
        """

    public func analyzePhone(_ image: CGImage, activeSubtitle: String?) async throws -> PhoneVisionResult {
        guard let jpeg = Self.encodeJPEG(image) else { throw AIFailure.unreachable }
        let gameName = game?()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let req = Self.makeRequest(provider: provider, key: key, model: model, jpegData: jpeg,
                                   game: gameName, activeSubtitle: activeSubtitle, instruction: instruction)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw AIFailure.busy
        } catch {
            throw AIFailure.unreachable
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let limit = AIRequest.rateLimit(status: http.statusCode, body: data) { throw AIRateLimited(limit: limit) }
            throw AIRequest.failure(status: http.statusCode, body: data)
        }
        let rawText = try AIRequest.text(provider: provider, from: data)
        return try Self.parseResult(from: rawText)
    }

    /// Telefon kırpıntısını en çok `maxDimension` px olacak şekilde küçültüp hafif JPEG verisine çevirir.
    public static func encodeJPEG(_ image: CGImage, maxDimension: Int = PhoneVisionTranslator.maxDimension,
                                  quality: CGFloat = PhoneVisionTranslator.jpegQuality) -> Data? {
        let prepared = resizedIfNeeded(image, maxDimension: maxDimension)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, prepared, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func resizedIfNeeded(_ image: CGImage, maxDimension: Int) -> CGImage {
        let w = image.width, h = image.height
        let longest = max(w, h)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = Double(maxDimension) / Double(longest)
        let nw = max(1, Int((Double(w) * scale).rounded()))
        let nh = max(1, Int((Double(h) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? image
    }

    /// Claude, Gemini ve OpenAI için çok-kipli (görüntü + talimat) HTTP isteği kurar.
    public static func makeRequest(provider: AIProvider, key: String, model: AIModel, jpegData: Data,
                                   game: String? = nil, activeSubtitle: String? = nil,
                                   instruction: String? = nil) -> URLRequest {
        let b64 = jpegData.base64EncodedString()
        let system = instruction.map { systemPrompt + "\n\nAdditional user instruction: " + $0 } ?? systemPrompt
        var userParts: [String] = []
        if let game, !game.isEmpty { userParts.append("Game: \(game)") }
        if let sub = activeSubtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !sub.isEmpty {
            userParts.append("Active main dialogue subtitle (ignore if seen at bottom edge): \(sub)")
        }
        userParts.append("Analyze this in-game phone screen and return ONLY the JSON object.")
        let userText = userParts.joined(separator: "\n")

        var request: URLRequest
        var body: [String: Any]
        switch provider {
        case .claude:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": model.id,
                "max_tokens": maxOutputTokens,
                "system": system,
                "messages": [[
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": b64,
                            ],
                        ],
                        ["type": "text", "text": userText],
                    ],
                ]],
            ]
            if let effort = model.effort { body["output_config"] = ["effort": effort] }
        case .gemini:
            let escaped = model.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model.id
            request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(escaped):generateContent")!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            var config: [String: Any] = [
                "maxOutputTokens": maxOutputTokens,
                "responseMimeType": "application/json",
            ]
            if let thinking = model.thinking { config["thinkingConfig"] = ["thinkingLevel": thinking] }
            body = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [[
                    "role": "user",
                    "parts": [
                        ["inline_data": ["mime_type": "image/jpeg", "data": b64]],
                        ["text": userText],
                    ],
                ]],
                "generationConfig": config,
            ]
        case .openAI, .local:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            body = [
                "model": model.id,
                "max_completion_tokens": maxOutputTokens,
                "response_format": ["type": "json_object"],
                "messages": [
                    ["role": "developer", "content": system],
                    [
                        "role": "user",
                        "content": [
                            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)", "detail": "auto"]],
                            ["type": "text", "text": userText],
                        ],
                    ],
                ],
            ]
            if let effort = model.effort { body["reasoning_effort"] = effort }
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Modelin döndürdüğü JSON yanıtını `PhoneVisionResult` yapısına ayrıştırır.
    public static func parseResult(from raw: String) throws -> PhoneVisionResult {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = trimmed.range(of: "</think>", options: .backwards) {
            trimmed = String(trimmed[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if trimmed.hasPrefix("```") {
            trimmed = trimmed.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                .filter { !$0.hasPrefix("```") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end,
              let data = String(trimmed[start...end]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIFailure.unreachable
        }
        let screenRaw = (root["screen"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "quiet"
        let screen = PhoneVisionResult.Screen(rawValue: screenRaw) ?? .card
        func optString(_ key: String, in dict: [String: Any]) -> String? {
            guard let s = dict[key] as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty || t.lowercased() == "null" ? nil : t
        }
        let title = optString("title", in: root)
        let subtitle = optString("subtitle", in: root)
        let clock = optString("clock", in: root)
        let rawList = root["messages"] as? [[String: Any]] ?? []
        var items: [PhoneVisionResult.Item] = []
        for entry in rawList {
            guard let tr = optString("tr", in: entry) ?? optString("text", in: entry) else { continue }
            let sideRaw = (entry["side"] as? String)?.lowercased() ?? "incoming"
            let side: PhoneContent.BubbleSide = sideRaw == "outgoing" ? .outgoing : .incoming
            let sender = side == .outgoing ? nil : optString("sender", in: entry)
            items.append(PhoneVisionResult.Item(
                side: side,
                sender: sender,
                time: optString("time", in: entry),
                date: optString("date", in: entry),
                text: tr
            ))
        }
        if screen == .quiet || items.isEmpty {
            return PhoneVisionResult(screen: .quiet, title: title, subtitle: subtitle, clock: clock, messages: [])
        }
        return PhoneVisionResult(screen: screen, title: title, subtitle: subtitle, clock: clock, messages: items)
    }
}
