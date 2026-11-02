defmodule Troupe.TestCapabilities do
  @moduledoc false
  # Capabilities with observable side effects (files), so tests can count real
  # executions across processes.

  @doc false
  def modules, do: [__MODULE__.Record, __MODULE__.Flaky, __MODULE__.Ledger, __MODULE__.Bad]

  @doc false
  def registry, do: Troupe.Registry.new!(Troupe.Capabilities.modules() ++ modules())

  @doc false
  def grant, do: Troupe.Grant.new!(["test.*", "text.*", "math.*", "list.*", "agent.*"])

  @doc false
  def lines(path) do
    case File.read(path) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end
end

defmodule Troupe.TestCapabilities.Record do
  @moduledoc false
  # Appends "<label> <activation> <os pid>" to `log`, returns value + 1. If
  # `crash_marker` is given and missing, creates it and halts the VM right
  # after the side effect — before Troupe can checkpoint the result.
  use Troupe.Capability,
    name: "test.record",
    version: "1.0.0",
    inputs: [
      log: :string,
      label: :string,
      value: :integer,
      crash_marker: [type: :string, default: nil]
    ],
    output: :integer

  @impl true
  def run(%{"log" => log, "label" => label, "value" => value} = args, context) do
    File.write!(log, "#{label} #{context.activation_id} #{System.pid()}\n", [:append])

    with marker when is_binary(marker) <- args["crash_marker"],
         false <- File.exists?(marker) do
      File.write!(marker, "")
      :erlang.halt(71, flush: false)
    end

    {:ok, value + 1}
  end
end

defmodule Troupe.TestCapabilities.Flaky do
  @moduledoc false
  # Fails (retryably) while the counter file holds fewer than `fail_times`
  # failures; `fail_until` makes it fail permanently while that file exists.
  use Troupe.Capability,
    name: "test.flaky",
    version: "1.0.0",
    inputs: [
      counter: :string,
      fail_times: [type: :integer, default: 0],
      block: [type: :string, default: nil]
    ],
    output: :map

  @impl true
  def run(%{"counter" => counter, "fail_times" => fail_times} = args, context) do
    calls = length(Troupe.TestCapabilities.lines(counter)) + 1
    File.write!(counter, "#{context.attempt_id}\n", [:append])

    cond do
      is_binary(args["block"]) and File.exists?(args["block"]) ->
        {:error, "blocked by #{args["block"]}"}

      calls <= fail_times ->
        {:retry, "transient failure #{calls}"}

      true ->
        {:ok,
         %{"calls" => calls, "attempt_id" => context.attempt_id, "key" => context.idempotency_key}}
    end
  end
end

defmodule Troupe.TestCapabilities.Ledger do
  @moduledoc false
  # An external "payment" with reconciliation: entries are keyed by the
  # idempotency key, so a crashed attempt can be recognised on resume.
  use Troupe.Capability,
    name: "test.ledger",
    version: "1.0.0",
    inputs: [ledger: :string, amount: :integer, crash_marker: [type: :string, default: nil]],
    output: :string

  @impl true
  def run(%{"ledger" => ledger, "amount" => amount} = args, context) do
    File.write!(ledger, "#{context.idempotency_key} #{amount}\n", [:append])

    with marker when is_binary(marker) <- args["crash_marker"],
         false <- File.exists?(marker) do
      File.write!(marker, "")
      :erlang.halt(72, flush: false)
    end

    {:ok, "charged #{amount}"}
  end

  @impl true
  def reconcile(%{"ledger" => ledger, "amount" => amount}, context) do
    if "#{context.idempotency_key} #{amount}" in Troupe.TestCapabilities.lines(ledger),
      do: {:ok, "charged #{amount}"},
      else: :unknown
  end
end

defmodule Troupe.TestCapabilities.Bad do
  @moduledoc false
  # Returns a value that is not plain data.
  use Troupe.Capability, name: "test.bad", version: "1.0.0", inputs: [], output: :any

  @impl true
  def run(_args, _context), do: {:ok, {:not, :plain}}
end
