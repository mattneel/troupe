defmodule Troupe.ExecutionTest do
  use ExUnit.Case, async: true

  alias Troupe.{Examples, Grant, TestCapabilities, TestWorkflows}

  @moduletag :tmp_dir

  defp run!(definition, inputs, opts \\ []) do
    opts =
      Keyword.merge(
        [registry: TestCapabilities.registry(), grant: TestCapabilities.grant()],
        opts
      )

    assert {:ok, run} = Troupe.run(definition, inputs, opts)
    run
  end

  defp events(run, type),
    do: for(%{"type" => ^type} = event <- Troupe.history(run.store, run.id), do: event)

  describe "Reactor execution of the examples" do
    test "the Spark greeting runs both actions in dependency order" do
      run = run!(Examples.definition("greeting"), %{"name" => "Ada"})

      assert run.output == "Hello, ADA!"
      assert Enum.map(events(run, "activation_completed"), & &1["node"]) == ["shout", "greet"]
    end

    test "the JSON Newton loop converges on a real square root" do
      run = run!(Examples.definition("sqrt_newton"), %{"n" => 2})

      assert_in_delta run.output, :math.sqrt(2), 1.0e-12
      assert [%{"iterations" => iterations}] = events(run, "loop_completed")
      assert iterations in 3..10
    end

    test "the ReAct-style agent loop applies each tool and keeps a bounded scratchpad" do
      plan = for operand <- 1..6, do: %{"tool" => "add", "operand" => operand}

      run =
        run!(Examples.definition("calculator_agent"), %{"start" => 0, "plan" => plan, "keep" => 2})

      assert run.output["value"] == 21
      assert Enum.count(run.output["scratchpad"]) == 2
      assert %{"thought" => "the answer is 21"} = List.last(run.output["scratchpad"])
    end
  end

  describe "identity: node vs activation vs attempt" do
    test "each loop iteration is a distinct activation of the same node" do
      plan = [%{"tool" => "add", "operand" => 4}, %{"tool" => "multiply", "operand" => 5}]
      run = run!(Examples.definition("calculator_agent"), %{"start" => 3, "plan" => plan})

      decides =
        for %{"node" => "decide"} = event <- events(run, "activation_completed"),
            do: event["activation"]

      assert decides == ["agent[0]/decide", "agent[1]/decide", "agent[2]/decide"]
      assert run.output["value"] == 35
    end

    test "identical work in every iteration is executed every time, not deduplicated", %{
      tmp_dir: dir
    } do
      log = Path.join(dir, "effects.log")

      definition =
        TestWorkflows.definition!(%{
          "schema_version" => 1,
          "id" => "repeat",
          "version" => "1.0.0",
          "nodes" => [
            %{
              "id" => "again",
              "kind" => "loop",
              "max_iterations" => 5,
              "state" => %{"value" => 0},
              "nodes" => [TestWorkflows.record("same", log, %{"value" => 1})],
              "next_state" => %{"value" => 0}
            }
          ],
          "output" => %{"result" => "again"}
        })

      run = run!(definition, %{})

      assert Enum.count(TestCapabilities.lines(log)) == 5
      activations = for event <- events(run, "activation_completed"), do: event["activation"]
      assert activations == Enum.map(0..4, &"again[#{&1}]/same")
      assert activations |> Enum.uniq() |> length() == 5
    end

    test "running the same definition twice performs the work twice under different run ids", %{
      tmp_dir: dir
    } do
      log = Path.join(dir, "effects.log")
      definition = TestWorkflows.definition!(TestWorkflows.chain(2, log))

      first = run!(definition, %{"start" => 1})
      second = run!(definition, %{"start" => 1})

      assert first.id != second.id
      assert first.output == second.output
      assert Enum.count(TestCapabilities.lines(log)) == 4
    end

    test "nested loops give each inner iteration its own activation path", %{tmp_dir: dir} do
      log = Path.join(dir, "effects.log")

      inner = %{
        "id" => "inner",
        "kind" => "loop",
        "max_iterations" => 2,
        "state" => %{"value" => 0},
        "nodes" => [TestWorkflows.record("work", log, %{"loop" => "index", "of" => "outer"})],
        "next_state" => %{"value" => 0}
      }

      definition =
        TestWorkflows.definition!(%{
          "schema_version" => 1,
          "id" => "nested",
          "version" => "1.0.0",
          "nodes" => [
            %{
              "id" => "outer",
              "kind" => "loop",
              "max_iterations" => 2,
              "state" => %{"value" => 0},
              "nodes" => [inner],
              "next_state" => %{"value" => 0}
            }
          ],
          "output" => %{"result" => "outer"}
        })

      run = run!(definition, %{})

      assert for(event <- events(run, "activation_completed"), do: event["activation"]) ==
               [
                 "outer[0]/inner[0]/work",
                 "outer[0]/inner[1]/work",
                 "outer[1]/inner[0]/work",
                 "outer[1]/inner[1]/work"
               ]
    end

    test "retries are new attempts of one activation with one idempotency key", %{tmp_dir: dir} do
      counter = Path.join(dir, "calls")
      definition = flaky(counter, 2, 3)

      run = run!(definition, %{})

      assert run.output["calls"] == 3
      assert run.output["attempt_id"] == "flaky@3"
      assert run.output["key"] == "#{run.id}/flaky"
      assert TestCapabilities.lines(counter) == ["flaky@1", "flaky@2", "flaky@3"]
      assert Enum.map(events(run, "attempt_failed"), & &1["retryable"]) == [true, true]
    end

    test "retries stop at max_attempts with attempts_exhausted", %{tmp_dir: dir} do
      counter = Path.join(dir, "calls")

      assert {:error, [%Troupe.Error{kind: :attempts_exhausted, details: details}]} =
               Troupe.run(flaky(counter, 5, 2), %{},
                 registry: TestCapabilities.registry(),
                 grant: TestCapabilities.grant()
               )

      assert %{"node" => "flaky", "activation" => "flaky", "attempt" => 2} = details
      assert Enum.count(TestCapabilities.lines(counter)) == 2
    end
  end

  describe "branching" do
    test "only the chosen case runs and the choice is recorded" do
      urgent = run!(Examples.definition("ticket_triage"), %{"text" => "URGENT: refund"})
      calm = run!(Examples.definition("ticket_triage"), %{"text" => "hello"})

      assert urgent.output == %{
               "urgent" => true,
               "reply" => "ESCALATED TO ON-CALL: URGENT: REFUND"
             }

      assert calm.output == %{
               "urgent" => false,
               "reply" => "Thanks! We will reply within a day: hello"
             }

      assert [%{"case" => 0}] = events(urgent, "branch_selected")
      assert [%{"case" => "default"}] = events(calm, "branch_selected")
      refute "acknowledge" in Enum.map(events(urgent, "attempt_started"), & &1["node"])
      refute "escalate" in Enum.map(events(calm, "attempt_started"), & &1["node"])
    end

    test "a value matching no case and no default fails with the value and node" do
      definition =
        TestWorkflows.definition!(%{
          "schema_version" => 1,
          "id" => "nomatch",
          "version" => "1.0.0",
          "inputs" => [%{"name" => "kind", "type" => "string"}],
          "nodes" => [
            %{
              "id" => "route",
              "kind" => "branch",
              "on" => %{"input" => "kind"},
              "cases" => [%{"match" => "a", "output" => %{"value" => 1}}]
            }
          ],
          "output" => %{"result" => "route"}
        })

      assert {:error,
              [%Troupe.Error{message: message, details: %{"node" => "route", "value" => "z"}}]} =
               Troupe.run(definition, %{"kind" => "z"}, grant: Grant.none())

      assert message =~ "no case matches"
    end

    test "independent branches of a diamond run concurrently and join" do
      definition =
        TestWorkflows.definition!(%{
          "schema_version" => 1,
          "id" => "diamond",
          "version" => "1.0.0",
          "inputs" => [%{"name" => "n", "type" => "number"}],
          "nodes" => [
            %{
              "id" => "left",
              "kind" => "action",
              "capability" => %{"name" => "math.add", "version" => "~> 1.0"},
              "args" => %{"a" => %{"input" => "n"}, "b" => %{"value" => 1}}
            },
            %{
              "id" => "right",
              "kind" => "action",
              "capability" => %{"name" => "math.multiply", "version" => "~> 1.0"},
              "args" => %{"a" => %{"input" => "n"}, "b" => %{"value" => 10}}
            },
            %{
              "id" => "join",
              "kind" => "action",
              "capability" => %{"name" => "math.add", "version" => "~> 1.0"},
              "args" => %{"a" => %{"result" => "left"}, "b" => %{"result" => "right"}}
            }
          ],
          "output" => %{"result" => "join"}
        })

      assert run!(definition, %{"n" => 2}).output == 23
    end
  end

  describe "useful runtime errors" do
    test "a capability error names the node, activation and attempt" do
      definition =
        TestWorkflows.definition!(%{
          "schema_version" => 1,
          "id" => "divide",
          "version" => "1.0.0",
          "nodes" => [
            %{
              "id" => "split",
              "kind" => "action",
              "capability" => %{"name" => "math.divide", "version" => "~> 1.0"},
              "args" => %{"a" => %{"value" => 1}, "b" => %{"value" => 0}}
            }
          ],
          "output" => %{"result" => "split"}
        })

      assert {:error, [error]} = Troupe.run(definition, %{}, grant: Grant.new!(["math.divide"]))

      assert %Troupe.Error{
               kind: :action_failed,
               details: %{"node" => "split", "attempt" => 1, "run_id" => run_id}
             } = error

      assert error.message =~ "division by zero"
      assert is_binary(run_id)
    end

    test "a missing path in a result reference is reported at runtime" do
      definition =
        TestWorkflows.definition!(%{
          "schema_version" => 1,
          "id" => "path",
          "version" => "1.0.0",
          "nodes" => [
            %{
              "id" => "n",
              "kind" => "action",
              "capability" => %{"name" => "math.add", "version" => "~> 1.0"},
              "args" => %{"a" => %{"value" => 1}, "b" => %{"value" => 1}}
            },
            %{
              "id" => "m",
              "kind" => "action",
              "capability" => %{"name" => "math.abs", "version" => "~> 1.0"},
              "args" => %{"value" => %{"result" => "n", "path" => ["total"]}}
            }
          ],
          "output" => %{"result" => "m"}
        })

      assert {:error,
              [%Troupe.Error{kind: :invalid_reference, path: "/args/value", message: message}]} =
               Troupe.run(definition, %{}, grant: Grant.new!(["math.*"]))

      assert message =~ ~s(result of "n" has no "total")
    end

    test "results of the wrong type and non-plain results are refused" do
      definition =
        TestWorkflows.definition!(%{
          "schema_version" => 1,
          "id" => "bad",
          "version" => "1.0.0",
          "nodes" => [
            %{
              "id" => "b",
              "kind" => "action",
              "capability" => %{"name" => "test.bad", "version" => "~> 1.0"}
            }
          ],
          "output" => %{"result" => "b"}
        })

      assert {:error, [%Troupe.Error{kind: :invalid_result, message: message}]} =
               Troupe.run(definition, %{},
                 registry: TestCapabilities.registry(),
                 grant: TestCapabilities.grant()
               )

      assert message =~ "a tuple"
    end

    test "inputs, permissions and secrets are checked before anything runs", %{tmp_dir: dir} do
      log = Path.join(dir, "effects.log")
      definition = TestWorkflows.definition!(TestWorkflows.chain(1, log))
      registry = TestCapabilities.registry()

      assert {:error,
              [
                %{
                  kind: :invalid_inputs,
                  path: "/inputs/start",
                  message: "input \"start\" must be integer, got a string"
                }
              ]} =
               Troupe.run(definition, %{"start" => "1"},
                 registry: registry,
                 grant: TestCapabilities.grant()
               )

      assert {:error, [%{kind: :not_granted, details: %{"capability" => "test.record"}}]} =
               Troupe.run(definition, %{"start" => 1},
                 registry: registry,
                 grant: Grant.new!(["text.*"])
               )

      assert TestCapabilities.lines(log) == []
    end

    test "secrets are resolved from run options and never stored" do
      definition =
        TestWorkflows.definition!(%{
          "schema_version" => 1,
          "id" => "secret",
          "version" => "1.0.0",
          "nodes" => [
            %{
              "id" => "len",
              "kind" => "action",
              "capability" => %{"name" => "text.contains", "version" => "~> 1.0"},
              "args" => %{"text" => %{"secret" => "API_TOKEN"}, "pattern" => %{"value" => "sk-"}}
            }
          ],
          "output" => %{"result" => "len"}
        })

      grant = Grant.new!(["text.contains"])

      assert {:error, [%{kind: :invalid_inputs, path: "/nodes/0/args/text"}]} =
               Troupe.run(definition, %{}, grant: grant)

      run = run!(definition, %{}, grant: grant, secrets: %{"API_TOKEN" => "sk-very-secret"})
      assert run.output == true

      {:ok, record} = Troupe.Store.fetch_run(run.store, run.id)

      stored =
        inspect(
          {record, Troupe.history(run.store, run.id),
           Troupe.Store.fetch_payload(run.store, run.id, "len@1")}
        )

      refute stored =~ "sk-very-secret"
    end
  end

  defp flaky(counter, fail_times, max_attempts) do
    TestWorkflows.definition!(%{
      "schema_version" => 1,
      "id" => "flaky",
      "version" => "1.0.0",
      "nodes" => [
        %{
          "id" => "flaky",
          "kind" => "action",
          "max_attempts" => max_attempts,
          "capability" => %{"name" => "test.flaky", "version" => "~> 1.0"},
          "args" => %{
            "counter" => %{"value" => counter},
            "fail_times" => %{"value" => fail_times}
          }
        }
      ],
      "output" => %{"result" => "flaky"}
    })
  end
end
