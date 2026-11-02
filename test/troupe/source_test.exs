defmodule Troupe.SourceTest do
  use ExUnit.Case, async: true

  alias Troupe.{Examples, JSON}
  alias Troupe.Workflow.Source

  test "the Spark example files parse, without compiling, to the compiled definitions" do
    for {module, file} <- [
          {Troupe.Examples.Greeting, "lib/troupe/examples/greeting.ex"},
          {Troupe.Examples.CalculatorAgent, "lib/troupe/examples/calculator_agent.ex"}
        ] do
      assert Source.parse(File.read!(file)) == {:ok, module.definition()}
    end
  end

  for id <- Enum.map(Examples.all(), & &1["id"]) do
    test "#{id}: definition -> DSL source -> definition is lossless, and matches JSON" do
      definition = Examples.definition(unquote(id))
      source = Source.to_source(definition)

      assert Source.parse(source) == {:ok, definition}
      assert {:ok, ^definition} = definition |> JSON.encode() |> JSON.decode()

      assert source ==
               Code.format_string!(source, locals_without_parens: Source.locals_without_parens())
               |> IO.iodata_to_binary()
               |> Kernel.<>("\n")
    end
  end

  test ".formatter.exs exports exactly the DSL's locals_without_parens" do
    {config, _binding} = Code.eval_file(Path.expand("../../.formatter.exs", __DIR__))

    assert Enum.sort(config[:export][:locals_without_parens]) ==
             Enum.sort(Source.locals_without_parens())
  end

  defp workflow(body) do
    """
    workflow do
      id "t"
      version "1.0.0"
      inputs text: :string
      output result(:a)

    #{body}
    end
    """
  end

  test "code outside the DSL is rejected with its line and never evaluated" do
    marker = Path.join(System.tmp_dir!(), "troupe-source-#{System.unique_integer([:positive])}")

    source =
      workflow("""
        action :a, "text.upcase", "~> 1.0" do
          arg :text, File.write!(#{inspect(marker)}, "pwned")
        end
      """)

    assert {:error, [%{message: message, details: %{"line" => 8}}]} = Source.parse(source)
    assert message =~ "File.write!"
    assert message =~ "never evaluated"
    refute File.exists?(marker)
  end

  test "unknown names never create atoms" do
    name = "troupe_never_seen_#{System.unique_integer([:positive])}"

    Source.parse(
      workflow("""
        action :#{name}, "text.upcase", "~> 1.0" do
          arg :#{name}, input(:#{name})
        end
      """)
    )

    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  test "validation errors carry the source line of the offending node or field" do
    source =
      workflow("""
        action :a, "text.upcase", "~> 1.0" do
          arg :text, input(:missing)
        end
      """)

    assert {:error,
            [%{kind: :invalid_reference, path: "/nodes/0/args/text", details: %{"line" => 8}}]} =
             Source.parse(source)
  end

  test "syntax errors, stray forms and non-portable literals report their line" do
    assert {:error, [%{message: "line " <> _rest, details: %{"line" => _line}}]} =
             Source.parse("workflow do\n  id \"x\"\n")

    assert {:error, [%{details: %{"line" => 7}, message: message}]} =
             Source.parse(workflow("  x = 1"))

    assert message =~ "unexpected"

    assert {:error, [%{message: message}]} =
             Source.parse(
               workflow("""
                 action :a, "text.upcase", "~> 1.0" do
                   arg :text, value(:atom)
                 end
               """)
             )

    assert message =~ "not portable"
  end

  test "a defmodule wrapper may contain only use, @moduledoc and the workflow" do
    source = """
    defmodule Evil do
      use Troupe.Workflow
      def run, do: :boom
      workflow do
      end
    end
    """

    assert {:error, [%{message: message}]} = Source.parse(source)
    assert message =~ "only `use Troupe.Workflow`"
  end
end
