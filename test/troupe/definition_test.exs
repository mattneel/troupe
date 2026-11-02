defmodule Troupe.DefinitionTest do
  use ExUnit.Case, async: true

  alias Troupe.{Binary, Definition, Examples, JSON, PlainData}

  @examples Enum.map(Examples.all(), & &1["id"])

  describe "one definition from every authoring path" do
    test "Spark DSL modules and their JSON files decode to the same validated definition" do
      for {module, file} <- [
            {Troupe.Examples.Greeting, "greeting"},
            {Troupe.Examples.CalculatorAgent, "calculator_agent"}
          ] do
        assert {:ok, from_json} = JSON.decode(Examples.json(file))
        assert from_json == module.definition()
        assert from_json.schema_version == Definition.schema_version()
      end
    end

    for id <- @examples do
      test "#{id} round-trips through JSON and Erlang term binaries" do
        definition = Examples.definition(unquote(id))

        assert {:ok, ^definition} = definition |> JSON.encode() |> JSON.decode()
        assert {:ok, ^definition} = definition |> Binary.encode() |> Binary.decode()
        assert {:ok, ^definition} = definition |> Definition.to_map() |> Definition.from_map()
      end

      test "#{id} exports only plain data with a schema version" do
        portable = unquote(id) |> Examples.definition() |> Definition.to_map()

        assert PlainData.check(portable) == :ok
        assert portable["schema_version"] == 1
        # Decodable without creating atoms or knowing any Troupe module.
        assert :erlang.binary_to_term(:erlang.term_to_binary(portable), [:safe]) == portable
      end
    end

    test "term binaries are deterministic" do
      definition = Examples.definition("calculator_agent")
      assert Binary.encode(definition) == Binary.encode(definition)
    end
  end

  describe "importing never yields executable values" do
    test "term binaries carrying PIDs, references, functions or module atoms are rejected with paths" do
      base = Definition.to_map(Examples.definition("greeting"))
      table = :ets.new(:not_portable, [])

      for {bad, description} <- [
            {self(), "a process id"},
            {make_ref(), "a reference"},
            {table, "a reference"},
            {fn -> :boom end, "a function"},
            {Troupe.Capabilities.Text.Upcase, "the atom"}
          ] do
        poisoned = put_in(base, ["nodes", Access.at(0), "args", "text"], %{"value" => bad})

        assert {:error, [%Troupe.Error{kind: :not_plain_data, path: path, message: message}]} =
                 Definition.from_map(poisoned)

        assert path == "/nodes/0/args/text/value"
        assert message =~ description
      end
    end

    test "corrupt term binaries fail with decode_failed" do
      assert {:error, [%Troupe.Error{kind: :decode_failed}]} = Binary.decode(<<131, 255, 0>>)
    end

    test "decoding does not resolve capabilities" do
      {:ok, definition} =
        "greeting"
        |> Examples.json()
        |> String.replace("text.upcase", "no.such_capability")
        |> JSON.decode()

      assert [%{name: "no.such_capability"} | _rest] = Definition.capabilities(definition)

      assert {:error, [%{kind: :unknown_capability, path: "/nodes/0/capability"}]} =
               Troupe.check(definition)
    end
  end

  describe "Spark DSL validation" do
    test "an invalid DSL workflow fails to compile with every problem listed" do
      source = """
      defmodule Troupe.DefinitionTest.Broken do
        use Troupe.Workflow

        workflow do
          id "broken"
          version "1.0.0"
          output result(:missing)

          action :shout, "text.upcase", "~> 1.0" do
            arg :text, input(:nobody)
          end
        end
      end
      """

      error = assert_raise Spark.Error.DslError, fn -> Code.compile_string(source) end
      assert error.message =~ ~s(unknown input "nobody")
      assert error.message =~ ~s(unknown node "missing")
    end
  end
end
