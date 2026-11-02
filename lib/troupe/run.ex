defmodule Troupe.Run do
  @moduledoc """
  A finished run: its id, the workflow output, and the store holding its
  history, payloads and checkpoints.
  """

  @type t :: %__MODULE__{id: String.t(), output: Troupe.PlainData.t(), store: Troupe.Store.t()}

  @enforce_keys [:id, :output, :store]
  defstruct [:id, :output, :store]
end
