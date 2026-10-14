defmodule Covenant.MutateTaskContractTest do
  @moduledoc """
  `mix covenant.mutate` as a user runs it: the task around the engine, driven in
  the fixture projects. `vm_project` holds components whose mutants write by a
  relative path, never end, or stop the VM.
  """

  use Covenant.Case, component: "covenant.mutate", async: false

  alias Covenant.ContractBuilder
  alias Mix.Tasks.Covenant.Mutate, as: Task

  @moduletag :e2e
  @moduletag timeout: 600_000

  @vm Path.expand("../../../fixtures/mutate/vm_project", __DIR__)
  @example ContractBuilder.fixture_project()
  @escaped Path.join(@vm, "covenant_mutate_escaped.txt")
  @probe Path.expand("../../../fixtures/mutate/runner_probe.exs", __DIR__)

  defp mix(project, args, env \\ [{"MIX_ENV", "dev"}], redirect \\ nil) do
    mix = System.find_executable("mix") || raise "mix not on PATH"
    env = [{"COVENANT_RESULTS_DIR", nil}, {"COVENANT_TMPDIR_LOG", nil} | env]

    case redirect do
      nil ->
        System.cmd(mix, args, cd: project, env: env, stderr_to_stdout: true)

      redirect ->
        command = Enum.map_join([mix | args], " ", &"'#{&1}'") <> " #{redirect}"
        System.cmd("sh", ["-c", command], cd: project, env: env, stderr_to_stdout: true)
    end
  end

  defp matrix(project, relative),
    do: Path.join(project, relative) |> File.read!() |> JSON.decode!()

  @tag obligation: "covenant.mutate.I22"
  test "--jobs 1 runs the mutants in a private copy: a mutant that writes by a relative path leaves the project untouched" do
    File.rm_rf!(@escaped)
    on_exit(fn -> File.rm_rf!(@escaped) end)

    {output, _status} =
      mix(@vm, ["covenant.mutate", "vm.touch", "--jobs", "1", "--out", "tmp/touch.json"])

    # the mutant that negates `if flag` ran, and survived (its test passes)
    assert output =~ ~r/SURVIVED/
    refute File.exists?(@escaped)
  end

  @tag obligation: "covenant.mutate.I22"
  test "a mutant that never ends is a timeout, the worker is respawned for the rest, and every mutant is reported" do
    {output, status} = mix(@vm, ["covenant.mutate", "vm.spin", "--out", "tmp/spin.json"])

    assert status == 1
    assert output =~ ~r/m\d+ .* \[timeout\]/
    assert output =~ "stopped by its watchdog"

    matrix = matrix(@vm, "tmp/spin.json")
    verdicts = Enum.map(matrix["mutants"], & &1["verdict"])
    assert "timeout" in verdicts
    assert Enum.any?(verdicts, &(&1 in ["killed", "survived"]))
    ids = Enum.map(matrix["mutants"], & &1["id"])
    assert ids == Enum.uniq(ids)
    assert length(ids) == matrix["summary"]["mutants"]
    assert matrix["summary"]["timeouts"] >= 1
    assert Path.wildcard(Path.join(@vm, "tmp/covenant/mutate/vm.spin/run-*")) == []
  end

  @tag obligation: "covenant.mutate.I22"
  test "two runs of one component at once do not clobber each other's raw results" do
    runs =
      for name <- ["a", "b"] do
        Elixir.Task.async(fn ->
          mix(@example, [
            "covenant.mutate",
            "example.counter",
            "--out",
            "tmp/concurrent-#{name}.json"
          ])
        end)
      end

    assert [{_, 0}, {_, 0}] = Elixir.Task.await_many(runs, 600_000)

    [a, b] = for name <- ["a", "b"], do: matrix(@example, "tmp/concurrent-#{name}.json")

    assert Enum.map(a["mutants"], &{&1["id"], &1["verdict"]}) ==
             Enum.map(b["mutants"], &{&1["id"], &1["verdict"]})

    assert Path.wildcard(Path.join(@example, "tmp/covenant/mutate/example.counter/run-*")) == []
  end

  @tag obligation: "covenant.mutate.I23"
  test "jobs are capped at the number of mutants, and a count over the schedulers is warned about" do
    assert {3, [_]} = Task.jobs_for(8, 3, 16)
    assert {2, [capped]} = Task.jobs_for(8, 2, 16)
    assert capped =~ "--jobs 8: only 2 mutant(s), running 2 worker(s)"
    assert {8, []} = Task.jobs_for(8, 100, 8)
    assert {9, [warning]} = Task.jobs_for(9, 100, 4)
    assert warning =~ "--jobs 9 exceeds the 4 schedulers online"
    assert {5, []} = Task.jobs_for(5, nil, 8)
    assert {1, []} = Task.jobs_for(1, 0, 8)
  end

  @tag obligation: "covenant.mutate.I22", tmp_dir: true
  test "publishing a matrix keeps another run's temporary output", %{tmp_dir: directory} do
    path = Path.join(directory, "matrix.json")
    other_run = path <> ".tmp"
    File.write!(other_run, "another run is writing here")

    {output, status} = mix(@vm, ["covenant.mutate", "vm.retirement", "--out", path])

    assert status == 0, output
    assert {:ok, "another run is writing here"} = File.read(other_run)
    assert JSON.decode!(File.read!(path))["summary"]["killed"] == 3
    assert Path.wildcard(path <> ".*.tmp") == []
  end

  @tag obligation: "covenant.mutate.I23"
  test "when one worker fails the others are stopped, not waited for" do
    parent = self()

    sleeper =
      Elixir.Task.async(fn ->
        send(parent, {:sleeper, self()})
        Process.sleep(:infinity)
      end)

    failing = Elixir.Task.async(fn -> {:error, "worker 2/2 exited with status 1"} end)
    assert_receive {:sleeper, sleeper_pid}
    ref = Process.monitor(sleeper_pid)

    assert {:error, "worker 2/2 exited with status 1"} = Task.await_workers([sleeper, failing])
    assert_receive {:DOWN, ^ref, :process, ^sleeper_pid, _}, 2_000

    ok = Elixir.Task.async(fn -> {:ok, [:raw]} end)
    assert {:ok, [:raw]} = Task.await_workers([ok])
  end

  @tag obligation: "covenant.mutate.I23"
  test "a worker halts with status 1 when its standard input ends, and a port's program sees that end when the port closes" do
    dir = Path.join(System.tmp_dir!(), "orphan-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    raw = Path.join(dir, "raw.json")

    # a worker whose stdin is already at its end stops at once, writing nothing
    {_, status} =
      mix(
        @vm,
        ["covenant.mutate", "vm.touch", "--raw", raw, "--slice", "1/1", "--out", dir],
        [{"MIX_ENV", "test"}],
        "< /dev/null"
      )

    assert status == 1
    refute File.exists?(raw)

    # `System.cmd` runs the worker through a port: closing the port, as the death of
    # its owner does, ends the worker's stdin
    marker = Path.join(dir, "stdin-ended")

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        {:args, ["-c", "cat > /dev/null; touch #{marker}"]}
      ])

    refute File.exists?(marker)
    Port.close(port)
    assert Enum.any?(1..50, fn _ -> File.exists?(marker) or Process.sleep(100) == :never end)
  end

  @tag obligation: "covenant.mutate.I20"
  test "a failing :on_timeout callback does not let a stray mutant process write into the project" do
    tmp = Path.join(@vm, "tmp")
    File.rm_rf!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {output, status} =
      mix(
        @vm,
        [
          "run",
          @probe,
          "vm.writer",
          "Vm.Writer",
          "lib/vm/writer.ex",
          "test/contract/vm/writer_contract_test.exs"
        ],
        [{"MIX_ENV", "test"}, {"PROBE_RAISE", "1"}]
      )

    assert status == 3
    assert output =~ "the :on_timeout callback failed"
    assert output =~ "the callback failed"
    refute File.exists?(tmp)
  end

  @tag obligation: "covenant.mutate.I11"
  test "a results file with a mutant of an unknown operator is an error naming the file, not a crash" do
    dir = Path.join(System.tmp_dir!(), "raw-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "raw.json")

    File.write!(path, ~s({"tests": [], "mutants": [{"id": "m007", "operator": "frobnicate"}]}))

    assert {:error, message} = Covenant.Mutate.decode_raw(path)
    assert message == ~s(#{path}: mutant "m007": unknown operator "frobnicate")
  end
end
