import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showMenu = false
    @State private var showAddBox = false
    @State private var showQRScanner = false
    @State private var showAskGemma = false
    @State private var showSettings = false

    private var isDetailPresented: Binding<Bool> {
        Binding(
            get: { appState.selectedBoxId != nil },
            set: { presented in
                if !presented {
                    appState.selectedBoxId = nil
                }
            }
        )
    }

    private var gridColumns: [GridItem] {
        if horizontalSizeClass == .regular {
            return [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 14)]
        }
        return [GridItem(.flexible(), spacing: 12)]
    }

    private var trimmedQuery: String {
        appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var matchingItems: [(box: BoxRecord, item: ItemRecord)] {
        guard !trimmedQuery.isEmpty else { return [] }
        var hits: [(BoxRecord, ItemRecord)] = []
        for summary in appState.boxSummaries {
            for item in summary.items {
                let hay = "\(item.name) \(item.category) \(item.notes)".lowercased()
                if hay.contains(trimmedQuery) {
                    hits.append((summary.box, item))
                }
            }
        }
        return hits
    }

    private var matchingBoxes: [BoxSummary] {
        guard !trimmedQuery.isEmpty else { return appState.boxSummaries }
        return appState.boxSummaries.filter { summary in
            var hay = "\(summary.box.code) \(summary.box.name) \(summary.box.location) \(summary.box.notes)"
            for item in summary.items {
                hay += " \(item.name) \(item.category) \(item.notes)"
            }
            return hay.lowercased().contains(trimmedQuery)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summaryCard
                    searchSection
                    resultsSection
                }
                .frame(maxWidth: 1060)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(BoxFinderTheme.pageBackground)
            .navigationTitle("Box Finder")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showMenu = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.title3.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Open navigation menu")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddBox = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Add box")
                }
            }
            .navigationDestination(isPresented: isDetailPresented) {
                if let boxId = appState.selectedBoxId {
                    BoxDetailView(boxId: boxId)
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
        }
        .tint(BoxFinderTheme.accent)
        .sheet(isPresented: $showMenu) {
            NavigationMenuSheet(
                onAddBox: { showAddBox = true },
                onScanQR: { showQRScanner = true },
                onAskGemma: { showAskGemma = true },
                onSyncNow: {
                    Task { await appState.startSync() }
                },
                onPhotoAiSetup: { appState.showPhotoAiSetupSheet = true },
                onSettings: { showSettings = true }
            )
        }
        .sheet(isPresented: $showAddBox) {
            BoxEditorSheet(existingBox: nil) { name, location, notes in
                if let saved = await appState.saveBox(id: 0, name: name, location: location, notes: notes) {
                    appState.selectedBoxId = saved.id
                }
            }
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerSheet { payload in
                appState.openScannedQR(payload)
            }
        }
        .sheet(isPresented: $showAskGemma) {
            AskGemmaSheet()
        }
        .sheet(isPresented: $appState.showPhotoAiSetupSheet) {
            NavigationStack {
                PhotoAiSetupView()
            }
        }
        .sheet(item: $appState.reviewSession) { session in
            SuggestionReviewSheet(session: session) { updatedItems in
                await appState.commitSuggestedItems(
                    boxId: session.boxId,
                    sourceTag: session.sourceTag,
                    items: updatedItems
                )
            }
        }
        .alert(item: $appState.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .confirmationDialog(
            "Changes on both devices",
            isPresented: Binding(
                get: { appState.pendingSyncConflict != nil },
                set: { if !$0 { appState.pendingSyncConflict = nil } }
            ),
            presenting: appState.pendingSyncConflict
        ) { conflict in
            Button("Keep Pi versions") {
                Task { await appState.executeSync(engine: conflict.engine, plan: conflict.plan, preferLocal: false) }
            }
            Button("Keep this device's versions") {
                Task { await appState.executeSync(engine: conflict.engine, plan: conflict.plan, preferLocal: true) }
            }
            Button("Cancel", role: .cancel) {
                appState.pendingSyncConflict = nil
            }
        } message: { conflict in
            let names = conflict.plan.conflicts.joined(separator: ", ")
            Text("These boxes changed on both the Pi and this device: \(names). Choose which version to keep for these boxes. Unconflicted boxes will still merge.")
        }
        .overlay {
            if let message = appState.busyMessage {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text(message)
                            .font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .frame(maxWidth: 320)
                    .background(BoxFinderTheme.cardBackground)
                    .cornerRadius(18)
                    .shadow(radius: 12)
                }
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(appState.boxSummaries.count) boxes  ·  \(appState.totalItemTypesCount) item types")
                .font(.title3.weight(.bold))
            Text("All inventory, search, photos, QR labels and backups work offline on this device.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(BoxFinderTheme.cardBackground)
        .cornerRadius(16)
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Browse Inventory")
                .font(.headline)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search by item, location, box name or code", text: $appState.searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !appState.searchText.isEmpty {
                    Button {
                        appState.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(BoxFinderTheme.cardBackground)
            .cornerRadius(14)
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        let items = matchingItems
        let boxes = matchingBoxes

        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Matching Items (\(items.count))")
                    .font(.headline)
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(items, id: \.item.id) { entry in
                        Button {
                            appState.selectedBoxId = entry.box.id
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("ITEM")
                                    .font(.caption.weight(.bold))
                                    .foregroundColor(BoxFinderTheme.accent)
                                Text("\(entry.item.quantity) × \(entry.item.name)")
                                    .font(.body.weight(.semibold))
                                    .foregroundColor(.primary)
                                if !entry.item.category.isEmpty {
                                    Text(entry.item.category)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Text("In \(entry.box.code) · \(entry.box.name) · \(entry.box.location)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(BoxFinderTheme.cardBackground)
                            .cornerRadius(14)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }

        if !boxes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !trimmedQuery.isEmpty {
                    Text("Matching Boxes (\(boxes.count))")
                        .font(.headline)
                }
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(boxes) { summary in
                        Button {
                            appState.selectedBoxId = summary.box.id
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(summary.box.code.uppercased())
                                    .font(.caption.weight(.bold))
                                    .tracking(1.1)
                                    .foregroundColor(BoxFinderTheme.accent)
                                Text(summary.box.name)
                                    .font(.title3.weight(.semibold))
                                    .foregroundColor(.primary)
                                let itemWord = summary.itemTypeCount == 1 ? "item type" : "item types"
                                Text("\(summary.box.location)  ·  \(summary.itemTypeCount) \(itemWord)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(BoxFinderTheme.cardBackground)
                            .cornerRadius(16)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(summary.box.code), \(summary.box.name), \(summary.box.location), \(summary.itemTypeCount) item types")
                    }
                }
            }
        } else if items.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: trimmedQuery.isEmpty ? "shippingbox" : "magnifyingglass")
                    .font(.system(size: 38))
                    .foregroundColor(.secondary)
                Text(trimmedQuery.isEmpty ? "No boxes yet" : "No matching boxes or items")
                    .font(.headline)
                Text(trimmedQuery.isEmpty ? "Tap + or open the menu to add your first storage box." : "Try a different keyword or clear the search filter.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                if trimmedQuery.isEmpty {
                    Button("Add First Box") {
                        showAddBox = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(28)
            .background(BoxFinderTheme.cardBackground)
            .cornerRadius(16)
        }
    }
}
