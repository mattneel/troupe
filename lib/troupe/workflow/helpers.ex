defmodule Troupe.Workflow.Helpers do
  @moduledoc """
  Expression helpers available inside `Troupe.Workflow` modules. Each returns
  the portable expression map documented in `Troupe.Expr`, so DSL-authored
  and JSON-authored workflows decode through the same code.
  """

  @type path :: [atom() | String.t() | non_neg_integer()]

  @doc ~S|A declared workflow input: `input(:name)` or `input(:user, [:email])`.|
  @spec input(atom() | String.t(), path()) :: map()
  def input(name, path \\ []), do: with_path(%{"input" => text(name)}, path)

  @doc ~S|The result of another node: `result(:shout)` or `result(:decide, [:tool])`.|
  @spec result(atom() | String.t(), path()) :: map()
  def result(node, path \\ []), do: with_path(%{"result" => text(node)}, path)

  @doc "The current state of an enclosing loop."
  @spec loop_state(atom() | String.t(), path()) :: map()
  def loop_state(loop, path \\ []), do: with_path(%{"loop" => "state", "of" => text(loop)}, path)

  @doc "The zero-based iteration index of an enclosing loop."
  @spec loop_index(atom() | String.t()) :: map()
  def loop_index(loop), do: %{"loop" => "index", "of" => text(loop)}

  @doc "A secret supplied by the host at run time (action arguments only)."
  @spec secret(String.t()) :: map()
  def secret(name), do: %{"secret" => name}

  @doc "A literal. Atom map keys become strings; other atoms are rejected by validation."
  @spec value(term()) :: map()
  def value(literal), do: %{"value" => literal(literal)}

  @doc "An object whose fields are expressions: `object(name: result(:shout))`."
  @spec object(keyword() | map()) :: map()
  def object(fields), do: %{"object" => Map.new(fields, fn {key, expr} -> {text(key), expr} end)}

  @doc "A list whose items are expressions."
  @spec list([map()]) :: map()
  def list(items) when is_list(items), do: %{"list" => items}

  defp with_path(map, []), do: map
  defp with_path(map, path), do: Map.put(map, "path", Enum.map(List.wrap(path), &segment/1))

  defp segment(segment) when is_integer(segment), do: segment
  defp segment(segment), do: text(segment)

  defp text(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp text(value), do: value

  defp literal(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {text(key), literal(value)} end)

  defp literal(list) when is_list(list), do: Enum.map(list, &literal/1)
  defp literal(value), do: value
end
