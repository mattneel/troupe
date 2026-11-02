defmodule Troupe.Capability.Spec do
  @moduledoc "Compile-time description of an installed capability."

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          description: String.t() | nil,
          inputs: [Troupe.Definition.Input.t()],
          output: Troupe.Definition.Input.type(),
          module: module()
        }

  @enforce_keys [:name, :version, :module]
  defstruct [:name, :version, :description, :module, inputs: [], output: :any]

  @doc "Portable catalog entry (no module names) for tools and UIs."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = spec) do
    %{
      "name" => spec.name,
      "version" => spec.version,
      "description" => spec.description,
      "output" => Atom.to_string(spec.output),
      "inputs" =>
        Enum.map(spec.inputs, fn input ->
          %{
            "name" => input.name,
            "type" => Atom.to_string(input.type),
            "required" => input.required,
            "default" => input.default
          }
        end)
    }
  end
end

defmodule Troupe.Capability.Context do
  @moduledoc """
  Identity of the attempt being executed.

    * `node_id` — stable definition identity (same in every loop iteration)
    * `activation_id` — one execution of a node within a run, e.g.
      `"agent[2]/think"`; loop iterations and branch scopes produce distinct
      activations of the same node
    * `attempt` / `attempt_id` — one try of an activation (`"agent[2]/think@1"`)
    * `idempotency_key` — `"<run_id>/<activation_id>"`, identical for every
      attempt of an activation, including attempts in a restarted process
  """

  @type t :: %__MODULE__{
          run_id: String.t(),
          node_id: String.t(),
          activation_id: String.t(),
          attempt: pos_integer(),
          attempt_id: String.t(),
          idempotency_key: String.t()
        }

  @enforce_keys [:run_id, :node_id, :activation_id, :attempt, :attempt_id, :idempotency_key]
  defstruct @enforce_keys
end

defmodule Troupe.Capability do
  @moduledoc """
  Behaviour and macro for trusted, installed action implementations.

  Workflows refer to capabilities only by name and version requirement; the
  host decides which modules are installed (`Troupe.Registry`) and which may
  run (`Troupe.Grant`).

      defmodule MyApp.Capabilities.Upcase do
        use Troupe.Capability,
          name: "text.upcase",
          version: "1.0.0",
          description: "Uppercases text.",
          inputs: [text: :string],
          output: :string

        @impl true
        def run(%{"text" => text}, _context), do: {:ok, String.upcase(text)}
      end

  `inputs` is a keyword list of `name: type` or `name: [type: t, required:
  false, default: value]`. Arguments arrive with string keys, already
  validated. Results must be plain data matching `output`.

  ## Side effects

  Troupe checkpoints a result only after `run/2` returns. If the process dies
  in between, the action runs again on resume (at-least-once). Use
  `context.idempotency_key` — stable across retries and restarts for one
  activation — to deduplicate external effects, and implement `reconcile/2`
  to report work that already happened.
  """

  alias Troupe.Capability.{Context, Spec}
  alias Troupe.Definition.Input

  @typedoc """
  Results should be plain data (`t:Troupe.PlainData.t/0`) of the declared
  output type. The runtime checks this and fails the attempt with
  `:invalid_result` otherwise, so the type is deliberately `term()`.
  """
  @type result :: {:ok, term()} | {:error, term()} | {:retry, term()}

  @doc "Performs the action. `{:retry, reason}` asks for another attempt if the node allows one."
  @callback run(args :: map(), context :: Context.t()) :: result()

  @doc """
  Called before re-running an activation whose earlier attempt started but was
  never checkpointed. Return `{:ok, result}` if the external effect is known to
  have completed, or `:unknown` to run the action again.
  """
  @callback reconcile(args :: map(), context :: Context.t()) ::
              {:ok, Troupe.PlainData.t()} | :unknown

  @optional_callbacks reconcile: 2

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Troupe.Capability
      @troupe_capability Troupe.Capability.build_spec!(__MODULE__, opts)

      @doc false
      def __troupe_capability__, do: @troupe_capability
    end
  end

  @doc false
  @spec build_spec!(module(), keyword()) :: Spec.t()
  def build_spec!(module, opts) do
    name = Keyword.fetch!(opts, :name)
    version = Keyword.fetch!(opts, :version)

    unless is_binary(name) and Regex.match?(~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$/, name) do
      raise ArgumentError, "#{inspect(module)}: invalid capability name #{inspect(name)}"
    end

    unless is_binary(version) and match?({:ok, _}, Version.parse(version)) do
      raise ArgumentError,
            "#{inspect(module)}: capability version must be semver, got #{inspect(version)}"
    end

    %Spec{
      name: name,
      version: version,
      description: Keyword.get(opts, :description),
      inputs: opts |> Keyword.get(:inputs, []) |> Enum.map(&input_spec!(module, &1)),
      output: type!(module, Keyword.get(opts, :output, :any)),
      module: module
    }
  end

  defp input_spec!(module, {name, type}) when is_atom(type),
    do: input_spec!(module, {name, [type: type]})

  defp input_spec!(module, {name, opts}) when is_atom(name) and is_list(opts) do
    %Input{
      name: Atom.to_string(name),
      type: type!(module, Keyword.fetch!(opts, :type)),
      required: Keyword.get(opts, :required, not Keyword.has_key?(opts, :default)),
      default: Keyword.get(opts, :default),
      description: Keyword.get(opts, :description)
    }
  end

  defp type!(module, type) do
    if type in [:string, :integer, :number, :boolean, :map, :list, :any],
      do: type,
      else: raise(ArgumentError, "#{inspect(module)}: unknown type #{inspect(type)}")
  end
end
