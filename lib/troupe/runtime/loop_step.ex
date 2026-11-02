defmodule Troupe.Runtime.LoopStep do
  @moduledoc """
  Reactor step for a loop node. Each run executes exactly one iteration as a
  separate Reactor run of the loop body, stores the next state as a payload,
  checkpoints progress, and then either returns the final state or re-emits
  itself (same step name, as `Reactor.Step.Recurse` does) carrying a new
  `Troupe.Runtime.Frame`.

  Iteration `k` sees `{"loop": "state"}` / `{"loop": "index"}` for itself and
  activations named `"<loop>[k]/<node>"`. Nothing from iterations before `k`
  is passed in except the state value the definition computed.

  Each frame is published as `[:troupe, :frame]` telemetry before its
  iteration runs, so the active state can be measured.
  """

  use Reactor.Step

  alias Reactor.Builder
  alias Troupe.Expr
  alias Troupe.Runtime.{Compiler, Env, Frame, Journal, Values}

  @impl true
  def run(args, context, opts) do
    ctx = context.troupe
    loop = opts[:node]
    {env, eval} = Values.env(args, opts[:locals], ctx)
    activation = env.prefix <> loop.id

    case enter(opts[:frame], ctx, loop, activation, eval) do
      {:done, value} -> {:ok, value}
      {:ok, %Frame{} = frame} -> iterate(frame, ctx, loop, env, eval, context, opts)
      {:error, _error} = error -> error
    end
  end

  defp enter(%Frame{} = frame, _ctx, _loop, _activation, _eval), do: {:ok, frame}

  defp enter(nil, ctx, loop, activation, eval) do
    case Journal.checkpoint(ctx, Journal.loop_key(activation)) do
      {:ok, %{"status" => "completed", "payload" => key}} ->
        with {:ok, value} <- Journal.payload(ctx, key),
             :ok <-
               Journal.event(ctx, "loop_replayed", %{
                 "activation" => activation,
                 "node" => loop.id
               }) do
          {:done, value}
        end

      {:ok, %{"status" => "running", "next_index" => index, "payload" => key}} ->
        {:ok, %Frame{activation: activation, index: index, state_key: key}}

      :none ->
        start(ctx, loop, activation, eval)
    end
  end

  defp start(ctx, loop, activation, eval) do
    key = state_key(activation, 0)

    with {:ok, state} <- evaluate(loop.state, eval, activation, loop.id),
         :ok <- Journal.put_payload(ctx, key, state),
         :ok <- progress(ctx, activation, 0, key) do
      {:ok, %Frame{activation: activation, index: 0, state_key: key}}
    end
  end

  defp iterate(frame, ctx, loop, env, eval, context, opts) do
    :telemetry.execute([:troupe, :frame], %{}, %{run_id: ctx.run_id, frame: frame})

    with {:ok, state} <- Journal.payload(ctx, frame.state_key),
         {:ok, %{state: next, done: done}} <-
           run_body(frame, state, ctx, loop, env, eval, context),
         {:ok, index, key} <- record_iteration(ctx, loop, frame, next) do
      if done or index >= loop.max_iterations,
        do: finish(ctx, loop, frame.activation, index, key, next),
        else: continue(ctx, frame, index, key, context, opts)
    end
  end

  defp record_iteration(ctx, loop, frame, next) do
    index = frame.index + 1
    key = state_key(frame.activation, index)

    fields = %{
      "activation" => frame.activation,
      "node" => loop.id,
      "iteration" => frame.index,
      "payload" => key
    }

    with :ok <- Journal.put_payload(ctx, key, next),
         :ok <- Journal.event(ctx, "loop_iteration_completed", fields) do
      {:ok, index, key}
    end
  end

  defp run_body(frame, state, ctx, loop, env, eval, context) do
    scope = %Env{
      inputs: env.inputs,
      results: eval.results,
      loops: Map.put(env.loops, loop.id, %{state: state, index: frame.index}),
      prefix: "#{frame.activation}[#{frame.index}]/"
    }

    run_opts = [async?: ctx.async?] ++ concurrency(context)

    loop
    |> Compiler.iteration()
    |> Reactor.run(%{scope: scope}, %{troupe: ctx}, run_opts)
  end

  defp concurrency(%{concurrency_key: key}) when is_reference(key), do: [concurrency_key: key]
  defp concurrency(_context), do: []

  defp finish(ctx, loop, activation, iterations, key, value) do
    with :ok <-
           Journal.put_checkpoint(ctx, Journal.loop_key(activation), %{
             "status" => "completed",
             "payload" => key
           }),
         :ok <-
           Journal.event(ctx, "loop_completed", %{
             "activation" => activation,
             "node" => loop.id,
             "iterations" => iterations,
             "payload" => key
           }) do
      {:ok, value}
    end
  end

  defp continue(ctx, frame, index, key, context, opts) do
    with :ok <- progress(ctx, frame.activation, index, key) do
      next = %Frame{activation: frame.activation, index: index, state_key: key}
      step = context.current_step

      impl = {__MODULE__, Keyword.put(opts, :frame, next)}
      step_opts = [max_retries: 0]
      replacement = Builder.new_step!(step.name, impl, step.arguments, step_opts)

      {:ok, nil, [replacement]}
    end
  end

  defp progress(ctx, activation, index, key),
    do:
      Journal.put_checkpoint(ctx, Journal.loop_key(activation), %{
        "status" => "running",
        "next_index" => index,
        "payload" => key
      })

  defp evaluate(expr, eval, activation, loop_id) do
    case Expr.evaluate(expr, eval) do
      {:ok, value} -> {:ok, value}
      {:error, error} -> {:error, Values.at(error, activation, loop_id)}
    end
  end

  defp state_key(activation, index), do: "#{activation}[#{index}]#state"
end
