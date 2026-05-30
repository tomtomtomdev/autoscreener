# Claude Skills — SwiftUI Architecture: MVVM vs UDF vs Clean Architecture (2026)

## Skill Identity

**Domain:** SwiftUI Application Architecture  
**Focus:** Choosing scalable architecture patterns for modern SwiftUI applications  
**Primary Recommendation:** UDF (Unidirectional Data Flow) with lightweight clean boundaries  
**Avoid:** UIKit-era MVVM abuse and excessive VIP/Clean boilerplate

---

# Core Principle

SwiftUI is fundamentally:

- Declarative
- State-driven
- Reactive
- Value-oriented
- Event-driven

Architecture should align with SwiftUI’s rendering model instead of fighting it.

The best SwiftUI architecture is one that:

- Preserves unidirectional state flow
- Minimizes mutable shared state
- Keeps rendering deterministic
- Supports async concurrency safely
- Scales modularly
- Matches SwiftUI mental models

---

# 1. The Problem with Traditional MVVM in SwiftUI

## Why MVVM Became Popular

MVVM originally solved UIKit problems:

- Massive UIViewControllers
- Delegate spaghetti
- Imperative UI coordination
- Difficult testing
- Tight coupling

In UIKit:

```text
ViewController
 ↕
ViewModel
 ↕
Services
```

This improved separation.

---

# 2. Why SwiftUI Changed Everything

SwiftUI already provides:

- Declarative rendering
- Automatic view updates
- State propagation
- Reactive bindings
- Environment injection
- Functional composition

As a result:

Traditional MVVM often becomes redundant.

---

# 3. Common MVVM Anti-Patterns in SwiftUI

## Massive ObservableObjects

Example:

```swift
class AppViewModel: ObservableObject {
    @Published var users: [User] = []
    @Published var loading = false
    @Published var selectedUser: User?

    func fetchUsers() {}
    func deleteUser() {}
    func syncCloud() {}
    func authenticate() {}
    func handleNotifications() {}
}
```

Problems:

- God objects
- Mixed responsibilities
- Hard testing
- Shared mutable state
- Race conditions
- Excessive MainActor usage
- Difficult modularization

---

## Business Logic in ViewModels

Bad pattern:

```text
ViewModel becomes:
- State manager
- Networking layer
- Database layer
- Business rules layer
- Navigation coordinator
- Cache manager
```

This creates architectural collapse.

---

## Two-Way Binding Abuse

Excessive:

```swift
@Binding
@ObservedObject
@EnvironmentObject
```

across deep hierarchies creates:

- Hidden dependencies
- Untraceable mutations
- Difficult debugging
- Non-deterministic updates

---

# 4. Modern SwiftUI Architectural Direction

## Preferred Direction

Modern SwiftUI apps increasingly use:

```text
Unidirectional Data Flow (UDF)
```

Inspired by:

- Elm
- Redux
- Flux
- TCA
- React reducers

---

# 5. What UDF Means

## Core Flow

```text
User Action
    ↓
Intent / Action
    ↓
Reducer / Feature Logic
    ↓
State Mutation
    ↓
SwiftUI Re-render
```

This aligns naturally with SwiftUI.

---

# 6. Benefits of UDF in SwiftUI

## Deterministic State

All mutations occur through explicit actions.

Benefits:

- Easier debugging
- Easier testing
- Predictable rendering
- Replayable state
- Better scalability

---

## Clear Data Ownership

State ownership becomes explicit.

Avoids:

- Hidden mutations
- Random object updates
- Cross-feature coupling

---

## Concurrency Safety

UDF works extremely well with:

- async/await
- actors
- structured concurrency
- cancellation
- AsyncSequence

---

## Modular Scalability

Each feature can own:

```text
Feature
 ├── State
 ├── Actions
 ├── Reducer
 ├── Effects
 └── Views
```

This scales far better than giant ViewModels.

---

# 7. Recommended Modern SwiftUI Architecture

## Preferred Stack

### UI Layer

Use:

- SwiftUI Views
- @State
- @Binding
- @Environment
- Observation framework

Views should remain:

- lightweight
- declarative
- render-focused

---

## Feature Layer

Use:

- Reducers
- Intent handling
- Feature stores
- Explicit actions

Responsibilities:

- state transitions
- orchestration
- side effects
- async tasks

---

## Domain Layer

Responsibilities:

- business rules
- validation
- pure logic
- workflows

Must remain:

- UI-independent
- deterministic
- testable

---

## Infrastructure Layer

Responsibilities:

- networking
- persistence
- logging
- analytics
- sync
- AI services
- caching

---

# 8. Modern Clean Architecture

## Important Clarification

Modern “clean architecture” does NOT necessarily mean:

```text
VIP
Interactor
Presenter
Router
```

That style originated from UIKit limitations.

---

# 9. Why VIP Is Often Too Heavy for SwiftUI

## Common Problems

### Boilerplate Explosion

Simple feature becomes:

```text
View
Interactor
Presenter
Entity
Router
Protocols
Factories
Builders
```

This slows development.

---

## Fighting SwiftUI

VIP often conflicts with:

- state-driven rendering
- reactive updates
- declarative composition
- local state ownership

---

## Over-Abstraction

Teams frequently create:

- unnecessary interfaces
- premature modularization
- indirection without value

Result:

- harder onboarding
- slower iteration
- cognitive overload

---

# 10. What Modern “Clean” Actually Means

## Good Modern Clean Architecture

Usually means:

```text
Feature isolation
+ dependency boundaries
+ separation of concerns
+ testability
+ modularity
```

NOT necessarily VIP.

---

# 11. Recommended Feature Structure

```text
Feature
 ├── Views
 ├── State
 ├── Actions
 ├── Reducer
 ├── Domain
 ├── Services
 └── Components
```

This fits SwiftUI naturally.

---

# 12. Recommended Architecture by App Size

## Small Apps

Use:

```text
SwiftUI
+ @Observable
+ lightweight services
+ local state
```

Avoid overengineering.

---

## Medium Apps

Use:

```text
UDF
+ feature modules
+ reducers
+ async services
```

This is the modern sweet spot.

---

## Large Apps

Use:

```text
Modular UDF
+ domain boundaries
+ actor-isolated services
+ dependency injection
+ event-driven systems
```

---

## Enterprise Apps

Use:

```text
Strict dependency rules
+ feature isolation
+ distributed state systems
+ infrastructure layers
```

Still usually NOT textbook VIP.

---

# 13. Best State Management Patterns

## Preferred Order

### Tier 1

- @Observable
- @State
- @Environment
- AsyncSequence

### Tier 2

- Reducer systems
- Feature stores
- Action dispatching

### Tier 3

Only when complexity requires:

- TCA
- custom Redux systems
- event buses

---

# 14. Recommended Concurrency Model

Modern SwiftUI architecture should embrace:

- structured concurrency
- actors
- cancellation
- async streams
- isolation safety

---

## Recommended Pattern

```swift
actor UserService {
    func fetchUsers() async throws -> [User] {
        ...
    }
}
```

instead of:

```swift
class UserService {
    var mutableCache = [:]
}
```

---

# 15. Navigation Architecture

## Preferred Navigation Style

Use:

- NavigationStack
- state-driven routing
- typed destinations

Avoid:

- imperative coordinators everywhere
- UINavigationController-era thinking

---

# 16. Dependency Injection

## Preferred Modern DI

Use:

- Environment
- protocol boundaries when useful
- constructor injection
- lightweight containers

Avoid:

- giant service locators
- magical runtime injection
- excessive protocols

---

# 17. Testing Strategy

## Best Testing Targets

### Highest Value

Test:

- reducers
- domain logic
- async workflows
- services
- state transitions

---

## Lower Value

Avoid over-testing:

- trivial SwiftUI rendering
- implementation details
- private view state

---

# 18. TCA (The Composable Architecture)

## When TCA Is Excellent

Use TCA for:

- large apps
- complex async workflows
- advanced state coordination
- highly modular systems
- multi-team environments

---

## TCA Downsides

Potential issues:

- learning curve
- boilerplate
- compile-time overhead
- abstraction complexity

Avoid forcing it into tiny apps.

---

# 19. Recommended Modern Stack

## Best Practical Stack (2026)

### UI

- SwiftUI
- Observation

### Architecture

- UDF
- feature modularization
- reducer patterns

### Concurrency

- async/await
- actors

### Persistence

- SwiftData
- SQLite

### Networking

- URLSession
- async networking

### Infrastructure

- os.Logger
- dependency injection
- analytics layer

---

# 20. Anti-Patterns

## Avoid

### Architecture

- Massive ViewModels
- God Stores
- Excessive protocols
- Deep inheritance
- Singleton-heavy systems

---

## SwiftUI-Specific

Avoid:

- giant EnvironmentObjects
- uncontrolled bindings
- state duplication
- logic-heavy views
- excessive GeometryReader usage

---

## Concurrency

Avoid:

- detached tasks everywhere
- mutable shared caches
- blocking MainActor
- unstructured async systems

---

# 21. Apple Ecosystem Direction

Apple APIs increasingly favor:

- reactive rendering
- value semantics
- isolated mutation
- observable state
- async streams
- unidirectional updates

SwiftUI architecture should align with this direction.

---

# 22. Final Recommendation

## Best Modern SwiftUI Architecture

For serious apps:

```text
SwiftUI
+ UDF
+ modular feature architecture
+ actor-isolated services
+ async/await
+ lightweight clean boundaries
```

---

## Use MVVM Only As:

```text
MVVM-lite
```

Meaning:

- thin observable wrappers
- local presentation state
- simple binding helpers

NOT giant ViewModels.

---

## Avoid Heavy VIP Unless:

- enterprise constraints require it
- organization already standardized on it
- team structure depends on strict layering

Even then:

Prefer simplified clean architecture.

---

# 23. Senior-Level Heuristics

## Heuristic 1

Architecture should match the UI framework.

---

## Heuristic 2

SwiftUI already solves many UIKit-era problems.

---

## Heuristic 3

The biggest SwiftUI scalability issue is uncontrolled mutable state.

---

## Heuristic 4

Reducer-based systems scale better than giant ViewModels.

---

## Heuristic 5

Boilerplate is architectural debt.

---

## Heuristic 6

Concurrency correctness matters more than pattern purity.

---

## Heuristic 7

Feature isolation is more important than strict textbook architecture.

---

# 24. Ideal SwiftUI Engineering Mindset

The best SwiftUI systems feel:

- deterministic
- composable
- responsive
- modular
- concurrency-safe
- predictable
- lightweight
- scalable
- testable
- native to SwiftUI’s mental model

Claude should optimize toward those qualities.

