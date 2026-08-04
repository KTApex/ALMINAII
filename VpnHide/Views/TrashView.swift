import SwiftUI
import UIKit

// MARK: - Trash View

/// Recycle Bin view. Deleted vault items are retained here for 30 days
/// before being permanently purged.
struct TrashView: View {
    @ObservedObject var storage: VaultStorageManager
    @Environment(\.dismiss) private var dismiss

    @State private var isConfirmingPermanentDelete = false
    @State private var selectedItems = Set<UUID>()

    /// The 30-day retention window.
    private let retentionDays = 30

    var body: some View {
        NavigationStack {
            Group {
                if storage.trashedItems.isEmpty {
                    emptyState
                } else {
                    trashList
                }
            }
            .navigationTitle("Trash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.blue)
                }

                if !storage.trashedItems.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Empty Trash", role: .destructive) {
                            isConfirmingPermanentDelete = true
                        }
                        .foregroundColor(.red)
                    }
                }
            }
            .confirmationDialog(
                "Permanently delete all \(storage.trashedItems.count) items?",
                isPresented: $isConfirmingPermanentDelete,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    storage.emptyTrash()
                }
                Button("Cancel", role: .cancel) {}
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "trash.slash.fill")
                .font(.system(size: 48))
                .foregroundColor(.gray)
            Text("Trash is Empty")
                .font(.headline)
                .foregroundColor(.white)
            Text("Deleted items stay here for \(retentionDays) days\nbefore being permanently removed.")
                .font(.caption)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - List

    private var trashList: some View {
        List {
            // Retention info header
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundColor(.orange)
                    Text("Items are permanently deleted after \(retentionDays) days")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(Color.clear)
            }

            ForEach(storage.trashedItems) { item in
                TrashRowView(item: item, storage: storage)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("Delete Forever", role: .destructive) {
                            storage.permanentlyDelete([item])
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button("Restore") {
                            storage.restoreFromTrash([item])
                        }
                        .tint(.green)
                    }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(red: 0.05, green: 0.07, blue: 0.12))
    }
}

// MARK: - Trash Row

private struct TrashRowView: View {
    let item: VaultItem
    @ObservedObject var storage: VaultStorageManager

    @State private var thumbnail: UIImage?
    @State private var daysRemaining: Int = 30

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: item.mediaType == .photo ? "photo.fill" : "video.fill")
                            .foregroundColor(.gray)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text("Deleted \(dateFormatter.string(from: item.deletedAt ?? Date()))")
                    .font(.caption)
                    .foregroundColor(.gray)

                // Expiration badge
                if let deletedAt = item.deletedAt {
                    let daysLeft = max(0, 30 - Calendar.current.dateComponents(
                        [.day],
                        from: deletedAt,
                        to: Date()
                    ).day ?? 0)

                    Text("\(daysLeft) days remaining")
                        .font(.caption2)
                        .foregroundColor(daysLeft < 5 ? .orange : .green)
                }
            }

            Spacer()

            // Restore button
            Button {
                storage.restoreFromTrash([item])
            } label: {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.green)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        guard item.mediaType == .photo else { return }
        thumbnail = storage.thumbnail(for: item)
    }
}