defmodule Covenant.MutateWorkerLifetimeContractTest do
  use Covenant.Case, component: "covenant.mutate", async: false
  @moduletag :e2e
  @moduletag timeout: 60_000
  @project Path.expand("../../../fixtures/mutate/vm_project", __DIR__)

  for {jobs, limit, workers} <- [{1, 1, 3}, {1, 2, 2}, {2, 1, 3}] do
    @tag obligation: "covenant.mutate.I28"
    test "#{jobs} worker slots with a #{limit}-mutation limit preserve every verdict" do
      directory = scratch()
      ledger = Path.join(directory, "ledger.jsonl")
      matrix = Path.join(directory, "matrix.json")

      {output, status} =
        mix(
          [
            "covenant.mutate",
            "vm.retirement",
            "--jobs",
            unquote(Integer.to_string(jobs)),
            "--max-mutants-per-worker",
            unquote(Integer.to_string(limit)),
            "--out",
            matrix
          ],
          [{"COVENANT_RETIREMENT_LEDGER", ledger}]
        )

      assert status == 0, output
      assert output =~ "retired after", output
      assert output =~ "every mutant is caught or sorted", output
      data = JSON.decode!(File.read!(matrix))
      assert data["summary"]["mutants"] == 3
      assert data["summary"]["killed"] == 3
      assert Enum.map(data["mutants"], & &1["id"]) == ["m001", "m002", "m003"]
      assert Enum.all?(data["mutants"], &(&1["credit"] == "exact"))

      runs = ledger |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      groups = Enum.group_by(runs, & &1["pid"])
      assert map_size(groups) == unquote(workers)

      for {pid, entries} <- groups do
        assert hd(entries)["value"] == 42
        assert List.last(entries)["value"] == 42
        assert length(entries) - 2 <= unquote(limit)
        assert {_, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
        assert status != 0
        refute File.exists?(hd(entries)["directory"])
      end

      if unquote(jobs) == 1 do
        # System.cmd waits for the old VM to exit before the next VM is started.
        # The ledger must therefore have one uninterrupted block per VM.
        blocks = Enum.chunk_by(runs, & &1["pid"])
        assert length(blocks) == map_size(groups)
      end

      assert [_, raw_directory] = Regex.run(~r/raw results: ([^\n]+)/, output)
      refute File.exists?(raw_directory)
    end
  end

  @tag obligation: "covenant.mutate.I28"
  test "failed final verification cannot retire a worker or start a replacement" do
    directory = scratch()
    ledger = Path.join(directory, "ledger.jsonl")

    {output, status} =
      mix(
        ["covenant.mutate", "vm.retirement", "--max-mutants-per-worker", "1"],
        [{"COVENANT_RETIREMENT_LEDGER", ledger}, {"COVENANT_RETIREMENT_POLLUTE", "1"}]
      )

    assert status == 1, output
    assert output =~ "unmutated suite is red after the last mutant", output
    refute output =~ "retired after"
    refute output =~ "starting a new worker"
    runs = ledger |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
    assert runs |> Enum.map(& &1["pid"]) |> Enum.uniq() |> length() == 1
    assert [_, raw_directory] = Regex.run(~r/partial results: ([^\n]+)/, output)
    on_exit(fn -> File.rm_rf!(raw_directory) end)
    assert [raw] = Path.wildcard(Path.join(raw_directory, "raw-*.json"))
    data = JSON.decode!(File.read!(raw))
    assert data["complete"] == false
    assert data["retired"] == false
    assert length(data["mutants"]) == 1
  end

  @tag obligation: "covenant.mutate.I28"
  test "worker mutation limits must be positive" do
    for value <- ["0", "-1"] do
      {output, status} =
        mix(["covenant.mutate", "vm.retirement", "--max-mutants-per-worker", value])

      assert status != 0
      assert output =~ "--max-mutants-per-worker must be positive", output
    end
  end

  defp scratch do
    directory =
      Path.join(System.tmp_dir!(), "covenant-retirement-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    directory
  end

  defp mix(args, env \\ []) do
    System.cmd(System.find_executable("mix"), args,
      cd: @project,
      env: [{"MIX_ENV", "test"}, {"COVENANT_RESULTS_DIR", nil}] ++ env,
      stderr_to_stdout: true
    )
  end
end
