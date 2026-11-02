# Troupe

Portable, durable agent and workflow definitions for Elixir, executed with
[Reactor](https://hexdocs.pm/reactor).

- **One definition.** People write workflows with a Spark DSL. Agents and
  tools write the same workflows as JSON. Both produce the same validated,
  versioned `Troupe.Definition`. That definition also round-trips through
  Erlang term binaries.
- **Plain data only.** Exported definitions never contain module names,
  closures, PIDs, references, ETS handles or secrets.
- **Explicit trust.** Definitions refer to capabilities by name and version
  (`text.upcase ~> 1.0`). The host decides which modules are installed
  (`Troupe.Registry`) and which may run (`Troupe.Grant`). Importing or editing
  a workflow grants nothing.
- **Bounded active state.** The immutable definition, active execution state,
  stored payloads and history are kept apart. A loop iteration sees only the
  state the definition carries forward. It never sees earlier frames.
- **Durable.** With `Troupe.Store.File`, a run that dies part-way resumes in
  a fresh OS process at the first unfinished action.
- **Runs in the browser.** A [Popcorn](https://hexdocs.pm/popcorn) playground
  loads, edits, validates, runs and exports the same definitions with the
  same code.

## Quick start

```sh
mix deps.get
mix test
```

### A Spark-authored workflow

```elixir
defmodule MyApp.Greeting do
  use Troupe.Workflow

  workflow do
    id "greeting"
    version "1.0.0"
    inputs name: :string, punctuation: [type: :string, required: false, default: "!"]
    output result(:greet)

    action :shout, "text.upcase", "~> 1.0" do
      arg :text, input(:name)
    end

    action :greet, "text.template", "~> 1.0" do
      arg :template, value("Hello, {{name}}{{punctuation}}")
      arg :vars, object(name: result(:shout), punctuation: input(:punctuation))
    end
  end
end
```

This module ships as `Troupe.Examples.Greeting`:

```sh
mix run -e '
grant = Troupe.Grant.new!(["text.*"])
{:ok, run} = Troupe.run(Troupe.Examples.Greeting.definition(), %{"name" => "Ada"}, grant: grant)
IO.puts(run.output)'
# Hello, ADA!
```

Without a grant, nothing runs:

```sh
mix run -e 'IO.inspect(Troupe.run(Troupe.Examples.Greeting.definition(), %{"name" => "Ada"}))'
# {:error, [%Troupe.Error{kind: :not_granted, message: "capability \"text.template\" (used by \"greet\") is not granted; ..."}, ...]}
```

### The same workflow as JSON

`examples/greeting.json` is the canonical export of the module above:

```sh
mix troupe.export Troupe.Examples.Greeting           # print canonical JSON
mix troupe.validate examples/greeting.json           # shape, references, installed capabilities
mix troupe.run examples/greeting.json --inputs '{"name": "Ada"}' --grant 'text.*'
```

From Elixir:

```elixir
{:ok, definition} = Troupe.JSON.decode(File.read!("examples/greeting.json"))
definition == Troupe.Examples.Greeting.definition()      #=> true
{:ok, ^definition} = definition |> Troupe.Binary.encode() |> Troupe.Binary.decode()
```

### More examples

| File | Authored with | Shows |
| --- | --- | --- |
| `lib/troupe/examples/greeting.ex`, `examples/greeting.json` | Spark + JSON twin | dependent actions |
| `lib/troupe/examples/calculator_agent.ex`, `examples/calculator_agent.json` | Spark + JSON twin | a ReAct-style loop: think → branch to a tool → observe into a bounded scratchpad |
| `examples/sqrt_newton.json` | JSON | a loop that runs until it converges |
| `examples/ticket_triage.json` | JSON | branching |

```sh
mix troupe.run examples/sqrt_newton.json --inputs '{"n": 2}' --grant 'math.*'
mix troupe.run examples/ticket_triage.json --inputs '{"text": "URGENT: checkout down"}' --grant 'text.*'
mix troupe.run examples/calculator_agent.json --grant 'agent.*,list.*,math.*' \
  --inputs '{"start": 3, "plan": [{"tool": "add", "operand": 4}, {"tool": "multiply", "operand": 5}]}'
```

`agent.scripted_policy` is a deterministic stand-in for an LLM policy. It lets
the agent loop run without network calls. To plug in a real model, write it as
another capability.

## Concepts

### The definition

`Troupe.Definition` is the single representation. `Troupe.Definition.from_map/1`
decodes and validates a portable map. JSON, term binaries and the Spark DSL
all go through it, and it reports every problem with a JSON pointer. See
[docs/format.md](docs/format.md) for the schema (version 1).

Node kinds:

- **action** — invokes one capability with expression arguments; `max_attempts`
  controls retries.
- **branch** — evaluates `on` and runs the first case whose `match` equals it,
  or the `default` case. Its result is that case's `output`.
- **loop** — runs its body repeatedly. Only `state` (and `index`) pass from one
  iteration to the next. It stops on `until` or `max_iterations` and returns
  the final state.

### Capabilities, registry and grant

```elixir
defmodule MyApp.Capabilities.Charge do
  use Troupe.Capability,
    name: "payments.charge",
    version: "1.0.0",
    inputs: [amount: :integer, token: :string],
    output: :string

  @impl true
  def run(%{"amount" => amount, "token" => token}, context) do
    # context.idempotency_key is identical for every attempt of this activation
    MyApp.Payments.charge(amount, token, idempotency_key: context.idempotency_key)
  end

  @impl true
  def reconcile(%{"amount" => amount}, context) do
    # Called only when an earlier attempt started but never checkpointed
    if MyApp.Payments.charged?(context.idempotency_key), do: {:ok, "charged #{amount}"}, else: :unknown
  end
end

registry = Troupe.Registry.new!(Troupe.Capabilities.modules() ++ [MyApp.Capabilities.Charge])
grant = Troupe.Grant.new!(["payments.charge"])

Troupe.run(definition, inputs,
  registry: registry,
  grant: grant,
  secrets: %{"PAYMENT_TOKEN" => System.fetch_env!("PAYMENT_TOKEN")}
)
```

`Troupe.run/3` resolves every capability and checks the grant, the inputs and
the referenced secrets before anything runs. Secrets are referenced in a
definition as `{"secret": "PAYMENT_TOKEN"}`. They may only appear as action
arguments, and they are never stored. Literal keys that look like secrets
(`api_key`, `password`, …) are rejected when a definition is imported.

### Identity

| Identity | Example | Meaning |
| --- | --- | --- |
| node | `decide` | stable id in the definition |
| activation | `agent[2]/decide` | one execution of a node within a run; every loop iteration is a new activation |
| attempt | `agent[2]/decide@1` | one try of an activation; retries and restarts add attempts |
| idempotency key | `<run_id>/agent[2]/decide` | the same for every attempt of an activation |

Completed work is recorded per activation, so loops and retries never merge
real work. Running a definition twice creates two runs.

### State, payloads and history are separate

- **Definition** — immutable plain data, stored once per run.
- **Active state** — what is in flight: the Reactor run for the current scope
  and, for loops, a `Troupe.Runtime.Frame` (`activation`, `index`, `state_key`).
  Each loop iteration runs as its own Reactor run, so finished iterations do
  not pile up in Reactor's results.
- **Payloads** — action results and loop states, stored by attempt/state key.
- **History** — an append-only event log that references payloads by key.

Measured with `mix run examples/memory_evidence.exs` (≈1 KiB observation per
iteration, scratchpad window `keep`):

| iterations | keep | frame words | state bytes | run heap words | run binary bytes | history events | payloads | store bytes | nested-frame bytes |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 10 | 3 | 28 | 3225 | 4185 | 10988 | 33 | 22 | 109248 | 10666 |
| 100 | 3 | 28 | 3225 | 4185 | 10989 | 303 | 202 | 426448 | 106606 |
| 1000 | 3 | 28 | 3234 | 4185 | 10990 | 3003 | 2002 | 4720504 | 1068238 |
| 1000 | 1000 | 28 | 1067190 | 28690 | 10990 | 3003 | 2002 | 102146368 | 1068238 |

The frame, the carried state, and the run process's live heap and binaries
stay flat. History and payloads grow in the store, which is a separate
process. The last column is what one frame would weigh if each frame embedded
its predecessor. The `keep: 1000` row shows the only state that grows is
state the definition explicitly chooses to carry. `test/troupe/memory_test.exs`
asserts this bound.

### Durability and side effects

```elixir
store = Troupe.Store.File.new("tmp/runs")
{:error, [error]} = Troupe.run(definition, inputs, store: store, run_id: "order-42", grant: grant)
# ...fix the cause, restart the VM...
{:ok, run} = Troupe.resume(store, "order-42", grant: grant)
```

- A result is checkpointed (payload, then completion record) before the next
  dependent action starts. Records are written to a temporary file, fsynced
  and renamed. On resume, completed activations are replayed from their
  stored payloads and are not executed again.
- **Delivery is at-least-once, not exactly-once.** If the process dies after
  an action's side effect but before its checkpoint, that action runs again
  on resume, with the same idempotency key. Make external effects idempotent
  using `context.idempotency_key`, or implement `reconcile/2` to report
  already-completed work.
- Interrupted attempts do not count toward `max_attempts`. Resuming a failed
  run gives the failed activation a fresh attempt budget, and its attempt
  numbers keep counting up.
- Resuming requires the grant again, because stored runs carry no permission.
  Pass `definition:` to assert the run uses the definition you expect.
- `test/troupe/restart_test.exs` runs everything in fresh `elixir` OS
  processes. A ten-action run is halted after five recorded completions, and
  the new process starts at action six. Two more tests cover duplicate
  re-execution without `reconcile/2` and reconciliation with it.

Mix tasks support the same flow:

```sh
mix troupe.run examples/sqrt_newton.json --inputs '{"n": 2}' --grant 'math.*' --store tmp/runs --run-id sqrt-1
mix troupe.resume --store tmp/runs --run-id sqrt-1 --grant 'math.*'   # completed runs return their output
```

## Playground (Popcorn)

`playground/` is a browser UI running Troupe itself on the BEAM compiled to
WebAssembly. With it you can:

- load the examples
- edit the JSON and validate it, with located errors
- tick the capabilities to grant
- run on real Reactor, then inspect steps, loop states, store statistics and
  history
- interrupt a run after N completions and resume it
- export JSON, a term binary, or snippet code for an app

```sh
./playground/build.sh          # cooks into playground/out (needs OTP 29, see below)
node playground/serve.mjs 4010 # serves with the COOP/COEP headers Popcorn needs
# open http://127.0.0.1:4010/            (interactive)
# open http://127.0.0.1:4010/?selftest   (scripted check; body[data-selftest] becomes "pass")
```

The Popcorn 1.0 VM is OTP 29, and `mix popcorn.cook` requires the same OTP
major on the host. `build.sh` therefore runs only the cook step through
`mise exec erlang@29 elixir@1.20.2-otp-29`. Set `TROUPE_OTP29=""` if you are
already on OTP 29. It uses a separate `wasm` Mix environment so the project's
own builds stay on its normal toolchain. `config :popcorn, strip: false` is
required, because Reactor checks step behaviours through BEAM attributes.

### Hosting on GitHub Pages

`.github/workflows/playground.yml` builds and publishes the playground on
every push to `master`/`main` (or manually via *Run workflow*). Enable it once
under **Settings → Pages → Build and deployment → Source: GitHub Actions**.

The build job:

1. installs OTP 29 and Elixir 1.20.2
2. runs `playground/build.sh`, then `playground/site.sh _site`
3. serves `_site` with a plain static server (no special headers, like Pages)
   and runs `playground/selftest.mjs`, which drives `?selftest` in headless
   Chrome
4. uploads the artifact only if every check passes; the `deploy` job then
   publishes it

GitHub Pages cannot set the COOP/COEP headers Popcorn needs (without them,
`SharedArrayBuffer` is missing and the VM times out). `coi-serviceworker.js`
supplies those headers client-side: the first visit installs it and reloads
once. To reproduce the CI check locally:

```sh
./playground/build.sh && ./playground/site.sh tmp/_site
python3 -m http.server 4032 --directory tmp/_site &
node playground/selftest.mjs http://127.0.0.1:4032/   # CHROME_PATH=... if Chrome is not on PATH
```

## Development

```sh
mix ci   # compile --warnings-as-errors, format check, tests, credo --strict,
         # dialyzer, ex_dna, reach.check --arch --smells
```

## Limits and non-goals

- Exactly-once execution is not provided (see above).
- Loop `state` is bounded only by what the definition carries. Use
  `list.append_window` or similar to keep it bounded.
- `Troupe.Store.File` fsyncs file contents but not directory entries. After a
  power loss (not a process crash), a just-renamed record may be missing on
  some filesystems. The run is then replayed from the previous checkpoint.
- Rebar-built dependencies (yamerl, telemetry, brotli) keep their own build
  state under `deps/*/_build/prod`. After running `build.sh`, run
  `mix deps.compile` if you build `MIX_ENV=prod` on OTP 28.
