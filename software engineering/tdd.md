---
name: tdd-kent-beck
description: Apply Test-Driven Development (TDD) principles from Kent Beck's "Test Driven Development: By Example" when writing, reviewing, or coaching on tests. Use this skill whenever the user asks to write tests, practice TDD, implement a feature test-first, refactor with test coverage, is stuck on how to start testing something, asks about mocking/stubbing/faking, wants to know how to structure a test suite, or mentions red-green-refactor, XCTest, Quick/Nimble, unit tests, or test strategy. Also trigger when the user shares untested code and asks "how do I test this?" or "where do I start?" — always consult this skill before writing tests or giving testing advice.
---

# TDD: By Example — Kent Beck

Use this skill to **write tests first, drive design from tests, and keep the Red→Green→Refactor cycle moving.** The goal, in Ron Jeffries' words: **"Clean code that works — now."**

> TDD is meant to eliminate fear in application development. Fear makes programmers tentative, uncommunicative, and unable to absorb criticism. Tests give you the confidence to go fast.

---

## The Canonical TDD Workflow (Kent Beck's "Canon TDD")

This is the exact workflow — not a loose interpretation of it.

```
1. Write a list of all test scenarios for the behavior you want to add
2. Pick exactly ONE test from the list — the smallest, most instructive one
3. Write a concrete, runnable, failing test for it
4. Change the code minimally to make the test (and all previous tests) pass
5. Refactor to remove duplication — then stop
6. Mark the test off the list, pick the next one, repeat
```

### The Three Laws (Uncle Bob's codification of Beck's rules)
1. **You may not write production code** unless it is to make a failing unit test pass
2. **You may not write more of a unit test** than is sufficient to fail — compilation failures count as failures
3. **You may not write more production code** than is sufficient to pass the one failing test

### Red → Green → Refactor
| Phase | Goal | Mindset |
|-------|------|---------|
| 🔴 **Red** | Write a failing test | Think about *what* behavior you want, not *how* |
| 🟢 **Green** | Make it pass by any means | Speed over design — commit necessary sins |
| 🔵 **Refactor** | Remove all duplication, clean the mess | Design quality, then stop |

**Critical separation**: Never refactor while making a test pass. Wear one hat at a time. Your brain cannot simultaneously pursue correct behavior AND correct structure.

---

## Common Mistakes (Beck's Explicit Warnings)

- **Copying actual values into expected values** — defeats double-checking; the test will always pass
- **Mixing refactoring into the green phase** — make it run, *then* make it right
- **Refactoring further than necessary** — stop when duplication is removed
- **Writing too large a first test** — if getting to green takes more than a few minutes, break the test apart
- **Discovering a needed test mid-cycle** — add it to the Test List; don't break the current cycle

---

## Part III Patterns — Reference

Beck's book dedicates an entire section to patterns. These are the ones to apply directly.

### TDD Patterns — When & What to Test

**Test List**
Before writing any test, list all the scenarios you'll need to cover. This is analysis — not test writing. A living list prevents you from losing track of what's left and stops you from trying to do everything at once.

**Test First**
Write the test before the code. This forces you to think about the interface (how it will be called) before the implementation (how it will work). This is where design happens.

**Assert First**
Write the assertion first. Work backwards: what should the result be? → what object needs to exist? → what does setUp need? Starting at the end clarifies what the test is actually verifying.

**Test Data**
Use data that makes the test readable and meaningful. `1` and `2` are better than `3492` and `7841`. Choose values that communicate the intent of the test, not just values that happen to work.

**Evident Data**
Make the relationship between input and expected output visible in the test itself. Don't calculate the expected value in the test — state it literally. If `rate = 2:1` and `amount = 100`, then expected is `50`, written as `50`, not `amount / rate`.

---

### Red Bar Patterns — How to Choose the Next Test

**One Step Test**
Pick a test that will teach you something new AND that you're confident you can implement. Each test is one step closer to the goal. If you're not confident you can implement it, pick a simpler one.

**Starter Test**
Begin with a variant that doesn't do much — trivially simple inputs and outputs. A realistic first test leaves you without feedback for too long. Get the loop spinning first. *"Start by testing a variant of an operation that doesn't do anything."*

**Explanation Test**
To spread TDD to teammates without force-converting them, explain requirements in test form: "If I give you these two inputs, you should get this output — agreed?" Tests as conversation.

**Learning Test**
When integrating a new framework or API you don't know yet, write tests against it to learn how it behaves. Discover its contracts before betting your feature code on assumptions.

**Another Test**
If a new idea occurs to you mid-cycle that isn't on the Test List, add it there and return to the current test. Don't chase tangents.

**Regression Test**
When a bug is reported, write the smallest possible test that demonstrates the failure first — before fixing it. The test *is* the bug report. Now fix it and the test confirms the fix.

**Broken Test**
When leaving a solo coding session, deliberately stop mid-cycle on a broken (red) test. When you return, you have an immediately actionable state — no warm-up required.

**Clean Check-in**
When returning to a team codebase, run all tests before starting. If anything fails, fix it before adding your work.

---

### Green Bar Patterns — How to Make a Test Pass

These are the three strategies, used in order of confidence:

**1. Fake It (Till You Make It)**
Return a hardcoded constant that makes the test pass. Then generalize step by step via refactoring. *Used when you're uncertain or nervous.* The discipline: you must refactor afterward — hardcoding is only permitted during the green phase.

**2. Triangulation**
Write a *second* test case that forces you to generalize. If the first test passes with `return 4`, the second test with a different expected result forces the real implementation. Only generalize when you have two or more examples. *Used when you're unsure how to generalize.*

**3. Obvious Implementation**
When the correct implementation is clear, just type it in and run the tests. If you get an unexpected red bar, step back to Fake It. *Used when you're confident.*

> In practice, Beck shifts fluidly between Obvious Implementation (when smooth) and Fake It (when uncertain). The test suite is the net that lets you move fast without fear.

---

### Testing Patterns — How to Write Better Tests

**Child Test**
If a test is too large to get green quickly, break it into smaller "child" tests. Get each child green, then tackle the original. Keep the cycle moving — long red bars kill momentum.

**Mock Object**
Replace a slow, complex, or external dependency with a lightweight fake that has a predetermined, known behavior. Mocks also serve as documentation — readers immediately see what the object is expected to respond to. Risk: the real object may not behave identically to the mock. Mitigate with integration tests at the boundary.

**Self Shunt**
When testing that object A communicates with object B correctly, make your test class *implement* the interface of B. The test observes the messages directly without a separate mock infrastructure.

**Log String**
When testing the *order* of operations, have the test object append to a string log as methods are called, then assert on the final string. Simple, readable, and avoids complex mock verification.

**Crash Test Dummy**
To test error handling, create an object that throws an exception on demand rather than doing real work. Makes the test's intent explicit: "I am testing what happens when this fails."

---

## Design Patterns Emerging from TDD

Beck demonstrates that several classical design patterns emerge naturally from following TDD. If you're doing TDD well, you'll find yourself arriving at these without forcing them:

| Pattern | When TDD leads you here |
|---------|------------------------|
| **Value Object** | When equality and immutability matter for test isolation |
| **Factory Method** | When tests need flexible object creation without coupling to concrete types |
| **Null Object** | When special-casing `nil` in tests becomes repetitive |
| **Template Method** | When two test paths differ only in one step |
| **Pluggable Object** | When conditional behavior needs to be swapped in tests |
| **Composite** | When you need uniform treatment of single and grouped objects |

---

## Swift / iOS Application

The book's examples are in Java and Python. Here's how the patterns apply directly to your stack:

### XCTest — Arrange-Act-Assert

```swift
func test_portfolioValue_withMultiplePositions_returnsSumInBaseCurrency() {
    // Arrange
    let portfolio = Portfolio()
    portfolio.add(Money(amount: 5, currency: "USD"))
    portfolio.add(Money(amount: 10, currency: "USD"))

    // Act
    let result = try portfolio.value(in: "USD", using: stubExchange)

    // Assert
    XCTAssertEqual(result, Money(amount: 15, currency: "USD"))
}
```

### Fake It → Triangulate → Generalize

```swift
// Red: write the assertion first
XCTAssertEqual(Money(5, "USD").times(2), Money(10, "USD"))

// Green (Fake It): hardcode the return
func times(_ multiplier: Int) -> Money { Money(10, "USD") }

// Add second test to force triangulation:
XCTAssertEqual(Money(5, "USD").times(3), Money(15, "USD"))

// Green (Obvious Implementation):
func times(_ multiplier: Int) -> Money { Money(amount * multiplier, currency) }
```

### Starter Test — Don't Start with the Hard Case

```swift
// BAD starter: too complex, too long before feedback
func test_viewModel_loadsTransactions_filtersAndSortsByDate() { ... }

// GOOD starter: trivial input, immediate feedback
func test_viewModel_init_hasEmptyTransactions() {
    let vm = TransactionViewModel()
    XCTAssertTrue(vm.transactions.isEmpty)
}
```

### Mock Object in Swift

```swift
protocol StockExchanging {
    func rate(from: String, to: String) -> Double
}

// In tests: fake with known behavior
struct StubExchange: StockExchanging {
    func rate(from: String, to: String) -> Double { 2.0 }
}

// Production: real implementation
struct LiveExchange: StockExchanging { ... }
```

### Learning Test — Before Integrating a New SDK

```swift
// Before trusting a new SDK, write a test that documents its behavior
func test_sdkBehavior_whenTokenExpired_returnsAuthError() {
    // This test documents what we discovered the SDK does,
    // not what we wish it does
    let result = SDKUnderTest.refreshToken(expiredToken)
    XCTAssertEqual(result.error, .authenticationExpired)
}
```

### Regression Test — Bug First, Fix Second

```swift
// Bug reported: formatter crashes on nil locale
// Step 1: write the failing test BEFORE touching production code
func test_currencyFormatter_withNilLocale_doesNotCrash() {
    let formatter = CurrencyFormatter(locale: nil)
    XCTAssertNoThrow(formatter.format(1234.56))
}
// Step 2: run it — confirm it fails (red)
// Step 3: fix the crash
// Step 4: run again — confirm it passes (green)
```

---

## When TDD Is Hard — Honest Caveats

Beck himself acknowledges TDD isn't a silver bullet. Apply judgment in these situations:

| Situation | Pragmatic approach |
|-----------|-------------------|
| **UI layout / visual tests** | TDD the ViewModel/Presenter fully; snapshot-test the View layer separately |
| **Legacy code with no seams** | Use Michael Feathers' techniques (see the legacy-code skill) to introduce testability first |
| **Third-party SDKs** | Write Learning Tests first; wrap the SDK behind a protocol before TDDing your layer |
| **Concurrency / async code** | Use async/await in XCTest + `XCTestExpectation` for async assertions; test behavior, not timing |
| **Getting stuck / red too long** | Revert to last green state. Pick a simpler starter test. Getting stuck = test order problem, not TDD's fault |
| **100% coverage as a goal** | Beck explicitly warns against this. Test what changes frequently and what needs confidence. Spot-test the stable parts. |

---

## TDD Mindset Checklist

Before each cycle, ask:

- [ ] Do I have a Test List for this feature?
- [ ] Am I picking the *simplest* test that teaches something?
- [ ] Did I write the assertion before the arrange/act?
- [ ] Is the test failing for the *right* reason?
- [ ] Did I get to green using the minimal change?
- [ ] Am I refactoring *after* green, not during?
- [ ] Did I stop refactoring when duplication was removed?
- [ ] Are all previous tests still passing?

> **The goal is not to write tests. The goal is to have confidence in the code — and to get there as fast as possible.**
