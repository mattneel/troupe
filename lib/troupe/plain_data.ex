defmodule Troupe.PlainData do
  @moduledoc """
  JSON-compatible plain data: `nil`, booleans, UTF-8 strings, integers, floats,
  lists and maps with string keys.

  Everything that crosses a portability boundary — definitions, workflow
  inputs, action results and stored payloads — must be plain data. Module
  names (atoms), closures, PIDs, ports, references (including ETS table ids)
  and tuples are rejected with the location of the offending value.
  """

  alias Troupe.Error

  @type t :: nil | boolean() | String.t() | number() | [t()] | %{optional(String.t()) => t()}

  @secret_key ~r/(pass(word|wd|phrase)?|secret|token|api[_-]?key|private[_-]?key|credential|auth(orization)?)$/i

  @doc "Checks that `value` is plain data; `pointer` locates it in error messages."
  @spec check(term(), String.t()) :: :ok | {:error, [Error.t()]}
  def check(value, pointer \\ "") do
    case problems(value, pointer, []) do
      [] -> :ok
      problems -> {:error, Enum.reverse(problems)}
    end
  end

  @doc """
  Checks a literal embedded in a definition: plain data that also does not
  look like an inline secret. Use `{"secret": "NAME"}` references instead.
  """
  @spec check_literal(term(), String.t()) :: :ok | {:error, [Error.t()]}
  def check_literal(value, pointer) do
    with :ok <- check(value, pointer) do
      case secret_keys(value, pointer, []) do
        [] -> :ok
        problems -> {:error, Enum.reverse(problems)}
      end
    end
  end

  @doc "True when `value` is plain data."
  @spec plain?(term()) :: boolean()
  def plain?(value), do: problems(value, "", []) == []

  defp problems(value, _pointer, acc)
       when is_nil(value) or is_boolean(value) or is_number(value),
       do: acc

  defp problems(value, pointer, acc) when is_binary(value) do
    if String.valid?(value),
      do: acc,
      else: [error(pointer, "binary is not valid UTF-8 text") | acc]
  end

  defp problems(value, pointer, acc) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {item, index}, acc -> problems(item, "#{pointer}/#{index}", acc) end)
  end

  defp problems(value, pointer, acc) when is_map(value) and not is_struct(value) do
    Enum.reduce(value, acc, fn
      {key, item}, acc when is_binary(key) -> problems(item, "#{pointer}/#{key}", acc)
      {key, _item}, acc -> [error(pointer, "map key #{describe(key)} is not a string") | acc]
    end)
  end

  defp problems(value, pointer, acc),
    do: [error(pointer, "#{describe(value)} is not portable plain data") | acc]

  defp secret_keys(value, pointer, acc) when is_map(value) do
    Enum.reduce(value, acc, fn {key, item}, acc ->
      acc =
        if Regex.match?(@secret_key, key) and item not in [nil, ""],
          do: [secret_error("#{pointer}/#{key}", key) | acc],
          else: acc

      secret_keys(item, "#{pointer}/#{key}", acc)
    end)
  end

  defp secret_keys(value, pointer, acc) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {item, index}, acc -> secret_keys(item, "#{pointer}/#{index}", acc) end)
  end

  defp secret_keys(_value, _pointer, acc), do: acc

  defp error(pointer, message), do: Error.new(:not_plain_data, message, path: pointer)

  defp secret_error(pointer, key) do
    Error.new(
      :possible_secret,
      "literal key #{inspect(key)} looks like a secret; pass it with {\"secret\": \"NAME\"} at run time instead of embedding it",
      path: pointer
    )
  end

  @doc "Short, non-revealing description of a value's type for error messages."
  @spec describe(term()) :: String.t()
  def describe(nil), do: "null"
  def describe(value) when is_boolean(value), do: "a boolean"
  def describe(value) when is_binary(value), do: "a string"
  def describe(value) when is_integer(value), do: "an integer"
  def describe(value) when is_float(value), do: "a float"
  def describe(value) when is_list(value), do: "a list"
  def describe(value) when is_struct(value), do: "a struct (#{inspect(value.__struct__)})"
  def describe(value) when is_map(value), do: "an object"
  def describe(value) when is_atom(value), do: "the atom #{inspect(value)}"
  def describe(value) when is_function(value), do: "a function"
  def describe(value) when is_pid(value), do: "a process id"
  def describe(value) when is_port(value), do: "a port"
  def describe(value) when is_reference(value), do: "a reference (e.g. an ETS table id)"
  def describe(value) when is_tuple(value), do: "a tuple"
  def describe(_value), do: "an unsupported value"
end
