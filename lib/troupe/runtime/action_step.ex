defmodule Troupe.Runtime.ActionStep do
  @moduledoc """
  Reactor step that runs one action activation with durable bookkeeping.

  For activation `A` (e.g. `"agent[2]/think"`):

    1. If `A` already has a completion checkpoint, its stored payload is
       returned without calling the capability (replay after resume).
    2. Arguments are evaluated and validated against the capability inputs.
    3. If the previous attempt started but never finished (the process died),
       the capability's optional `reconcile/2` may report the result.
    4. Otherwise attempt `n` is recorded *before* the capability runs, the
       capability runs, and the result payload and completion checkpoint are
       written before the step returns.

  A crash between 4's call and its checkpoint re-runs the action on resume:
  delivery is at-least-once, with `idempotency_key` stable across attempts.
  """

  use Reactor.Step

  alias Troupe.Capability.{Context, Spec}
  alias Troupe.{Error, Expr, PlainData, Schema}
  alias Troupe.Runtime.{Journal, Values}

  @impl true
  def run(args, context, opts) do
    ctx = context.troupe
    action = opts[:node]
    {env, eval} = Values.env(args, opts[:locals], ctx)
    activation = env.prefix <> action.id

    case Journal.checkpoint(ctx, Journal.done_key(activation)) do
      {:ok, %{"payload" => key, "attempt" => attempt}} ->
        replay(ctx, activation, action, key, attempt)

      :none ->
        execute(ctx, action, activation, eval)
    end
  end

  defp replay(ctx, activation, action, key, attempt) do
    with {:ok, value} <- Journal.payload(ctx, key),
         :ok <-
           Journal.event(
             ctx,
             "activation_replayed",
             fields(activation, action, attempt, %{"payload" => key})
           ) do
      {:ok, value}
    end
  end

  defp execute(ctx, action, activation, eval) do
    spec = Map.fetch!(ctx.resolved, action.id)

    with {:ok, values} <- evaluate_args(action, eval, activation),
         {:ok, values} <- validate_args(values, spec, activation, action.id),
         {:ok, previous} <- previous_attempt(ctx, activation) do
      attempt(ctx, action, spec, activation, values, previous)
    end
  end

  defp evaluate_args(action, eval, activation) do
    action.args
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {key, expr}, {:ok, acc} ->
      case Expr.evaluate(expr, eval) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        {:error, error} ->
          {:halt, {:error, Values.at(%{error | path: "/args/#{key}"}, activation, action.id)}}
      end
    end)
  end

  defp validate_args(values, spec, activation, node_id) do
    case Schema.validate_fields(values, spec.inputs, "argument", :invalid_arguments) do
      {:ok, values} -> {:ok, values}
      {:error, [error | _rest]} -> {:error, Values.at(error, activation, node_id)}
    end
  end

  # Attempt bookkeeping: `count` numbers every attempt ever started (so
  # attempt ids stay unique across restarts), `failures` counts attempts that
  # returned an error. Interrupted attempts do not consume max_attempts.
  defp previous_attempt(ctx, activation) do
    case Journal.checkpoint(ctx, Journal.attempts_key(activation)) do
      {:ok, %{"count" => count, "failures" => failures, "open" => open}} ->
        {:ok, {count, failures, open}}

      :none ->
        {:ok, {0, 0, false}}
    end
  end

  # The last attempt started but never recorded an outcome: it may have
  # performed its side effect. Ask the capability before running again.
  defp attempt(ctx, action, spec, activation, values, {count, failures, true}) do
    if function_exported?(spec.module, :reconcile, 2) do
      case spec.module.reconcile(values, capability_context(ctx, action, activation, count)) do
        {:ok, value} -> reconciled(ctx, action, spec, activation, {count, failures}, value)
        :unknown -> attempt(ctx, action, spec, activation, values, {count, failures, false})
      end
    else
      attempt(ctx, action, spec, activation, values, {count, failures, false})
    end
  end

  defp attempt(_ctx, action, _spec, activation, _values, {count, failures, false})
       when failures >= action.max_attempts do
    {:error,
     Values.at(
       Error.new(:attempts_exhausted, "all #{action.max_attempts} attempt(s) failed",
         details: %{"attempts" => count, "failures" => failures}
       ),
       activation,
       action.id
     )}
  end

  defp attempt(ctx, action, spec, activation, values, {count, failures, false}) do
    tally = {count + 1, failures}

    started =
      fields(activation, action, count + 1, %{"capability" => "#{spec.name}@#{spec.version}"})

    with :ok <- put_attempts(ctx, activation, tally, true),
         :ok <- Journal.event(ctx, "attempt_started", started) do
      ctx
      |> invoke(spec, values, capability_context(ctx, action, activation, count + 1))
      |> outcome(ctx, action, spec, activation, tally)
    end
  end

  defp put_attempts(ctx, activation, {number, failures}, open) do
    Journal.put_checkpoint(ctx, Journal.attempts_key(activation), %{
      "count" => number,
      "failures" => failures,
      "open" => open
    })
  end

  defp invoke(_ctx, %Spec{module: module}, values, capability_context) do
    module.run(values, capability_context)
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, inspect(reason)}}
  end

  defp outcome({:ok, value}, ctx, action, spec, activation, tally) do
    if PlainData.plain?(value) and Schema.type?(value, spec.output) do
      complete(ctx, action, activation, tally, value, "activation_completed")
    else
      failed(
        ctx,
        action,
        activation,
        tally,
        :invalid_result,
        "#{spec.name} returned #{PlainData.describe(value)}; expected plain data of type #{spec.output}",
        false
      )
    end
  end

  defp outcome({:retry, reason}, ctx, action, _spec, activation, {_number, failures} = tally) do
    with {:error, error} <-
           failed(ctx, action, activation, tally, :action_failed, describe(reason), true) do
      if failures + 1 < action.max_attempts,
        do: {:retry, error},
        else: {:error, %{error | kind: :attempts_exhausted}}
    end
  end

  defp outcome({:error, reason}, ctx, action, _spec, activation, tally),
    do: failed(ctx, action, activation, tally, :action_failed, describe(reason), false)

  defp outcome(other, ctx, action, spec, activation, tally) do
    failed(
      ctx,
      action,
      activation,
      tally,
      :action_failed,
      "#{spec.name} returned #{inspect(other)}; expected {:ok, value}, {:error, reason} or {:retry, reason}",
      false
    )
  end

  defp complete(ctx, action, activation, {number, _failures}, value, event) do
    key = "#{activation}@#{number}"

    with :ok <- Journal.put_payload(ctx, key, value),
         :ok <-
           Journal.put_checkpoint(ctx, Journal.done_key(activation), %{
             "payload" => key,
             "attempt" => number
           }),
         :ok <- Journal.event(ctx, event, fields(activation, action, number, %{"payload" => key})) do
      {:ok, value}
    end
  end

  defp reconciled(ctx, action, spec, activation, tally, value) do
    if PlainData.plain?(value) and Schema.type?(value, spec.output),
      do: complete(ctx, action, activation, tally, value, "attempt_reconciled"),
      else:
        failed(
          ctx,
          action,
          activation,
          tally,
          :invalid_result,
          "#{spec.name} reconcile/2 returned an invalid result",
          false
        )
  end

  defp failed(ctx, action, activation, {number, failures}, kind, message, retryable) do
    error =
      kind
      |> Error.new(message, details: %{"attempt" => number, "retryable" => retryable})
      |> Values.at(activation, action.id)

    with :ok <- put_attempts(ctx, activation, {number, failures + 1}, false),
         :ok <-
           Journal.event(
             ctx,
             "attempt_failed",
             fields(activation, action, number, %{"error" => message, "retryable" => retryable})
           ) do
      {:error, error}
    end
  end

  defp capability_context(ctx, action, activation, number) do
    %Context{
      run_id: ctx.run_id,
      node_id: action.id,
      activation_id: activation,
      attempt: number,
      attempt_id: "#{activation}@#{number}",
      idempotency_key: "#{ctx.run_id}/#{activation}"
    }
  end

  defp fields(activation, action, attempt, extra),
    do: Map.merge(%{"activation" => activation, "node" => action.id, "attempt" => attempt}, extra)

  defp describe(reason) when is_binary(reason), do: reason
  defp describe({:exception, message}), do: "raised: " <> message
  defp describe(reason), do: inspect(reason)
end
