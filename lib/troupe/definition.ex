defmodule Troupe.Definition do
  @moduledoc """
  The validated, immutable workflow definition.

  Every way of authoring a workflow — the `Troupe.Workflow` Spark DSL, JSON via
  `Troupe.JSON`, or Erlang term binaries via `Troupe.Binary` — goes through
  `from_map/1`, so all of them yield the same struct. `to_map/1` returns the
  canonical portable form: plain data with string keys and no atoms, module
  names, closures, PIDs, references or secrets.

  A definition describes work; it never grants permission to run it. See
  `Troupe.Grant`.
  """

  alias Troupe.Definition.{Action, Branch, Case, Decoder, Input, Loop, Validator}
  alias Troupe.{Error, Expr, PlainData}

  @schema_version 1

  @type workflow_node :: Action.t() | Branch.t() | Loop.t()

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          version: String.t(),
          description: String.t() | nil,
          inputs: [Input.t()],
          nodes: [workflow_node()],
          output: Expr.t()
        }

  @enforce_keys [:id, :version, :nodes, :output]
  defstruct schema_version: @schema_version,
            id: nil,
            version: nil,
            description: nil,
            inputs: [],
            nodes: [],
            output: nil

  @doc "The portable schema version this library reads and writes."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Decodes and validates a portable map (string keys, as produced by
  `Jason.decode/1`). Non-plain values (atoms, tuples, PIDs, references,
  functions) are rejected before decoding. Returns every problem found, each
  with a JSON-pointer path.
  """
  @spec from_map(term()) :: {:ok, t()} | {:error, [Error.t()]}
  def from_map(map) do
    with :ok <- PlainData.check(map),
         {:ok, definition} <- Decoder.decode(map),
         :ok <- Validator.validate(definition) do
      {:ok, definition}
    end
  end

  @doc "Canonical portable form of a definition."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = definition) do
    %{
      "schema_version" => definition.schema_version,
      "id" => definition.id,
      "version" => definition.version,
      "inputs" => Enum.map(definition.inputs, &input_to_map/1),
      "nodes" => Enum.map(definition.nodes, &node_to_map/1),
      "output" => Expr.to_portable(definition.output)
    }
    |> put_optional("description", definition.description)
  end

  defp input_to_map(%Input{} = input) do
    %{"name" => input.name, "type" => Atom.to_string(input.type), "required" => input.required}
    |> put_optional("default", input.default)
    |> put_optional("description", input.description)
  end

  defp node_to_map(%Action{} = action) do
    %{
      "id" => action.id,
      "kind" => "action",
      "capability" => %{"name" => action.capability.name, "version" => action.capability.version},
      "args" => Map.new(action.args, fn {key, expr} -> {key, Expr.to_portable(expr)} end),
      "max_attempts" => action.max_attempts
    }
    |> put_optional("description", action.description)
  end

  defp node_to_map(%Branch{} = branch) do
    %{
      "id" => branch.id,
      "kind" => "branch",
      "on" => Expr.to_portable(branch.on),
      "cases" => Enum.map(branch.cases, &case_to_map/1)
    }
    |> put_optional("default", branch.default && case_to_map(branch.default))
    |> put_optional("description", branch.description)
  end

  defp node_to_map(%Loop{} = loop) do
    %{
      "id" => loop.id,
      "kind" => "loop",
      "max_iterations" => loop.max_iterations,
      "state" => Expr.to_portable(loop.state),
      "nodes" => Enum.map(loop.nodes, &node_to_map/1),
      "next_state" => Expr.to_portable(loop.next_state)
    }
    |> put_optional("until", loop.until && Expr.to_portable(loop.until))
    |> put_optional("description", loop.description)
  end

  defp case_to_map(%Case{} = branch_case) do
    %{
      "nodes" => Enum.map(branch_case.nodes, &node_to_map/1),
      "output" => Expr.to_portable(branch_case.output)
    }
    |> put_optional_match(branch_case)
  end

  defp put_optional_match(map, %Case{default?: true}), do: map
  defp put_optional_match(map, %Case{match: match}), do: Map.put(map, "match", match)

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  @doc "Every node in the definition, depth first, including nested ones."
  @spec all_nodes(t() | [workflow_node()]) :: [workflow_node()]
  def all_nodes(%__MODULE__{nodes: nodes}), do: all_nodes(nodes)

  def all_nodes(nodes) when is_list(nodes),
    do: Enum.flat_map(nodes, &[&1 | all_nodes(children(&1))])

  @doc "Directly nested nodes of a composite node."
  @spec children(workflow_node()) :: [workflow_node()]
  def children(%Action{}), do: []
  def children(%Loop{nodes: nodes}), do: nodes
  def children(%Branch{} = branch), do: Enum.flat_map(Branch.all_cases(branch), & &1.nodes)

  @doc "Capability references used by the definition, deduplicated."
  @spec capabilities(t()) :: [Troupe.Definition.CapabilityRef.t()]
  def capabilities(%__MODULE__{} = definition) do
    for %Action{capability: capability} <- all_nodes(definition), uniq: true, do: capability
  end
end
