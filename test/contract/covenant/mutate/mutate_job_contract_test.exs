defmodule Covenant.MutateJobContractTest do
  use Covenant.Case, component: "covenant.mutate", async: false
  @moduletag :e2e
  @moduletag timeout: 60_000
  @project Path.expand("../../../fixtures/mutate/vm_project", __DIR__)

  @tag obligation: "covenant.mutate.I27"
  test "a worker crash preserves its completed verdicts without claiming a complete run" do
    {output, status} = mix(["covenant.mutate", "vm.checkpoint", "--jobs", "1"])
    assert status == 1, output
    assert output =~ "exited with status 7", output
    assert [_, path] = Regex.run(~r/partial results: ([^\n]+)/, output)
    assert File.dir?(path)
    on_exit(fn -> File.rm_rf!(path) end)
    [raw] = Path.wildcard(Path.join(path, "raw-*.json"))
    data = raw |> File.read!() |> JSON.decode!()
    assert data["complete"] == false
    assert [%{"id" => "m001", "verdict" => "killed"}] = data["mutants"]
    assert data["all"] == 3
  end

  @tag obligation: "covenant.mutate.I27"
  test "a zero-status worker crash cannot turn a checkpoint into a complete matrix" do
    {output, status} =
      System.cmd(
        System.find_executable("mix"),
        ["covenant.mutate", "vm.checkpoint", "--jobs", "1"],
        cd: @project,
        env: [
          {"MIX_ENV", "test"},
          {"COVENANT_RESULTS_DIR", nil},
          {"COVENANT_CHECKPOINT_EXIT", "0"}
        ],
        stderr_to_stdout: true
      )

    assert status == 1, output
    assert output =~ "results are incomplete", output
    assert [_, path] = Regex.run(~r/partial results: ([^\n]+)/, output)
    on_exit(fn -> File.rm_rf!(path) end)
    refute output =~ "every mutant is caught or sorted"
  end

  @tag obligation: "covenant.mutate.I27"
  test "the total deadline stops a job even before its first verdict" do
    {output, status} = mix(["covenant.mutate", "vm.hang", "--jobs", "1", "--max-runtime", "1000"])
    assert status == 1, output
    assert output =~ "job deadline", output
    refute output =~ "every mutant is caught or sorted"
  end

  @tag obligation: "covenant.mutate.I27"
  test "the total deadline must be positive before workers start" do
    for value <- ["0", "-1"] do
      {output, status} = mix(["covenant.mutate", "vm.checkpoint", "--max-runtime", value])

      assert status != 0
      assert output =~ "--max-runtime must be positive"
      refute output =~ "raw results:"
    end
  end

  @tag obligation: ["covenant.mutate.I27", "covenant.mutate.I28"]
  test "the same job deadline stops a replacement worker" do
    {output, status} =
      mix(
        [
          "covenant.mutate",
          "vm.checkpoint",
          "--max-mutants-per-worker",
          "1",
          "--timeout",
          "20000",
          "--max-runtime",
          "10000"
        ],
        [{"COVENANT_CHECKPOINT_WAIT", "1"}]
      )

    assert status == 1, output
    assert output =~ "retired after 1 verified verdict(s)", output
    assert output =~ "job deadline exceeded", output
    assert [_, worker, directory] = Regex.run(~r/CHECKPOINT_WAIT (\d+) ([^\n]+)/, output)
    assert [_, path] = Regex.run(~r/partial results: ([^\n]+)/, output)
    on_exit(fn -> File.rm_rf!(path) end)

    assert Enum.any?(1..100, fn _ ->
             {_, alive} = System.cmd("kill", ["-0", worker], stderr_to_stdout: true)
             (not File.exists?(directory) and alive != 0) or Process.sleep(20) == :never
           end)
  end

  @tag obligation: ["covenant.mutate.I27", "covenant.mutate.I28"]
  test "SIGTERM cancels a live worker and retains its checkpoint" do
    port =
      Port.open({:spawn_executable, System.find_executable("mix")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, @project},
        {:env, [{~c"MIX_ENV", ~c"test"}, {~c"COVENANT_CHECKPOINT_WAIT", ~c"1"}]},
        {:args,
         [
           "covenant.mutate",
           "vm.checkpoint",
           "--jobs",
           "1",
           "--max-mutants-per-worker",
           "1",
           "--max-runtime",
           "60000"
         ]}
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    output = wait_for_worker(port, "")
    assert output =~ "retired after 1 verified verdict(s)", output
    assert [_, worker, directory] = Regex.run(~r/CHECKPOINT_WAIT (\d+) ([^\n]+)/, output)
    assert {:os_pid, manager} = Port.info(port, :os_pid)
    {_, 0} = System.cmd("kill", ["-TERM", Integer.to_string(manager)])
    {output, status} = finished(port, output)
    assert status == 1, output
    assert output =~ "job cancelled by SIGTERM", output
    assert [_, path] = Regex.run(~r/partial results: ([^\n]+)/, output)
    on_exit(fn -> File.rm_rf!(path) end)
    [raw] = Path.wildcard(Path.join(path, "raw-*.json"))
    assert [%{"id" => "m001", "verdict" => "killed"}] = JSON.decode!(File.read!(raw))["mutants"]
    # The port closes first; its worker acknowledges parent loss by removing
    # its private directory before halting. Wait for that observable cleanup.
    assert Enum.any?(1..100, fn _ ->
             {_, alive} = System.cmd("kill", ["-0", worker], stderr_to_stdout: true)
             (not File.exists?(directory) and alive != 0) or Process.sleep(20) == :never
           end)
  end

  @tag obligation: "covenant.mutate.I25"
  test "runtime mode purges deleted helpers after baseline, mutations and final verification" do
    probe = Path.expand("../../../fixtures/mutate/runtime_cleanup_probe.exs", __DIR__)
    {output, status} = mix(["run", probe])
    assert status == 0, output
    assert output =~ "RUNTIME_CLEANUP_OK"
  end

  defp wait_for_worker(port, output) do
    receive do
      {^port, {:data, data}} ->
        output = output <> data

        if Regex.match?(~r/CHECKPOINT_WAIT \d+ [^\n]+\n/, output),
          do: output,
          else: wait_for_worker(port, output)

      {^port, {:exit_status, status}} ->
        flunk("worker exited #{status}: #{output}")
    after
      15_000 -> flunk("worker did not reach its barrier: #{output}")
    end
  end

  defp finished(port, output) do
    receive do
      {^port, {:data, data}} -> finished(port, output <> data)
      {^port, {:exit_status, status}} -> {output, status}
    after
      5_000 -> flunk("cancellation did not stop the manager: #{output}")
    end
  end

  defp mix(args, env \\ []) do
    System.cmd(System.find_executable("mix"), args,
      cd: @project,
      env: [{"MIX_ENV", "test"}, {"COVENANT_RESULTS_DIR", nil}] ++ env,
      stderr_to_stdout: true
    )
  end
end
