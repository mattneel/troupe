defprotocol Troupe.Store do
  @moduledoc """
  Run storage, kept separate from the immutable definition and from active
  execution state:

    * **run record** — the portable definition, validated inputs and status
    * **history** — an append-only event log (`append_event/3`, `events/2`)
    * **payloads** — results and loop states, addressed by attempt/state key
    * **checkpoints** — small records that make resume possible: completed
      activations, attempt counters, loop progress and branch choices

  Events and checkpoints reference payloads by key; they never embed earlier
  frames. Implementations: `Troupe.Store.Memory` (process-backed, works in the
  browser) and `Troupe.Store.File` (durable, survives restarts).
  """

  @doc "Writes (or replaces) the run record."
  @spec put_run(t(), String.t(), map()) :: :ok | {:error, Troupe.Error.t()}
  def put_run(store, run_id, record)

  @doc "Reads the run record."
  @spec fetch_run(t(), String.t()) :: {:ok, map()} | :error
  def fetch_run(store, run_id)

  @doc "Appends one history event."
  @spec append_event(t(), String.t(), map()) :: :ok | {:error, Troupe.Error.t()}
  def append_event(store, run_id, event)

  @doc "All history events in append order."
  @spec events(t(), String.t()) :: [map()]
  def events(store, run_id)

  @doc "Stores a payload under `key`."
  @spec put_payload(t(), String.t(), String.t(), term()) :: :ok | {:error, Troupe.Error.t()}
  def put_payload(store, run_id, key, value)

  @doc "Reads a payload."
  @spec fetch_payload(t(), String.t(), String.t()) :: {:ok, term()} | :error
  def fetch_payload(store, run_id, key)

  @doc "Durably writes (or replaces) a checkpoint."
  @spec put_checkpoint(t(), String.t(), String.t(), map()) :: :ok | {:error, Troupe.Error.t()}
  def put_checkpoint(store, run_id, key, value)

  @doc "Reads a checkpoint."
  @spec fetch_checkpoint(t(), String.t(), String.t()) :: {:ok, map()} | :error
  def fetch_checkpoint(store, run_id, key)

  @doc "Storage statistics: counts of events, payloads and checkpoints."
  @spec stats(t(), String.t()) :: %{
          events: non_neg_integer(),
          payloads: non_neg_integer(),
          checkpoints: non_neg_integer()
        }
  def stats(store, run_id)
end
