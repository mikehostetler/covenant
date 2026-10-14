defmodule Covenant.Mutate.Job do
  @moduledoc false

  @doc false
  def run(milliseconds, fun) do
    owner = self()
    guard = spawn(fn -> loop(Process.monitor(owner), %{}, deadline(milliseconds), nil) end)
    handler = {__MODULE__.Signals, guard}
    :ok = :gen_event.add_handler(:erl_signal_server, handler, guard)
    :ok = :os.set_signal(:sigterm, :handle)

    try do
      fun.(guard)
    after
      :gen_event.delete_handler(:erl_signal_server, handler, :normal)
      :os.set_signal(:sigterm, :default)
      send(guard, :done)
    end
  end

  @doc false
  def watch(guard, task) do
    Process.unlink(task.pid)
    ref = make_ref()
    send(guard, {:watch, task.pid, self(), ref})

    receive do
      ^ref -> :ok
    end

    task
  end

  @doc false
  def artifacts(guard, directory), do: send(guard, {:artifacts, directory})

  defp deadline(milliseconds), do: System.monotonic_time(:millisecond) + milliseconds

  defp loop(owner, workers, deadline, directory) do
    receive do
      {:watch, pid, caller, ref} ->
        monitor = Process.monitor(pid)
        send(caller, ref)
        loop(owner, Map.put(workers, monitor, pid), deadline, directory)

      {:artifacts, directory} ->
        loop(owner, workers, deadline, directory)

      {:DOWN, ^owner, :process, _, _} ->
        stop(workers)

      {:DOWN, ref, :process, _, _} ->
        loop(owner, Map.delete(workers, ref), deadline, directory)

      :done ->
        stop(workers)

      :cancel ->
        halt(workers, directory, "job cancelled by SIGTERM")
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        halt(workers, directory, "job deadline exceeded")
    end
  end

  defp halt(workers, directory, reason) do
    IO.puts(:stderr, "covenant.mutate: #{reason}")
    if directory, do: IO.puts(:stderr, "covenant.mutate: partial results: #{directory}")
    stop(workers)
    System.halt(1)
  end

  # These are the task owners of the worker ports. Killing the owners closes
  # the ports. The workers' stdin watchers then remove their copies and halt.
  defp stop(workers), do: Enum.each(workers, fn {_, pid} -> Process.exit(pid, :kill) end)
end

defmodule Covenant.Mutate.Job.Signals do
  @moduledoc false
  @behaviour :gen_event
  @impl true
  def init(guard), do: {:ok, guard}
  @impl true
  def handle_event(:sigterm, guard) do
    send(guard, :cancel)
    {:ok, guard}
  end

  def handle_event(_, guard), do: {:ok, guard}
  @impl true
  def handle_call(_, guard), do: {:ok, :ok, guard}
  @impl true
  def handle_info(_, guard), do: {:ok, guard}
  @impl true
  def terminate(_, _), do: :ok
  @impl true
  def code_change(_, guard, _), do: {:ok, guard}
end
