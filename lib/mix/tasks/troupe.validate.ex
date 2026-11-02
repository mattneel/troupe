defmodule Mix.Tasks.Troupe.Validate do
  @shortdoc "Validates a workflow JSON file"
  @moduledoc """
  Decodes and validates a JSON workflow, then checks it against the standard
  capability registry. Prints every problem with its JSON pointer and exits
  non-zero on failure. Validation never grants permission to run.

      mix troupe.validate examples/sqrt_newton.json
  """

  use Mix.Task

  alias Troupe.Tasks

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    path =
      case argv do
        [path] -> path
        _other -> Mix.raise("usage: mix troupe.validate PATH")
      end

    definition = Tasks.load!(path)
    Tasks.ok!(Troupe.check(definition))

    caps =
      definition
      |> Troupe.Definition.capabilities()
      |> Enum.map_join(", ", &"#{&1.name}@#{&1.version}")

    Mix.shell().info("valid: #{definition.id}@#{definition.version} (capabilities: #{caps})")
  end
end
