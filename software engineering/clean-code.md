---
name: clean-code
description: Apply Clean Code principles by Robert C. Martin (Uncle Bob) to review, write, or refactor code. Use this skill whenever the user asks to review code quality, refactor for readability, identify code smells, improve naming/functions/classes, write cleaner tests, or when they mention "clean code", "Uncle Bob", "code smell", "refactor", "readability", "maintainability", or wants feedback on their code's structure. Also trigger when user shares a code snippet and asks "is this good?" or "how can I improve this?" — always consult this skill before responding to code quality questions.
---

# Clean Code — Robert C. Martin

Use this skill to **evaluate, write, or refactor code** according to Uncle Bob's principles. Apply it chapter by chapter as relevant to the task at hand. When reviewing code, scan all sections and flag violations. When writing new code, use these as active constraints.

---

## Core Philosophy

> "Clean code can be read and enhanced by a developer other than its original author."

**The Boy Scout Rule**: Always leave the code cleaner than you found it — even if you didn't write it. Small, continuous improvements compound into significantly better codebases.

**Code is written for humans first, machines second.** If it can't be understood easily by everyone on the team, it's not clean.

---

## Ch. 2 — Meaningful Names

The single biggest readability lever. Bad names force readers to decode intent instead of reading it.

| Rule | Bad | Good |
|------|-----|------|
| Intention-revealing | `d` | `elapsedTimeInDays` |
| No disinformation | `accountList` (it's a Map) | `accounts` |
| Meaningful distinction | `getData()` vs `getInfo()` | `getUserProfile()` vs `getUserPermissions()` |
| Pronounceable | `genymdhms` | `generationTimestamp` |
| Searchable | `7` | `MAX_CLASSES_PER_STUDENT` |
| No encodings | `m_name`, `strName` | `name` |

**Swift/iOS note**: Avoid `Manager`, `Helper`, `Util` suffixes — they signal unclear responsibility. Prefer `UserAuthenticator` over `AuthManager`.

---

## Ch. 3 — Functions

Functions are the primary unit of organization. Keep them small and focused.

### Rules (in priority order)
1. **Do one thing** — if you can extract a function from it with a name that isn't merely a restatement, it's doing more than one thing
2. **Small** — ideally < 20 lines; a screen's worth at most
3. **One level of abstraction per function** — don't mix high-level orchestration with low-level detail
4. **Descriptive names** — a long descriptive name beats a short mysterious one
5. **Prefer fewer arguments** — 0 is ideal, 1 is fine, 2 is acceptable, 3+ needs justification
6. **No side effects** — a function named `checkPassword()` should not start a session
7. **No flag arguments** — `render(true)` is unclear; split into `renderForSuite()` / `renderForSingleTest()`

### Swift example — before/after
```swift
// BAD: multiple levels, side effects, flag arg
func process(_ data: [User], isAdmin: Bool) {
    for user in data {
        if isAdmin { db.save(user); log.write(user) }
        else { db.saveReadOnly(user) }
    }
}

// GOOD: separated concerns, no flags
func persistUsers(_ users: [User]) { users.forEach(db.save) }
func persistReadOnlyUsers(_ users: [User]) { users.forEach(db.saveReadOnly) }
func auditUsers(_ users: [User]) { users.forEach(log.write) }
```

---

## Ch. 4 — Comments

**The best comment is no comment** — rewrite the code so it explains itself.

### When comments ARE acceptable
- Legal/copyright headers
- Warning of consequences: `// Thread-unsafe; call only from main queue`
- Explanation of intent for non-obvious business logic
- Amplification of something that seems unimportant but isn't
- TODO markers (but resolve them, don't accumulate)

### Never do this
- Redundant comments (`i++ // increment i`)
- Commented-out code — delete it; that's what git is for
- Closing brace comments (`} // end if`)
- Journal/changelog comments in source files
- Noise comments that restate the function signature

---

## Ch. 5 — Formatting

Formatting is **communication**. It signals team discipline and makes intent legible.

- **Vertical openness**: blank lines between concepts
- **Vertical density**: related lines close together (no blank lines inside a logical unit)
- **Vertical ordering**: callers above callees; high-level above low-level
- **Declare variables near use** — not all at the top of a function
- **Line length**: 80–120 chars max
- **No horizontal alignment** of variable names/assignments (fragile, misleading)
- **Team-wide enforcement** via SwiftLint / linter — consistency beats personal preference

---

## Ch. 6 — Objects and Data Structures

Choose deliberately between the two paradigms:

| | Objects | Data Structures |
|---|---|---|
| Hide | Internal data | Functions |
| Expose | Behavior | Data |
| Good for | Polymorphism, adding new types | Adding new functions to existing types |

**Law of Demeter** — a module should not know the internals of the objects it manipulates:
```swift
// BAD: train wreck / Law of Demeter violation
let city = user.address.city.name

// GOOD: ask, don't dig
let city = user.city()
```

**Avoid hybrid structures** — half object, half data structure. Pick one.

---

## Ch. 7 — Error Handling

Error handling is part of the code's logic — not an afterthought.

- **Use exceptions/throws, not return codes** — errors that can be ignored will be ignored
- **Provide context** in errors — what operation failed, what state was involved
- **Define exception classes by caller's needs** — wrap third-party APIs at boundaries
- **Don't return nil** — return a Special Case object or throw; nil-checks cascade
- **Don't pass nil** — it's a hidden bomb
- **Separate error handling from business logic** — a function that does both violates SRP

```swift
// BAD: nil propagation
func findUser(id: String) -> User? { ... }

// BETTER: explicit failure contract
func findUser(id: String) throws -> User { ... }
```

---

## Ch. 8 — Boundaries

When integrating third-party code or external APIs:

- **Write learning tests** — test the third-party API in isolation to understand its behavior before integrating
- **Wrap external APIs** — expose only what your codebase needs; insulates you from API changes
- **Define your interface first** — write the interface you *wish* existed, then adapt the real one to it
- **Don't let third-party types leak** across your codebase; depend on your own abstraction

```swift
// Wrap the SDK; your app talks to this, not directly to the SDK
protocol AnalyticsTracking {
    func track(event: AnalyticsEvent)
}

struct FirebaseAnalyticsAdapter: AnalyticsTracking {
    func track(event: AnalyticsEvent) { /* Firebase-specific */ }
}
```

---

## Ch. 9 — Unit Tests

**F.I.R.S.T. rules** (non-negotiable):
- **Fast** — slow tests don't get run
- **Independent** — no test should set up state for another
- **Repeatable** — same result in any environment
- **Self-validating** — pass or fail; no manual inspection
- **Timely** — write tests just before the production code that makes them pass (TDD)

### Clean test structure
- **One assert per test** (or one concept per test)
- **Readable** — the test is the specification; future maintainers must understand it
- **Build-Operate-Check** (Arrange-Act-Assert) pattern — three clearly separated phases
- Test code deserves the same quality attention as production code

---

## Ch. 10 — Classes

- **Single Responsibility Principle (SRP)**: a class should have one reason to change
- **Small** — measure by responsibilities, not line count
- **High cohesion**: instance variables used by most methods → high cohesion is good
- **Open/Closed Principle**: open for extension, closed for modification
- **Organize for change**: isolate things that change from things that don't

```swift
// BAD: PaymentProcessor knows about formatting AND validation AND charging
class PaymentProcessor {
    func validate(_ card: Card) -> Bool { ... }
    func formatReceipt(_ payment: Payment) -> String { ... }
    func charge(_ card: Card, amount: Decimal) { ... }
}

// GOOD: each class has one job
class CardValidator { func validate(_ card: Card) throws { ... } }
class ReceiptFormatter { func format(_ payment: Payment) -> String { ... } }
class PaymentGateway { func charge(_ card: Card, amount: Decimal) throws { ... } }
```

---

## Ch. 11 — Systems

- **Separate construction from use** — defer object creation to startup/factory; use dependency injection
- **Obey Separation of Concerns** — startup logic ≠ runtime logic
- **Delay decisions** — defer architectural choices until you have the information to make them well
- **Use POJOs/plain structs** for domain logic; keep frameworks at the boundary

---

## Ch. 12 — Emergence (Kent Beck's 4 Rules of Simple Design)

In priority order:
1. **Runs all the tests** — a system must be verifiable
2. **Contains no duplication** — duplicate code represents extra risk; every duplication is a future inconsistency
3. **Expresses the intent of the programmer** — use good names, small functions, standard patterns
4. **Minimizes the number of classes and methods** — don't over-engineer; eliminate waste

---

## Ch. 13 — Concurrency

Concurrency is hard. Default to caution.

- **Severely limit access to shared data** — prefer immutable data; use actors in Swift
- **Use copies of data** rather than sharing when possible
- **Keep concurrency concerns separate** from other logic
- **Know your concurrency primitives** — Swift actors, async/await, DispatchQueue — use the right one
- **Test concurrency edge cases** explicitly — data races won't appear in single-threaded tests

---

## Code Smells — Quick Reference

Use these as a checklist when reviewing code:

| Smell | Description | Fix |
|-------|-------------|-----|
| **Rigidity** | Small change cascades everywhere | Decouple; depend on abstractions |
| **Fragility** | Code breaks in unrelated places | Increase cohesion; reduce coupling |
| **Immobility** | Can't reuse pieces elsewhere | Extract to library/module |
| **Needless Complexity** | Overengineered for current needs | YAGNI; simplify |
| **Needless Repetition** | DRY violation | Extract to shared function/protocol |
| **Opacity** | Hard to understand what code does | Rename; decompose; add doc |
| **Long Method** | Function > 20 lines | Extract functions |
| **Long Parameter List** | > 3 arguments | Introduce Parameter Object |
| **Shotgun Surgery** | One change touches many classes | Consolidate responsibilities |
| **Feature Envy** | Method uses another class's data more than its own | Move method |
| **Data Clumps** | Same group of variables always together | Extract to struct/class |
| **Inappropriate Intimacy** | Classes know too much about each other | Introduce interface; move methods |
| **Comments Explaining Bad Code** | Comment exists because code is unclear | Rewrite the code |

---

## When Applying This Skill

1. **Code review**: Scan against all sections above; call out smells by name with the fix
2. **Writing new code**: Apply Names → Functions → Classes rules upfront
3. **Refactoring**: Start with tests first (Ch. 9), then extract functions (Ch. 3), then extract classes (Ch. 10)
4. **Architecture**: Apply Ch. 11 (Systems) + Ch. 8 (Boundaries) + Ch. 12 (Emergence)

> ⚠️ **One honest caveat**: Clean Code is Java-centric and some advice (e.g., "always use exceptions") requires adaptation for Swift, Go, or functional paradigms. Apply the *intent* of each principle, not the literal Java idiom.
