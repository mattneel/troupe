defmodule Troupe.Grant do
  @moduledoc """
  Explicit execution permission, supplied by the host at run time.

  Authoring, importing or validating a definition never grants anything:
  `Troupe.run/3` refuses to start unless every capability the definition
  uses is allowed by the grant passed in. Patterns are exact capability names
  (`"text.upcase"`) or namespace wildcards (`"math.*"`).

      grant = Troupe.Grant.new!(["text.upcase", "math.*"])
  """

  alias Troupe.Capability.Spec
  alias Troupe.Error

  @type t :: %__MODULE__{allow: [String.t()]}

  defstruct allow: []

  @pattern ~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*(\.\*)?$/

  @doc "A grant that allows nothing."
  @spec none() :: t()
  def none, do: %__MODULE__{}

  @doc "Builds a grant from capability name patterns."
  @spec new([String.t()]) :: {:ok, t()} | {:error, Error.t()}
  def new(patterns) when is_list(patterns) do
    case Enum.reject(patterns, &(is_binary(&1) and Regex.match?(@pattern, &1))) do
      [] ->
        {:ok, %__MODULE__{allow: patterns |> Enum.uniq() |> Enum.sort()}}

      bad ->
        {:error,
         Error.new(
           :not_granted,
           "invalid grant patterns #{inspect(bad)}; use names like \"text.upcase\" or \"math.*\""
         )}
    end
  end

  @doc "Like `new/1`, raising on invalid patterns."
  @spec new!([String.t()]) :: t()
  def new!(patterns) do
    case new(patterns) do
      {:ok, grant} -> grant
      {:error, error} -> raise error
    end
  end

  @doc "Does the grant allow the named capability?"
  @spec allows?(t(), String.t()) :: boolean()
  def allows?(%__MODULE__{allow: allow}, name) do
    Enum.any?(allow, fn pattern ->
      case String.split(pattern, ".*", parts: 2) do
        [prefix, ""] -> String.starts_with?(name, prefix <> ".")
        [exact] -> exact == name
      end
    end)
  end

  @doc """
  Checks resolved capabilities (node id => spec) against the grant and lists
  every capability that is not allowed.
  """
  @spec authorize(t(), %{String.t() => Spec.t()}) :: :ok | {:error, [Error.t()]}
  def authorize(%__MODULE__{} = grant, resolved) do
    denied =
      resolved
      |> Enum.reject(fn {_node, spec} -> allows?(grant, spec.name) end)
      |> Enum.group_by(fn {_node, spec} -> spec.name end, fn {node, _spec} -> node end)
      |> Enum.sort()

    case denied do
      [] ->
        :ok

      denied ->
        {:error,
         Enum.map(denied, fn {name, nodes} ->
           Error.new(
             :not_granted,
             "capability #{inspect(name)} (used by #{Enum.map_join(Enum.sort(nodes), ", ", &inspect/1)}) is not granted; pass it in grant: Troupe.Grant.new!([...])",
             details: %{"capability" => name, "nodes" => Enum.sort(nodes)}
           )
         end)}
    end
  end
end
