defmodule Troupe.Definition.Scope do
  @moduledoc """
  Static scope analysis shared by validation and compilation.

  Nodes live in *lists*: the workflow root, each branch case body and each
  loop body. A list is identified by the path of `{composite_id, slot}`
  segments leading to it (`[]` is the root; slot is a case index, `:default`
  or `:body`). An expression may reference a node's result when that node's
  list encloses the expression and the node is not one of the expression's
  enclosing composites.
  """

  alias Troupe.Definition
  alias Troupe.Definition.{Action, Branch, Loop}
  alias Troupe.Expr

  @type slot :: non_neg_integer() | :default | :body
  @type list_path :: [{String.t(), slot()}]
  @type context ::
          :arg | :branch_on | :case_output | :loop_state | :loop_next | :loop_until | :output

  @type site :: %{
          expr: Expr.t(),
          pointer: String.t(),
          owner: String.t() | nil,
          list: list_path(),
          context: context()
        }

  @type location :: %{node: Definition.workflow_node(), list: list_path(), pointer: String.t()}

  @doc "Locations of every node by id (first occurrence wins for duplicates)."
  @spec locations(Definition.t()) :: %{String.t() => location()}
  def locations(%Definition{nodes: nodes}) do
    nodes
    |> walk_nodes([], "/nodes")
    |> Enum.reduce(%{}, fn {node, list, pointer}, acc ->
      Map.put_new(acc, node.id, %{node: node, list: list, pointer: pointer})
    end)
  end

  @doc "Every node with its list path and pointer, in document order."
  @spec walk(Definition.t()) :: [{Definition.workflow_node(), list_path(), String.t()}]
  def walk(%Definition{nodes: nodes}), do: walk_nodes(nodes, [], "/nodes")

  defp walk_nodes(nodes, list, pointer) do
    nodes
    |> Enum.with_index()
    |> Enum.flat_map(fn {node, index} ->
      node_pointer = "#{pointer}/#{index}"
      [{node, list, node_pointer} | walk_children(node, list, node_pointer)]
    end)
  end

  defp walk_children(%Action{}, _list, _pointer), do: []

  defp walk_children(%Loop{} = loop, list, pointer),
    do: walk_nodes(loop.nodes, list ++ [{loop.id, :body}], pointer <> "/nodes")

  defp walk_children(%Branch{} = branch, list, pointer) do
    branch
    |> case_slots(pointer)
    |> Enum.flat_map(fn {branch_case, slot, case_pointer} ->
      walk_nodes(branch_case.nodes, list ++ [{branch.id, slot}], case_pointer <> "/nodes")
    end)
  end

  defp case_slots(%Branch{} = branch, pointer) do
    matches =
      branch.cases
      |> Enum.with_index()
      |> Enum.map(fn {branch_case, index} ->
        {branch_case, index, "#{pointer}/cases/#{index}"}
      end)

    case branch.default do
      nil -> matches
      default -> matches ++ [{default, :default, pointer <> "/default"}]
    end
  end

  @doc "Every expression in the definition with its scope."
  @spec sites(Definition.t()) :: [site()]
  def sites(%Definition{} = definition) do
    node_sites =
      definition
      |> walk()
      |> Enum.flat_map(fn {node, list, pointer} -> node_sites(node, list, pointer) end)

    node_sites ++ [site(definition.output, "/output", nil, [], :output)]
  end

  defp node_sites(%Action{} = action, list, pointer) do
    action.args
    |> Enum.sort()
    |> Enum.map(fn {key, expr} -> site(expr, "#{pointer}/args/#{key}", action.id, list, :arg) end)
  end

  defp node_sites(%Branch{} = branch, list, pointer) do
    outputs =
      branch
      |> case_slots(pointer)
      |> Enum.map(fn {branch_case, slot, case_pointer} ->
        site(
          branch_case.output,
          case_pointer <> "/output",
          branch.id,
          list ++ [{branch.id, slot}],
          :case_output
        )
      end)

    [site(branch.on, pointer <> "/on", branch.id, list, :branch_on) | outputs]
  end

  defp node_sites(%Loop{} = loop, list, pointer) do
    body = list ++ [{loop.id, :body}]

    until =
      if loop.until,
        do: [site(loop.until, pointer <> "/until", loop.id, body, :loop_until)],
        else: []

    [
      site(loop.state, pointer <> "/state", loop.id, list, :loop_state),
      site(loop.next_state, pointer <> "/next_state", loop.id, body, :loop_next)
      | until
    ]
  end

  defp site(expr, pointer, owner, list, context),
    do: %{expr: expr, pointer: pointer, owner: owner, list: list, context: context}

  @doc """
  The node in `target_list` that contains `site`, i.e. the sibling of the
  referenced node that must wait for it. `nil` for the workflow output.
  """
  @spec representative(site(), list_path()) :: String.t() | nil
  def representative(%{list: list, owner: owner}, target_list) do
    depth = length(target_list)

    if depth == length(list) do
      owner
    else
      list |> Enum.at(depth) |> elem(0)
    end
  end

  @doc "True when `list` is `prefix` or nested inside it."
  @spec within?(list_path(), list_path()) :: boolean()
  def within?(list, prefix), do: Enum.take(list, length(prefix)) == prefix

  @doc "Ids of composites enclosing a list."
  @spec enclosing(list_path()) :: [String.t()]
  def enclosing(list), do: Enum.map(list, &elem(&1, 0))

  @doc "Ids of nodes defined in a node's subtree, including itself."
  @spec defined_ids(Definition.workflow_node()) :: MapSet.t(String.t())
  def defined_ids(node), do: MapSet.new(Definition.all_nodes([node]), & &1.id)

  @doc """
  Result ids a node's subtree references from outside the subtree. These are
  the dependencies the node must wait for, hoisted to its own list.
  """
  @spec external_refs(Definition.workflow_node()) :: [String.t()]
  def external_refs(node) do
    defined = defined_ids(node)

    node
    |> subtree_exprs()
    |> Enum.flat_map(&Expr.result_ids/1)
    |> Enum.reject(&MapSet.member?(defined, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp subtree_exprs(node) do
    Enum.flat_map(Definition.all_nodes([node]), &own_exprs/1)
  end

  @doc "Expressions owned directly by a node (not by its nested nodes)."
  @spec own_exprs(Definition.workflow_node()) :: [Expr.t()]
  def own_exprs(%Action{args: args}), do: args |> Enum.sort() |> Enum.map(&elem(&1, 1))

  def own_exprs(%Branch{} = branch),
    do: [branch.on | Enum.map(Branch.all_cases(branch), & &1.output)]

  def own_exprs(%Loop{} = loop),
    do: Enum.reject([loop.state, loop.next_state, loop.until], &is_nil/1)

  @doc """
  Ids of nodes executed by the same Reactor as `nodes`: the list itself plus
  branch case bodies, but not loop bodies (each loop iteration is its own
  Reactor run).
  """
  @spec reactor_local([Definition.workflow_node()]) :: MapSet.t(String.t())
  def reactor_local(nodes) do
    nodes
    |> Enum.flat_map(fn
      %Branch{} = branch ->
        [branch.id | MapSet.to_list(reactor_local(Definition.children(branch)))]

      node ->
        [node.id]
    end)
    |> MapSet.new()
  end
end
