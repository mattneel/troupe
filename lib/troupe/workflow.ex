defmodule Troupe.Workflow do
  @moduledoc """
  Spark DSL for authoring workflows in Elixir.

      defmodule MyApp.Greeting do
        use Troupe.Workflow

        workflow do
          id "greeting"
          version "1.0.0"
          inputs name: :string
          output result(:greet)

          action :shout, "text.upcase", "~> 1.0" do
            arg :text, input(:name)
          end

          action :greet, "text.template", "~> 1.0" do
            arg :template, value("Hello, {{name}}!")
            arg :vars, object(name: result(:shout))
          end
        end
      end

      MyApp.Greeting.definition()
      #=> %Troupe.Definition{...}

  The DSL compiles to the portable map and is validated by
  `Troupe.Definition.from_map/1` at compile time, so a DSL module and its JSON
  export (`Troupe.JSON.encode(MyApp.Greeting.definition())`) are the same
  definition. Invalid workflows fail compilation with every problem listed.
  """

  use Spark.Dsl, default_extensions: [extensions: [Troupe.Workflow.Dsl]]

  @impl Spark.Dsl
  def handle_before_compile(_opts) do
    quote do
      @doc "The validated `Troupe.Definition` authored by this module."
      @spec definition() :: Troupe.Definition.t()
      def definition, do: Spark.Dsl.Extension.get_persisted(__MODULE__, :troupe_definition)
    end
  end
end
