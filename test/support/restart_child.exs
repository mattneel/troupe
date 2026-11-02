# Runs in a fresh OS process (`elixir -pa ... restart_child.exs ...`) for
# Troupe.RestartTest. Not compiled into the test build.
#
#   start  STORE RUN_ID DEFINITION_JSON START HALT_AFTER
#     runs the workflow and halts the VM (status 70) as soon as HALT_AFTER
#     activations have durably completed; HALT_AFTER 0 means run to the end
#   resume STORE RUN_ID
#     resumes the run from the store alone

{:ok, _apps} = Application.ensure_all_started(:troupe)

store_dir = Enum.at(System.argv(), 1)
run_id = Enum.at(System.argv(), 2)
store = Troupe.Store.File.new(store_dir)

opts = [
  store: store,
  registry: Troupe.TestCapabilities.registry(),
  grant: Troupe.TestCapabilities.grant(),
  async?: false
]

report = fn
  {:ok, run} ->
    IO.puts("OUTPUT " <> Jason.encode!(run.output))
    System.halt(0)

  {:error, errors} ->
    Enum.each(errors, &IO.puts("ERROR " <> Exception.message(&1)))
    System.halt(1)
end

case System.argv() do
  ["start", _store, _run, path, start, halt_after] ->
    halt_after = String.to_integer(halt_after)
    counter = :counters.new(1, [])

    :telemetry.attach(
      "halt-after",
      [:troupe, :event],
      fn
        _name, _measurements, %{event: %{"type" => "activation_completed"}}, _config ->
          :counters.add(counter, 1, 1)
          if :counters.get(counter, 1) == halt_after, do: :erlang.halt(70, flush: false)

        _name, _measurements, _metadata, _config ->
          :ok
      end,
      nil
    )

    definition = Troupe.JSON.decode!(File.read!(path))

    report.(
      Troupe.run(definition, %{"start" => String.to_integer(start)}, [run_id: run_id] ++ opts)
    )

  ["resume", _store, _run] ->
    report.(Troupe.resume(store, run_id, opts))
end
