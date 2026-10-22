# Component boundaries

A boundary is a place where one component plugs into another: an interface with several
implementations, an extension point, a handler or plugin role, a module's public entry that
other modules call. Its signature shows the shape. What an implementation may do through it —
and must never do — is not in the code, and an agent writing the next implementation cannot
read it there. Written down, it reaches that agent and review holds the diff against it.

## What to write

Only what the code cannot say, for one role:

```
NodeHandler (app/Flow/Contracts/NodeHandlerInterface.php)

MAY:      read flow.*; return effects; select sourceHandle
MUST:     return a NodeExecutionResult for every node it accepts
MUST NOT: persist FlowSession; commit a transaction; modify system.*;
          resolve another handler
Why:      the engine owns persistence and the transaction; a handler that commits
          breaks rollback of the whole flow step.
```

In the convention template this block is the Practice section, one example of an
implementation that honours it is the Example, and `Why` is the Rationale. No signatures or
parameters — they are in the code and a copy drifts. Each line is a promise
someone designed, not a description of what the current implementations happen to do.

## Where it goes

- **One boundary, one `convention`**, reached by the files that must honour it:

  ```
  .ai/scripts/jig knowledge new convention <role> --paths <interface file>,<implementations glob>
  ```

  The paths name the interface **and** its implementations (and callers, when the rules bind
  them): the agent who needs the MUST NOT is the one writing an implementation. A new
  implementation makes the document stale; consolidation then rereads the rules and stamps it.
- A domain made of one boundary may keep it in its `rule` document instead — Jig's own
  profiles are bound this way in `domains/verify/RULES.md`.
- The direction dependencies may point between layers is `ARCHITECTURE.md`, not a boundary
  document.

## Who writes it

- **At design.** A task that introduces or changes a boundary states its MAY / MUST / MUST NOT
  where its plan is read: `design.md` for T3 and T4, approved at the gate; `plan.md` for T2,
  shown to the human verbatim and confirmed before implementing — a promise to other
  components is a human's decision even when the route has no gate. Consolidation moves only
  approved lines into the convention.
- **From existing code** (`jig-map`), each line is a question — "promised, or incidental?" —
  and only what the human confirms stays.

Not every interface is a boundary. Write one when implementations are or will be written by
someone else than the interface's author, or when breaking a rule would fail far from the
code that broke it. A single implementation with nothing forbidden needs none.

## How it is used

- `jig-review`: a MUST NOT in a resolved boundary document is a rule. A diff that breaks it is
  a blocking finding; quote the line.
- `jig-architecture-review`, **Boundaries**: checked against `ARCHITECTURE.md` and the boundary
  documents context resolved.
- A change that alters a promise updates the document in the same task.
