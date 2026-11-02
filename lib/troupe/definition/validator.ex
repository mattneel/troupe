defmodule Troupe.Definition.Validator do
  @moduledoc false
  # Semantic validation of a decoded definition: unique ids, references that
  # exist and are in scope, loop references to enclosing loops, secret usage
  # and dependency cycles.

  alias Troupe.{Definition, Error, Expr}
  alias Troupe.Definition.Scope

  @max_nodes 1_000

  @spec validate(Definition.t()) :: :ok | {:error, [Error.t()]}
  def validate(%Definition{} = definition) do
    walked = Scope.walk(definition)
    locations = Scope.locations(definition)
    sites = Scope.sites(definition)
    inputs = MapSet.new(definition.inputs, & &1.name)

    errors =
      size_errors(walked) ++
        duplicate_errors(walked) ++
        Enum.flat_map(sites, &site_errors(&1, locations, inputs)) ++
        cycle_errors(sites, locations)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp size_errors(walked) when length(walked) > @max_nodes,
    do: [invalid("/nodes", "definition has #{length(walked)} nodes; the limit is #{@max_nodes}")]

  defp size_errors(_walked), do: []

  defp duplicate_errors(walked) do
    {_seen, errors} =
      Enum.reduce(walked, {%{}, []}, fn {node, _list, pointer}, {seen, errors} ->
        case Map.fetch(seen, node.id) do
          {:ok, first} ->
            {seen,
             [
               invalid(
                 pointer <> "/id",
                 "duplicate node id #{inspect(node.id)} (first defined at #{first})"
               )
               | errors
             ]}

          :error ->
            {Map.put(seen, node.id, pointer), errors}
        end
      end)

    Enum.reverse(errors)
  end

  defp site_errors(site, locations, inputs) do
    site.expr
    |> Expr.refs()
    |> Enum.uniq()
    |> Enum.flat_map(&ref_errors(&1, site, locations, inputs))
  end

  defp ref_errors({:input, name}, site, _locations, inputs) do
    if MapSet.member?(inputs, name),
      do: [],
      else: [reference(site, "unknown input #{inspect(name)}; declared inputs: #{list(inputs)}")]
  end

  defp ref_errors({:secret, name}, %{context: :arg}, _locations, _inputs) when is_binary(name),
    do: []

  defp ref_errors({:secret, name}, site, _locations, _inputs) do
    [
      reference(
        site,
        "secret #{inspect(name)} may only be passed directly as an action argument, so it never reaches results, state or history"
      )
    ]
  end

  defp ref_errors({:loop, of}, site, _locations, _inputs) do
    if {of, :body} in site.list,
      do: [],
      else: [
        reference(
          site,
          "loop #{inspect(of)} does not enclose this expression; loop state and index are only visible inside the loop body"
        )
      ]
  end

  defp ref_errors({:result, id}, site, locations, _inputs) do
    case Map.fetch(locations, id) do
      :error ->
        [
          reference(
            site,
            "unknown node #{inspect(id)}; known nodes: #{list(Map.keys(locations))}"
          )
        ]

      {:ok, location} ->
        result_scope_errors(id, location, site)
    end
  end

  defp result_scope_errors(id, location, site) do
    cond do
      id == site.owner and site.context in [:arg, :branch_on, :loop_state] ->
        [reference(site, "node #{inspect(id)} cannot reference its own result")]

      id in Scope.enclosing(site.list) ->
        [
          reference(
            site,
            "#{inspect(id)} encloses this expression, so its result is not available yet; use loop state or the case output instead"
          )
        ]

      not Scope.within?(site.list, location.list) ->
        [
          reference(
            site,
            "node #{inspect(id)} #{placement(location.list)} and is not in scope here"
          )
        ]

      true ->
        []
    end
  end

  defp placement([]), do: "is a top-level node"

  defp placement(list) do
    case List.last(list) do
      {loop, :body} -> "runs inside loop #{inspect(loop)}"
      {branch, :default} -> "runs inside the default case of branch #{inspect(branch)}"
      {branch, index} -> "runs inside case #{index} of branch #{inspect(branch)}"
    end
  end

  # Builds sibling dependency edges per list and reports cycles.
  defp cycle_errors(sites, locations) do
    edges =
      for site <- sites,
          id <- Expr.result_ids(site.expr),
          {:ok, location} <- [Map.fetch(locations, id)],
          Scope.within?(site.list, location.list),
          from <- [Scope.representative(site, location.list)],
          from != nil and from != id,
          uniq: true,
          do: {location.list, from, id}

    edges
    |> Enum.group_by(&elem(&1, 0), fn {_list, from, to} -> {from, to} end)
    |> Enum.sort()
    |> Enum.flat_map(fn {_list, pairs} -> find_cycles(pairs, locations) end)
  end

  defp find_cycles(pairs, locations) do
    graph = Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))

    graph
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce({MapSet.new(), []}, fn start, {done, errors} ->
      case visit(start, graph, [], done) do
        {:ok, done} -> {done, errors}
        {:cycle, cycle, done} -> {done, [cycle_error(cycle, locations) | errors]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.details)
  end

  defp visit(node, graph, stack, done) do
    cond do
      node in stack ->
        cycle = [node | Enum.reverse(Enum.take_while(stack, &(&1 != node)))] ++ [node]
        {:cycle, cycle, done}

      MapSet.member?(done, node) ->
        {:ok, done}

      true ->
        graph
        |> Map.get(node, [])
        |> Enum.sort()
        |> Enum.reduce_while({:ok, done}, &visit_next(&1, &2, graph, [node | stack]))
        |> mark_done(node)
    end
  end

  defp visit_next(next, {:ok, done}, graph, stack) do
    case visit(next, graph, stack, done) do
      {:ok, done} -> {:cont, {:ok, done}}
      cycle -> {:halt, cycle}
    end
  end

  defp mark_done({:ok, done}, node), do: {:ok, MapSet.put(done, node)}
  defp mark_done({:cycle, cycle, done}, node), do: {:cycle, cycle, MapSet.put(done, node)}

  defp cycle_error([first | _rest] = cycle, locations) do
    canonical = cycle |> Enum.drop(-1) |> Enum.sort()

    Error.new(:invalid_reference, "dependency cycle: #{Enum.join(cycle, " -> ")}",
      path: locations[first].pointer,
      details: %{"cycle" => canonical}
    )
  end

  defp reference(site, message), do: Error.new(:invalid_reference, message, path: site.pointer)
  defp invalid(pointer, message), do: Error.new(:invalid_definition, message, path: pointer)

  defp list(items) do
    case items |> Enum.to_list() |> Enum.sort() do
      [] -> "(none)"
      items -> Enum.map_join(items, ", ", &inspect/1)
    end
  end
end
