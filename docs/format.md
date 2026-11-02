# Troupe workflow format, schema version 1

This is the portable form read by `Troupe.Definition.from_map/1`,
`Troupe.JSON.decode/1` and `Troupe.Binary.decode/1`. The same form is written
by `Troupe.Definition.to_map/1`, `Troupe.JSON.encode/1` and
`Troupe.Binary.encode/1`. Spark DSL modules compile to it.

All of it is plain data: objects with string keys, strings, numbers,
booleans, `null` and lists. Unknown fields are errors. Every error carries a
JSON pointer, for example `/nodes/1/args/text`.

## Workflow

```json
{
  "schema_version": 1,
  "id": "greeting",
  "version": "1.0.0",
  "description": "optional",
  "inputs": [ ... ],
  "nodes": [ ... ],
  "output": { ...expression... }
}
```

| Field | Rule |
| --- | --- |
| `schema_version` | must be `1`; other values fail with `unsupported_schema_version` |
| `id` | `^[a-z][a-z0-9_.-]{0,127}$` |
| `version` | semantic version of this workflow, e.g. `"1.2.0"` |
| `inputs` | optional list of input declarations |
| `nodes` | non-empty list of nodes; at most 1000 nodes in total, nested at most 16 levels deep |
| `output` | expression evaluated at the top level |

## Inputs

```json
{"name": "n", "type": "number", "required": false, "default": 2, "description": "optional"}
```

- `type` is one of `string`, `integer`, `number`, `boolean`, `map`, `list` or
  `any`.
- `required` defaults to `true`, or to `false` when a `default` is given. A
  required input cannot have a default.
- At run time, inputs are checked for unknown names, missing required values
  and wrong types.

## Nodes

Node ids match `^[a-z][a-z0-9_]{0,63}$` and are unique across the whole
definition, including nested nodes.

### action

```json
{
  "id": "shout",
  "kind": "action",
  "capability": {"name": "text.upcase", "version": "~> 1.0"},
  "args": {"text": {"input": "name"}},
  "max_attempts": 1
}
```

- `capability.name` is a dotted name; `capability.version` is an Elixir
  `Version` requirement. Both are resolved against the host's
  `Troupe.Registry`. A definition never names a module.
- `args` maps capability input names to expressions. `Troupe.check/2` checks
  them against the capability's declared inputs.
- `max_attempts` (1–20) limits attempts that fail with `{:retry, reason}`.

### branch

```json
{
  "id": "route",
  "kind": "branch",
  "on": {"result": "urgent"},
  "cases": [
    {"match": true, "nodes": [ ... ], "output": {"result": "escalate"}}
  ],
  "default": {"nodes": [ ... ], "output": {"result": "acknowledge"}}
}
```

Cases are tried in order, comparing each `match` (a literal) with the value
of `on`. Only the chosen case's nodes run, and the branch's result is that
case's `output`. Without a `default`, a value that matches no case is a
runtime error. The choice is checkpointed; if a resume computes a different
choice, the run fails with `definition_mismatch`.

### loop

```json
{
  "id": "agent",
  "kind": "loop",
  "max_iterations": 20,
  "state": {"object": {"value": {"input": "start"}}},
  "nodes": [ ... ],
  "next_state": {"object": {"value": {"result": "act"}}},
  "until": {"result": "decide", "path": ["done"]}
}
```

- `state` is evaluated once, in the loop's enclosing scope.
- Each iteration runs `nodes` as a fresh Reactor run. Inside the body,
  `{"loop": "state", "of": "agent"}` and `{"loop": "index", "of": "agent"}`
  give the current state and the zero-based index.
- `next_state` and `until` are evaluated after the body. The loop stops when
  `until` is truthy or after `max_iterations` (1–100000), and returns the final
  state.

## Expressions

Each expression is an object with exactly one tag:

| Form | Meaning |
| --- | --- |
| `{"input": "name", "path": [...]}` | a declared input |
| `{"result": "node_id", "path": [...]}` | the result of a node in scope |
| `{"loop": "state" or "index", "of": "loop_id", "path": [...]}` | state or index of an enclosing loop |
| `{"secret": "API_TOKEN"}` | a host-supplied secret (`:secrets` run option); action arguments only |
| `{"value": <json>}` | a literal |
| `{"object": {"key": <expression>}}` | an object built from expressions |
| `{"list": [<expression>]}` | a list built from expressions |

`path` is optional. Its elements are object keys (strings) or list indexes
(non-negative integers). A missing segment is a runtime `invalid_reference`
error that names the reference and the segment.

### Scope

A node's result may be referenced from its own list (the root, a case body or
a loop body) and from any list nested inside it. These references are not
allowed:

- a node referencing itself
- a reference to an enclosing branch or loop from inside it (use loop state,
  or the case output)
- a reference to a node inside a case or loop body from outside that body

Dependencies between siblings, including those from nested nodes, must not
form cycles.

### Literals and secrets

Literals must be plain data. Object keys that look like credentials
(`password`, `secret`, `token`, `api_key`, `private_key`, `credential`,
`authorization`, …) with non-empty values are rejected as `possible_secret`.
Pass such values with `{"secret": "NAME"}` at run time instead.

## Identity and storage

| Identity | Format |
| --- | --- |
| activation | node id, prefixed by enclosing loop iterations: `outer[1]/inner[0]/work` |
| attempt | `<activation>@<n>`, numbered from 1 across restarts |
| idempotency key | `<run_id>/<activation>` |

A run's store keeps:

- the run record: the portable definition, the validated inputs and the status
- the history events
- payloads (results keyed by attempt id, loop states keyed `<loop activation>[k]#state`)
- checkpoints (`done:`, `attempts:`, `loop:` and `branch:` records, keyed by activation)

History event types:

- run: `run_started`, `run_resumed`, `run_completed`, `run_failed`
- attempt: `attempt_started`, `attempt_failed`, `attempt_reconciled`
- activation: `activation_completed`, `activation_replayed`
- branch: `branch_selected`, `branch_replayed`
- loop: `loop_iteration_completed`, `loop_completed`, `loop_replayed`
