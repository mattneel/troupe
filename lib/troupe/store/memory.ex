defmodule Troupe.Store.Memory do
  @moduledoc """
  In-memory store backed by an `Agent`, so stored history and payloads live in
  a separate process from the run. Not durable across VM restarts; works in
  the Popcorn browser VM.
  """

  @type t :: %__MODULE__{pid: pid()}

  @enforce_keys [:pid]
  defstruct [:pid]

  @doc "Starts a store linked to the caller."
  @spec new() :: t()
  def new do
    {:ok, pid} = Agent.start_link(fn -> %{} end)
    %__MODULE__{pid: pid}
  end

  @doc "Starts an unlinked store (e.g. owned by a long-lived server)."
  @spec start() :: t()
  def start do
    {:ok, pid} = Agent.start(fn -> %{} end)
    %__MODULE__{pid: pid}
  end

  @doc false
  def update(%__MODULE__{pid: pid}, run_id, fun) do
    Agent.update(pid, fn state -> Map.update(state, run_id, fun.(empty()), fun) end)
  end

  @doc false
  def get(%__MODULE__{pid: pid}, run_id, fun) do
    Agent.get(pid, fn state -> fun.(Map.get(state, run_id, empty())) end)
  end

  defp empty, do: %{record: nil, events: [], event_count: 0, payloads: %{}, checkpoints: %{}}

  defimpl Troupe.Store do
    alias Troupe.Store.Memory

    def put_run(store, run_id, record), do: Memory.update(store, run_id, &%{&1 | record: record})

    def fetch_run(store, run_id) do
      case Memory.get(store, run_id, & &1.record) do
        nil -> :error
        record -> {:ok, record}
      end
    end

    def append_event(store, run_id, event),
      do:
        Memory.update(
          store,
          run_id,
          &%{&1 | events: [event | &1.events], event_count: &1.event_count + 1}
        )

    def events(store, run_id), do: Memory.get(store, run_id, &Enum.reverse(&1.events))

    def put_payload(store, run_id, key, value),
      do: Memory.update(store, run_id, &%{&1 | payloads: Map.put(&1.payloads, key, value)})

    def fetch_payload(store, run_id, key),
      do: Memory.get(store, run_id, &Map.fetch(&1.payloads, key))

    def put_checkpoint(store, run_id, key, value),
      do: Memory.update(store, run_id, &%{&1 | checkpoints: Map.put(&1.checkpoints, key, value)})

    def fetch_checkpoint(store, run_id, key),
      do: Memory.get(store, run_id, &Map.fetch(&1.checkpoints, key))

    def stats(store, run_id) do
      Memory.get(store, run_id, fn run ->
        %{
          events: run.event_count,
          payloads: map_size(run.payloads),
          checkpoints: map_size(run.checkpoints)
        }
      end)
    end
  end
end
