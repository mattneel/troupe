defmodule Troupe.Runtime.Context do
  @moduledoc false
  # Per-run services handed to every step through the Reactor context. Holds
  # handles (store, resolved capability modules) but never payloads.

  @type t :: %__MODULE__{
          run_id: String.t(),
          store: Troupe.Store.t(),
          resolved: %{String.t() => Troupe.Capability.Spec.t()},
          secrets: %{String.t() => term()},
          async?: boolean()
        }

  @enforce_keys [:run_id, :store, :resolved]
  defstruct [:run_id, :store, :resolved, secrets: %{}, async?: true]
end

defmodule Troupe.Runtime.Env do
  @moduledoc """
  The values one Reactor run can see: validated workflow inputs, results of
  nodes outside the current Reactor that the scope references, the
  state/index of enclosing loops, and the activation prefix (e.g.
  `"agent[2]/"`) that turns node ids into activation ids.

  An env is built per Reactor run and holds only values the definition
  statically references; it never accumulates earlier iterations.
  """

  @type t :: %__MODULE__{
          inputs: map(),
          results: %{String.t() => term()},
          loops: %{String.t() => %{state: term(), index: non_neg_integer()}},
          prefix: String.t()
        }

  defstruct inputs: %{}, results: %{}, loops: %{}, prefix: ""
end

defmodule Troupe.Runtime.Frame do
  @moduledoc """
  Active state of a running loop between iterations: which activation, the
  next iteration index, and a *reference* to the stored state payload.

  This is everything carried from one iteration to the next. Its size does
  not depend on how many iterations have run; earlier iterations' results
  and events stay in the store.
  """

  @type t :: %__MODULE__{
          activation: String.t(),
          index: non_neg_integer(),
          state_key: String.t()
        }

  @enforce_keys [:activation, :index, :state_key]
  defstruct [:activation, :index, :state_key]
end
