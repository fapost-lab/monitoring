# Glossary

Canonical ubiquitous language for this project. One entry per term. Use the canonical
term in source code, database schema, APIs, documentation and commit messages.

Entry format:

```
## <Canonical Term>

One-sentence definition.

Informal synonyms: <words people say instead>.
Use in: source code, schema, API, documentation.
```

<!-- Add terms below. Delete this comment when the first real term is added. -->

## Operator surface

One operator screen (Horizon, Pulse, Telescope, Logs, Health), named by Foundation's `OperatorSurface`.

Informal synonyms: operator screen, monitoring screen.
Use in: source code (`OperatorSurface`), documentation.

## Surface middleware

The middleware class that asks the operator access contract about one surface and answers 404 on no.

Informal synonyms: gate middleware.
Use in: source code (`AllowPulse`, `AllowLogs`).
