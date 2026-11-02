defmodule Troupe.Workflow.Dsl.Arg do
  @moduledoc false
  defstruct [:name, :value, :__identifier__, :__spark_metadata__]
end

defmodule Troupe.Workflow.Dsl.Action do
  @moduledoc false
  defstruct [
    :id,
    :capability,
    :version,
    :description,
    :__identifier__,
    :__spark_metadata__,
    max_attempts: 1,
    args: []
  ]
end

defmodule Troupe.Workflow.Dsl.Case do
  @moduledoc false
  defstruct [:value, :output, :__identifier__, :__spark_metadata__, steps: []]
end

defmodule Troupe.Workflow.Dsl.Branch do
  @moduledoc false
  defstruct [:id, :on, :description, :default, :__identifier__, :__spark_metadata__, cases: []]
end

defmodule Troupe.Workflow.Dsl.Loop do
  @moduledoc false
  defstruct [
    :id,
    :max_iterations,
    :state,
    :next_state,
    :until,
    :description,
    :__identifier__,
    :__spark_metadata__,
    steps: []
  ]
end

defmodule Troupe.Workflow.Dsl do
  @moduledoc false

  alias Spark.Dsl.{Entity, Section}
  alias Troupe.Workflow.{Dsl, Helpers}

  @expression [
    type: :any,
    required: true,
    doc: "An expression built with `Troupe.Workflow.Helpers`."
  ]

  @arg %Entity{
    name: :arg,
    describe: "Passes an expression to one capability input.",
    target: Dsl.Arg,
    args: [:name, :value],
    imports: [Helpers],
    schema: [
      name: [type: :atom, required: true, doc: "Capability input name."],
      value: @expression
    ]
  }

  @action %Entity{
    name: :action,
    describe: "Invokes a capability by name and version requirement.",
    target: Dsl.Action,
    args: [:id, :capability, :version],
    identifier: :id,
    imports: [Helpers],
    entities: [args: [@arg]],
    recursive_as: :steps,
    schema: [
      id: [type: :atom, required: true, doc: "Stable node id."],
      capability: [type: :string, required: true, doc: ~s(Capability name, e.g. "text.upcase".)],
      version: [type: :string, required: true, doc: ~s(Version requirement, e.g. "~> 1.0".)],
      max_attempts: [
        type: :pos_integer,
        default: 1,
        doc: "Attempts allowed when the capability asks to retry."
      ],
      description: [type: :string, doc: "Human description."]
    ]
  }

  @match %Entity{
    name: :match,
    describe: "Runs nested steps when the branch value equals `value`.",
    target: Dsl.Case,
    args: [:value],
    imports: [Helpers],
    entities: [steps: []],
    schema: [
      value: [type: :any, required: true, doc: "Literal compared with the branch value."],
      output: @expression
    ]
  }

  @default %Entity{
    name: :default,
    describe: "Runs nested steps when no match applies.",
    target: Dsl.Case,
    imports: [Helpers],
    entities: [steps: []],
    schema: [output: @expression]
  }

  @branch %Entity{
    name: :branch,
    describe: "Chooses one case by comparing `on` with each match value.",
    target: Dsl.Branch,
    args: [:id],
    identifier: :id,
    imports: [Helpers],
    entities: [cases: [@match], default: [@default]],
    singleton_entity_keys: [:default],
    recursive_as: :steps,
    schema: [
      id: [type: :atom, required: true, doc: "Stable node id."],
      on: @expression,
      description: [type: :string, doc: "Human description."]
    ]
  }

  @loop %Entity{
    name: :loop,
    describe: "Repeats nested steps, carrying only `state` between iterations.",
    target: Dsl.Loop,
    args: [:id],
    identifier: :id,
    imports: [Helpers],
    entities: [steps: []],
    recursive_as: :steps,
    schema: [
      id: [type: :atom, required: true, doc: "Stable node id."],
      max_iterations: [type: :pos_integer, required: true, doc: "Hard iteration limit."],
      state: [type: :any, required: true, doc: "Initial state expression."],
      next_state: [
        type: :any,
        required: true,
        doc: "State for the next iteration, evaluated in the body."
      ],
      until: [type: :any, doc: "Stops the loop when truthy, evaluated in the body."],
      description: [type: :string, doc: "Human description."]
    ]
  }

  @workflow %Section{
    name: :workflow,
    describe: "A portable Troupe workflow definition.",
    imports: [Helpers],
    schema: [
      id: [type: :string, required: true, doc: "Workflow id."],
      version: [type: :string, required: true, doc: "Workflow semantic version."],
      description: [type: :string, doc: "Human description."],
      inputs: [
        type: :keyword_list,
        default: [],
        doc:
          "Inputs as `name: type` or `name: [type: t, required: false, default: v, description: d]`."
      ],
      output: @expression
    ],
    entities: [@action, @branch, @loop]
  }

  use Spark.Dsl.Extension, sections: [@workflow], transformers: [Dsl.Build]
end

defmodule Troupe.Workflow.Dsl.Build do
  @moduledoc false
  # Converts DSL entities to the portable map and validates it with
  # Troupe.Definition.from_map/1 — the same path JSON imports take.

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError
  alias Troupe.Definition
  alias Troupe.Workflow.Dsl

  @impl true
  def transform(dsl_state) do
    portable = to_portable(dsl_state)

    case Definition.from_map(portable) do
      {:ok, definition} ->
        {:ok, Transformer.persist(dsl_state, :troupe_definition, definition)}

      {:error, errors} ->
        {:error,
         DslError.exception(
           module: Transformer.get_persisted(dsl_state, :module),
           path: [:workflow],
           message:
             "invalid workflow:\n" <>
               Enum.map_join(errors, "\n", &("  * " <> Exception.message(&1)))
         )}
    end
  end

  defp to_portable(dsl_state) do
    option = &Transformer.get_option(dsl_state, [:workflow], &1)

    %{
      "schema_version" => Definition.schema_version(),
      "id" => option.(:id),
      "version" => option.(:version),
      "inputs" => Enum.map(option.(:inputs) || [], &input/1),
      "nodes" => dsl_state |> Transformer.get_entities([:workflow]) |> Enum.map(&node_map/1),
      "output" => option.(:output)
    }
    |> put_optional("description", option.(:description))
  end

  defp input({name, type}) when is_atom(type), do: input({name, [type: type]})

  defp input({name, opts}) do
    %{"name" => Atom.to_string(name), "type" => opts |> Keyword.fetch!(:type) |> Atom.to_string()}
    |> put_optional("required", Keyword.get(opts, :required))
    |> put_optional("default", Keyword.get(opts, :default))
    |> put_optional("description", Keyword.get(opts, :description))
  end

  defp node_map(%Dsl.Action{} = action) do
    %{
      "id" => Atom.to_string(action.id),
      "kind" => "action",
      "capability" => %{"name" => action.capability, "version" => action.version},
      "args" => Map.new(action.args, &{Atom.to_string(&1.name), &1.value}),
      "max_attempts" => action.max_attempts
    }
    |> put_optional("description", action.description)
  end

  defp node_map(%Dsl.Branch{} = branch) do
    %{
      "id" => Atom.to_string(branch.id),
      "kind" => "branch",
      "on" => branch.on,
      "cases" => Enum.map(branch.cases, &Map.put(case_map(&1), "match", &1.value))
    }
    |> put_optional("default", branch.default && case_map(branch.default))
    |> put_optional("description", branch.description)
  end

  defp node_map(%Dsl.Loop{} = loop) do
    %{
      "id" => Atom.to_string(loop.id),
      "kind" => "loop",
      "max_iterations" => loop.max_iterations,
      "state" => loop.state,
      "nodes" => Enum.map(loop.steps, &node_map/1),
      "next_state" => loop.next_state
    }
    |> put_optional("until", loop.until)
    |> put_optional("description", loop.description)
  end

  defp case_map(%Dsl.Case{} = branch_case),
    do: %{"nodes" => Enum.map(branch_case.steps, &node_map/1), "output" => branch_case.output}

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
