defmodule Troupe.Runtime.Values do
  @moduledoc false
  # Builds the expression environment for a step from its Reactor arguments:
  # the shared env plus results of same-Reactor dependencies.

  alias Troupe.Error
  alias Troupe.Runtime.{Context, Env}

  @spec env(map(), [{String.t(), atom()}], Context.t()) :: {Env.t(), Troupe.Expr.env()}
  def env(%{scope: %Env{} = env} = args, locals, %Context{secrets: secrets}) do
    results =
      Enum.reduce(locals, env.results, fn {id, key}, acc ->
        Map.put(acc, id, Map.fetch!(args, key))
      end)

    {env, %{inputs: env.inputs, results: results, loops: env.loops, secrets: secrets}}
  end

  @doc "Annotates an error with the activation it happened in."
  @spec at(Error.t(), String.t(), String.t()) :: Error.t()
  def at(%Error{} = error, activation, node_id) do
    %{
      error
      | message: "#{error.message} (node #{inspect(node_id)}, activation #{inspect(activation)})",
        details: Map.merge(error.details, %{"node" => node_id, "activation" => activation})
    }
  end
end

defmodule Troupe.Runtime.ValueStep do
  @moduledoc false
  # Evaluates an expression: the workflow output or a branch case output.
  use Reactor.Step

  alias Troupe.Expr
  alias Troupe.Runtime.Values

  @impl true
  def run(args, context, opts) do
    {_env, eval} = Values.env(args, opts[:locals], context.troupe)
    Expr.evaluate(opts[:expr], eval)
  end
end

defmodule Troupe.Runtime.IterationStep do
  @moduledoc false
  # Last step of a loop iteration: computes the next state and the stop flag.
  use Reactor.Step

  alias Troupe.{Error, Expr, PlainData}
  alias Troupe.Runtime.Values

  @impl true
  def run(args, context, opts) do
    loop = opts[:node]
    {env, eval} = Values.env(args, opts[:locals], context.troupe)

    with {:ok, next} <- Expr.evaluate(loop.next_state, eval),
         :ok <- plain_state(next, env.prefix <> loop.id, loop.id),
         {:ok, stop} <- stop?(loop.until, eval) do
      {:ok, %{state: next, done: stop}}
    end
  end

  defp plain_state(state, activation, loop_id) do
    if PlainData.plain?(state),
      do: :ok,
      else:
        {:error,
         Values.at(
           Error.new(:invalid_result, "next_state must be plain data"),
           activation,
           loop_id
         )}
  end

  defp stop?(nil, _eval), do: {:ok, false}

  defp stop?(until, eval) do
    with {:ok, value} <- Expr.evaluate(until, eval), do: {:ok, value not in [nil, false]}
  end
end

defmodule Troupe.Runtime.BranchStep do
  @moduledoc false
  # Evaluates `on`, records the chosen case (so a resumed run can detect a
  # different choice), then lets Reactor's Switch emit the case's steps.
  use Reactor.Step

  alias Reactor.Step.Switch
  alias Troupe.{Error, Expr, PlainData}
  alias Troupe.Runtime.{Compiler, Journal, Values}

  @impl true
  def run(args, context, opts) do
    branch = opts[:node]
    ctx = context.troupe
    {env, eval} = Values.env(args, opts[:locals], ctx)
    activation = env.prefix <> branch.id

    with {:ok, value} <- Expr.evaluate(branch.on, eval),
         {:ok, slot} <- select(opts, value, activation, branch.id),
         :ok <- record(ctx, activation, branch.id, slot) do
      matches =
        Enum.map(opts[:matches], fn {match, specs} ->
          {&(&1 == match), Enum.map(specs, &Compiler.emit/1)}
        end)

      default = if opts[:default], do: Enum.map(opts[:default], &Compiler.emit/1)
      switch_opts = [on: :value, matches: matches, allow_async?: true]
      switch_opts = if default, do: Keyword.put(switch_opts, :default, default), else: switch_opts

      Switch.run(%{value: value}, context, switch_opts)
    end
  end

  defp select(opts, value, activation, branch_id) do
    index = Enum.find_index(opts[:matches], fn {match, _specs} -> match == value end)

    cond do
      is_integer(index) ->
        {:ok, index}

      opts[:default] != nil ->
        {:ok, "default"}

      true ->
        error =
          Error.new(
            :invalid_reference,
            "no case matches #{PlainData.describe(value)} #{inspect(value)} and there is no default case",
            details: %{"value" => value}
          )

        {:error, Values.at(error, activation, branch_id)}
    end
  end

  defp record(ctx, activation, branch_id, slot) do
    key = Journal.branch_key(activation)
    fields = %{"activation" => activation, "node" => branch_id, "case" => slot}

    case Journal.checkpoint(ctx, key) do
      {:ok, %{"case" => ^slot}} ->
        Journal.event(ctx, "branch_replayed", fields)

      {:ok, %{"case" => original}} ->
        {:error,
         Values.at(
           Error.new(
             :definition_mismatch,
             "branch chose case #{inspect(slot)} on resume but #{inspect(original)} originally; its input changed between runs"
           ),
           activation,
           branch_id
         )}

      :none ->
        with :ok <- Journal.put_checkpoint(ctx, key, %{"case" => slot}) do
          Journal.event(ctx, "branch_selected", fields)
        end
    end
  end
end
