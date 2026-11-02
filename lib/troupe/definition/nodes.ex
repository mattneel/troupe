defmodule Troupe.Definition.Input do
  @moduledoc "A declared workflow input."

  @type type :: :string | :integer | :number | :boolean | :map | :list | :any

  @type t :: %__MODULE__{
          name: String.t(),
          type: type(),
          required: boolean(),
          default: Troupe.PlainData.t(),
          description: String.t() | nil
        }

  @enforce_keys [:name, :type]
  defstruct name: nil, type: :any, required: true, default: nil, description: nil
end

defmodule Troupe.Definition.CapabilityRef do
  @moduledoc """
  A named, versioned reference to an installed capability, e.g.
  `%{name: "text.upcase", version: "~> 1.0"}`. `version` is an Elixir
  `Version` requirement. References are resolved against a
  `Troupe.Registry` at run time; they never name modules.
  """

  @type t :: %__MODULE__{name: String.t(), version: String.t()}

  @enforce_keys [:name, :version]
  defstruct [:name, :version]
end

defmodule Troupe.Definition.Action do
  @moduledoc "A node that invokes one capability with expression arguments."

  alias Troupe.Definition.CapabilityRef

  @type t :: %__MODULE__{
          id: String.t(),
          capability: CapabilityRef.t(),
          args: %{String.t() => Troupe.Expr.t()},
          max_attempts: pos_integer(),
          description: String.t() | nil
        }

  @enforce_keys [:id, :capability]
  defstruct id: nil, capability: nil, args: %{}, max_attempts: 1, description: nil
end

defmodule Troupe.Definition.Case do
  @moduledoc """
  One branch arm: nodes to run and the expression that becomes the branch's
  result. The `default` arm has `default?: true` and no match value.
  """

  @type t :: %__MODULE__{
          match: Troupe.PlainData.t(),
          default?: boolean(),
          nodes: [Troupe.Definition.workflow_node()],
          output: Troupe.Expr.t()
        }

  @enforce_keys [:output]
  defstruct match: nil, default?: false, nodes: [], output: nil
end

defmodule Troupe.Definition.Branch do
  @moduledoc """
  A node that evaluates `on` and runs the first case whose `match` equals the
  value, or the `default` case. Its result is the chosen case's `output`.
  """

  alias Troupe.Definition.Case

  @type t :: %__MODULE__{
          id: String.t(),
          on: Troupe.Expr.t(),
          cases: [Case.t()],
          default: Case.t() | nil,
          description: String.t() | nil
        }

  @enforce_keys [:id, :on, :cases]
  defstruct id: nil, on: nil, cases: [], default: nil, description: nil

  @doc "Match cases followed by the default case, if any."
  @spec all_cases(t()) :: [Case.t()]
  def all_cases(%__MODULE__{cases: cases, default: nil}), do: cases
  def all_cases(%__MODULE__{cases: cases, default: default}), do: cases ++ [default]
end

defmodule Troupe.Definition.Loop do
  @moduledoc """
  A node that runs its body repeatedly. Each iteration sees only the loop's
  current `state` and `index`; `next_state` (evaluated against the body's
  results) becomes the next iteration's state. The loop stops when `until`
  evaluates truthy or after `max_iterations`. Its result is the final state.

  Iterations never receive earlier iterations' frames: history lives in the
  run store, not in active state.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          max_iterations: pos_integer(),
          state: Troupe.Expr.t(),
          nodes: [Troupe.Definition.workflow_node()],
          next_state: Troupe.Expr.t(),
          until: Troupe.Expr.t() | nil,
          description: String.t() | nil
        }

  @enforce_keys [:id, :max_iterations, :state, :nodes, :next_state]
  defstruct id: nil,
            max_iterations: nil,
            state: nil,
            nodes: [],
            next_state: nil,
            until: nil,
            description: nil
end
