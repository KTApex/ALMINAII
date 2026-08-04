import PhotosUI
import SwiftUI

/// The main vault interface showing a clean, date-grouped grid of encrypted media.
/// Features:
///  - Chronological grouping (Today / Yesterday / Month / Year)
///  - Album & category system (Personal, Documents, Favorites, custom)
///  - Sort (Date Added / File Size / Name) and Filter (Photos / Videos)
///  - Slideshow trigger inside the filter menu
///  - Single Media Viewer with pinch-to-zoom for photos and AVPlayer for videos
///  - Multi-select, import via PhotosPicker, delete
struct MediaVaultView: View {
    @EnvironmentObject var session: VaultSessionManager
    @ObservedObject var storage = VaultStorageManager.shared

    // MARK: - View State

    @State private var isMultiSelectMode = false
    @State private var selectedItems: Set<UUID> = []
    @State private var showPhotoPicker = false
    @State private var showSlideshow = false
    @State private var showDeleteConfirmation = false
    @State private var showMoveToAlbum = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var importError: String?

    // Filter / Sort / Album state
    @State private var sortOption: VaultSortOption = .dateAdded
    @State private var filterOption: VaultFilterOption = .all
    @State private var selectedAlbumID: UUID?
    @State private var showFilterMenu = false
    @State private var showAlbumMenu = false
    @State private var showCreateAlbum = false

    // Single media viewer
    @State private var viewerItem: VaultItem?

    // MARK: - Computed

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    /// Items after applying album, filter, and sort.
    private var displayedItems: [VaultItem] {
        var items = storage.vaultItems

        // Album filter
        if let selectedAlbumID {
            items = items.filter { $0.albumID == selectedAlbumID }
        }

        // Type filter
        switch filterOption {
        case .all:
            break
        case .photosOnly:
            items = items.filter { $0.mediaType == .photo }
        case .videosOnly:
            items = items.filter { $0.mediaType == .video }
        }

        // Sort
        switch sortOption {
        case .dateAdded:
            items.sort { $0.createdAt > $1.createdAt }
        case .fileSize:
            items.sort { $0.fileSize > $1.fileSize }
        case .name:
            items.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }

        return items
    }

    /// Groups the displayed items into chronological sections.
    private var groupedItems: [(group: DateGroup, items: [VaultItem])] {
        guard sortOption == .dateAdded else {
            return [(.today, displayedItems)]
        }

        var groups: [DateGroup: [VaultItem]] = [:]
        for item in displayedItems {
            let group = DateGroup.group(for: item.createdAt)
            groups[group, default: []].append(item)
        }

        return groups
            .sorted { lhs, rhs in
                // Today > Yesterday > recent months > older years
                groupRank(lhs.key) < groupRank(rhs.key)
            }
            .map { (group: $0.key, items: $0.value.sorted { $0.createdAt > $1.createdAt }) }
    }

    private func groupRank(_ group: DateGroup) -> Int {
        switch group {
        case .today: return 0
        case .yesterday: return 1
        case .month(let date):
            let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
            return 2 + (days / 30)
        case .year(let year):
            return 100 + (Date().year - year)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color(red: 0.05, green: 0.07, blue: 0.12)
                    .ignoresSafeArea()

                if displayedItems.isEmpty {
                    emptyStateView
                } else {
                    groupedGridView
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

                // Filter / Sort button
                ToolbarItem(placement: .topBarTrailing) {
                    if isMultiSelectMode {
                        Button("Cancel") {
                            exitMultiSelectMode()
                        }
                        .foregroundColor(.blue)
                    } else {
                        HStack(spacing: 14) {
                            // Album selector
                            Button {
                                showAlbumMenu = true
                            } label: {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(selectedAlbumID != nil ? .blue : .gray)
                            }

                            // Filter/Sort menu
                            Button {
                                showFilterMenu = true
                            } label: {
                                Image(systemName: filterOption != .all ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                                    .foregroundColor(filterOption != .all ? .blue : .gray)
                            }

                            // Add
                            Button {
                                showPhotoPicker = true
                            } label: {
                                Image(systemName: "plus")
                                    .foregroundColor(.blue)
                            }
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
            .onChange(of: pickerItems) { newItems in
                importPickedItems(newItems)
            }
            .fullScreenCover(isPresented: $showSlideshow) {
                SlideshowView(items: slideshowItems, storage: storage)
            }
            .fullScreenCover(item: $viewerItem) { item in
                MediaViewerView(item: item, storage: storage)
            }
            .sheet(isPresented: $showFilterMenu) {
                FilterSortMenuView(
                    sortOption: $sortOption,
                    filterOption: $filterOption,
                    onPlaySlideshow: {
                        showFilterMenu = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showSlideshow = true
                        }
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showAlbumMenu) {
                AlbumMenuView(
                    albums: storage.albums,
                    selectedAlbumID: $selectedAlbumID,
                    onCreateAlbum: {
                        showAlbumMenu = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showCreateAlbum = true
                        }
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showCreateAlbum) {
                CreateAlbumView { name in
                    storage.createAlbum(name: name)
                }
                .presentationDetents([.height(220)])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showMoveToAlbum) {
                MoveToAlbumView(
                    albums: storage.albums,
                    onMove: { album in
                        let itemsToMove = storage.vaultItems.filter { selectedItems.contains($0.id) }
                        storage.moveItems(itemsToMove, to: album)
                        exitMultiSelectMode()
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
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

    // MARK: - Grouped Grid

    private var groupedGridView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(groupedItems, id: \.group) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        // Section header
                        HStack {
                            Text(section.group.title)
                                .font(.headline)
                                .foregroundColor(.white)

                            Spacer()

                            Text("\(section.items.count) item\(section.items.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding(.horizontal, 12)

                        // Grid for this section
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(section.items) { item in
                                gridCell(for: item)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }
            .padding(.vertical, 12)
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
                    .background(Circle().fill(Color.black.opacity(0.3)))
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

            Text(emptyStateTitle)
                .font(.title3.bold())
                .foregroundColor(.white)

            Text(emptyStateMessage)
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            if selectedAlbumID == nil && filterOption == .all {
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
        }
        .padding(30)
    }

    private var emptyStateTitle: String {
        if let selectedAlbumID,
           let album = storage.albums.first(where: { $0.id == selectedAlbumID }) {
            return "No Items in \"\(album.name)\""
        }
        if filterOption == .photosOnly {
            return "No Photos"
        }
        if filterOption == .videosOnly {
            return "No Videos"
        }
        return "Your Vault is Empty"
    }

    private var emptyStateMessage: String {
        if selectedAlbumID != nil {
            return "Add items to this album by selecting them\nand choosing \"Move to Album\"."
        }
        return "Tap + to import photos and videos.\nThey will be encrypted and stored securely."
    }

    // MARK: - Multi-Select Action Bar

    private var multiSelectActionBar: some View {
        HStack(spacing: 14) {
            // Slideshow button
            Button {
                showSlideshow = true
            } label: {
                Label("Slideshow", systemImage: "play.rectangle.fill")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.blue))
            }
            .disabled(selectedItems.isEmpty)

            // Move to album
            Button {
                showMoveToAlbum = true
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.orange))
            }
            .disabled(selectedItems.isEmpty)

            // Delete
            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash.fill")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.red))
            }
            .disabled(selectedItems.isEmpty)

            Spacer()

            Text("\(selectedItems.count)")
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(0.1)))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(red: 0.10, green: 0.12, blue: 0.20))
                .shadow(color: .black.opacity(0.4), radius: 12, y: -4)
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Slideshow Items

    private var slideshowItems: [VaultItem] {
        if isMultiSelectMode && !selectedItems.isEmpty {
            return displayedItems.filter { selectedItems.contains($0.id) }
        }
        return displayedItems
    }

    // MARK: - Selection Logic

    private func handleTap(on item: VaultItem) {
        if isMultiSelectMode {
            toggleSelection(item)
        } else {
            // Open the single media viewer
            viewerItem = item
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

// MARK: - Filter & Sort Menu

struct FilterSortMenuView: View {
    @Binding var sortOption: VaultSortOption
    @Binding var filterOption: VaultFilterOption
    var onPlaySlideshow: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Sort section
                Section("Sort By") {
                    ForEach(VaultSortOption.allCases) { option in
                        Button {
                            sortOption = option
                        } label: {
                            HStack {
                                Label(option.rawValue, systemImage: sortIcon(for: option))
                                    .foregroundColor(.white)
                                Spacer()
                                if sortOption == option {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }

                // Filter section
                Section("Filter") {
                    ForEach(VaultFilterOption.allCases) { option in
                        Button {
                            filterOption = option
                        } label: {
                            HStack {
                                Label(option.rawValue, systemImage: filterIcon(for: option))
                                    .foregroundColor(.white)
                                Spacer()
                                if filterOption == option {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }

                // Slideshow section
                Section {
                    Button {
                        onPlaySlideshow()
                    } label: {
                        Label("Play Slideshow", systemImage: "play.rectangle.fill")
                            .font(.headline)
                            .foregroundColor(.blue)
                    }
                }
            }
            .navigationTitle("Sort & Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.blue)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func sortIcon(for option: VaultSortOption) -> String {
        switch option {
        case .dateAdded: return "calendar"
        case .fileSize: return "externaldrive"
        case .name: return "textformat"
        }
    }

    private func filterIcon(for option: VaultFilterOption) -> String {
        switch option {
        case .all: return "square.grid.2x2"
        case .photosOnly: return "photo"
        case .videosOnly: return "film"
        }
    }
}

// MARK: - Album Menu

struct AlbumMenuView: View {
    let albums: [VaultAlbum]
    @Binding var selectedAlbumID: UUID?
    var onCreateAlbum: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // All items (no album)
                Button {
                    selectedAlbumID = nil
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "square.grid.2x2")
                            .foregroundColor(.blue)
                        Text("All Items")
                            .foregroundColor(.white)
                        Spacer()
                        if selectedAlbumID == nil {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                }

                // Album list
                Section("Albums") {
                    ForEach(albums) { album in
                        Button {
                            selectedAlbumID = album.id
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: album.icon)
                                    .foregroundColor(.blue)
                                Text(album.name)
                                    .foregroundColor(.white)
                                Spacer()
                                if selectedAlbumID == album.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }

                // Create new
                Section {
                    Button {
                        onCreateAlbum()
                    } label: {
                        Label("Create New Album", systemImage: "folder.badge.plus")
                            .foregroundColor(.blue)
                    }
                }
            }
            .navigationTitle("Albums")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.blue)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Create Album

struct CreateAlbumView: View {
    var onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var albumName = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextField("Album Name", text: $albumName)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                Button {
                    let trimmed = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onCreate(trimmed)
                    dismiss()
                } label: {
                    Text("Create Album")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(Color.blue))
                        .foregroundColor(.white)
                }
                .padding(.horizontal)
                .disabled(albumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
            .padding(.top, 24)
            .navigationTitle("New Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.gray)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Move to Album

struct MoveToAlbumView: View {
    let albums: [VaultAlbum]
    var onMove: (VaultAlbum?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Move To") {
                    // Remove from album
                    Button {
                        onMove(nil)
                        dismiss()
                    } label: {
                        Label("No Album", systemImage: "xmark.circle")
                            .foregroundColor(.white)
                    }

                    ForEach(albums) { album in
                        Button {
                            onMove(album)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: album.icon)
                                    .foregroundColor(.blue)
                                Text(album.name)
                                    .foregroundColor(.white)
                            }
                        }
                    }
                }

                Section {
                    Text("Selected items will be moved to the chosen album.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            .navigationTitle("Move Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.gray)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Date Extensions

private extension Date {
    var year: Int {
        Calendar.current.component(.year, from: self)
    }
}