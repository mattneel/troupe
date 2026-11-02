defmodule Troupe.Examples do
  @moduledoc """
  Example workflows with sample inputs and the grants they need. Spark
  examples are `Troupe.Workflow` modules; JSON examples are read from
  `examples/*.json` at compile time, so they ship inside the Popcorn bundle.
  """

  alias Troupe.Definition

  @json_dir Path.expand("../../examples", __DIR__)

  @examples [
    %{
      "id" => "greeting",
      "title" => "Greeting (Spark DSL, two dependent actions)",
      "source" => "spark",
      "inputs" => %{"name" => "Ada"},
      "grant" => ["text.*"]
    },
    %{
      "id" => "calculator_agent",
      "title" => "ReAct-style calculator agent (Spark DSL, loop + branch)",
      "source" => "spark",
      "inputs" => %{
        "start" => 3,
        "plan" => [%{"tool" => "add", "operand" => 4}, %{"tool" => "multiply", "operand" => 5}],
        "keep" => 3
      },
      "grant" => ["agent.*", "list.*", "math.*"]
    },
    %{
      "id" => "sqrt_newton",
      "title" => "Square root by Newton's method (JSON, loop until converged)",
      "source" => "json",
      "inputs" => %{"n" => 2},
      "grant" => ["math.*"]
    },
    %{
      "id" => "ticket_triage",
      "title" => "Support ticket triage (JSON, branch)",
      "source" => "json",
      "inputs" => %{"text" => "URGENT: checkout is failing"},
      "grant" => ["text.*"]
    }
  ]

  @spark %{
    "greeting" => Troupe.Examples.Greeting,
    "calculator_agent" => Troupe.Examples.CalculatorAgent
  }

  for %{"id" => id} <- @examples do
    @external_resource Path.join(@json_dir, id <> ".json")
  end

  @json Map.new(@examples, fn %{"id" => id} ->
          {id, File.read!(Path.join(@json_dir, id <> ".json"))}
        end)

  @doc "Example metadata: id, title, source (`spark` or `json`), sample inputs and grant patterns."
  @spec all() :: [map()]
  def all, do: @examples

  @doc "The JSON text of an example as shipped in `examples/`."
  @spec json(String.t()) :: String.t()
  def json(id), do: Map.fetch!(@json, id)

  @spark_dir Path.expand("examples", __DIR__)

  for {id, _module} <- @spark do
    @external_resource Path.join(@spark_dir, id <> ".ex")
  end

  @sources Map.new(@spark, fn {id, _module} ->
             {id, File.read!(Path.join(@spark_dir, id <> ".ex"))}
           end)

  @doc """
  Elixir DSL source of an example: the real module file for `spark`
  examples, otherwise rendered from the JSON by `Troupe.Workflow.Source`.
  """
  @spec source(String.t()) :: String.t()
  def source(id) do
    case Map.fetch(@sources, id) do
      {:ok, source} -> source
      :error -> Troupe.Workflow.Source.to_source(definition(id))
    end
  end

  @doc """
  The definition of an example: from its Spark module for `spark` examples,
  otherwise decoded from its JSON file.
  """
  @spec definition(String.t()) :: Definition.t()
  def definition(id) do
    case Map.fetch(@spark, id) do
      {:ok, module} -> module.definition()
      :error -> Troupe.JSON.decode!(json(id))
    end
  end
end
