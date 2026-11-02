defmodule Troupe.Expr do
  @moduledoc """
  Plain-data expressions used for node arguments, branch selectors, loop state
  and workflow output.

  Portable (JSON) form — exactly one tag key per object:

  | Portable form                                      | Meaning                         |
  | -------------------------------------------------- | ------------------------------- |
  | `{"input": "name", "path": [..]}`                  | declared workflow input         |
  | `{"result": "node_id", "path": [..]}`              | result of a node in scope       |
  | `{"loop": "state" \\| "index", "of": "loop_id"}`   | state/index of an enclosing loop |
  | `{"secret": "API_KEY"}`                            | host secret (action args only)  |
  | `{"value": <json>}`                                | literal                         |
  | `{"object": {"k": <expr>}}`                        | object built from expressions   |
  | `{"list": [<expr>]}`                               | list built from expressions     |

  `path` is optional and selects into the value with string keys and
  non-negative integer list indexes.
  """

  alias Troupe.{Error, PlainData}

  @type segment :: String.t() | non_neg_integer()
  @type path :: [segment()]
  @type t ::
          {:input, String.t(), path()}
          | {:result, String.t(), path()}
          | {:loop, :state | :index, String.t(), path()}
          | {:secret, String.t()}
          | {:value, PlainData.t()}
          | {:object, %{String.t() => t()}}
          | {:list, [t()]}

  @type env :: %{
          inputs: map(),
          results: map(),
          loops: %{String.t() => %{state: term(), index: non_neg_integer()}},
          secrets: map()
        }

  @tags ~w(input result loop secret value object list)
  @secret_name ~r/^[A-Z][A-Z0-9_]{0,63}$/

  @doc "Parses a portable expression found at `pointer`."
  @spec parse(term(), String.t()) :: {:ok, t()} | {:error, [Error.t()]}
  def parse(map, pointer) when is_map(map) do
    case Enum.filter(@tags, &Map.has_key?(map, &1)) do
      [tag] -> parse_tagged(tag, map, pointer)
      [] -> invalid(pointer, "expression needs one of #{Enum.join(@tags, ", ")}")
      tags -> invalid(pointer, "expression has conflicting tags #{Enum.join(tags, ", ")}")
    end
  end

  def parse(other, pointer),
    do: invalid(pointer, "expression must be an object, got #{PlainData.describe(other)}")

  defp parse_tagged("input", map, pointer) do
    with :ok <- only_keys(map, ~w(input path), pointer),
         {:ok, name} <- name(map["input"], pointer <> "/input"),
         {:ok, path} <- path(map, pointer) do
      {:ok, {:input, name, path}}
    end
  end

  defp parse_tagged("result", map, pointer) do
    with :ok <- only_keys(map, ~w(result path), pointer),
         {:ok, id} <- name(map["result"], pointer <> "/result"),
         {:ok, path} <- path(map, pointer) do
      {:ok, {:result, id, path}}
    end
  end

  defp parse_tagged("loop", map, pointer) do
    with :ok <- only_keys(map, ~w(loop of path), pointer),
         {:ok, field} <- loop_field(map["loop"], pointer <> "/loop"),
         {:ok, of} <- name(map["of"], pointer <> "/of"),
         {:ok, path} <- path(map, pointer) do
      {:ok, {:loop, field, of, path}}
    end
  end

  defp parse_tagged("secret", map, pointer) do
    with :ok <- only_keys(map, ~w(secret), pointer) do
      name = map["secret"]

      if is_binary(name) and Regex.match?(@secret_name, name),
        do: {:ok, {:secret, name}},
        else:
          invalid(pointer <> "/secret", "secret name must match #{Regex.source(@secret_name)}")
    end
  end

  defp parse_tagged("value", map, pointer) do
    with :ok <- only_keys(map, ~w(value), pointer),
         :ok <- PlainData.check_literal(map["value"], pointer <> "/value") do
      {:ok, {:value, map["value"]}}
    end
  end

  defp parse_tagged("object", map, pointer) do
    with :ok <- only_keys(map, ~w(object), pointer) do
      parse_object(map["object"], pointer <> "/object")
    end
  end

  defp parse_tagged("list", map, pointer) do
    with :ok <- only_keys(map, ~w(list), pointer) do
      parse_list(map["list"], pointer <> "/list")
    end
  end

  defp parse_object(fields, pointer) when is_map(fields) do
    fields
    |> Enum.sort()
    |> collect(fn {key, expr} -> parse_field(key, expr, pointer) end)
    |> wrap(&{:object, Map.new(&1)})
  end

  defp parse_object(other, pointer),
    do: invalid(pointer, "must be an object, got #{PlainData.describe(other)}")

  defp parse_list(items, pointer) when is_list(items) do
    items
    |> Enum.with_index()
    |> collect(fn {expr, index} -> parse(expr, "#{pointer}/#{index}") end)
    |> wrap(&{:list, &1})
  end

  defp parse_list(other, pointer),
    do: invalid(pointer, "must be a list, got #{PlainData.describe(other)}")

  defp parse_field(key, expr, pointer) when is_binary(key) do
    with {:ok, parsed} <- parse(expr, pointer <> "/" <> key), do: {:ok, {key, parsed}}
  end

  defp parse_field(key, _expr, pointer),
    do: invalid(pointer, "object keys must be strings, got #{PlainData.describe(key)}")

  defp loop_field("state", _pointer), do: {:ok, :state}
  defp loop_field("index", _pointer), do: {:ok, :index}
  defp loop_field(_other, pointer), do: invalid(pointer, ~s(must be "state" or "index"))

  defp name(value, pointer) do
    if is_binary(value) and value != "",
      do: {:ok, value},
      else: invalid(pointer, "must be a non-empty string")
  end

  defp path(map, pointer) do
    case Map.get(map, "path", []) do
      segments when is_list(segments) ->
        if Enum.all?(segments, &segment?/1),
          do: {:ok, segments},
          else: invalid(pointer <> "/path", "segments must be strings or non-negative integers")

      other ->
        invalid(pointer <> "/path", "must be a list, got #{PlainData.describe(other)}")
    end
  end

  defp segment?(segment), do: is_binary(segment) or (is_integer(segment) and segment >= 0)

  defp only_keys(map, allowed, pointer) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      extra -> invalid(pointer, "unknown expression keys #{inspect(Enum.sort(extra))}")
    end
  end

  defp invalid(pointer, message),
    do: {:error, [Error.new(:invalid_definition, message, path: pointer)]}

  @doc false
  @spec collect(Enumerable.t(), (term() -> {:ok, term()} | {:error, [Error.t()]})) ::
          {:ok, list()} | {:error, [Error.t()]}
  def collect(items, fun) do
    {values, errors} =
      Enum.reduce(items, {[], []}, fn item, {values, errors} ->
        case fun.(item) do
          {:ok, value} -> {[value | values], errors}
          {:error, more} -> {values, errors ++ more}
        end
      end)

    if errors == [], do: {:ok, Enum.reverse(values)}, else: {:error, errors}
  end

  defp wrap({:ok, value}, fun), do: {:ok, fun.(value)}
  defp wrap(error, _fun), do: error

  @doc "Encodes an expression to its portable form."
  @spec to_portable(t()) :: map()
  def to_portable({:input, name, path}), do: with_path(%{"input" => name}, path)
  def to_portable({:result, id, path}), do: with_path(%{"result" => id}, path)

  def to_portable({:loop, field, of, path}),
    do: with_path(%{"loop" => Atom.to_string(field), "of" => of}, path)

  def to_portable({:secret, name}), do: %{"secret" => name}
  def to_portable({:value, value}), do: %{"value" => value}

  def to_portable({:object, fields}),
    do: %{"object" => Map.new(fields, fn {key, expr} -> {key, to_portable(expr)} end)}

  def to_portable({:list, items}), do: %{"list" => Enum.map(items, &to_portable/1)}

  defp with_path(map, []), do: map
  defp with_path(map, path), do: Map.put(map, "path", path)

  @doc "Lists every reference used by an expression."
  @spec refs(t()) :: [{:input | :result | :loop | :secret, String.t()}]
  def refs({:input, name, _path}), do: [{:input, name}]
  def refs({:result, id, _path}), do: [{:result, id}]
  def refs({:loop, _field, of, _path}), do: [{:loop, of}]
  def refs({:secret, name}), do: [{:secret, name}]
  def refs({:value, _value}), do: []
  def refs({:object, fields}), do: Enum.flat_map(fields, fn {_key, expr} -> refs(expr) end)
  def refs({:list, items}), do: Enum.flat_map(items, &refs/1)

  @doc "Result node ids referenced by an expression."
  @spec result_ids(t()) :: [String.t()]
  def result_ids(expr), do: for({:result, id} <- refs(expr), uniq: true, do: id)

  @doc """
  Evaluates an expression. Missing paths produce `:invalid_reference` errors
  naming the reference and the missing segment.
  """
  @spec evaluate(t(), env()) :: {:ok, term()} | {:error, Error.t()}
  def evaluate({:input, name, path}, env),
    do:
      fetch_root(env.inputs, name, "input #{inspect(name)}")
      |> select(path, "input #{inspect(name)}")

  def evaluate({:result, id, path}, env),
    do:
      fetch_root(env.results, id, "result of #{inspect(id)}")
      |> select(path, "result of #{inspect(id)}")

  def evaluate({:loop, field, of, path}, env) do
    label = "loop #{field} of #{inspect(of)}"

    case Map.fetch(env.loops, of) do
      {:ok, frame} -> select({:ok, Map.fetch!(frame, field)}, path, label)
      :error -> reference_error("#{label} is not available here", %{"loop" => of})
    end
  end

  def evaluate({:secret, name}, env) do
    case Map.fetch(env.secrets, name) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        reference_error("secret #{inspect(name)} was not provided by the host", %{
          "secret" => name
        })
    end
  end

  def evaluate({:value, value}, _env), do: {:ok, value}

  def evaluate({:object, fields}, env) do
    fields
    |> Enum.sort()
    |> reduce_ok([], fn {key, expr}, acc ->
      with {:ok, value} <- evaluate(expr, env), do: {:ok, [{key, value} | acc]}
    end)
    |> wrap(&Map.new/1)
  end

  def evaluate({:list, items}, env) do
    items
    |> reduce_ok([], fn expr, acc ->
      with {:ok, value} <- evaluate(expr, env), do: {:ok, [value | acc]}
    end)
    |> wrap(&Enum.reverse/1)
  end

  defp reduce_ok(items, acc, fun) do
    Enum.reduce_while(items, {:ok, acc}, fn item, {:ok, acc} ->
      case fun.(item, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp fetch_root(map, key, label) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> reference_error("#{label} is not available here", %{"ref" => key})
    end
  end

  defp select({:ok, value}, [], _label), do: {:ok, value}

  defp select({:ok, value}, [segment | rest], label) when is_map(value) and is_binary(segment) do
    case Map.fetch(value, segment) do
      {:ok, inner} -> select({:ok, inner}, rest, label)
      :error -> missing(label, segment, value)
    end
  end

  defp select({:ok, value}, [index | rest], label) when is_list(value) and is_integer(index) do
    case Enum.fetch(value, index) do
      {:ok, inner} -> select({:ok, inner}, rest, label)
      :error -> missing(label, index, value)
    end
  end

  defp select({:ok, value}, [segment | _rest], label), do: missing(label, segment, value)
  defp select(error, _path, _label), do: error

  defp missing(label, segment, value) do
    reference_error(
      "#{label} has no #{inspect(segment)} (value is #{PlainData.describe(value)})",
      %{"segment" => segment}
    )
  end

  defp reference_error(message, details),
    do: {:error, Error.new(:invalid_reference, message, details: details)}
end
