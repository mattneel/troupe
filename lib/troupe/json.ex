defmodule Troupe.JSON do
  @moduledoc """
  Jason-based import/export of workflow definitions — the format agents and
  tools read and write.

      {:ok, definition} = Troupe.JSON.decode(File.read!("examples/greeting.json"))
      json = Troupe.JSON.encode(definition)

  Decoding validates fully; it never resolves capabilities or grants
  permission to execute.
  """

  alias Troupe.{Definition, Error}

  @doc "Encodes a definition as canonical, pretty-printed JSON."
  @spec encode(Definition.t(), keyword()) :: String.t()
  def encode(%Definition{} = definition, opts \\ []) do
    definition
    |> Definition.to_map()
    |> Jason.encode!(pretty: Keyword.get(opts, :pretty, true))
  end

  @doc "Decodes and validates JSON text."
  @spec decode(String.t()) :: {:ok, Definition.t()} | {:error, [Error.t()]}
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} ->
        Definition.from_map(map)

      {:error, %Jason.DecodeError{} = error} ->
        {:error,
         [
           Error.new(:decode_failed, "invalid JSON: #{Exception.message(error)}",
             details: %{"position" => error.position}
           )
         ]}
    end
  end

  @doc "Like `decode/1` but raises `Troupe.Error` (the first problem) on failure."
  @spec decode!(String.t()) :: Definition.t()
  def decode!(json) do
    case decode(json) do
      {:ok, definition} -> definition
      {:error, [error | _rest]} -> raise error
    end
  end
end
