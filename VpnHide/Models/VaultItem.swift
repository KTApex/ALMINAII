import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum VaultMediaType: String, Codable {
    case photo
    case video
}

struct VaultItem: Identifiable, Codable, Hashable {
    let id: UUID
    var fileName: String
    var encryptedFileName: String
    var mediaType: VaultMediaType
    var createdAt: Date
    var fileSize: Int64
    var duration: Double
    var isDecoy: Bool = false

    init(
        id: UUID = UUID(),
        fileName: String,
        encryptedFileName: String,
        mediaType: VaultMediaType,
        createdAt: Date = Date(),
        fileSize: Int64,
        duration: Double = 0,
        isDecoy: Bool = false
    ) {
        self.id = id
        self.fileName = fileName
        self.encryptedFileName = encryptedFileName
        self.mediaType = mediaType
        self.createdAt = createdAt
        self.fileSize = fileSize
        self.duration = duration
        self.isDecoy = isDecoy
    }

    var displayName: String {
        fileName
    }

    var fileExtension: String {
        (fileName as NSString).pathExtension
    }

    var utType: UTType {
        mediaType == .photo ? .image : .movie
    }
}