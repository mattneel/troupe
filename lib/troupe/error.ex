defmodule Troupe.Error do
  @moduledoc """
  Structured error returned by validation, permission checks and execution.

  `kind` is a stable machine-readable atom, `path` locates the problem inside
  the portable definition (JSON-pointer style, e.g. `"/nodes/1/args/text"`),
  and `details` carries plain data useful to tools and agents.
  """

  @type kind ::
          :invalid_definition
          | :unsupported_schema_version
          | :invalid_reference
          | :not_plain_data
          | :possible_secret
          | :unknown_capability
          | :not_granted
          | :invalid_inputs
          | :invalid_arguments
          | :invalid_result
          | :action_failed
          | :attempts_exhausted
          | :definition_mismatch
          | :run_not_found
          | :decode_failed
          | :store_failed

  @type t :: %__MODULE__{
          kind: kind(),
          message: String.t(),
          path: String.t() | nil,
          details: map()
        }

  defexception [:kind, :message, path: nil, details: %{}]

  @doc "Builds an error."
  @spec new(kind(), String.t(), keyword()) :: t()
  def new(kind, message, opts \\ []) do
    %__MODULE__{
      kind: kind,
      message: message,
      path: Keyword.get(opts, :path),
      details: Keyword.get(opts, :details, %{})
    }
  end

  @impl true
  def message(%__MODULE__{message: message, path: nil, kind: kind}), do: "#{kind}: #{message}"

  def message(%__MODULE__{message: message, path: path, kind: kind}),
    do: "#{kind} at #{path}: #{message}"

  @doc "Converts an error into JSON-compatible data."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    %{
      "kind" => Atom.to_string(error.kind),
      "message" => error.message,
      "path" => error.path,
      "details" => error.details
    }
  end
end
