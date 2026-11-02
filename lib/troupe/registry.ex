defmodule Troupe.Registry do
  @moduledoc """
  The host's set of trusted, installed capabilities.

  A registry is built from modules the host chooses (`use Troupe.Capability`).
  Definitions reference `name` + version requirement; `resolve/2` picks the
  highest installed version satisfying the requirement. Nothing in a
  definition can add modules to a registry.
  """

  alias Troupe.Capability.Spec
  alias Troupe.Definition
  alias Troupe.Definition.{Action, CapabilityRef, Scope}
  alias Troupe.{Error, PlainData, Schema}

  @type t :: %__MODULE__{capabilities: %{String.t() => [Spec.t()]}}

  defstruct capabilities: %{}

  @doc "Builds a registry from capability modules."
  @spec new([module()]) :: {:ok, t()} | {:error, String.t()}
  def new(modules) when is_list(modules) do
    with {:ok, specs} <- specs(modules) do
      duplicates =
        specs
        |> Enum.frequencies_by(&{&1.name, &1.version})
        |> Enum.filter(fn {_key, count} -> count > 1 end)

      case duplicates do
        [] ->
          {:ok,
           %__MODULE__{
             capabilities: specs |> Enum.group_by(& &1.name) |> Map.new(&newest_first/1)
           }}

        [{{name, version}, _count} | _rest] ->
          {:error, "capability #{name}@#{version} is installed more than once"}
      end
    end
  end

  defp newest_first({name, specs}),
    do: {name, Enum.sort_by(specs, &Version.parse!(&1.version), {:desc, Version})}

  @doc "Like `new/1`, raising `ArgumentError`."
  @spec new!([module()]) :: t()
  def new!(modules) do
    case new(modules) do
      {:ok, registry} -> registry
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc "Registry of the capabilities shipped with Troupe (`Troupe.Capabilities`)."
  @spec standard() :: t()
  def standard, do: new!(Troupe.Capabilities.modules())

  @doc "Adds more capability modules."
  @spec merge(t(), [module()]) :: {:ok, t()} | {:error, String.t()}
  def merge(%__MODULE__{} = registry, modules) do
    new(Enum.map(all(registry), & &1.module) ++ modules)
  end

  defp specs(modules) do
    Enum.reduce_while(modules, {:ok, []}, fn module, {:ok, acc} ->
      if Code.ensure_loaded?(module) and function_exported?(module, :__troupe_capability__, 0) do
        {:cont, {:ok, [module.__troupe_capability__() | acc]}}
      else
        {:halt, {:error, "#{inspect(module)} is not a Troupe capability (use Troupe.Capability)"}}
      end
    end)
  end

  @doc "All installed capability specs, sorted by name then version."
  @spec all(t()) :: [Spec.t()]
  def all(%__MODULE__{capabilities: capabilities}) do
    capabilities
    |> Enum.sort()
    |> Enum.flat_map(fn {_name, specs} -> Enum.reverse(specs) end)
  end

  @doc "Plain-data catalog for agents, tools and the playground."
  @spec catalog(t()) :: [map()]
  def catalog(registry), do: registry |> all() |> Enum.map(&Spec.to_map/1)

  @doc "Resolves a capability reference to the highest matching installed version."
  @spec resolve(t(), CapabilityRef.t()) :: {:ok, Spec.t()} | {:error, Error.t()}
  def resolve(%__MODULE__{capabilities: capabilities}, %CapabilityRef{
        name: name,
        version: requirement
      }) do
    installed = Map.get(capabilities, name, [])

    case Enum.find(installed, &Version.match?(&1.version, requirement)) do
      %Spec{} = spec ->
        {:ok, spec}

      nil when installed == [] ->
        {:error,
         Error.new(:unknown_capability, "capability #{inspect(name)} is not installed",
           details: %{
             "capability" => name,
             "installed" => capabilities |> Map.keys() |> Enum.sort()
           }
         )}

      nil ->
        {:error,
         Error.new(
           :unknown_capability,
           "no installed version of #{inspect(name)} satisfies #{inspect(requirement)}",
           details: %{
             "capability" => name,
             "requirement" => requirement,
             "installed" => Enum.map(installed, & &1.version)
           }
         )}
    end
  end

  @doc """
  Resolves every action in a definition and checks its arguments against the
  capability's declared inputs (names, required fields and literal types).
  Does not consider permission; see `Troupe.Grant.authorize/2`.
  """
  @spec resolve_definition(t(), Definition.t()) ::
          {:ok, %{String.t() => Spec.t()}} | {:error, [Error.t()]}
  def resolve_definition(%__MODULE__{} = registry, %Definition{} = definition) do
    {resolved, errors} =
      definition
      |> Scope.walk()
      |> Enum.reduce({%{}, []}, fn
        {%Action{} = action, _list, pointer}, {resolved, errors} ->
          case resolve(registry, action.capability) do
            {:ok, spec} ->
              {Map.put(resolved, action.id, spec), errors ++ arg_errors(action, spec, pointer)}

            {:error, error} ->
              {resolved, errors ++ [%{error | path: pointer <> "/capability"}]}
          end

        _composite, acc ->
          acc
      end)

    if errors == [], do: {:ok, resolved}, else: {:error, errors}
  end

  defp arg_errors(%Action{args: args, capability: ref}, %Spec{inputs: inputs}, pointer) do
    known = Map.new(inputs, &{&1.name, &1})
    label = "#{ref.name}@#{ref.version}"

    unknown =
      for key <- args |> Map.keys() |> Enum.sort(), not Map.has_key?(known, key) do
        Error.new(
          :invalid_arguments,
          "#{label} has no input #{inspect(key)}; inputs are #{inspect(Map.keys(known) |> Enum.sort())}",
          path: "#{pointer}/args/#{key}"
        )
      end

    missing =
      for %{name: name, required: true} <- inputs, not Map.has_key?(args, name) do
        Error.new(:invalid_arguments, "#{label} requires input #{inspect(name)}",
          path: "#{pointer}/args"
        )
      end

    literal =
      for {key, {:value, value}} <- Enum.sort(args),
          %{type: type} <- [known[key]],
          not Schema.type?(value, type) do
        Error.new(
          :invalid_arguments,
          "#{label} input #{inspect(key)} must be #{type}, got #{PlainData.describe(value)}",
          path: "#{pointer}/args/#{key}"
        )
      end

    unknown ++ missing ++ literal
  end
end
