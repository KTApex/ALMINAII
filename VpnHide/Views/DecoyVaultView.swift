import PhotosUI
import SwiftUI

/// The fake/decoy vault shown when the Panic PIN is entered.
/// Contains only non-sensitive media to satisfy forced inspection.
struct DecoyVaultView: View {
    @EnvironmentObject var session: VaultSessionManager
    @ObservedObject var storage = VaultStorageManager.shared

    @State private var showPhotoPicker = false
    @State private var pickerItems: [PhotosPickerItem] = []

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.05, green: 0.07, blue: 0.12)
                    .ignoresSafeArea()

                if storage.decoyItems.isEmpty {
                    emptyStateView
                } else {
                    decoyGrid
                }
            }
            .navigationTitle("My Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        session.lockVault()
                    } label: {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.gray)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(.blue)
                    }
                }
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $pickerItems,
                maxSelectionCount: 20,
                matching: .any(of: [.images, .videos])
            )
            .onChange(of: pickerItems) { newItems in
                importPickedItems(newItems)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Grid

    private var decoyGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(storage.decoyItems) { item in
                    MediaThumbnailView(item: item, storage: storage)
                }
            }
            .padding(2)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundColor(.gray.opacity(0.5))

            Text("No Photos Yet")
                .font(.title3.bold())
                .foregroundColor(.white)

            Text("Add some photos to get started.")
                .font(.subheadline)
                .foregroundColor(.gray)

            Button {
                showPhotoPicker = true
            } label: {
                Label("Add Photos", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Color.blue))
                    .foregroundColor(.white)
            }
            .padding(.top, 8)
        }
        .padding(30)
    }

    // MARK: - Import

    private func importPickedItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }

        Task {
            for item in items {
                do {
                    if let data = try await item.loadTransferable(type: Data.self) {
                        let tempURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)

                        try data.write(to: tempURL)

                        if let type = item.supportedContentTypes.first {
                            let ext = type.preferredFilenameExtension ?? "jpg"
                            let renamedURL = tempURL.appendingPathExtension(ext)
                            try? FileManager.default.moveItem(at: tempURL, to: renamedURL)

                            try await storage.importMedia(from: renamedURL, isDecoy: true)
                            try? FileManager.default.removeItem(at: renamedURL)
                        } else {
                            try await storage.importMedia(from: tempURL, isDecoy: true)
                            try? FileManager.default.removeItem(at: tempURL)
                        }
                    }
                } catch {
                    // Silently ignore - decoy vault should be simple
                }
            }
            pickerItems = []
        }
    }
}