# Working with Legacy Code

> Skill based on "Working Effectively with Legacy Code" by Michael Feathers

## Core Definition

**Legacy code is code without tests.** The central problem is not age or messiness — it is the absence of a feedback mechanism (tests) that lets you change code safely.

---

## The Legacy Code Change Algorithm

Every change to legacy code follows this sequence:

1. **Identify change points** — find where the code needs to change
2. **Find test points** — locate places where you can observe behavior (interception points)
3. **Break dependencies** — make the code testable without large-scale rewrites
4. **Write characterization tests** — capture current behavior as a safety net
5. **Make changes and refactor** — only now add the feature / fix the bug

New code writing comes **last**, not first. Never skip the refactoring step.

---

## The Legacy Code Dilemma

You need tests to change code safely, but you need to change code to add tests. The resolution: perform **minimal, conservative refactorings** — just enough to get the code into a test harness. Accept temporary ugliness; treat it as a scar to heal once tests are in place.

---

## The Seam Model

A **seam** is a place where you can alter program behavior without editing in that place. Every seam has an **enabling point** — the place where you decide which behavior to use.

### Seam Types

| Type | Mechanism | Enabling Point |
|------|-----------|---------------|
| **Object Seam** | Subclass and override, dependency injection | Constructor / method parameter |
| **Link Seam** | Swap classpath, library, or module | Build configuration |
| **Preprocessing Seam** | `#define`, `#include`, conditional compilation | Preprocessor directives |

Object seams are the most useful in OOP languages. Use them by default.

---

## Key Techniques

### Characterization Tests

Capture **actual** behavior (not intended behavior) as a snapshot. Steps:
1. Call the code and let it fail or produce output
2. Assert against whatever it actually does
3. The test now documents real behavior and guards against unintended changes

Also called: Approval Testing, Snapshot Testing, Golden Master.

### Sprout Method / Sprout Class

When you need to add new behavior:
1. Write the new logic in a **fresh method or class**, developed with TDD
2. Call it from the legacy code at the insertion point
3. Legacy code stays untouched; new code is fully tested

Use **Sprout Class** when the existing class is too tangled to even instantiate in a test.

### Wrap Method / Wrap Class

When you need to add behavior before or after existing logic:
1. Rename the original method (e.g., `process` -> `processOriginal`)
2. Create a new method with the original name
3. Call the renamed method plus the new logic from the new method

**Wrap Class** applies the Decorator pattern — wrap the existing class without modifying it.

### Scratch Refactoring

Explore opaque code by freely refactoring — extract methods, rename variables, simplify logic. **Critical rule: revert everything when done.** The goal is understanding, not production code.

### Effect Sketching

Draw a diagram of objects, their dependencies, and execution paths on paper. Trace side effects outward from your change point to find the best interception points for tests.

### Break Out Method Object

Convert a monster method into its own class. The method body becomes the class's main method; local variables become fields. This opens up extraction and testing opportunities.

---

## 24 Dependency-Breaking Techniques

These are the tactical moves for getting legacy code into a test harness:

| # | Technique | When to Use |
|---|-----------|------------|
| 1 | **Adapt Parameter** | Parameter type is hard to fake and Extract Interface isn't viable |
| 2 | **Break Out Method Object** | Long method needs isolation — move it to its own class |
| 3 | **Definition Completion** | Declare type in one place, define elsewhere to break compile dependency |
| 4 | **Encapsulate Global References** | Global variables cause hidden coupling — wrap in a class |
| 5 | **Expose Static Method** | Method doesn't use instance data — make it static for direct testing |
| 6 | **Extract and Override Call** | Extract a method call so a test subclass can override it |
| 7 | **Extract and Override Factory Method** | Object creation in constructor — extract to overridable factory |
| 8 | **Extract and Override Getter** | Lazy-initialized dependency — extract getter, override in test |
| 9 | **Extract Implementer** | Turn a concrete class into an interface + implementation |
| 10 | **Extract Interface** | Create an interface for the methods you need in your context |
| 11 | **Introduce Instance Delegator** | Static method needs substitution — create instance method that delegates |
| 12 | **Introduce Static Setter** | Singleton needs test replacement — add static setter |
| 13 | **Link Substitution** | Swap implementations via classpath/linker configuration |
| 14 | **Parameterize Constructor** | Constructor creates its own dependencies — pass them in instead |
| 15 | **Parameterize Method** | Method creates objects internally — pass them as parameters |
| 16 | **Primitivize Parameter** | Use primitive/intermediate representations to reduce class dependencies |
| 17 | **Pull Up Feature** | Move method to abstract superclass for testing |
| 18 | **Push Down Dependency** | Make class abstract, push problematic dependencies into subclass |
| 19 | **Replace Function with Function Pointer** | Substitute behavior via function pointer (C/C++) |
| 20 | **Replace Global Reference with Getter** | Replace direct global access with overridable getter |
| 21 | **Subclass and Override Method** | Override unwanted behavior in a test subclass |
| 22 | **Supersede Instance Variable** | Add setter to replace constructor-created objects (use cautiously) |
| 23 | **Text Redefinition** | Redefine methods in test files (dynamic languages like Ruby) |
| 24 | **Mock Objects** | Create fake implementations of dependencies |

### Highest-Value Techniques (Feathers' recommended starting set)

- **Parameterize Constructor** (#14) — easiest way to break hidden constructor dependencies
- **Extract Interface** (#10) — most versatile for creating test doubles
- **Subclass and Override Method** (#21) — quick wins in OOP languages
- **Extract and Override Call** (#6) — minimal change to isolate a single call
- **Sprout Method/Class** — safest way to add new behavior

---

## Sensing vs. Separation

Two reasons to break dependencies:

- **Sensing**: gain access to values the code computes internally (so you can assert on them)
- **Separation**: isolate code so it can run in a test harness without dragging in the world

Ask: "Do I need to *see* what happened, or do I need to *detach* this code from its environment?" The answer determines which technique to use.

---

## Unit Test Criteria

A test is NOT a unit test if it:
- Talks to a database
- Communicates across a network
- Touches the file system
- Requires environment/config changes to run
- Runs slower than ~100ms

These are integration tests. Keep them separate. Unit tests must be fast enough to run hundreds per second.

---

## Anti-Patterns to Avoid

- **Edit and Pray**: changing code and hoping nothing breaks. Always Cover and Modify instead.
- **Direct library coupling**: every library call should go through your own abstraction layer
- **Singletons in your own code**: they resist testing. Avoid creating new ones.
- **Skipping the Refactor step**: Red-Green-Refactor, not Red-Green-Repeat
- **Overriding concrete methods**: prefer overriding abstract/virtual methods

---

## Architecture Principles for Legacy Work

- **Wrap third-party libraries** behind your own interfaces — you control the seam
- **Delete unused code** — it costs attention and hides real structure
- **Tell, Don't Ask** (Command-Query Separation) — "tell" code is easier to mock than "ask" code
- **Look for hidden classes** — clusters of private variables used by method subsets suggest extraction candidates
- **Name things well** — "Rename Class" is a surprisingly powerful refactoring that reveals hidden structure
- **Everyone owns the architecture** — not just one person

---

## Quick-Reference Decision Tree

```
Need to change legacy code?
|
+-> Can you write a test for it right now?
|   +-> YES: Write characterization test, then make changes
|   +-> NO: Why not?
|       +-> Can't instantiate the class -> Parameterize Constructor / Extract Interface
|       +-> Can't call the method in isolation -> Extract and Override Call / Subclass and Override
|       +-> Can't observe the effect -> Break dependency for Sensing (add fake/mock)
|       +-> Method is too long -> Break Out Method Object / Sprout Method
|       +-> Adding new behavior -> Sprout Method/Class or Wrap Method/Class
|       +-> Need to understand the code first -> Scratch Refactoring / Effect Sketching
```

---

## Four Reasons Software Changes

| Reason | Structure | Functionality | Existing Behavior |
|--------|-----------|--------------|-------------------|
| Adding a feature | Changes | Changes | Preserved |
| Fixing a bug | Changes | Changes | Preserved |
| Refactoring | Changes | Unchanged | Preserved |
| Optimizing | Unchanged | Unchanged | Preserved |

Understanding which type of change you're making clarifies what tests need to verify.
