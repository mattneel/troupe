defmodule Troupe.Runtime.Runner do
  @moduledoc false
  # Starts and resumes runs: validates inputs, resolves and authorizes
  # capabilities, writes the run record, and executes the compiled Reactor.

  alias Troupe.{Definition, Error, Expr, Grant, Registry, Run, Schema, Store}
  alias Troupe.Runtime.{Compiler, Context, Env, Journal}

  @output_key "#output"

  @spec run(Definition.t(), map(), keyword()) :: {:ok, Run.t()} | {:error, [Error.t()]}
  def run(%Definition{} = definition, inputs, opts) do
    store = Keyword.get_lazy(opts, :store, &Store.Memory.new/0)
    run_id = Keyword.get_lazy(opts, :run_id, &new_run_id/0)

    with {:ok, inputs} <- validate_inputs(definition, inputs),
         {:ok, ctx} <- prepare(definition, run_id, store, opts),
         :ok <- fresh(store, run_id),
         :ok <- Store.put_run(store, run_id, record(definition, inputs, "running")),
         :ok <-
           Journal.event(ctx, "run_started", %{
             "workflow" => definition.id,
             "version" => definition.version
           }) do
      execute(definition, inputs, ctx)
    end
    |> listify()
  end

  @spec resume(Store.t(), String.t(), keyword()) :: {:ok, Run.t()} | {:error, [Error.t()]}
  def resume(store, run_id, opts) do
    with {:ok, record} <- fetch(store, run_id),
         {:ok, definition} <- Definition.from_map(record["definition"]),
         :ok <- expected_definition(definition, Keyword.get(opts, :definition)),
         {:ok, ctx} <- prepare(definition, run_id, store, opts) do
      continue(record, definition, ctx)
    end
    |> listify()
  end

  defp continue(%{"status" => "completed"}, _definition, ctx) do
    with {:ok, output} <- Journal.payload(ctx, @output_key) do
      {:ok, %Run{id: ctx.run_id, output: output, store: ctx.store}}
    end
  end

  defp continue(record, definition, ctx) do
    with :ok <- reset_failed_activation(record, ctx),
         :ok <- Journal.event(ctx, "run_resumed", %{"previous_status" => record["status"]}) do
      execute(definition, record["inputs"], ctx)
    end
  end

  # Resuming a failed run is an explicit operator decision to try again: the
  # activation that failed gets a fresh max_attempts budget while its attempt
  # numbers keep counting up.
  defp reset_failed_activation(
         %{"status" => "failed", "error" => %{"details" => %{"activation" => activation}}},
         ctx
       ) do
    key = Journal.attempts_key(activation)

    case Journal.checkpoint(ctx, key) do
      {:ok, attempts} -> Journal.put_checkpoint(ctx, key, %{attempts | "failures" => 0})
      :none -> :ok
    end
  end

  defp reset_failed_activation(_record, _ctx), do: :ok

  defp execute(definition, inputs, ctx) do
    reactor = Compiler.workflow(definition)

    case Reactor.run(reactor, %{scope: %Env{inputs: inputs}}, %{troupe: ctx}, async?: ctx.async?) do
      {:ok, output} ->
        with :ok <- Journal.put_payload(ctx, @output_key, output),
             :ok <- Store.put_run(ctx.store, ctx.run_id, record(definition, inputs, "completed")),
             :ok <- Journal.event(ctx, "run_completed", %{"payload" => @output_key}) do
          {:ok, %Run{id: ctx.run_id, output: output, store: ctx.store}}
        end

      {:error, reason} ->
        failed(definition, inputs, ctx, troupe_error(reason))

      {:halted, _reactor} ->
        failed(
          definition,
          inputs,
          ctx,
          Error.new(:action_failed, "the run halted before completing")
        )
    end
  end

  defp failed(definition, inputs, ctx, error) do
    error = %{error | details: Map.put(error.details, "run_id", ctx.run_id)}
    record = definition |> record(inputs, "failed") |> Map.put("error", Error.to_map(error))

    with :ok <- Store.put_run(ctx.store, ctx.run_id, record),
         :ok <-
           Journal.event(ctx, "run_failed", %{
             "error" => error.message,
             "kind" => Atom.to_string(error.kind)
           }) do
      {:error, [error]}
    end
  end

  defp prepare(definition, run_id, store, opts) do
    registry = Keyword.get_lazy(opts, :registry, &Registry.standard/0)
    grant = Keyword.get(opts, :grant, Grant.none())

    secrets =
      opts
      |> Keyword.get(:secrets, %{})
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    with {:ok, resolved} <- Registry.resolve_definition(registry, definition),
         :ok <- Grant.authorize(grant, resolved),
         :ok <- secrets_present(definition, secrets) do
      {:ok,
       %Context{
         run_id: run_id,
         store: store,
         resolved: resolved,
         secrets: secrets,
         async?: Keyword.get(opts, :async?, true)
       }}
    end
  end

  defp validate_inputs(definition, inputs) when is_map(inputs) do
    inputs =
      Map.new(inputs, fn {key, value} ->
        {if(is_atom(key), do: Atom.to_string(key), else: key), value}
      end)

    case Schema.validate_fields(inputs, definition.inputs, "input", :invalid_inputs) do
      {:ok, inputs} -> {:ok, inputs}
      {:error, errors} -> {:error, Enum.map(errors, &%{&1 | path: "/inputs" <> (&1.path || "")})}
    end
  end

  defp validate_inputs(_definition, inputs),
    do:
      {:error,
       [
         Error.new(
           :invalid_inputs,
           "inputs must be a map, got #{Troupe.PlainData.describe(inputs)}"
         )
       ]}

  defp secrets_present(definition, secrets) do
    missing =
      for site <- Troupe.Definition.Scope.sites(definition),
          {:secret, name} <- Expr.refs(site.expr),
          not Map.has_key?(secrets, name),
          uniq: true do
        Error.new(
          :invalid_inputs,
          "secret #{inspect(name)} is referenced but was not provided in :secrets",
          path: site.pointer
        )
      end

    if missing == [], do: :ok, else: {:error, missing}
  end

  defp fresh(store, run_id) do
    case Store.fetch_run(store, run_id) do
      :error ->
        :ok

      {:ok, _record} ->
        {:error,
         Error.new(
           :invalid_inputs,
           "run #{inspect(run_id)} already exists; resume it with Troupe.resume/3"
         )}
    end
  end

  defp fetch(store, run_id) do
    case Store.fetch_run(store, run_id) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, Error.new(:run_not_found, "no run #{inspect(run_id)} in this store")}
    end
  end

  defp expected_definition(_stored, nil), do: :ok
  defp expected_definition(stored, stored), do: :ok

  defp expected_definition(stored, %Definition{} = given) do
    {:error,
     Error.new(
       :definition_mismatch,
       "run was started with #{stored.id}@#{stored.version}, but a different definition (#{given.id}@#{given.version}) was supplied"
     )}
  end

  defp record(definition, inputs, status) do
    %{"definition" => Definition.to_map(definition), "inputs" => inputs, "status" => status}
  end

  defp new_run_id, do: "run-" <> Base.encode16(:rand.bytes(8), case: :lower)

  defp listify({:error, %Error{} = error}), do: {:error, [error]}
  defp listify(other), do: other

  # Reactor wraps step errors (Splode); dig out the Troupe.Error a step returned.
  defp troupe_error(reason) do
    find_error(reason) ||
      Error.new(
        :action_failed,
        if(is_exception(reason), do: Exception.message(reason), else: inspect(reason))
      )
  end

  defp find_error(%Error{} = error), do: error
  defp find_error(list) when is_list(list), do: Enum.find_value(list, &find_error/1)

  defp find_error(%{} = map) do
    Enum.find_value([:error, :errors, :reason, :value], fn key ->
      find_error(Map.get(map, key))
    end)
  end

  defp find_error(_other), do: nil
end
