defmodule Troupe.Schema do
  @moduledoc """
  Minimal, dependency-free type checks shared by workflow inputs and
  capability argument/result declarations. Pure Elixir so it runs unchanged
  in the Popcorn browser VM.

  Types: `string`, `integer`, `number`, `boolean`, `map`, `list`, `any`.
  """

  alias Troupe.Definition.Input
  alias Troupe.{Error, PlainData}

  @types %{
    "string" => :string,
    "integer" => :integer,
    "number" => :number,
    "boolean" => :boolean,
    "map" => :map,
    "list" => :list,
    "any" => :any
  }

  @doc "All type names."
  @spec type_names() :: [String.t()]
  def type_names, do: @types |> Map.keys() |> Enum.sort()

  @doc "Parses a type name."
  @spec parse_type(term()) :: {:ok, Input.type()} | :error
  def parse_type(name) when is_binary(name), do: Map.fetch(@types, name)
  def parse_type(_name), do: :error

  @doc "Does `value` have `type`?"
  @spec type?(term(), Input.type()) :: boolean()
  def type?(_value, :any), do: true
  def type?(value, :string), do: is_binary(value)
  def type?(value, :integer), do: is_integer(value)
  def type?(value, :number), do: is_number(value)
  def type?(value, :boolean), do: is_boolean(value)
  def type?(value, :map), do: is_map(value) and not is_struct(value)
  def type?(value, :list), do: is_list(value)

  @doc """
  Validates a map of named values against field specs, applying defaults to
  absent optional fields. `label` names the fields in messages ("input",
  "argument"); errors use `kind`.
  """
  @spec validate_fields(term(), [Input.t()], String.t(), Error.kind()) ::
          {:ok, map()} | {:error, [Error.t()]}
  def validate_fields(values, specs, label, kind) when is_map(values) do
    known = MapSet.new(specs, & &1.name)

    unknown =
      for key <- values |> Map.keys() |> Enum.sort(), not MapSet.member?(known, key) do
        Error.new(kind, "unknown #{label} #{inspect(key)}",
          path: "/#{key}",
          details: %{"known" => Enum.sort(MapSet.to_list(known))}
        )
      end

    {normalized, errors} =
      Enum.reduce(specs, {%{}, unknown}, fn spec, {acc, errors} ->
        case check_field(values, spec, label, kind) do
          {:ok, value} -> {Map.put(acc, spec.name, value), errors}
          {:error, error} -> {acc, errors ++ [error]}
        end
      end)

    plain_errors =
      case PlainData.check(values) do
        :ok -> []
        {:error, problems} -> Enum.map(problems, &%{&1 | kind: kind})
      end

    case errors ++ plain_errors do
      [] -> {:ok, normalized}
      errors -> {:error, errors}
    end
  end

  def validate_fields(values, _specs, label, kind),
    do:
      {:error,
       [Error.new(kind, "#{label}s must be an object, got #{PlainData.describe(values)}")]}

  defp check_field(values, %Input{name: name} = spec, label, kind) do
    case Map.fetch(values, name) do
      {:ok, value} ->
        if type?(value, spec.type),
          do: {:ok, value},
          else:
            {:error,
             Error.new(
               kind,
               "#{label} #{inspect(name)} must be #{spec.type}, got #{PlainData.describe(value)}",
               path: "/#{name}"
             )}

      :error when spec.required ->
        {:error, Error.new(kind, "missing required #{label} #{inspect(name)}", path: "/#{name}")}

      :error ->
        {:ok, spec.default}
    end
  end
end
