import PhotosUI
import SwiftUI

/// The main vault interface showing a 3-column grid of encrypted media.
/// Supports multi-select mode, media import via PhotosPicker, and launching
/// a full-screen manual slideshow of selected items.
struct MediaVaultView: View {
    @EnvironmentObject var session: VaultSessionManager
    @ObservedObject var storage = VaultStorageManager.shared

    @State private var isMultiSelectMode = false
    @State private var selectedItems: Set<UUID> = []
    @State private var showPhotoPicker = false
    @State private var showSlideshow = false
    @State private var showDeleteConfirmation = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var importError: String?

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color(red: 0.05, green: 0.07, blue: 0.12)
                    .ignoresSafeArea()

                if storage.vaultItems.isEmpty {
                    emptyStateView
                } else {
                    mediaGrid
                }
            }
            .navigationTitle("Private Vault")
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
                    if isMultiSelectMode {
                        Button("Cancel") {
                            exitMultiSelectMode()
                        }
                        .foregroundColor(.blue)
                    } else {
                        Button {
                            showPhotoPicker = true
                        } label: {
                            Image(systemName: "plus")
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isMultiSelectMode {
                    multiSelectActionBar
                }
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $pickerItems,
                maxSelectionCount: 20,
                matching: .any(of: [.images, .videos])
            )
            .onChange(of: pickerItems) { _, newItems in
                importPickedItems(newItems)
            }
            .fullScreenCover(isPresented: $showSlideshow) {
                if let slideshowItems = selectedVaultItems {
                    SlideshowView(items: slideshowItems, storage: storage)
                }
            }
            .alert("Delete Selected Items?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    deleteSelectedItems()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently remove \(selectedItems.count) item(s) from your vault.")
            }
            .alert("Import Error", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Grid

    private var mediaGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(storage.vaultItems) { item in
                    gridCell(for: item)
                }
            }
            .padding(2)
        }
    }

    private func gridCell(for item: VaultItem) -> some View {
        ZStack(alignment: .topTrailing) {
            MediaThumbnailView(item: item, storage: storage)

            // Selection indicator
            if isMultiSelectMode {
                Image(systemName: selectedItems.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(selectedItems.contains(item.id) ? .blue : .white.opacity(0.7))
                    .padding(6)
                    .shadow(radius: 2)
            }
        }
        .onTapGesture {
            handleTap(on: item)
        }
        .onLongPressGesture {
            enterMultiSelectMode(with: item)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 60))
                .foregroundColor(.gray.opacity(0.5))

            Text("Your Vault is Empty")
                .font(.title3.bold())
                .foregroundColor(.white)

            Text("Tap + to import photos and videos.\nThey will be encrypted and stored securely.")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            Button {
                showPhotoPicker = true
            } label: {
                Label("Import Media", systemImage: "plus.circle.fill")
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

    // MARK: - Bottom Action Bar (Multi-select)

    private var bottomSelectBar: some View {
        HStack(spacing: 20) {
            Button {
                showSlideshow = true
            } label: {
                Label("Slideshow", systemImage: "play.rectangle.fill")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.blue))
            }
            .disabled(selectedItems.isEmpty)

            Button {
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash.fill")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.red))
            }
            .disabled(selectedItems.isEmpty)

            Spacer()

            Text("\(selectedItems.count) selected")
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.10, green: 0.12, blue: 0.20))
                .shadow(color: .black.opacity(0.3), radius: 10, y: -5)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var bottomActionBar: some View {
        bottomSelectBar
    }

    private var multiSelectActionBar: some View {
        bottomActionBar
    }

    // MARK: - Selection Logic

    private var selectedVaultItems: [VaultItem]? {
        let items = storage.vaultItems.filter { selectedItems.contains($0.id) }
        return items.isEmpty ? nil : items
    }

    private func handleTap(on item: VaultItem) {
        if isMultiSelectMode {
            toggleSelection(item)
        } else {
            // Single tap in normal mode - could open a preview
            // For now, enter multi-select on long press only
        }
    }

    private func toggleSelection(_ item: VaultItem) {
        if selectedItems.contains(item.id) {
            selectedItems.remove(item.id)
        } else {
            selectedItems.insert(item.id)
        }

        if selectedItems.isEmpty {
            exitMultiSelectMode()
        }
    }

    private func enterMultiSelectMode(with item: VaultItem) {
        isMultiSelectMode = true
        selectedItems.insert(item.id)
    }

    private func exitMultiSelectMode() {
        isMultiSelectMode = false
        selectedItems.removeAll()
    }

    // MARK: - Import

    private func importPickedItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }

        isImporting = true

        Task {
            for item in items {
                do {
                    if let data = try await item.loadTransferable(type: Data.self) {
                        // Write to temp file and import
                        let tempURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)

                        try data.write(to: tempURL)

                        // Determine file extension from supported content types
                        if let type = item.supportedContentTypes.first {
                            let ext = type.preferredFilenameExtension ?? "jpg"
                            let renamedURL = tempURL.appendingPathExtension(ext)
                            try? FileManager.default.moveItem(at: tempURL, to: renamedURL)

                            try storage.importMedia(from: renamedURL)
                            try? FileManager.default.removeItem(at: renamedURL)
                        } else {
                            try storage.importMedia(from: tempURL)
                            try? FileManager.default.removeItem(at: tempURL)
                        }
                    }
                } catch {
                    importError = "Failed to import one or more items."
                }
            }

            isImporting = false
            pickerItems = []
        }
    }

    // MARK: - Delete

    private func deleteSelectedItems() {
        let itemsToDelete = storage.vaultItems.filter { selectedItems.contains($0.id) }
        storage.deleteItems(itemsToDelete)
        exitMultiSelectMode()
    }
}