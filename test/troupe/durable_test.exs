defmodule Troupe.DurableTest do
  use ExUnit.Case, async: true

  alias Troupe.{Grant, Store, TestCapabilities, TestWorkflows}

  @moduletag :tmp_dir

  defp opts(store),
    do: [store: store, registry: TestCapabilities.registry(), grant: TestCapabilities.grant()]

  # A loop whose second iteration fails while `block` exists.
  defp blocking_loop(log, block, counter) do
    TestWorkflows.definition!(%{
      "schema_version" => 1,
      "id" => "blocking_loop",
      "version" => "1.0.0",
      "nodes" => [
        %{
          "id" => "steps",
          "kind" => "loop",
          "max_iterations" => 4,
          "state" => %{"value" => 0},
          "nodes" => [
            TestWorkflows.record("work", log, %{"loop" => "state", "of" => "steps"}),
            %{
              "id" => "gate",
              "kind" => "branch",
              "on" => %{"loop" => "index", "of" => "steps"},
              "cases" => [
                %{
                  "match" => 2,
                  "nodes" => [
                    %{
                      "id" => "check",
                      "kind" => "action",
                      "capability" => %{"name" => "test.flaky", "version" => "~> 1.0"},
                      "args" => %{
                        "counter" => %{"value" => counter},
                        "block" => %{"value" => block}
                      }
                    }
                  ],
                  "output" => %{"value" => "checked"}
                }
              ],
              "default" => %{"output" => %{"value" => "skipped"}}
            }
          ],
          "next_state" => %{"result" => "work"}
        }
      ],
      "output" => %{"result" => "steps"}
    })
  end

  test "a failed run resumes mid-loop without repeating finished iterations", %{tmp_dir: dir} do
    log = Path.join(dir, "effects.log")
    block = Path.join(dir, "block")
    File.write!(block, "")
    store = Store.File.new(Path.join(dir, "store"))
    definition = blocking_loop(log, block, Path.join(dir, "calls"))

    assert {:error, [%{kind: :action_failed, details: %{"activation" => "steps[2]/check"}}]} =
             Troupe.run(definition, %{}, [run_id: "loop-1"] ++ opts(store))

    assert {:ok, %{"status" => "failed"}} = Store.fetch_run(store, "loop-1")

    assert Enum.map(TestCapabilities.lines(log), &hd(String.split(&1))) == [
             "work",
             "work",
             "work"
           ]

    File.rm!(block)
    assert {:ok, run} = Troupe.resume(store, "loop-1", Keyword.delete(opts(store), :store))
    assert run.output == 4

    activations = log |> TestCapabilities.lines() |> Enum.map(&Enum.at(String.split(&1), 1))
    assert activations == ["steps[0]/work", "steps[1]/work", "steps[2]/work", "steps[3]/work"]

    types = Troupe.history(store, "loop-1") |> Enum.map(& &1["type"])
    assert "branch_replayed" in types
    assert Enum.count(types, &(&1 == "activation_replayed")) == 1
  end

  test "resuming a completed run returns its output without executing", %{tmp_dir: dir} do
    log = Path.join(dir, "effects.log")
    store = Store.File.new(Path.join(dir, "store"))
    definition = TestWorkflows.definition!(TestWorkflows.chain(3, log))

    assert {:ok, %{output: 3}} =
             Troupe.run(definition, %{"start" => 0}, [run_id: "done"] ++ opts(store))

    assert {:ok, %{output: 3}} = Troupe.resume(store, "done", opts(store))
    assert Enum.count(TestCapabilities.lines(log)) == 3
  end

  test "resume re-checks permission and the definition, and refuses unknown runs", %{tmp_dir: dir} do
    log = Path.join(dir, "effects.log")
    store = Store.File.new(Path.join(dir, "store"))
    definition = TestWorkflows.definition!(TestWorkflows.chain(2, log))
    registry = TestCapabilities.registry()
    {:ok, _run} = Troupe.run(definition, %{"start" => 0}, [run_id: "r"] ++ opts(store))

    assert {:error, [%{kind: :not_granted}]} =
             Troupe.resume(store, "r", registry: registry, grant: Grant.none())

    other = TestWorkflows.definition!(TestWorkflows.chain(3, log))

    assert {:error, [%{kind: :definition_mismatch}]} =
             Troupe.resume(store, "r",
               definition: other,
               registry: registry,
               grant: TestCapabilities.grant()
             )

    assert {:error, [%{kind: :run_not_found}]} = Troupe.resume(store, "missing", opts(store))

    assert {:error, [%{kind: :invalid_inputs, message: message}]} =
             Troupe.run(definition, %{"start" => 0}, [run_id: "r"] ++ opts(store))

    assert message =~ "already exists"
  end

  test "the file store survives torn history frames and keeps record kinds apart", %{tmp_dir: dir} do
    store = Store.File.new(dir)
    :ok = Store.append_event(store, "run", %{"type" => "a"})
    :ok = Store.append_event(store, "run", %{"type" => "b"})

    File.write!(
      Path.join(Store.File.run_dir(store, "run"), "events.log"),
      <<0, 0, 0, 99, 1, 2>>,
      [:append]
    )

    assert Enum.map(Store.events(store, "run"), & &1["type"]) == ["a", "b"]

    :ok = Store.put_payload(store, "run", "x@1", %{"big" => "value"})
    :ok = Store.put_checkpoint(store, "run", "x@1", %{"small" => true})
    assert {:ok, %{"big" => "value"}} = Store.fetch_payload(store, "run", "x@1")
    assert {:ok, %{"small" => true}} = Store.fetch_checkpoint(store, "run", "x@1")
    assert Store.fetch_payload(store, "run", "absent") == :error
    assert %{events: 2, payloads: 1, checkpoints: 1} = Store.stats(store, "run")
  end
end
