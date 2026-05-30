---
name: macos-development
description: >
  Expert guidance for building macOS applications with Swift, SwiftUI, and AppKit. Use this skill
  whenever the user is working on a Mac app — writing Swift/SwiftUI code, architecting an app,
  setting up Xcode projects, integrating frameworks (SwiftData, Combine, Swift Concurrency),
  handling macOS-specific patterns (menu bar, windows, NSWindowController, scenes), or preparing
  for App Store / Developer ID distribution (sandboxing, entitlements, notarization). Trigger even
  for general questions like "how do I build a macOS app", "help me structure my Mac project",
  or "what's the best way to do X in Swift on Mac".
---

# macOS Development Skill

Comprehensive guidance for building production-quality macOS applications in 2025 and beyond.

---

## Framework Selection

### SwiftUI (Preferred for new development)
- **Use SwiftUI first** for all new Mac apps and new features in existing apps
- Declarative syntax: describe *what* the UI should look like, not *how* to build it
- Cross-platform: one codebase targets macOS, iOS, iPadOS, watchOS, tvOS, visionOS
- `App` struct → `Scene` (window group) → `View` hierarchy
- Xcode Previews via `#Preview` macro for rapid iteration
- List performance now handles ~20,000 items well on macOS 26+; use with confidence

```swift
import SwiftUI

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            // Add custom menu commands here
        }
    }
}
```

### AppKit (Use when SwiftUI gaps exist)
- Required for: certain SiriKit Intents, deep NSTableView customization (very large datasets), complex text editing (use `NSTextView` wrapped via `NSViewRepresentable`)
- Interop with SwiftUI: wrap AppKit views using `NSViewRepresentable` / `NSViewControllerRepresentable`
- Embed SwiftUI views into AppKit using `NSHostingView` / `NSHostingController`
- **No expectation of 100% SwiftUI**; mixing is common and supported

### Choosing Between Them
| Scenario | Recommendation |
|---|---|
| New app | SwiftUI |
| Existing AppKit app, adding features | SwiftUI incrementally via `NSHostingView` |
| Complex table with 100k+ rows | AppKit `NSTableView` |
| Rich text editing | `NSTextView` wrapped in SwiftUI |
| Menu bar extras | `MenuBarExtra` (SwiftUI) or `NSStatusItem` (AppKit) |
| Standard windows, sheets, popovers | SwiftUI |

---

## Architecture Patterns

### MVVM (Recommended with SwiftUI)
Separate UI from business logic for testability and maintainability.

```swift
// Model
struct Task: Identifiable, Codable {
    let id = UUID()
    var title: String
    var isCompleted: Bool
}

// ViewModel — use @Observable (Swift 5.9+) instead of ObservableObject
@Observable
class TaskViewModel {
    var tasks: [Task] = []
    
    func addTask(title: String) {
        tasks.append(Task(title: title, isCompleted: false))
    }
}

// View
struct ContentView: View {
    @State private var viewModel = TaskViewModel()
    
    var body: some View {
        List(viewModel.tasks) { task in
            Text(task.title)
        }
    }
}
```

**Key rule**: `@Observable` (macros, Swift 5.9+) supersedes `ObservableObject` + `@Published` for new code. Only use `ObservableObject` for backward compatibility (macOS 12 or earlier targets).

### Clean Architecture (for large apps)
Layer strictly: `Presentation` → `Domain` → `Data`
- Domain layer holds business logic, no framework imports
- Data layer: repositories, network, persistence
- Dependency injection via protocols for testability

---

## Swift Concurrency (Modern Async)

Prefer Swift Concurrency over Combine for new code targeting macOS 12+.

```swift
// async/await for network
func fetchData() async throws -> [Item] {
    let url = URL(string: "https://api.example.com/items")!
    let (data, _) = try await URLSession.shared.data(from: url)
    return try JSONDecoder().decode([Item].self, from: data)
}

// MainActor for UI work
@MainActor
class ContentViewModel: ObservableObject {
    @Published var items: [Item] = []
    
    func load() async {
        do {
            items = try await fetchData()
        } catch {
            print(error)
        }
    }
}

// Parallel execution with async let
func loadAll() async -> (String, Int) {
    async let a = fetchString()
    async let b = fetchCount()
    return await (a, b)
}

// Actors protect shared mutable state
actor DataCache {
    private var cache: [String: Data] = [:]
    
    func store(_ data: Data, forKey key: String) {
        cache[key] = data
    }
    
    func retrieve(forKey key: String) -> Data? {
        cache[key]
    }
}
```

**Critical rules:**
- `async` ≠ background thread — use `Task.detached` or `withTaskGroup` for CPU work off main
- Always annotate UI types with `@MainActor`
- Check `Task.checkCancellation()` in long loops
- Never use `DispatchSemaphore` with `async/await` (deadlock risk)
- Swift 6 strict concurrency: all `Sendable` conformances are compile-time checked

### Combine (Use for complex UI input pipelines)
```swift
// Still useful for: debounce, throttle, complex stream composition
$searchText
    .debounce(for: 0.3, scheduler: RunLoop.main)
    .removeDuplicates()
    .sink { [weak self] text in
        self?.performSearch(text)
    }
    .store(in: &cancellables)
```

---

## Persistence

### SwiftData (Preferred, macOS 14+)
```swift
import SwiftData

@Model
class Note {
    var title: String
    var content: String
    var createdAt: Date
    
    init(title: String, content: String) {
        self.title = title
        self.content = content
        self.createdAt = .now
    }
}

// In App struct
@main
struct NotesApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: Note.self)
    }
}

// Querying in views
struct ContentView: View {
    @Query(sort: \Note.createdAt, order: .reverse) var notes: [Note]
    @Environment(\.modelContext) private var context
    
    var body: some View {
        List(notes) { note in Text(note.title) }
    }
}
```

**SwiftData Concurrency**: Use `ModelActor` for background operations — it wraps a `ModelContext` in an actor for thread safety.

### Core Data (for macOS 12 and earlier targets)
- Use `NSPersistentCloudKitContainer` for iCloud sync
- Always perform operations on the correct context queue
- Background work: `performBackgroundTask` or a dedicated `NSManagedObjectContext`

---

## macOS-Specific UI Patterns

### Window Management
```swift
// Multiple window types
var body: some Scene {
    WindowGroup {              // main document windows
        ContentView()
    }
    Window("Settings", id: "settings") {  // single utility window
        SettingsView()
    }
    .keyboardShortcut(",", modifiers: .command)
}
```

### Menu Bar App
```swift
// SwiftUI MenuBarExtra (macOS 13+)
MenuBarExtra("App", systemImage: "star") {
    MenuBarContentView()
}
.menuBarExtraStyle(.window)   // or .menu for simple menus
```

### Custom Commands / Menu Items
```swift
.commands {
    CommandGroup(after: .newItem) {
        Button("Import...") { importAction() }
            .keyboardShortcut("i", modifiers: [.command, .shift])
    }
}
```

### Toolbar
```swift
.toolbar {
    ToolbarItem(placement: .primaryAction) {
        Button(action: addItem) {
            Label("Add", systemImage: "plus")
        }
    }
}
```

### Settings / Preferences
```swift
Settings {
    SettingsView()
}
```

---

## Security, Sandboxing & Distribution

> See `references/distribution.md` for detailed CLI commands and code signing steps.

### Quick Reference

**Sandbox**: Required for Mac App Store; optional (but recommended) for Developer ID.
- Restricts file system, network, device access to declared entitlements
- App Store apps **must** be sandboxed

**Key Entitlements:**
```xml
<!-- App Sandbox -->
<key>com.apple.security.app-sandbox</key><true/>

<!-- Network -->
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.network.server</key><true/>

<!-- File access (user-selected via Open/Save panel) -->
<key>com.apple.security.files.user-selected.read-write</key><true/>

<!-- Hardware -->
<key>com.apple.security.device.camera</key><true/>
<key>com.apple.security.device.microphone</key><true/>
```

**Hardened Runtime**: Required for notarization. Prevents code injection, DLL hijacking, memory tampering.

**Notarization flow** (Developer ID distribution):
1. Archive in Xcode
2. Upload to Apple via `notarytool` or Xcode Organizer
3. Apple scans for malware, issues Notarization Token
4. Staple token: `xcrun stapler staple MyApp.app`
5. Distribute in a signed DMG

**Distribution channels:**
- Mac App Store: sandboxed, reviewed by Apple
- Developer ID (DMG/pkg): notarized, Hardened Runtime required
- Direct (internal/enterprise): no notarization required but users see Gatekeeper warnings

---

## Xcode Project Structure (Recommended)

```
MyApp/
├── MyApp.xcodeproj
├── Sources/
│   ├── App/
│   │   └── MyApp.swift          # @main App struct
│   ├── Features/
│   │   ├── Home/
│   │   │   ├── HomeView.swift
│   │   │   └── HomeViewModel.swift
│   │   └── Settings/
│   │       └── SettingsView.swift
│   ├── Models/
│   │   └── Note.swift
│   ├── Services/
│   │   └── NoteService.swift
│   └── Utilities/
│       └── Extensions.swift
├── Resources/
│   ├── Assets.xcassets
│   └── Localizable.strings
└── Tests/
    └── MyAppTests/
```

---

## Accessibility & Localization

Always include:
- Accessibility labels on interactive elements: `.accessibilityLabel("Add item")`
- Support VoiceOver by reviewing focus order and descriptions
- Use `Foundation` for date/number/currency formatting (handles locales automatically)
- Add `Localizable.strings` and use `String(localized:)` or `NSLocalizedString`
- Test right-to-left layouts (`Scheme > Options > Application Language: Right to Left`)

---

## Performance Tips

- Profile with **Instruments** before optimizing
- `List` is fine up to ~20k items in macOS 26; use `LazyVStack` for custom lazy layouts
- Move heavy computation off `@MainActor` using `Task.detached` or `async let`
- For large text: bridge `NSTextView` from AppKit to avoid SwiftUI `Text` hitches
- Use `@Observable` instead of `ObservableObject` — more granular updates, less overhead

---

## Reference Files

- `references/distribution.md` — Full code signing, notarization, and DMG creation CLI commands
- `references/frameworks.md` — Deeper notes on AppKit interop, SwiftCharts, Swift Charts, CoreData migration to SwiftData

Read those files when the user needs detailed step-by-step guidance beyond this overview.
