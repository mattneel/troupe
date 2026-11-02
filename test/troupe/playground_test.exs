defmodule Troupe.PlaygroundTest do
  # The same server the browser calls through Popcorn.Proxy, driven directly.
  use ExUnit.Case, async: true

  alias Troupe.Examples

  setup do
    name = :"playground_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Troupe.Playground, name: name})
    %{server: pid}
  end

  defp call(server, request), do: server |> GenServer.call(request, 30_000) |> Jason.decode!()

  test "init lists every example with JSON and the capability catalog", %{server: server} do
    reply = call(server, ["init"])

    assert reply["schema_version"] == 1
    assert Enum.map(reply["examples"], & &1["id"]) == Enum.map(Examples.all(), & &1["id"])
    assert Enum.all?(reply["examples"], &(is_binary(&1["json"]) and is_binary(&1["elixir"])))
    assert "agent.scripted_policy" in Enum.map(reply["capabilities"], & &1["name"])
  end

  test "validate returns canonical JSON and an outline, or located errors", %{server: server} do
    reply = call(server, ["validate", "json", Examples.json("calculator_agent")])

    assert reply["ok"]
    assert {:ok, _definition} = Troupe.JSON.decode(reply["json"])

    assert Enum.map(reply["outline"], &{&1["id"], &1["depth"]}) == [
             {"agent", 0},
             {"decide", 1},
             {"act", 1},
             {"add", 2},
             {"multiply", 2},
             {"note", 1}
           ]

    broken =
      String.replace(Examples.json("greeting"), ~s("result": "shout"), ~s("result": "shot"))

    assert %{"ok" => false, "errors" => [%{"kind" => "invalid_reference", "path" => path}]} =
             call(server, ["validate", "json", broken])

    assert path =~ "/nodes/1/args/vars"
  end

  test "Elixir DSL source validates, runs and converts to the same definition as JSON", %{
    server: server
  } do
    source = Examples.source("greeting")
    assert source =~ "use Troupe.Workflow"

    elixir = call(server, ["validate", "elixir", source])
    json = call(server, ["validate", "json", Examples.json("greeting")])
    assert elixir["ok"] and elixir["json"] == json["json"]

    converted =
      call(server, ["export", "json", Examples.json("ticket_triage"), "source"])["content"]

    assert {:ok, Examples.definition("ticket_triage")} == Troupe.Workflow.Source.parse(converted)

    reply =
      call(server, [
        "run",
        "elixir",
        source,
        ~s({"name": "Ada"}),
        ["text.template", "text.upcase"],
        0
      ])

    assert reply["output"] == "Hello, ADA!"

    broken = String.replace(source, "input(:name)", "input(:nobody)")

    assert %{"ok" => false, "errors" => [%{"details" => %{"line" => line}}]} =
             call(server, ["validate", "elixir", broken])

    assert source |> String.split("\n") |> Enum.at(line - 1) =~ "arg :text"
  end

  test "run executes only with the ticked grant and reports steps, history and loop states", %{
    server: server
  } do
    json = Examples.json("calculator_agent")
    inputs = Jason.encode!(%{"start" => 3, "plan" => [%{"tool" => "add", "operand" => 4}]})

    denied = call(server, ["run", "json", json, inputs, ["math.add"], 0])
    assert denied["status"] == "failed"
    assert Enum.any?(denied["errors"], &(&1["kind"] == "not_granted"))

    reply =
      call(server, [
        "run",
        "json",
        json,
        inputs,
        ["agent.scripted_policy", "list.append_window", "math.add", "math.multiply"],
        0
      ])

    assert reply["status"] == "completed"
    assert reply["output"]["value"] == 7

    assert %{"activation" => "agent[0]/add", "status" => "completed", "result" => 7} =
             Enum.find(reply["steps"], &(&1["node"] == "add"))

    assert [%{"iteration" => 0, "next_state" => %{"value" => 7}}, %{"iteration" => 1}] =
             reply["loops"]

    assert List.last(reply["events"])["type"] == "run_completed"
  end

  test "an interrupted run resumes from its checkpoints", %{server: server} do
    json = Examples.json("ticket_triage")
    inputs = Jason.encode!(%{"text" => "urgent: help"})
    grant = ["text.contains", "text.template", "text.upcase"]

    interrupted = call(server, ["run", "json", json, inputs, grant, 2])
    assert interrupted["status"] == "interrupted"
    assert interrupted["stats"]["checkpoints"] > 0

    resumed = call(server, ["resume", interrupted["run_id"], grant])
    assert resumed["status"] == "completed"
    assert resumed["output"]["reply"] == "ESCALATED TO ON-CALL: URGENT: HELP"

    statuses = Map.new(resumed["steps"], &{&1["node"], &1["status"]})
    assert statuses["urgent"] == "replayed"
    assert statuses["escalate"] == "completed"
  end

  test "export produces JSON, an Elixir module, a term binary and app code for the same definition",
       %{server: server} do
    json = Examples.json("sqrt_newton")
    definition = Troupe.JSON.decode!(json)
    export = &call(server, ["export", "json", json, &1])["content"]

    assert {:ok, ^definition} = Troupe.JSON.decode(export.("json"))
    assert {:ok, ^definition} = Troupe.Binary.decode(Base.decode64!(export.("etf")))
    assert {:ok, ^definition} = Troupe.Workflow.Source.parse(export.("elixir"))
    assert export.("elixir") =~ "defmodule MyApp.Workflows.SqrtNewton do"
    assert export.("app") =~ "Troupe.Grant.new!"
  end

  test "the exported Elixir module compiles with the real Spark DSL to the same definition", %{
    server: server
  } do
    json = Examples.json("calculator_agent")

    module_source =
      call(server, ["export", "json", json, "elixir"])["content"]
      |> String.replace("MyApp.Workflows.CalculatorAgent", "Troupe.PlaygroundTest.Exported")

    [{module, _bytecode}] = Code.compile_string(module_source)
    assert module.definition() == Troupe.JSON.decode!(json)
  end
end
