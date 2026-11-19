import Foundation

struct ImagePayload: Sendable, Equatable {
    var data: Data
    var contentType: String
}

struct PendingFeedback: Codable, Sendable, Identifiable {
    struct Image: Codable, Sendable {
        var file: String
        var contentType: String
    }

    var id: String
    var createdAt: Date
    var submission: FeedbackSubmission
    var pendingImages: [Image]
}

/// Feedback that couldn't be delivered, persisted until the next successful refresh.
struct FeedbackQueue: Sendable {
    let directory: URL

    private func itemDirectory(_ id: String) -> URL {
        directory.appendingPathComponent(id, isDirectory: true)
    }

    @discardableResult
    func enqueue(_ submission: FeedbackSubmission, images: [ImagePayload]) throws -> PendingFeedback {
        let id = UUID().uuidString.lowercased()
        let folder = itemDirectory(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var stored: [PendingFeedback.Image] = []
        for (index, image) in images.enumerated() {
            let file = "image-\(index).\(image.contentType == "image/png" ? "png" : "jpg")"
            try image.data.write(to: folder.appendingPathComponent(file), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            stored.append(.init(file: file, contentType: image.contentType))
        }
        let item = PendingFeedback(id: id, createdAt: Date(), submission: submission, pendingImages: stored)
        try save(item)
        return item
    }

    func save(_ item: PendingFeedback) throws {
        let folder = itemDirectory(item.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSON.encoder.encode(item).write(to: folder.appendingPathComponent("item.json"), options: .atomic)
    }

    func items() -> [PendingFeedback] {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return folders
            .compactMap { folder in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("item.json")) else { return nil }
                return try? JSON.decoder.decode(PendingFeedback.self, from: data)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func imageData(_ image: PendingFeedback.Image, of item: PendingFeedback) -> Data? {
        try? Data(contentsOf: itemDirectory(item.id).appendingPathComponent(image.file))
    }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: itemDirectory(id))
    }

    var count: Int { items().count }
}
