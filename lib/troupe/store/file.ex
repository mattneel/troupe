defmodule Troupe.Store.File do
  @moduledoc """
  Durable store on the local filesystem; a run can be resumed by a fresh OS
  process pointing at the same directory.

  Layout per run (`<dir>/runs/<run-id>/`):

    * `run.etf` — run record
    * `events.log` — append-only history, length-prefixed term frames
    * `payloads/<hash>.etf`, `checkpoints/<hash>.etf` — one file per key

  Records are written to a temporary file, `fsync`ed and renamed into place,
  so a crash leaves either the old or the new record. A torn final history
  frame is ignored when reading. Directory entries are not separately
  fsynced; on filesystems that need it, a rename can be lost on power failure
  (not on process crash). Each file stores its full key, verified on read.
  """

  alias Troupe.Error

  @type t :: %__MODULE__{dir: String.t()}

  @enforce_keys [:dir]
  defstruct [:dir]

  @doc "Uses (and creates) `dir` as the store root."
  @spec new(Path.t()) :: t()
  def new(dir) do
    dir = Path.expand(dir)
    File.mkdir_p!(dir)
    %__MODULE__{dir: dir}
  end

  @doc false
  def run_dir(%__MODULE__{dir: dir}, run_id), do: Path.join([dir, "runs", file_name(run_id)])

  @doc false
  def key_path(store, run_id, kind, key),
    do: Path.join([run_dir(store, run_id), kind, file_name(key) <> ".etf"])

  # Hex MD5 keeps names short and filesystem-safe; the key itself is stored in
  # the file and checked on read, so a collision is detected, never silent.
  defp file_name(key), do: key |> :erlang.md5() |> Base.encode16(case: :lower)

  @doc false
  @spec write_record(String.t(), String.t(), term()) :: :ok | {:error, Error.t()}
  def write_record(path, key, value) do
    data = :erlang.term_to_binary({key, value})
    tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, fd} <- :file.open(tmp, [:write, :binary, :raw]),
         :ok <- write_and_sync(fd, data),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} -> store_error("write #{path}", reason)
    end
  end

  defp write_and_sync(fd, data) do
    with :ok <- :file.write(fd, data), :ok <- :file.sync(fd) do
      :file.close(fd)
    end
  end

  @doc false
  @spec read_record(String.t(), String.t()) :: {:ok, term()} | :error
  def read_record(path, key) do
    with {:ok, data} <- File.read(path),
         {^key, value} <- :erlang.binary_to_term(data, [:safe]) do
      {:ok, value}
    else
      _missing_or_mismatch -> :error
    end
  end

  @doc false
  @spec append(String.t(), term()) :: :ok | {:error, Error.t()}
  def append(path, term) do
    frame = :erlang.term_to_binary(term)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, fd} <- :file.open(path, [:append, :binary, :raw]),
         :ok <- write_and_sync(fd, <<byte_size(frame)::32, frame::binary>>) do
      :ok
    else
      {:error, reason} -> store_error("append #{path}", reason)
    end
  end

  @doc false
  @spec read_frames(String.t()) :: [term()]
  def read_frames(path) do
    case File.read(path) do
      {:ok, data} -> frames(data, [])
      {:error, _reason} -> []
    end
  end

  defp frames(<<size::32, frame::binary-size(size), rest::binary>>, acc),
    do: frames(rest, [:erlang.binary_to_term(frame, [:safe]) | acc])

  defp frames(_torn_or_empty, acc), do: Enum.reverse(acc)

  @doc false
  def count_files(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.count(names, &String.ends_with?(&1, ".etf"))
      {:error, _reason} -> 0
    end
  end

  defp store_error(action, reason),
    do: {:error, Error.new(:store_failed, "could not #{action}: #{inspect(reason)}")}

  defimpl Troupe.Store do
    alias Troupe.Store.File, as: FileStore

    def put_run(store, run_id, record),
      do:
        FileStore.write_record(
          Path.join(FileStore.run_dir(store, run_id), "run.etf"),
          run_id,
          record
        )

    def fetch_run(store, run_id),
      do: FileStore.read_record(Path.join(FileStore.run_dir(store, run_id), "run.etf"), run_id)

    def append_event(store, run_id, event),
      do: FileStore.append(events_path(store, run_id), event)

    def events(store, run_id), do: FileStore.read_frames(events_path(store, run_id))

    def put_payload(store, run_id, key, value),
      do: FileStore.write_record(FileStore.key_path(store, run_id, "payloads", key), key, value)

    def fetch_payload(store, run_id, key),
      do: FileStore.read_record(FileStore.key_path(store, run_id, "payloads", key), key)

    def put_checkpoint(store, run_id, key, value),
      do:
        FileStore.write_record(FileStore.key_path(store, run_id, "checkpoints", key), key, value)

    def fetch_checkpoint(store, run_id, key),
      do: FileStore.read_record(FileStore.key_path(store, run_id, "checkpoints", key), key)

    def stats(store, run_id) do
      dir = FileStore.run_dir(store, run_id)

      %{
        events: length(events(store, run_id)),
        payloads: FileStore.count_files(Path.join(dir, "payloads")),
        checkpoints: FileStore.count_files(Path.join(dir, "checkpoints"))
      }
    end

    defp events_path(store, run_id), do: Path.join(FileStore.run_dir(store, run_id), "events.log")
  end
end
