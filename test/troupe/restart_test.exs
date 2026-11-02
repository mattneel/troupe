defmodule Troupe.RestartTest do
  # Durable resume across real OS processes: every run below happens in a
  # fresh `elixir` VM that shares only the store directory with the others.
  use ExUnit.Case, async: true

  alias Troupe.TestCapabilities
  alias Troupe.TestWorkflows

  @moduletag :tmp_dir
  @child Path.expand("../support/restart_child.exs", __DIR__)

  defp child(args) do
    code_paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))
    pa = Enum.flat_map(code_paths, &["-pa", &1])
    System.cmd(System.find_executable("elixir"), pa ++ [@child | args], stderr_to_stdout: true)
  end

  defp write_definition(dir, map) do
    path = Path.join(dir, "workflow.json")
    File.write!(path, map |> TestWorkflows.definition!() |> Troupe.JSON.encode())
    path
  end

  defp parse_log(log) do
    for line <- TestCapabilities.lines(log) do
      [label, activation, pid] = String.split(line, " ")
      %{label: label, activation: activation, pid: pid}
    end
  end

  test "a ten-action run interrupted after five completions resumes at action six in a new process",
       %{tmp_dir: dir} do
    log = Path.join(dir, "effects.log")
    store_dir = Path.join(dir, "store")
    path = write_definition(dir, TestWorkflows.chain(10, log))

    {first_output, first_status} = child(["start", store_dir, "run-10", path, "100", "5"])
    assert first_status == 70, first_output

    first = parse_log(log)
    assert Enum.map(first, & &1.label) == Enum.map(1..5, &"step_#{&1}")
    [first_pid] = first |> Enum.map(& &1.pid) |> Enum.uniq()

    store = Troupe.Store.File.new(store_dir)

    completed =
      for %{"type" => "activation_completed", "node" => node} <- Troupe.history(store, "run-10"),
          do: node

    assert completed == Enum.map(1..5, &"step_#{&1}")
    assert {:ok, %{"status" => "running"}} = Troupe.Store.fetch_run(store, "run-10")

    {second_output, second_status} = child(["resume", store_dir, "run-10"])
    assert second_status == 0, second_output
    assert second_output =~ "OUTPUT 110"

    all = parse_log(log)
    assert Enum.map(all, & &1.label) == Enum.map(1..10, &"step_#{&1}")
    resumed = Enum.drop(all, 5)
    assert [%{label: "step_6", pid: second_pid} | _rest] = resumed
    assert second_pid != first_pid
    assert Enum.all?(resumed, &(&1.pid == second_pid))

    history = Troupe.history(store, "run-10")
    after_resume = Enum.drop_while(history, &(&1["type"] != "run_resumed"))
    replayed = for %{"type" => "activation_replayed", "node" => node} <- after_resume, do: node
    assert replayed == Enum.map(1..5, &"step_#{&1}")

    assert %{"type" => "attempt_started", "node" => "step_6", "attempt" => 1} =
             Enum.find(after_resume, &(&1["type"] == "attempt_started"))

    assert {:ok, %{"status" => "completed"}} = Troupe.Store.fetch_run(store, "run-10")
  end

  test "a crash after an external effect but before its checkpoint re-runs the action (at-least-once)",
       %{tmp_dir: dir} do
    log = Path.join(dir, "effects.log")
    store_dir = Path.join(dir, "store")
    marker = Path.join(dir, "crashed")
    path = write_definition(dir, TestWorkflows.chain(3, log, crash_at: 2, crash_marker: marker))

    assert {_out, 71} = child(["start", store_dir, "run-crash", path, "0", "0"])
    assert {out, 0} = child(["resume", store_dir, "run-crash"])
    assert out =~ "OUTPUT 3"

    labels = log |> parse_log() |> Enum.map(& &1.label)
    assert labels == ["step_1", "step_2", "step_2", "step_3"]

    store = Troupe.Store.File.new(store_dir)

    attempts =
      for %{"type" => "attempt_started", "node" => "step_2", "attempt" => n} <-
            Troupe.history(store, "run-crash"),
          do: n

    assert attempts == [1, 2]
  end

  test "reconcile/2 recognises an in-doubt effect by idempotency key instead of repeating it",
       %{tmp_dir: dir} do
    ledger = Path.join(dir, "ledger.txt")
    store_dir = Path.join(dir, "store")
    marker = Path.join(dir, "crashed")

    path =
      write_definition(dir, %{
        "schema_version" => 1,
        "id" => "payment",
        "version" => "1.0.0",
        "inputs" => [%{"name" => "start", "type" => "integer"}],
        "nodes" => [
          %{
            "id" => "charge",
            "kind" => "action",
            "capability" => %{"name" => "test.ledger", "version" => "~> 1.0"},
            "args" => %{
              "ledger" => %{"value" => ledger},
              "amount" => %{"input" => "start"},
              "crash_marker" => %{"value" => marker}
            }
          }
        ],
        "output" => %{"result" => "charge"}
      })

    assert {_out, 72} = child(["start", store_dir, "run-pay", path, "42", "0"])
    assert {out, 0} = child(["resume", store_dir, "run-pay"])
    assert out =~ ~s(OUTPUT "charged 42")

    assert TestCapabilities.lines(ledger) == ["run-pay/charge 42"]

    types = Troupe.history(Troupe.Store.File.new(store_dir), "run-pay") |> Enum.map(& &1["type"])
    assert "attempt_reconciled" in types
    refute "activation_completed" in types
  end
end
