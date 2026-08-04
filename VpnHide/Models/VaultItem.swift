import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum VaultMediaType: String, Codable {
    case photo
    case video
}

/// A user-created album/category for organizing vault media.
struct VaultAlbum: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var icon: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        icon: String = "folder.fill",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.createdAt = createdAt
    }
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
    var albumID: UUID?
    // MARK: - Trash Support
    /// Set when the item is moved to the trash (30-day retention).
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        fileName: String,
        encryptedFileName: String,
        mediaType: VaultMediaType,
        createdAt: Date = Date(),
        fileSize: Int64,
        duration: Double = 0,
        isDecoy: Bool = false,
        albumID: UUID? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.encryptedFileName = encryptedFileName
        self.mediaType = mediaType
        self.createdAt = createdAt
        self.fileSize = fileSize
        self.duration = duration
        self.isDecoy = isDecoy
        self.albumID = albumID
        self.deletedAt = deletedAt
    }

    /// True when the item is in the trash (deletedAt is non-nil).
    var isTrashed: Bool {
        deletedAt != nil
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

// MARK: - Sort & Filter Options

enum VaultSortOption: String, CaseIterable, Identifiable {
    case dateAdded = "Date Added"
    case fileSize = "File Size"
    case name = "Name"

    var id: String { rawValue }
}

enum VaultFilterOption: String, CaseIterable, Identifiable {
    case all = "All"
    case photosOnly = "Photos Only"
    case videosOnly = "Videos Only"

    var id: String { rawValue }
}

// MARK: - Date Grouping

/// Groups items into chronological sections with friendly headers.
enum DateGroup: Hashable {
    case today
    case yesterday
    case month(Date)
    case year(Int)

    var title: String {
        switch self {
        case .today:
            return "Today"
        case .yesterday:
            return "Yesterday"
        case .month(let date):
            let formatter = DateFormatter()
            formatter.dateFormat = "MMMM yyyy"
            return formatter.string(from: date)
        case .year(let year):
            return "\(year)"
        }
    }

    static func group(for date: Date) -> DateGroup {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return .today
        }
        if calendar.isDateInYesterday(date) {
            return .yesterday
        }

        // Check if within the current year
        let currentYear = calendar.component(.year, from: Date())
        let itemYear = calendar.component(.year, from: date)

        if itemYear == currentYear {
            return .month(date)
        }
        return .year(itemYear)
    }
}
