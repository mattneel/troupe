defmodule Troupe do
  @moduledoc """
  Portable, durable agent/workflow definitions executed with Reactor.

  One versioned, plain-data `Troupe.Definition` is authored either with the
  `Troupe.Workflow` Spark DSL or as JSON (`Troupe.JSON`), round-trips through
  JSON and Erlang term binaries (`Troupe.Binary`), and runs on Reactor.

      definition = Troupe.Examples.Greeting.definition()
      grant = Troupe.Grant.new!(["text.*"])
      {:ok, run} = Troupe.run(definition, %{"name" => "Ada"}, grant: grant)
      run.output
      #=> "Hello, ADA!"

  Capabilities are resolved by name and version from a `Troupe.Registry` of
  trusted modules; running requires an explicit `Troupe.Grant`. Pass a
  durable `Troupe.Store.File` as `:store` to resume interrupted runs with
  `resume/3`.
  """

  alias Troupe.{Definition, Error, Grant, Registry, Run, Store}
  alias Troupe.Runtime.Runner

  @typedoc """
  Run options:

    * `:grant` — `Troupe.Grant` of capabilities allowed to run (default: none)
    * `:registry` — installed capabilities (default: `Troupe.Registry.standard/0`)
    * `:store` — `Troupe.Store` for history, payloads and checkpoints
      (default: a new `Troupe.Store.Memory`)
    * `:run_id` — run identifier (default: random)
    * `:secrets` — map of secret name to value for `{"secret": name}` arguments;
      never stored
    * `:async?` — let Reactor run independent steps concurrently (default: true)
  """
  @type option ::
          {:grant, Grant.t()}
          | {:registry, Registry.t()}
          | {:store, Store.t()}
          | {:run_id, String.t()}
          | {:secrets, map()}
          | {:async?, boolean()}

  @doc """
  Validates inputs, resolves and authorizes every capability, then executes.
  Fails before running anything if any capability is unknown or not granted.
  """
  @spec run(Definition.t(), map(), [option()]) :: {:ok, Run.t()} | {:error, [Error.t()]}
  def run(%Definition{} = definition, inputs, opts \\ []),
    do: Runner.run(definition, inputs, opts)

  @doc """
  Resumes a run from its store. Completed activations are replayed from
  stored payloads instead of re-running. Requires a grant again — stored runs
  carry no permission. Pass `definition:` to assert the run uses it.
  """
  @spec resume(Store.t(), String.t(), [option() | {:definition, Definition.t()}]) ::
          {:ok, Run.t()} | {:error, [Error.t()]}
  def resume(store, run_id, opts \\ []), do: Runner.resume(store, run_id, opts)

  @doc """
  Checks a definition against installed capabilities (names, versions and
  arguments) without needing or granting permission.
  """
  @spec check(Definition.t(), Registry.t()) :: :ok | {:error, [Error.t()]}
  def check(%Definition{} = definition, registry \\ Registry.standard()) do
    with {:ok, _resolved} <- Registry.resolve_definition(registry, definition), do: :ok
  end

  @doc "History events of a run, numbered from 1 in append order."
  @spec history(Store.t(), String.t()) :: [map()]
  def history(store, run_id) do
    store
    |> Store.events(run_id)
    |> Enum.with_index(1)
    |> Enum.map(fn {event, seq} -> Map.put(event, "seq", seq) end)
  end
end
