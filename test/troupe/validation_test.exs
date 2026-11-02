defmodule Troupe.ValidationTest do
  use ExUnit.Case, async: true

  alias Troupe.{Definition, JSON}

  defp action(id, args, capability \\ "text.upcase") do
    %{
      "id" => id,
      "kind" => "action",
      "capability" => %{"name" => capability, "version" => "~> 1.0"},
      "args" => args
    }
  end

  defp workflow(nodes, overrides \\ %{}) do
    Map.merge(
      %{
        "schema_version" => 1,
        "id" => "test",
        "version" => "1.0.0",
        "inputs" => [%{"name" => "text", "type" => "string"}],
        "nodes" => nodes,
        "output" => %{"result" => List.first(nodes)["id"]}
      },
      overrides
    )
  end

  defp errors(map) do
    assert {:error, errors} = Definition.from_map(map)
    Enum.map(errors, &{&1.kind, &1.path, &1.message})
  end

  test "a valid minimal workflow decodes" do
    assert {:ok, %Definition{id: "test"}} =
             Definition.from_map(workflow([action("a", %{"text" => %{"input" => "text"}})]))
  end

  test "unsupported schema versions are refused explicitly" do
    assert [{:unsupported_schema_version, "/schema_version", message}] =
             errors(workflow([action("a", %{})], %{"schema_version" => 2}))

    assert message =~ "reads version 1"
  end

  test "every shape problem is reported with its location" do
    map =
      workflow([
        %{
          "id" => "Bad Id",
          "kind" => "action",
          "capability" => %{"name" => "Text!", "version" => "one"},
          "args" => %{}
        },
        %{"id" => "b", "kind" => "teleport"},
        %{
          "id" => "c",
          "kind" => "action",
          "capability" => %{"name" => "text.upcase", "version" => "~> 1.0"},
          "argz" => %{}
        }
      ])

    paths = map |> errors() |> Enum.map(&elem(&1, 1))

    assert "/nodes/0/id" in paths
    assert "/nodes/0/capability/name" in paths
    assert "/nodes/0/capability/version" in paths
    assert "/nodes/1/kind" in paths
    assert "/nodes/2/argz" in paths
  end

  test "references must exist" do
    assert [
             {:invalid_reference, "/nodes/0/args/text", "unknown input \"nope\"" <> _},
             {:invalid_reference, "/nodes/1/args/text", "unknown node \"ghost\"" <> _}
           ] =
             errors(
               workflow([
                 action("a", %{"text" => %{"input" => "nope"}}),
                 action("b", %{"text" => %{"result" => "ghost"}})
               ])
             )
  end

  test "nodes inside a branch case or loop are not visible outside it" do
    branch = %{
      "id" => "route",
      "kind" => "branch",
      "on" => %{"input" => "text"},
      "cases" => [
        %{
          "match" => "x",
          "nodes" => [action("inner", %{"text" => %{"input" => "text"}})],
          "output" => %{"result" => "inner"}
        }
      ]
    }

    assert [{:invalid_reference, "/nodes/1/args/text", message}] =
             errors(workflow([branch, action("outside", %{"text" => %{"result" => "inner"}})]))

    assert message =~ "runs inside case 0 of branch \"route\""
  end

  test "dependency cycles are reported" do
    assert [{:invalid_reference, "/nodes/0", "dependency cycle: a -> b -> a"}] =
             errors(
               workflow([
                 action("a", %{"text" => %{"result" => "b"}}),
                 action("b", %{"text" => %{"result" => "a"}})
               ])
             )
  end

  test "self references and references to an enclosing node are rejected" do
    loop = %{
      "id" => "spin",
      "kind" => "loop",
      "max_iterations" => 2,
      "state" => %{"value" => 0},
      "nodes" => [action("body", %{"text" => %{"result" => "spin"}})],
      "next_state" => %{"value" => 0}
    }

    assert [
             {:invalid_reference, "/nodes/0/args/text",
              "node \"a\" cannot reference its own result"}
           ] =
             errors(workflow([action("a", %{"text" => %{"result" => "a"}})]))

    assert [{:invalid_reference, "/nodes/0/nodes/0/args/text", message}] =
             errors(workflow([loop]))

    assert message =~ "encloses this expression"
  end

  test "loop state is only visible inside that loop" do
    assert [{:invalid_reference, "/nodes/0/args/text", message}] =
             errors(workflow([action("a", %{"text" => %{"loop" => "state", "of" => "agent"}})]))

    assert message =~ "does not enclose"
  end

  test "duplicate ids, duplicate matches and bad defaults are reported" do
    branch = %{
      "id" => "a",
      "kind" => "branch",
      "on" => %{"input" => "text"},
      "cases" => [
        %{"match" => 1, "output" => %{"value" => 1}},
        %{"match" => 1, "output" => %{"value" => 2}}
      ]
    }

    assert {:invalid_definition, "/nodes/0/cases/1/match", "duplicate match 1"} in errors(
             workflow([branch])
           )

    assert [{:invalid_definition, "/nodes/1/id", "duplicate node id \"a\"" <> _}] =
             errors(
               workflow([
                 action("a", %{"text" => %{"input" => "text"}}),
                 action("a", %{"text" => %{"input" => "text"}})
               ])
             )

    inputs = [
      %{"name" => "n", "type" => "integer", "default" => "seven"},
      %{"name" => "m", "type" => "integer", "required" => true, "default" => 1}
    ]

    assert [
             {:invalid_definition, "/inputs/0/default", "default must be integer, got a string"},
             {:invalid_definition, "/inputs/1/default", _required_message}
           ] =
             errors(
               workflow([action("a", %{"text" => %{"value" => "x"}})], %{"inputs" => inputs})
             )
  end

  test "inline secrets are refused; secret references are allowed only as action arguments" do
    assert [{:possible_secret, "/nodes/0/args/text/value/api_key", message}] =
             errors(workflow([action("a", %{"text" => %{"value" => %{"api_key" => "sk-123"}}})]))

    assert message =~ ~s({"secret": "NAME"})

    assert {:ok, _definition} =
             Definition.from_map(workflow([action("a", %{"text" => %{"secret" => "API_TOKEN"}})]))

    assert [{:invalid_reference, "/output", message}] =
             errors(
               workflow([action("a", %{"text" => %{"input" => "text"}})], %{
                 "output" => %{"secret" => "API_TOKEN"}
               })
             )

    assert message =~ "only be passed directly as an action argument"
  end

  test "malformed JSON reports the position" do
    assert {:error, [%Troupe.Error{kind: :decode_failed, details: %{"position" => 1}}]} =
             JSON.decode("{]")
  end

  test "capability arguments are checked against installed declarations" do
    {:ok, definition} =
      Definition.from_map(
        workflow([
          action("a", %{"txt" => %{"input" => "text"}}),
          action("b", %{"a" => %{"value" => "1"}, "b" => %{"value" => 2}}, "math.add")
        ])
      )

    assert {:error, errors} = Troupe.check(definition)

    assert Enum.map(errors, &{&1.kind, &1.path}) == [
             {:invalid_arguments, "/nodes/0/args/txt"},
             {:invalid_arguments, "/nodes/0/args"},
             {:invalid_arguments, "/nodes/1/args/a"}
           ]
  end

  test "version requirements must be satisfiable by an installed version" do
    {:ok, definition} =
      Definition.from_map(
        workflow([
          %{
            action("a", %{"text" => %{"input" => "text"}})
            | "capability" => %{"name" => "text.upcase", "version" => "~> 2.0"}
          }
        ])
      )

    assert {:error,
            [%{kind: :unknown_capability, message: message, details: %{"installed" => ["1.0.0"]}}]} =
             Troupe.check(definition)

    assert message =~ "satisfies \"~> 2.0\""
  end
end
