defmodule Mix.Tasks.Troupe.Run do
  @shortdoc "Runs a workflow JSON file"
  @moduledoc """
  Runs a JSON workflow with the standard capabilities.

      mix troupe.run examples/greeting.json --inputs '{"name": "Ada"}' --grant 'text.*'
      mix troupe.run examples/sqrt_newton.json --inputs '{"n": 2}' --grant 'math.*' \\
        --store tmp/runs --run-id sqrt-1

  Options:

    * `--inputs JSON` — workflow inputs (default `{}`)
    * `--grant PATTERNS` — comma-separated capability patterns to allow
    * `--store DIR` — durable `Troupe.Store.File` directory (default: memory)
    * `--run-id ID` — run id (default: random)

  Prints the output as JSON and the run id; exits non-zero on failure.
  """

  use Mix.Task

  alias Troupe.Tasks

  @switches [inputs: :string, grant: :string, store: :string, run_id: :string]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args} = OptionParser.parse!(argv, strict: @switches)

    path =
      case args do
        [path] ->
          path

        _other ->
          Mix.raise("usage: mix troupe.run PATH [--inputs JSON] [--grant PATTERNS] [--store DIR]")
      end

    definition = Tasks.load!(path)
    inputs = Tasks.decode_inputs!(Keyword.get(opts, :inputs, "{}"))

    definition
    |> Troupe.run(inputs, Tasks.run_opts(opts))
    |> Tasks.report!()
  end
end

defmodule Mix.Tasks.Troupe.Resume do
  @shortdoc "Resumes a stored workflow run"
  @moduledoc """
  Resumes a run kept in a durable store. Completed activations are replayed
  from stored payloads; the grant must be supplied again.

      mix troupe.resume --store tmp/runs --run-id sqrt-1 --grant 'math.*'
  """

  use Mix.Task

  alias Troupe.Tasks

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _args} =
      OptionParser.parse!(argv, strict: [grant: :string, store: :string, run_id: :string])

    {store, run_id} =
      case {opts[:store], opts[:run_id]} do
        {store, run_id} when is_binary(store) and is_binary(run_id) ->
          {Troupe.Store.File.new(store), run_id}

        _other ->
          Mix.raise("usage: mix troupe.resume --store DIR --run-id ID [--grant PATTERNS]")
      end

    store
    |> Troupe.resume(run_id, Tasks.run_opts(Keyword.delete(opts, :store)))
    |> Tasks.report!()
  end
end

defmodule Troupe.Tasks do
  @moduledoc false
  # Shared helpers for the troupe.* Mix tasks.

  @spec load!(Path.t()) :: Troupe.Definition.t()
  def load!(path) do
    json = File.read!(path)

    case Troupe.JSON.decode(json) do
      {:ok, definition} -> definition
      {:error, errors} -> fail!(errors)
    end
  end

  @spec ok!(:ok | {:error, [Troupe.Error.t()]}) :: :ok
  def ok!(:ok), do: :ok
  def ok!({:error, errors}), do: fail!(errors)

  @spec decode_inputs!(String.t()) :: map()
  def decode_inputs!(json) do
    case Jason.decode(json) do
      {:ok, inputs} when is_map(inputs) -> inputs
      _other -> Mix.raise("--inputs must be a JSON object")
    end
  end

  @spec run_opts(keyword()) :: keyword()
  def run_opts(opts) do
    grant =
      opts
      |> Keyword.get(:grant, "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Troupe.Grant.new!()

    [grant: grant]
    |> put_if(:store, opts[:store] && Troupe.Store.File.new(opts[:store]))
    |> put_if(:run_id, opts[:run_id])
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  @spec report!({:ok, Troupe.Run.t()} | {:error, [Troupe.Error.t()]}) :: :ok
  def report!({:ok, run}) do
    Mix.shell().info(Jason.encode!(run.output, pretty: true))
    Mix.shell().info("run #{run.id} completed")
  end

  def report!({:error, errors}), do: fail!(errors)

  @spec fail!([Troupe.Error.t()]) :: no_return()
  def fail!(errors) do
    Enum.each(errors, &Mix.shell().error("  * " <> Exception.message(&1)))
    Mix.raise("#{length(errors)} problem(s)")
  end
end
