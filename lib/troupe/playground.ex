defmodule Troupe.Playground do
  @moduledoc """
  Server behind the browser playground (`playground/`). In the Popcorn VM it
  is registered as `:troupe_playground` and called from JavaScript through
  `Popcorn.Proxy`; on the host it is an ordinary GenServer, which is how its
  tests drive it.

  Every request is a list and every reply a JSON string. Definitions arrive
  as `[format, text]`, where format is `"elixir"` (the `Troupe.Workflow` DSL,
  read by `Troupe.Workflow.Source` without evaluation) or `"json"`. Both decode
  to the same `Troupe.Definition`.

    * `["init"]` — examples (with Elixir source, JSON text, sample inputs and
      grants) and the installed capability catalog
    * `["validate", format, text]` — canonical Elixir and JSON, a node
      outline and required capabilities, or every error with its JSON pointer
      and, when known, its source line (`details.line`)
    * `["run", format, text, inputs_json, granted, interrupt_after]` — runs
      the definition with `Troupe.run/3` on an in-memory store. `granted` is
      the list of capability names the user ticked; nothing is granted by
      loading or editing. `interrupt_after > 0` kills the run process after
      that many completed activations, like a crash
    * `["resume", run_id, granted]` — resumes an interrupted or failed run
    * `["export", format, text, as]` — `as` is `"json"`, `"elixir"` (DSL
      module source), `"source"` (a bare `workflow do ... end` block, used to
      switch the editor's format), `"etf"` (base64 term binary) or `"app"`
      (code to load the export in an app)

  Run replies include the output, per-activation steps with their stored
  results, the event history, loop states and store statistics.
  """

  use GenServer

  alias Troupe.{Binary, Definition, Error, Examples, Grant, JSON, Registry, Store}
  alias Troupe.Definition.{Action, Branch, Loop}
  alias Troupe.Workflow.Source

  @name :troupe_playground

  @doc false
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))

  @impl true
  def init(_opts), do: {:ok, %{store: Store.Memory.start(), pending: %{}}}

  @impl true
  def handle_call(["init"], _from, state) do
    examples =
      Enum.map(Examples.all(), fn example ->
        Map.merge(example, %{
          "json" => Examples.json(example["id"]),
          "elixir" => Examples.source(example["id"])
        })
      end)

    reply(state, %{
      "ok" => true,
      "schema_version" => Definition.schema_version(),
      "examples" => examples,
      "capabilities" => Registry.catalog(Registry.standard())
    })
  end

  def handle_call(["validate", format, text], _from, state) do
    case decode(format, text) do
      {:ok, definition} ->
        reply(state, Map.merge(%{"ok" => true}, describe(definition, source_lines(format, text))))

      {:error, errors} ->
        reply(state, failure(errors))
    end
  end

  def handle_call(["run", format, text, inputs_json, granted, interrupt_after], from, state) do
    with {:ok, definition} <- decode(format, text),
         {:ok, inputs} <- decode_inputs(inputs_json),
         {:ok, grant} <- grant(granted) do
      run_id = "play-" <> Integer.to_string(System.unique_integer([:positive]))
      opts = [run_id: run_id, grant: grant, store: state.store, async?: false]
      start(state, from, run_id, interrupt_after, fn -> Troupe.run(definition, inputs, opts) end)
    else
      {:error, errors} -> reply(state, failure(errors))
    end
  end

  def handle_call(["resume", run_id, granted], from, state) do
    case grant(granted) do
      {:ok, grant} ->
        start(state, from, run_id, 0, fn ->
          Troupe.resume(state.store, run_id, grant: grant, async?: false)
        end)

      {:error, errors} ->
        reply(state, failure(errors))
    end
  end

  def handle_call(["export", format, text, as], _from, state) do
    case decode(format, text) do
      {:ok, definition} ->
        reply(state, %{"ok" => true, "format" => as, "content" => export(definition, as)})

      {:error, errors} ->
        reply(state, failure(errors))
    end
  end

  def handle_call(other, _from, state) do
    reply(
      state,
      failure([
        Error.new(:invalid_inputs, "unknown playground request #{inspect(other, limit: 5)}")
      ])
    )
  end

  @impl true
  def handle_info({:playground_result, pid, result}, state) when is_map_key(state.pending, pid) do
    {{ref, from, run_id}, pending} = Map.pop(state.pending, pid)
    Process.demonitor(ref, [:flush])
    GenServer.reply(from, Jason.encode!(run_reply(state.store, run_id, result)))
    {:noreply, %{state | pending: pending}}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state)
      when is_map_key(state.pending, pid) do
    {{_ref, from, run_id}, pending} = Map.pop(state.pending, pid)
    GenServer.reply(from, Jason.encode!(run_reply(state.store, run_id, {:interrupted, reason})))
    {:noreply, %{state | pending: pending}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Runs in a separate, monitored process so an interrupt kills the run (as a
  # crash would) while the store and this server survive.
  defp start(state, from, run_id, interrupt_after, fun) do
    server = self()

    {pid, ref} =
      spawn_monitor(fn ->
        handler = interrupt(run_id, interrupt_after)
        result = fun.()
        if handler, do: :telemetry.detach(handler)
        send(server, {:playground_result, self(), result})
      end)

    {:noreply, %{state | pending: Map.put(state.pending, pid, {ref, from, run_id})}}
  end

  defp interrupt(_run_id, limit) when not is_integer(limit) or limit <= 0, do: nil

  defp interrupt(run_id, limit) do
    handler = "troupe-playground-" <> run_id
    counter = :counters.new(1, [])

    :telemetry.attach(
      handler,
      [:troupe, :event],
      &__MODULE__.count_completion/4,
      {run_id, limit, counter, handler}
    )

    handler
  end

  @doc false
  def count_completion(
        _event,
        _measurements,
        %{run_id: run_id, event: %{"type" => type}},
        {run_id, limit, counter, handler}
      )
      when type in ["activation_completed", "attempt_reconciled"] do
    :counters.add(counter, 1, 1)

    if :counters.get(counter, 1) >= limit do
      :telemetry.detach(handler)
      Process.exit(self(), :kill)
    end

    :ok
  end

  def count_completion(_event, _measurements, _metadata, _config), do: :ok

  defp run_reply(store, run_id, result) do
    base = %{
      "run_id" => run_id,
      "steps" => steps(store, run_id),
      "events" => Troupe.history(store, run_id),
      "loops" => loops(store, run_id),
      "stats" => Store.stats(store, run_id)
    }

    case result do
      {:ok, run} ->
        Map.merge(base, %{"ok" => true, "status" => "completed", "output" => run.output})

      {:error, errors} ->
        Map.merge(base, Map.put(failure(errors), "status", "failed"))

      {:interrupted, _reason} ->
        Map.merge(base, %{"ok" => false, "status" => "interrupted", "errors" => []})
    end
  end

  # One row per activation, in first-seen order, with its latest status and
  # stored result.
  defp steps(store, run_id) do
    store
    |> Troupe.history(run_id)
    |> Enum.filter(&(&1["activation"] && &1["type"] not in ["loop_iteration_completed"]))
    |> Enum.reduce({[], %{}}, fn event, {order, rows} ->
      activation = event["activation"]

      row =
        Map.get(rows, activation, %{
          "activation" => activation,
          "node" => event["node"],
          "attempts" => 0
        })

      order = if Map.has_key?(rows, activation), do: order, else: [activation | order]
      {order, Map.put(rows, activation, step_row(row, event, store, run_id))}
    end)
    |> then(fn {order, rows} -> order |> Enum.reverse() |> Enum.map(&Map.fetch!(rows, &1)) end)
  end

  defp step_row(row, %{"type" => "attempt_started", "attempt" => attempt}, _store, _run_id),
    do: %{row | "attempts" => max(row["attempts"], attempt)} |> Map.put("status", "running")

  defp step_row(row, %{"type" => type, "payload" => key}, store, run_id)
       when type in [
              "activation_completed",
              "activation_replayed",
              "attempt_reconciled",
              "loop_completed",
              "loop_replayed"
            ] do
    row
    |> Map.put("status", String.replace(type, ["activation_", "attempt_", "loop_"], ""))
    |> Map.put("result", payload(store, run_id, key))
  end

  defp step_row(row, %{"type" => "attempt_failed", "error" => error}, _store, _run_id),
    do: Map.merge(row, %{"status" => "failed", "error" => error})

  defp step_row(row, %{"type" => type, "case" => slot}, _store, _run_id)
       when type in ["branch_selected", "branch_replayed"],
       do: Map.merge(row, %{"status" => "case #{slot}"})

  defp step_row(row, _event, _store, _run_id), do: row

  defp loops(store, run_id) do
    for %{"type" => "loop_iteration_completed"} = event <- Troupe.history(store, run_id) do
      %{
        "loop" => event["activation"],
        "iteration" => event["iteration"],
        "next_state" => payload(store, run_id, event["payload"])
      }
    end
  end

  defp payload(store, run_id, key) do
    case Store.fetch_payload(store, run_id, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp describe(definition, lines) do
    %{
      "id" => definition.id,
      "version" => definition.version,
      "json" => JSON.encode(definition),
      "elixir" => Source.to_source(definition),
      "outline" => outline(definition.nodes, 0),
      "capabilities" =>
        definition
        |> Definition.capabilities()
        |> Enum.map(&%{"name" => &1.name, "version" => &1.version}),
      "check" => check(definition, lines)
    }
  end

  # Capability problems carry JSON pointers; for DSL source, add their lines.
  defp check(definition, lines) do
    case Troupe.check(definition) do
      :ok -> []
      {:error, errors} -> Enum.map(errors, &(&1 |> with_line(lines) |> Error.to_map()))
    end
  end

  defp with_line(error, lines) do
    case Source.line_for(error.path, lines) do
      nil -> error
      line -> %{error | details: Map.put(error.details, "line", line)}
    end
  end

  defp source_lines("elixir", text) do
    case Source.parse_with_lines(text) do
      {:ok, _definition, lines} -> lines
      {:error, _errors, lines} -> lines
    end
  end

  defp source_lines(_format, _text), do: %{}

  defp outline(nodes, depth) do
    Enum.flat_map(nodes, fn node ->
      [outline_row(node, depth) | outline(Definition.children(node), depth + 1)]
    end)
  end

  defp outline_row(%Action{} = action, depth),
    do: %{
      "id" => action.id,
      "kind" => "action",
      "depth" => depth,
      "detail" => "#{action.capability.name} #{action.capability.version}"
    }

  defp outline_row(%Branch{} = branch, depth),
    do: %{
      "id" => branch.id,
      "kind" => "branch",
      "depth" => depth,
      "detail" => "#{length(branch.cases)} case(s)#{if branch.default, do: " + default"}"
    }

  defp outline_row(%Loop{} = loop, depth),
    do: %{
      "id" => loop.id,
      "kind" => "loop",
      "depth" => depth,
      "detail" => "max #{loop.max_iterations} iterations"
    }

  defp export(definition, "json"), do: JSON.encode(definition)
  defp export(definition, "etf"), do: Base.encode64(Binary.encode(definition))
  defp export(definition, "source"), do: Source.to_source(definition)

  defp export(definition, "elixir") do
    module = definition.id |> String.replace(~r/[^a-z0-9_]/, "_") |> Macro.camelize()
    body = definition |> Source.to_source() |> String.trim_trailing() |> indent()

    """
    defmodule MyApp.Workflows.#{module} do
      use Troupe.Workflow

    #{body}
    end
    """
  end

  defp export(definition, "app") do
    caps = definition |> Definition.capabilities() |> Enum.map(& &1.name) |> Enum.uniq()

    """
    # Either compile the "Elixir module" export into the app, or save the JSON
    # export as priv/workflows/#{definition.id}.json and load it:
    definition = Troupe.JSON.decode!(File.read!("priv/workflows/#{definition.id}.json"))

    # Loading grants nothing; the app decides what may run:
    grant = Troupe.Grant.new!(#{inspect(caps)})

    {:ok, run} = Troupe.run(definition, %{}, grant: grant, store: Troupe.Store.File.new("runs"))
    """
  end

  defp export(_definition, format),
    do: "unknown export format #{inspect(format)}; use json, elixir, source, etf or app"

  defp indent(text),
    do: text |> String.split("\n") |> Enum.map_join("\n", &if(&1 == "", do: "", else: "  " <> &1))

  defp decode("json", text), do: JSON.decode(text)
  defp decode("elixir", text), do: Source.parse(text)

  defp decode(format, _text),
    do:
      {:error,
       [
         Error.new(
           :decode_failed,
           "unknown definition format #{inspect(format)}; use elixir or json"
         )
       ]}

  defp decode_inputs(json) do
    case Jason.decode(json) do
      {:ok, inputs} when is_map(inputs) ->
        {:ok, inputs}

      {:ok, _other} ->
        {:error, [Error.new(:invalid_inputs, "inputs must be a JSON object")]}

      {:error, error} ->
        {:error,
         [Error.new(:decode_failed, "inputs are not valid JSON: #{Exception.message(error)}")]}
    end
  end

  defp grant(names) when is_list(names) do
    case Grant.new(names) do
      {:ok, grant} -> {:ok, grant}
      {:error, error} -> {:error, [error]}
    end
  end

  defp grant(_names),
    do: {:error, [Error.new(:not_granted, "granted capabilities must be a list of names")]}

  defp failure(errors), do: %{"ok" => false, "errors" => Enum.map(errors, &Error.to_map/1)}

  defp reply(state, map), do: {:reply, Jason.encode!(map), state}
end
