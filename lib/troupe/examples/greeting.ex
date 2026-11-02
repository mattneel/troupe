defmodule Troupe.Examples.Greeting do
  @moduledoc """
  Spark-authored example: two dependent actions. Its JSON twin is
  `examples/greeting.json`; both decode to the same `Troupe.Definition`.
  """

  use Troupe.Workflow

  workflow do
    id("greeting")
    version("1.0.0")
    description "Shouts a name and greets it."
    inputs(name: :string, punctuation: [type: :string, required: false, default: "!"])
    output(result(:greet))

    action :shout, "text.upcase", "~> 1.0" do
      arg(:text, input(:name))
    end

    action :greet, "text.template", "~> 1.0" do
      arg(:template, value("Hello, {{name}}{{punctuation}}"))
      arg(:vars, object(name: result(:shout), punctuation: input(:punctuation)))
    end
  end
end
