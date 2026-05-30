---
name: clean-architecture
description: >
  Apply Uncle Bob's Clean Architecture principles when designing or reviewing software systems.
  Use this skill whenever the user mentions: architecture, SOLID principles, dependency rule,
  use cases, entities, interface adapters, layers, boundaries, coupling, cohesion, component design,
  hexagonal/onion/ports-and-adapters architecture, or asks how to structure a codebase, separate
  concerns, make code testable without a database, swap frameworks, or reduce technical debt.
  Also trigger for questions like "how do I structure this project", "where does this logic go",
  "is my architecture clean", or "how do I decouple X from Y".
---

# Clean Architecture — Robert C. Martin ("Uncle Bob")

> "The goal of software architecture is to minimize the human resources required to build and
> maintain the required system." — Robert C. Martin

---

## The Core Idea

Good architecture **separates concerns** by dividing software into layers. The single rule that
makes it all work:

### The Dependency Rule
> **Source code dependencies must point only inward. Nothing in an inner circle can know anything
> about something in an outer circle.**

Inner layers = high-level policy (stable, abstract, business rules)
Outer layers = low-level details (volatile, concrete: databases, frameworks, UIs, APIs)

The Web is a detail. The database is a detail. Keep them on the outside where they can do little harm.

---

## The Four Concentric Layers

```
┌─────────────────────────────────────────┐
│  Frameworks & Drivers (outermost)        │  ← Web, DB, UI, Devices
│  ┌───────────────────────────────────┐   │
│  │  Interface Adapters               │   │  ← Controllers, Presenters, Gateways
│  │  ┌─────────────────────────────┐  │   │
│  │  │  Use Cases                  │  │   │  ← Application Business Rules
│  │  │  ┌───────────────────────┐  │  │   │
│  │  │  │  Entities             │  │  │   │  ← Enterprise Business Rules
│  │  │  └───────────────────────┘  │  │   │
│  │  └─────────────────────────────┘  │   │
│  └───────────────────────────────────┘   │
└─────────────────────────────────────────┘
       Dependencies point INWARD only →
```

### Layer 1 — Entities (Enterprise Business Rules)
- Core business objects and their critical rules
- Pure domain objects — no framework imports, no DB awareness
- Shared across multiple applications in an enterprise
- Change only when fundamental business rules change
- **Example:** `Order`, `Customer`, `LoanApplication` with their validation rules

### Layer 2 — Use Cases (Application Business Rules)
- Orchestrate the flow of data to and from entities
- Implement application-specific business rules (not shared enterprise-wide)
- Define their own input/output data structures (DTOs)
- Independent of UI, database, and frameworks
- **Example:** `CreateOrderUseCase`, `EnrollStudentUseCase`, `ProcessPaymentUseCase`

### Layer 3 — Interface Adapters
- Convert data between the format most convenient for use cases and the format most convenient for the outside world
- **Controllers**: receive external input, convert to use case input format
- **Presenters**: receive use case output, convert to view model format
- **Gateways/Repositories**: implement the repository interfaces defined by use cases
- Contains the MVC architecture of a GUI
- **Example:** `OrderController`, `OrderRepository` (implements interface from use case layer)

### Layer 4 — Frameworks & Drivers (Outermost)
- Web frameworks, databases, devices, external services
- Mostly glue code — you don't write much here, you configure
- The most volatile layer — changes here should not ripple inward
- **Example:** Express.js, Django, SQLAlchemy, Spring, Next.js, Rails

---

## SOLID Principles

The microarchitecture foundation. Apply at the class/module level.

| Principle | Name | Rule |
|---|---|---|
| **S** | Single Responsibility | A module should have one, and only one, reason to change (one actor) |
| **O** | Open/Closed | Open for extension, closed for modification. Add behavior with new code, not by changing proven code |
| **L** | Liskov Substitution | Subtypes must be substitutable for their base types without breaking behavior |
| **I** | Interface Segregation | Prefer many small, focused interfaces over one large general-purpose one |
| **D** | Dependency Inversion | High-level modules depend on abstractions. Low-level modules implement those abstractions |

**DIP is the key mechanism** that makes the Dependency Rule possible — it lets inner layers define interfaces that outer layers implement, keeping dependencies pointing inward even when control flow goes outward.

```swift
// ❌ BAD — use case knows about the database (inner layer imports outer layer)
import CoreData  // wrong — use case layer should never import this
final class CreateOrderUseCase {
    private let context = NSManagedObjectContext(...)  // concrete, not abstract
}

// ✅ GOOD — use case defines the protocol; infrastructure implements it
// Protocol lives IN the use case layer
protocol OrderRepository {
    func save(_ order: Order) async throws
    func find(id: OrderID) async throws -> Order?
}

final class CreateOrderUseCase {
    private let repository: any OrderRepository  // depends on abstraction

    init(repository: any OrderRepository) {
        self.repository = repository
    }
}

// Lives in the infrastructure layer — knows about SwiftData
import SwiftData
final class SwiftDataOrderRepository: OrderRepository {
    private let context: ModelContext
    func save(_ order: Order) async throws { /* SwiftData specifics here */ }
    func find(id: OrderID) async throws -> Order? { /* ... */ }
}
```

---

## Component Principles

At scale, classes group into **components** (deployable units: packages, jars, DLLs, services).

### Component Cohesion — What goes together?

| Principle | Rule | Related To |
|---|---|---|
| **REP** — Reuse/Release Equivalence | Group classes into components that are released together. The granule of reuse = the granule of release | — |
| **CCP** — Common Closure | Group classes that change for the same reasons at the same times. Separate classes that change at different times | SRP at component level |
| **CRP** — Common Reuse | Don't force users of a component to depend on things they don't need | ISP at component level |

These three pull against each other. Early projects prioritize CCP (easy development). Mature projects balance all three.

### Component Coupling — How components relate

| Principle | Rule |
|---|---|
| **ADP** — Acyclic Dependencies | No cycles in the component dependency graph. Break cycles with DIP or by extracting a new component |
| **SDP** — Stable Dependencies | Depend in the direction of stability. Volatile components depend on stable ones, not vice versa |
| **SAP** — Stable Abstractions | Stable components should be abstract. Instability and concreteness go together; stability and abstraction go together |

**ADP violation example:**
```
Orders → Payments → Inventory → Orders  ← CYCLE. No team can move independently.
```
**Fix:** Break cycle with an interface or event, or extract shared code into a new `SharedContracts` component.

---

## Architectural Independence — The Four "Ables"

A well-designed system following the Dependency Rule is:

1. **Independent of Frameworks** — frameworks are tools, not constraints. You can use them without being married to them
2. **Testable** — business rules can be tested without UI, database, web server, or any external element
3. **Independent of UI** — swap React for a CLI without changing business rules
4. **Independent of Databases** — swap PostgreSQL for MongoDB without changing business rules

---

## Crossing Boundaries

Data that crosses a boundary must be in a form convenient to the *inner* circle, never in a form dictated by the outer circle. Use simple DTOs (data transfer objects) — structs or plain data classes with no behavior.

**Never pass framework objects inward.** Don't pass `ModelContext`, `NSManagedObject`, `URLRequest`, or SwiftData `@Model` types into a use case.

```swift
// Plain structs — no framework imports, cross boundaries safely
struct CreateOrderInput {
    let customerID: CustomerID
    let items: [OrderItemInput]
}

struct OrderItemInput {
    let productID: ProductID
    let quantity: Int
}

struct CreateOrderOutput {
    let orderID: OrderID
    let total: Decimal
    let estimatedDelivery: Date
}

final class CreateOrderUseCase {
    func execute(_ input: CreateOrderInput) async throws -> CreateOrderOutput {
        let order = Order(customerID: input.customerID, items: input.items)
        try await repository.save(order)
        return CreateOrderOutput(orderID: order.id, total: order.total,
                                 estimatedDelivery: order.estimatedDelivery)
    }
}
```

---

## The Main Component

Every system needs a `Main` (or equivalent composition root) that:
- Lives in the outermost circle
- Wires everything together (dependency injection)
- Creates concrete implementations and injects them inward
- Is the dirtiest, most coupled component — and the easiest to fix

```swift
// MyApp.swift — the composition root (outermost layer)
@main
struct MyApp: App {
    // All concrete infrastructure constructed here
    private let container: AppContainer = .init()

    var body: some Scene {
        WindowGroup {
            // Inject concrete implementations inward
            let repo = SwiftDataOrderRepository(context: container.modelContext)
            let emailService = SendGridEmailService(apiKey: Config.sendGridKey)
            let useCase = CreateOrderUseCase(repository: repo, email: emailService)
            let viewModel = OrderViewModel(createOrder: useCase)
            ContentView(viewModel: viewModel)
        }
    }
}
```

---

## Common Anti-Patterns to Flag and Fix

| Anti-Pattern | Problem | Fix |
|---|---|---|
| `@Model` class used as domain entity | SwiftData concern leaks into domain | Separate `@Model` (infrastructure) from domain struct; use a mapper |
| `ModelContext` injected into use case | Use case coupled to SwiftData | Inject `OrderRepository` protocol instead |
| ViewModel imports `SwiftData` | Adapter layer leaks infrastructure | ViewModel only knows use cases and domain types |
| `URLSession.shared.data(from:)` called in use case | Use case coupled to HTTP | Define `RemoteService` protocol; inject it |
| `@AppStorage` or `UserDefaults` inside use case | Config detail in business logic | Pass values as parameters; storage stays in ViewModel/View |
| Circular component imports | Violates ADP, blocks independent builds | Extract shared contract/protocol into a new module or invert dependency |
| SwiftUI `View` contains business logic | Not testable without UI | Move logic to ViewModel; View only renders `@Observable` state |
| SwiftData `@Model` returned from repository | Outer type leaks inward | Repository returns domain struct; maps internally |

---

## Testing Strategy

Clean Architecture naturally produces a test pyramid:

- **Entity tests** (unit): fast, no mocks, pure logic
- **Use case tests** (unit): mock the repository/gateway interfaces, test orchestration
- **Adapter tests** (integration): test controller input mapping, gateway SQL queries
- **E2E tests** (system): minimal, test the whole flow

```swift
// Use case test — no SwiftData, no network, no SwiftUI, no framework at all
final class MockOrderRepository: OrderRepository {
    var saved: [Order] = []
    var shouldThrow = false
    func save(_ order: Order) async throws {
        if shouldThrow { throw OrderError.saveFailed }
        saved.append(order)
    }
    func find(id: OrderID) async throws -> Order? { saved.first { $0.id == id } }
}

func testCreateOrderFailsForInactiveCustomer() async throws {
    let repo = MockOrderRepository()
    let customers = MockCustomerRepository(inactiveID: CustomerID())
    let useCase = CreateOrderUseCase(repository: repo, customers: customers)

    await #expect(throws: CustomerError.inactive) {
        try await useCase.execute(CreateOrderInput(customerID: customers.inactiveID, items: []))
    }
}
```

---

## Project Structure That Screams Intent

The architecture should communicate what the system *does*, not what framework it uses.

```
# ❌ BAD — screams "I use MVC and SwiftUI navigation patterns"
MyApp/
├── Models/
├── Views/
├── ViewModels/
└── Services/

# ✅ GOOD — screams "I'm an order management system"
MyApp/
├── Domain/
│   ├── Entities/          # Order.swift, Customer.swift — pure Swift
│   └── Errors/
├── Application/
│   ├── Protocols/         # OrderRepository.swift — protocols owned here
│   ├── UseCases/          # CreateOrderUseCase.swift, CancelOrderUseCase.swift
│   └── DTOs/              # CreateOrderInput.swift, CreateOrderOutput.swift
├── InterfaceAdapters/
│   ├── ViewModels/        # OrderViewModel.swift — @Observable, bridges use cases to SwiftUI
│   └── Mappers/           # OrderMapper.swift
├── Infrastructure/
│   ├── Persistence/       # SwiftDataOrderRepository.swift
│   └── Networking/        # URLSessionAPIClient.swift
└── UI/
    └── Orders/            # OrderListView.swift, OrderDetailView.swift
```

---

## Quick Reference Checklist

When reviewing or designing architecture, ask:

- [ ] Can I test business rules without spinning up a database?
- [ ] Can I test use cases by mocking repositories?
- [ ] Do entities have zero imports from frameworks or ORMs?
- [ ] Do use cases define their own input/output types (not framework types)?
- [ ] Are database models separate from domain entities?
- [ ] Is there a clear composition root that wires everything together?
- [ ] Could I swap the web framework without touching use cases or entities?
- [ ] Are component dependencies acyclic (no cycles)?
- [ ] Do volatile components depend on stable ones, not the reverse?

---

## Reference Files

- `references/solid-deep-dive.md` — detailed SOLID principle examples in Python, TypeScript, Java
- `references/patterns-and-comparisons.md` — how Clean Architecture relates to Hexagonal, Onion, DDD; practical folder structures by language
