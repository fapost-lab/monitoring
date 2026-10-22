# UI states when UI behavior changes

Reuse existing components. In design.md, map each affected screen/component to applicable
states: default, loading, empty, error, permission and success. A compact table is enough:

| Screen/component | State | Expected behavior / criterion | Reused component | UI evidence |
|---|---|---|---|---|
| Results | empty | Explain no matches; AC-02 | Existing empty state | Pending |

Derive applicability from real flows. Explain ambiguous omissions; do not create irrelevant
states. A larger separate manifest must earn its cost. Verify UI criteria through the UI,
including important failure states; a happy-path screenshot cannot prove error behavior.
Backend-only work needs no UI artifact and no permission to omit one.
