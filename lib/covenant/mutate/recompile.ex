defmodule Covenant.Mutate.Recompile do
  @moduledoc false

  alias Covenant.Mutate.Mutator

  @type t :: %{files: [map()], originals: [{module(), binary(), charlist()}]}

  @doc false
  @spec prepare([Path.t()], Path.t(), [Path.t()]) :: {:ok, t()} | {:error, String.t()}
  def prepare(patterns, root, targets) do
    with {:ok, paths} <- expand(patterns, root, targets),
         {:ok, files} <- parse(paths),
         {:ok, compiled} <- compile(%{files: files}) do
      # Caller compilation establishes the baseline. A disk BEAM can be older
      # or use different compile-time settings, so retain these exact binaries.
      originals = Enum.map(compiled, fn {module, binary} -> {module, binary, ~c"nofile"} end)
      {:ok, %{files: files, originals: originals}}
    end
  end

  defp expand(patterns, root, targets) do
    root = Path.expand(root)

    Enum.reduce_while(patterns, {:ok, []}, fn pattern, {:ok, paths} ->
      matches = pattern |> Path.expand(root) |> Path.wildcard() |> Enum.sort()

      case Enum.find(matches, &(not allowed?(&1, root, targets))) do
        nil when matches != [] ->
          {:cont, {:ok, paths ++ matches}}

        nil ->
          {:halt, {:error, "recompile source not found: #{pattern}"}}

        path ->
          {:halt,
           {:error,
            "recompile source must be a project source outside the mutation targets: #{path}"}}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, paths |> Enum.reverse() |> Enum.uniq() |> Enum.reverse()}
      error -> error
    end
  end

  defp allowed?(path, root, targets) do
    relative = Path.relative_to(path, root)

    String.starts_with?(path, root <> "/") and
      Path.extname(path) in [".ex", ".exs"] and File.regular?(path) and
      :filelib.safe_relative_path(String.to_charlist(relative), String.to_charlist(root)) !=
        :unsafe and
      path not in targets
  end

  defp parse(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn file, {:ok, files} ->
      with {:ok, source} <- File.read(file),
           {:ok, ast} <- Mutator.parse(source, file) do
        {:cont, {:ok, files ++ [%{file: file, ast: ast}]}}
      else
        {:error, reason} ->
          {:halt, {:error, "cannot prepare recompile source #{file}: #{inspect(reason)}"}}
      end
    end)
  end

  @doc false
  @spec compile(map()) :: {:ok, [{module(), binary()}]} | {:error, String.t()}
  def compile(%{files: files}) do
    Enum.reduce_while(files, {:ok, []}, fn %{file: file, ast: ast}, {:ok, compiled} ->
      case Mutator.compile(ast, file) do
        {:ok, modules} -> {:cont, {:ok, compiled ++ modules}}
        {:error, reason} -> {:halt, {:error, "caller #{file} does not compile: #{reason}"}}
      end
    end)
  end

  @doc false
  @spec with_cleanup((-> result)) :: result when result: var
  def with_cleanup(fun) do
    loaded = loaded_modules()
    tracer = spawn_link(fn -> collect(MapSet.new()) end)
    session = :trace.session_create(__MODULE__, tracer, [])
    # Only the module name is sent, never the potentially large BEAM binary.
    match = [{[:"$1", [], :_], [], [{:message, :"$1"}]}]
    :trace.function(session, {:code, :load_binary, 3}, match, [:local])
    :trace.process(session, :all, true, [:call, :arity])

    try do
      fun.()
    after
      :trace.process(session, :all, false, [:call])
      ref = :trace.delivered(session, :all)

      receive do
        {:trace_delivered, :all, ^ref} -> :ok
      end

      send(tracer, {:modules, self(), ref})

      compiled =
        receive do
          {^ref, modules} -> modules
        end

      :trace.session_destroy(session)
      send(tracer, :stop)
      remove_generated(loaded, compiled)
    end
  end

  # Code.load_binary/3 observes Module.create/3 as well as compiler workers.
  # A deleted helper is absent from all_loaded/0 while old code can remain.
  defp collect(modules) do
    receive do
      {:trace, _pid, :call, {:code, :load_binary, 3}, module} ->
        collect(MapSet.put(modules, module))

      {:modules, caller, ref} ->
        send(caller, {ref, MapSet.to_list(modules)})
        collect(modules)

      :stop ->
        :ok

      _ ->
        collect(modules)
    end
  end

  @doc false
  @spec loaded_modules() :: MapSet.t(module())
  def loaded_modules, do: MapSet.new(:code.all_loaded(), &elem(&1, 0))

  @doc false
  @spec remove_generated(MapSet.t(module())) :: :ok
  def remove_generated(loaded, compiled \\ []) do
    # Elixir loads compiled modules with an empty code filename, including
    # Module.create/3 with virtual sources. Disk modules loaded on demand have
    # a BEAM filename and must remain loaded. The snapshot also protects all
    # modules that existed before this mutant, including in-memory fixtures.
    memory = for {module, []} <- :code.all_loaded(), do: module

    for module <- Enum.uniq(memory ++ compiled), not MapSet.member?(loaded, module) do
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end

    :ok
  end
end
