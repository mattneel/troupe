defmodule Troupe.MemoryTest do
  # Active execution state must not grow with history: the frame carried
  # between loop iterations and the run process's live heap stay flat while
  # events and payloads accumulate in the (separate) store.
  use ExUnit.Case, async: false

  @blob String.duplicate("x", 1024)

  defp definition(iterations) do
    {:ok, definition} =
      Troupe.Definition.from_map(%{
        "schema_version" => 1,
        "id" => "memory",
        "version" => "1.0.0",
        "nodes" => [
          %{
            "id" => "agent",
            "kind" => "loop",
            "max_iterations" => iterations,
            "state" => %{"object" => %{"scratchpad" => %{"value" => []}}},
            "nodes" => [
              %{
                "id" => "observe",
                "kind" => "action",
                "capability" => %{"name" => "list.append_window", "version" => "~> 1.0"},
                "args" => %{
                  "list" => %{"loop" => "state", "of" => "agent", "path" => ["scratchpad"]},
                  "item" => %{
                    "object" => %{
                      "i" => %{"loop" => "index", "of" => "agent"},
                      "blob" => %{"value" => @blob}
                    }
                  },
                  "keep" => %{"value" => 3}
                }
              }
            ],
            "next_state" => %{"object" => %{"scratchpad" => %{"result" => "observe"}}}
          }
        ],
        "output" => %{"result" => "agent"}
      })

    definition
  end

  def sample(_event, _measurements, %{frame: frame}, table) do
    :erlang.garbage_collect()
    {:total_heap_size, heap} = Process.info(self(), :total_heap_size)
    :ets.insert(table, {frame.index, :erts_debug.size(frame), heap})
  end

  defp measure(iterations) do
    table = :ets.new(:samples, [:public])
    store = Troupe.Store.Memory.new()
    id = "memory-test-#{iterations}"
    :telemetry.attach(id, [:troupe, :frame], &__MODULE__.sample/4, table)

    {:ok, run} =
      Troupe.run(definition(iterations), %{},
        store: store,
        async?: false,
        grant: Troupe.Grant.new!(["list.*"])
      )

    :telemetry.detach(id)
    samples = :ets.tab2list(table)

    %{
      frames: length(samples),
      frame_words: samples |> Enum.map(&elem(&1, 1)) |> Enum.max(),
      heap_words: samples |> Enum.map(&elem(&1, 2)) |> Enum.max(),
      stats: Troupe.Store.stats(store, run.id),
      output: run.output
    }
  end

  test "frame and live heap stay flat while history grows 20x" do
    short = measure(20)
    long = measure(400)

    assert short.frames == 20 and long.frames == 400
    # Per iteration: attempt_started, activation_completed, loop_iteration_completed.
    assert short.stats.events == 3 * 20 + 3
    assert long.stats.events == 3 * 400 + 3
    assert long.stats.payloads == 2 * 400 + 2

    # Same frame shape regardless of iteration count (only index digits differ).
    assert long.frame_words <= short.frame_words + 2
    # Live heap after GC does not scale with iterations (allow allocator slack).
    assert long.heap_words <= short.heap_words * 1.5

    # The loop result carries only the bounded window the definition asked for.
    assert Enum.map(long.output["scratchpad"], & &1["i"]) == [397, 398, 399]
  end
end
