defmodule Troupe.Binary do
  @moduledoc """
  Erlang external term format for definitions.

  The encoded term is the canonical portable map (`Troupe.Definition.to_map/1`),
  not the struct, so no module names or atoms are embedded. Decoding uses
  `:erlang.binary_to_term/2` with `:safe` and then the same validation as
  JSON, rejecting PIDs, references, functions and other non-plain terms.
  """

  alias Troupe.{Definition, Error}

  @doc "Encodes a definition deterministically."
  @spec encode(Definition.t()) :: binary()
  def encode(%Definition{} = definition) do
    definition
    |> Definition.to_map()
    |> :erlang.term_to_binary([:deterministic])
  end

  @doc "Decodes and validates a term binary."
  @spec decode(binary()) :: {:ok, Definition.t()} | {:error, [Error.t()]}
  def decode(binary) when is_binary(binary) do
    binary
    |> :erlang.binary_to_term([:safe])
    |> Definition.from_map()
  rescue
    ArgumentError ->
      {:error,
       [
         Error.new(
           :decode_failed,
           "not a safe Erlang term binary (corrupt, or it references atoms unknown to this node)"
         )
       ]}
  end
end
