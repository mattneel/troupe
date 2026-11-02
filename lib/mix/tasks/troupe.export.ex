defmodule Mix.Tasks.Troupe.Export do
  @shortdoc "Exports a Spark-authored workflow as canonical JSON"
  @moduledoc """
  Prints (or writes) the canonical JSON of a `Troupe.Workflow` module.

      mix troupe.export Troupe.Examples.Greeting
      mix troupe.export Troupe.Examples.Greeting --out examples/greeting.json
      mix troupe.export Troupe.Examples.Greeting --format etf --out greeting.etf
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: [out: :string, format: :string])
    Mix.Task.run("compile")

    args
    |> workflow!()
    |> encode!(Keyword.get(opts, :format, "json"))
    |> write(opts[:out])
  end

  defp workflow!([name]) do
    module = Module.concat([name])

    if Code.ensure_loaded?(module) and function_exported?(module, :definition, 0),
      do: module.definition(),
      else: Mix.raise("#{inspect(module)} is not a Troupe.Workflow module")
  end

  defp workflow!(_args),
    do: Mix.raise("usage: mix troupe.export MODULE [--out PATH] [--format json|etf]")

  defp encode!(definition, "json"), do: Troupe.JSON.encode(definition) <> "\n"
  defp encode!(definition, "etf"), do: Troupe.Binary.encode(definition)

  defp encode!(_definition, other),
    do: Mix.raise("unknown --format #{inspect(other)}; use json or etf")

  defp write(data, nil), do: IO.binwrite(data)

  defp write(data, path) do
    File.write!(path, data)
    Mix.shell().info("wrote #{path}")
  end
end
