defmodule Covenant.SiblingE2EContractTest do
  @moduledoc """
  Runs the mix tasks as subprocesses in the sibling-layout fixture
  (`test/fixtures/sibling_project`), whose Contract is `contract/calc/`. Tests
  that change the fixture put every file back when they end.
  """

  use Covenant.Case, component: "covenant.primitive", async: false

  @moduletag :e2e
  @moduletag timeout: 300_000

  @project Path.expand("../../../fixtures/sibling_project", __DIR__)

  defp mix(args, env \\ []) do
    mix = System.find_executable("mix") || raise "mix not on PATH"
    env = [{"MIX_ENV", "dev"}, {"COVENANT_RESULTS_DIR", nil}, {"COVENANT_ROOT", nil}] ++ env
    System.cmd(mix, args, cd: @project, env: env, stderr_to_stdout: true)
  end

  # Writes `files` (relative to the fixture) for the test and puts the fixture back afterwards.
  defp change(files) do
    for {relative, text} <- files do
      path = Path.join(@project, relative)
      previous = if File.exists?(path), do: File.read!(path)

      on_exit(fn ->
        if previous, do: File.write!(path, previous), else: File.rm_rf!(path)
        if previous == nil, do: remove_empty_parents(Path.dirname(path))
      end)

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, text)
    end
  end

  defp remove_empty_parents(dir) do
    if dir != @project and File.ls!(dir) == [] do
      File.rmdir!(dir)
      remove_empty_parents(Path.dirname(dir))
    end
  end

  setup_all do
    File.rm_rf!(Path.join(@project, "_build/covenant"))
    File.rm_rf!(Path.join(@project, "tmp"))
    :ok
  end

  @tag obligation: "covenant.primitive.I6"
  test "mix covenant.check runs the Contract tests beside each README and reports the primitives" do
    {output, status} = mix(["covenant.check"])
    assert status == 0, output

    assert output =~ "covenant.check: running mix test contract"
    assert output =~ ~r/(3 tests, 0 failures|Result: 3 passed)/
    assert output =~ "  calc          2/2  100.0%"
    assert output =~ "  app contract      2/2  100.0%"
    assert output =~ "wrote contract/coverage.json"
    assert output =~ "covenant.check: the Contract holds"
    refute output =~ "declare no modules"

    coverage = @project |> Path.join("contract/coverage.json") |> File.read!() |> JSON.decode!()
    assert coverage["components"]["calc"]["obligations"]["calc/A1"]["passing"] == 1
    assert coverage["components"]["calc"]["obligations"]["calc/A2"]["passing"] == 2
  end

  @tag obligation: "covenant.primitive.I6"
  test "mix covenant.check fails on an unnamed obligation, a covers line naming no code, overlapping covers and a stray Contract comment" do
    readme = File.read!(Path.join(@project, "contract/calc/README.md"))

    change(%{
      "contract/calc/README.md" =>
        readme
        |> String.replace("```covers\nCalc\n", "```covers\nCalc\nCalc.missing/1\n")
        |> String.replace("- **A2**", "- **A3** Nothing names this one.\n- **A2**"),
      "contract/round/README.md" => "# round\n\nRounding.\n\n```covers\nCalc\n```\n",
      "test/stray_test.exs" => """
      defmodule StrayTest do
        use ExUnit.Case

        # Contract: calc/A1
        test "an implementation test that claims an obligation" do
          assert Calc.add(1, 1) == 2
        end
      end
      """
    })

    {output, status} = mix(["covenant.check"])
    assert status == 1, output

    assert output =~
             "contract/calc/README.md:8: obligation `calc/A3` is named by no Contract test; put `# Contract: calc/A3` above the test"

    assert output =~
             "contract/calc/README.md:13: covers `Calc.missing/1` names no code in this project"

    assert output =~
             "contract/round/README.md:6: `round` covers `Calc`, which `calc` covers too; one primitive owns a piece of code"

    assert output =~
             "test/stray_test.exs:4: a Contract comment or tag naming a primitive's obligation outside the sibling layout's directory"

    assert output =~ "covenant.check: 4 problem(s) found in the Contract"
  end

  @tag obligation: "covenant.primitive.I6"
  test "mix covenant.check --static reads the comments and skips the covers" do
    {output, status} = mix(["covenant.check", "--static"])
    assert status == 0, output

    assert output =~ "read 1 file(s), 1 contract test module(s), 3 tagged test(s) under"
    assert output =~ "  calc          2/2  100.0%"

    assert output =~
             "skipped (need compiled code): 0 exception target(s), 0 module ceiling(s), the covers of 1 primitive(s): calc"

    assert output =~ "wrote contract/coverage.static.json"
    assert output =~ "covenant.check: the Contract holds statically"

    change(%{
      "contract/calc/calc_test.exs" =>
        @project
        |> Path.join("contract/calc/calc_test.exs")
        |> File.read!()
        |> String.replace("  # Contract: calc/A1\n", "")
    })

    {output, status} = mix(["covenant.check", "--static"])
    assert status == 1, output

    assert output =~
             "contract/calc/calc_test.exs:4: test add sums its arguments names no obligation; put `# Contract: calc/<id>` on the line above it"
  end

  @tag obligation: "covenant.primitive.I7"
  test "mix covenant.mutate mutates what a primitive covers and sorts its survivors from mutants.md" do
    {output, status} = mix(["covenant.mutate", "calc"])
    assert status == 0, output

    assert output =~ "covenant.mutate: calc — modules (covers): Calc"
    assert output =~ "covenant.mutate: tests: contract/calc/calc_test.exs"
    assert output =~ "11 mutants: 9 killed, 2 survived, 0 timed out, 0 invalid"
    assert output =~ ~r"calc/A1\s+2\s+2"
    assert output =~ ~r"calc/A2\s+7\s+7"
    assert output =~ "Survivors (2; 0 unsorted)"

    assert output =~
             "comparison_swap `<` → `<=`  equivalent — At a bound, the bound is n: When `n` equals `lo`"

    assert output =~ "covenant.mutate: every mutant is caught or sorted"
  end

  @tag obligation: "covenant.primitive.I7"
  test "the most specific covers reference decides which primitive a mutant belongs to" do
    change(%{
      "contract/sum/README.md" =>
        "# sum\n\nSums.\n\n- **S1** Add adds.\n\n```covers\nCalc.add/2\n```\n",
      "contract/sum/sum_test.exs" => """
      defmodule Sum.ContractTest do
        use Covenant.Case, async: true

        # Contract: sum/S1
        test "add adds" do
          assert Calc.add(2, 2) == 4
        end
      end
      """
    })

    {output, status} = mix(["covenant.mutate", "calc"])
    assert status == 0, output
    assert output =~ "9 mutants: 7 killed, 2 survived"
    refute output =~ "a + b"

    {output, status} = mix(["covenant.mutate", "sum"])
    assert status == 0, output
    assert output =~ "covenant.mutate: sum — modules (covers): Calc"
    assert output =~ "2 mutants: 2 killed, 0 survived"
    assert output =~ ~r"sum/S1\s+2\s+2"
  end

  @tag obligation: "covenant.primitive.I7"
  test "a contradicted or unmatched declaration fails the run, and an unsorted survivor is printed for mutants.md" do
    change(%{
      "contract/calc/mutants.md" => """
      # Mutants the calc Contract leaves alone

      ## At a bound, the bound is n

      ```equivalent
      Calc.clamp/3: < -> <=
      ```

      ## Claims a test contradicts

      ```unpromised
      Calc.add/2: + -> -
      Calc.clamp/3: < -> >
      ```
      """
    })

    {output, status} = mix(["covenant.mutate", "calc"])
    assert status == 1, output

    assert output =~
             "contract/calc/mutants.md:12: declaration `Calc.add/2: + -> -` (m002) is contradicted: a Contract test kills that mutant"

    assert output =~
             "contract/calc/mutants.md:13: declaration `Calc.clamp/3: < -> >` matches no surviving mutant"

    assert output =~ "lib/calc.ex:13: mutant m009 (comparison_swap `>` → `>=`) survived"
    assert output =~ "```unpromised\nCalc.clamp/3: > -> >=\n```"
  end

  @tag obligation: "covenant.primitive.I7"
  test "mix covenant.regen packs a primitive with its README, tests, helper and stubs from its covers, and not mutants.md" do
    {output, status} = mix(["covenant.regen", "calc", "--out", "tmp/pack"])
    assert status == 0, output

    pack = Path.join(@project, "tmp/pack")

    for file <-
          ~w(PROMPT.md REGENERATION_BRIEF.md contract/calc/README.md contract/test_helper.exs
                  contract/calc/calc_test.exs stubs/lib/calc.ex) do
      assert File.exists?(Path.join(pack, file)), "#{file} is missing from the pack"
    end

    refute File.exists?(Path.join(pack, "lib/calc.ex"))
    refute File.exists?(Path.join(pack, "contract/calc/mutants.md"))

    stub = File.read!(Path.join(pack, "stubs/lib/calc.ex"))
    assert stub =~ "def add(_arg1, _arg2) do"
    assert stub =~ "def clamp(_arg1, _arg2, _arg3) do"
    refute stub =~ "a + b"

    prompt = File.read!(Path.join(pack, "PROMPT.md"))
    assert prompt =~ "`contract/calc/README.md` — the primitive's Contract README"
    assert prompt =~ "- `calc/A1` — Add returns the sum of its arguments."
    assert prompt =~ "  - `contract/calc/calc_test.exs`"
    assert prompt =~ "`contract/test_helper.exs`"
    refute prompt =~ "CONTRACT_CONVENTION.md"
    refute prompt =~ "mutants.md"
  end

  @tag obligation: "covenant.primitive.I6"
  test "with COVENANT_ROOT set, mix covenant.check still runs the sibling layout's tests" do
    {output, status} = mix(["covenant.check"], [{"COVENANT_ROOT", @project}])
    assert status == 0, output
    assert output =~ "covenant.check: running mix test contract"
    assert output =~ "  calc          2/2  100.0%"
    assert output =~ "wrote contract/coverage.json"
  end

  @tag obligation: "covenant.primitive.I7"
  test "a declaration whose occurrence is past the last fails the run" do
    mutants = Path.join(@project, "contract/calc/mutants.md")

    change(%{
      "contract/calc/mutants.md" =>
        String.replace(File.read!(mutants), "Calc.clamp/3: < -> <=", "Calc.clamp/3: < -> <= #2")
    })

    {output, status} = mix(["covenant.mutate", "calc"])
    assert status == 1, output

    assert output =~
             "contract/calc/mutants.md:9: #2: only 1 mutant(s) in Calc.clamp/3 share < -> <="

    assert output =~ "lib/calc.ex:12: mutant m007 (comparison_swap `<` → `<=`) survived"
  end
end
