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
    assert Enum.all?(reply["examples"], &is_binary(&1["json"]))
    assert "agent.scripted_policy" in Enum.map(reply["capabilities"], & &1["name"])
  end

  test "validate returns canonical JSON and an outline, or located errors", %{server: server} do
    reply = call(server, ["validate", Examples.json("calculator_agent")])

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
             call(server, ["validate", broken])

    assert path =~ "/nodes/1/args/vars"
  end

  test "run executes only with the ticked grant and reports steps, history and loop states", %{
    server: server
  } do
    json = Examples.json("calculator_agent")
    inputs = Jason.encode!(%{"start" => 3, "plan" => [%{"tool" => "add", "operand" => 4}]})

    denied = call(server, ["run", json, inputs, ["math.add"], 0])
    assert denied["status"] == "failed"
    assert Enum.any?(denied["errors"], &(&1["kind"] == "not_granted"))

    reply =
      call(server, [
        "run",
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

    interrupted = call(server, ["run", json, inputs, grant, 2])
    assert interrupted["status"] == "interrupted"
    assert interrupted["stats"]["checkpoints"] > 0

    resumed = call(server, ["resume", interrupted["run_id"], grant])
    assert resumed["status"] == "completed"
    assert resumed["output"]["reply"] == "ESCALATED TO ON-CALL: URGENT: HELP"

    statuses = Map.new(resumed["steps"], &{&1["node"], &1["status"]})
    assert statuses["urgent"] == "replayed"
    assert statuses["escalate"] == "completed"
  end

  test "export produces JSON, a term binary and app code for the same definition", %{
    server: server
  } do
    json = Examples.json("sqrt_newton")
    definition = Troupe.JSON.decode!(json)

    assert {:ok, ^definition} =
             Troupe.JSON.decode(call(server, ["export", json, "json"])["content"])

    assert {:ok, ^definition} =
             Troupe.Binary.decode(
               Base.decode64!(call(server, ["export", json, "etf"])["content"])
             )

    assert call(server, ["export", json, "elixir"])["content"] =~ "Troupe.Grant.new!"
  end
end
