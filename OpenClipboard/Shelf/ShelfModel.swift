import Foundation
import Observation
import OpenClipboardKit
import SwiftUI

/// What the shelf shows: the clips that match the search and filter, and which one is selected.
@Observable
final class ShelfModel {
    enum Filter: Int, CaseIterable, Identifiable {
        case all, pinned, text, link, image, file, color

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .pinned: "Pinned"
            case .text: "Text"
            case .link: "Links"
            case .image: "Images"
            case .file: "Files"
            case .color: "Colors"
            }
        }

        var symbol: String {
            switch self {
            case .all: "square.stack"
            case .pinned: "pin"
            case .text: "text.alignleft"
            case .link: "link"
            case .image: "photo"
            case .file: "doc"
            case .color: "paintpalette"
            }
        }

        var kind: ClipKind? {
            switch self {
            case .all, .pinned: nil
            case .text: .text
            case .link: .link
            case .image: .image
            case .file: .file
            case .color: .color
            }
        }
    }

    static let pageSize = 60

    @ObservationIgnored let store: HistoryStore

    private(set) var items: [ClipItem] = []
    /// How many clips match in total. `items` holds the ones loaded so far.
    private(set) var totalCount = 0
    /// False until the first load finished, so the empty state does not flash.
    private(set) var hasLoaded = false

    var searchText = "" {
        didSet { if searchText != oldValue { reload(keepingSelection: false) } }
    }

    var filter = Filter.all {
        didSet { if filter != oldValue { reload(keepingSelection: false) } }
    }

    private(set) var selection: ClipItem.ID?
    /// Whether the user has chosen a clip since the shelf opened. Until then the selection
    /// follows the newest clip, so that something copied a moment before opening the
    /// shelf, and only noticed now, is what Return pastes.
    @ObservationIgnored private var hasChosen = false
    /// Drives the appear and disappear animation of the shelf.
    var isPresented = false
    var isPreviewing = false
    /// While ⌘ is held, the cards show the number that pastes them.
    var isCommandDown = false
    /// The cards that are on screen, left to right.
    var visibleIDs: [ClipItem.ID] = []
    /// The moment the shelf was opened. Card ages are measured against it.
    var presentedAt = Date()
    /// Incremented to put the keyboard focus in the search field.
    var focusRequest = 0
    /// Where the selected card is, in the coordinates of the shelf window.
    var selectedCardFrame = CGRect.zero

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observation: Task<Void, Never>?

    init(store: HistoryStore) {
        self.store = store
        observation = Task { [weak self] in
            for await _ in await store.changes() {
                guard let self else { return }
                // A hidden shelf reloads when it is opened; there is nothing to keep fresh.
                if self.isPresented { self.reload(keepingSelection: self.hasChosen) }
            }
        }
    }

    var selectedItem: ClipItem? {
        guard let selection else { return nil }
        return items.first { $0.id == selection }
    }

    var selectedIndex: Int? {
        guard let selection else { return nil }
        return items.firstIndex { $0.id == selection }
    }

    private var query: ClipQuery {
        ClipQuery(text: searchText, kind: filter.kind, pinnedOnly: filter == .pinned)
    }

    var isFiltering: Bool { !searchText.isEmpty || filter != .all }

    // MARK: - Loading

    /// Called each time the shelf opens: back to the newest clip, nothing filtered.
    func prepareForPresentation() {
        presentedAt = Date()
        isPreviewing = false
        isCommandDown = false
        hasChosen = false
        if searchText.isEmpty, filter == .all {
            reload(keepingSelection: false)
        } else {
            // Each of these reloads through its observer; the last one wins.
            searchText = ""
            filter = .all
        }
        focusRequest += 1
    }

    func reload(keepingSelection: Bool) {
        generation += 1
        let generation = generation
        let query = query
        // Keep as many rows as were loaded, so the scroll position survives a refresh.
        let limit = keepingSelection ? max(items.count, Self.pageSize) : Self.pageSize
        Task {
            let fetched = (try? await store.items(matching: query, limit: limit)) ?? []
            let count = (try? await store.count(matching: query)) ?? fetched.count
            guard generation == self.generation else { return }
            items = fetched
            totalCount = count
            hasLoaded = true
            if !keepingSelection || !fetched.contains(where: { $0.id == selection }) {
                selection = fetched.first?.id
            }
        }
    }

    /// Forgets the loaded clips. Called some time after the shelf closed: the next opening
    /// reloads them, and until then the cards and their pictures do not occupy memory.
    func unload() {
        generation += 1
        items = []
        totalCount = 0
        hasLoaded = false
        selection = nil
        visibleIDs = []
        selectedCardFrame = .zero
    }

    /// Loads the next page once the user gets near the end of what is loaded.
    func cardAppeared(_ item: ClipItem) {
        guard items.count < totalCount, let index = items.firstIndex(where: { $0.id == item.id }),
              index >= items.count - 12
        else { return }
        let generation = generation
        let query = query
        let offset = items.count
        Task {
            let more = (try? await store.items(matching: query, limit: Self.pageSize, offset: offset)) ?? []
            guard generation == self.generation, offset == items.count else { return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: more.filter { !known.contains($0.id) })
        }
    }

    // MARK: - Selection

    func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        let current = selectedIndex ?? (offset > 0 ? -1 : items.count)
        let target = min(max(current + offset, 0), items.count - 1)
        select(items[target].id)
    }

    func selectFirst() { select(items.first?.id) }
    func selectLast() { select(items.last?.id) }

    /// Selects the clip the user pointed at, with the keyboard or the mouse.
    func select(_ id: ClipItem.ID?) {
        hasChosen = true
        selection = id
    }

    func cycleFilter(forward: Bool) {
        let all = Filter.allCases
        guard let index = all.firstIndex(of: filter) else { return }
        filter = all[(index + (forward ? 1 : all.count - 1)) % all.count]
    }

    /// The number, 1 to 9, that pastes the clip together with ⌘: its position among the
    /// cards that are on screen right now.
    func quickPasteNumber(for id: ClipItem.ID) -> Int? {
        guard let index = visibleIDs.prefix(9).firstIndex(of: id) else { return nil }
        return index + 1
    }

    func visibleItem(number: Int) -> ClipItem? {
        guard number >= 1, number <= min(visibleIDs.count, 9) else { return nil }
        let id = visibleIDs[number - 1]
        return items.first { $0.id == id }
    }

    /// Stores which cards are visible, in the order of the list.
    func updateVisible(_ ids: [ClipItem.ID]) {
        let visible = Set(ids)
        visibleIDs = items.map(\.id).filter(visible.contains)
    }

    // MARK: - Local edits, applied at once and then written to the store

    func removeLocally(_ item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: index)
        totalCount = max(totalCount - 1, 0)
        if selection == item.id {
            selection = items.indices.contains(index) ? items[index].id : items.last?.id
        }
    }

    func setPinnedLocally(_ pinned: Bool, _ item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinnedAt = pinned ? Date() : nil
    }
}
