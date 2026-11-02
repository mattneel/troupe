defmodule Troupe.Runtime.Journal do
  @moduledoc false
  # Store access for steps: checkpoints, payloads and history events, plus a
  # `[:troupe, :event]` telemetry signal after each event is durably appended.

  alias Troupe.{Error, Store}
  alias Troupe.Runtime.Context

  @spec event(Context.t(), String.t(), map()) :: :ok | {:error, Error.t()}
  def event(%Context{} = ctx, type, fields \\ %{}) do
    event =
      fields
      |> Map.put("type", type)
      |> Map.put("at", System.system_time(:millisecond))

    with :ok <- Store.append_event(ctx.store, ctx.run_id, event) do
      :telemetry.execute([:troupe, :event], %{}, %{run_id: ctx.run_id, event: event})
      :ok
    end
  end

  @spec checkpoint(Context.t(), String.t()) :: {:ok, map()} | :none
  def checkpoint(%Context{} = ctx, key) do
    case Store.fetch_checkpoint(ctx.store, ctx.run_id, key) do
      {:ok, value} -> {:ok, value}
      :error -> :none
    end
  end

  @spec put_checkpoint(Context.t(), String.t(), map()) :: :ok | {:error, Error.t()}
  def put_checkpoint(%Context{} = ctx, key, value),
    do: Store.put_checkpoint(ctx.store, ctx.run_id, key, value)

  @spec put_payload(Context.t(), String.t(), term()) :: :ok | {:error, Error.t()}
  def put_payload(%Context{} = ctx, key, value),
    do: Store.put_payload(ctx.store, ctx.run_id, key, value)

  @spec payload(Context.t(), String.t()) :: {:ok, term()} | {:error, Error.t()}
  def payload(%Context{} = ctx, key) do
    case Store.fetch_payload(ctx.store, ctx.run_id, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        {:error, Error.new(:store_failed, "payload #{inspect(key)} is missing from the store")}
    end
  end

  # Checkpoint keys. Activation ids are unique per run, so prefixes keep the
  # record kinds apart.
  def done_key(activation), do: "done:" <> activation
  def attempts_key(activation), do: "attempts:" <> activation
  def loop_key(activation), do: "loop:" <> activation
  def branch_key(activation), do: "branch:" <> activation
end
