defmodule Covenant.TasksUmbrellaContractTest do
  @moduledoc """
  Runs the mix tasks as subprocesses in `apps/shop` of the umbrella-shaped fixture, where the
  Contract and the config live two directories up: the working directory is never the root.
  Slow on the first run (the fixture compiles its own `_build`).
  """

  use Covenant.Case, component: "covenant.tasks", async: false

  @moduletag :e2e
  @moduletag timeout: 300_000

  @umbrella Path.expand("../../../fixtures/umbrella_project", __DIR__)
  @app Path.join(@umbrella, "apps/shop")

  defp mix(args, opts \\ []) do
    mix = System.find_executable("mix") || raise "mix not on PATH"
    env = [{"MIX_ENV", "dev"}, {"COVENANT_RESULTS_DIR", nil}, {"COVENANT_ROOT", nil}]

    {output, status} =
      System.cmd(mix, args, cd: opts[:cd] || @app, env: env, stderr_to_stdout: true)

    if opts[:print], do: IO.puts(output)
    {output, status}
  end

  setup_all do
    File.rm_rf!(Path.join(@umbrella, "_build/covenant"))
    File.rm_rf!(Path.join(@umbrella, "tmp"))
    :ok
  end

  @tag obligation: "covenant.tasks.I9"
  test "mix covenant.regen run from an app finds the app's contract tests and lays them out from the root" do
    pack = Path.join(@umbrella, "tmp/pack")

    {output, status} = mix(["covenant.regen", "shop.cart", "--out", pack])
    assert status == 0, output

    assert output =~ "  apps/shop/test/contract/shop/cart_contract_test.exs\n"
    assert output =~ "covenant.regen: skipped (owned by shop.catalog): Shop.Catalog"

    assert File.exists?(Path.join(pack, "apps/shop/test/contract/shop/cart_contract_test.exs"))
    assert File.exists?(Path.join(pack, "stubs/lib/shop/cart.ex"))
    refute File.exists?(Path.join(pack, "stubs/lib/shop/catalog.ex"))

    assert File.read!(Path.join(pack, "PROMPT.md")) =~
             "`apps/shop/test/contract/shop/cart_contract_test.exs`"
  end

  @tag obligation: "covenant.tasks.I9"
  test "mix covenant.check --static run from an app reads the tests of every app (two of them)" do
    {output, status} = mix(["covenant.check", "--static"])
    assert status == 0, output

    assert output =~
             "covenant.check --static: read 3 file(s), 3 contract test module(s), 3 tagged test(s) under apps/*/test/contract; no test was compiled or run"

    assert output =~ "covenant.check: the Contract holds statically"
    refute output =~ "declare no modules"
  end

  @tag obligation: "covenant.tasks.I9"
  test "mix covenant.check run from an app runs the configured tests, run from the umbrella root, handed to mix test relative to it" do
    {output, status} = mix(["covenant.check"])
    assert status == 0, output

    assert output =~
             "covenant.check: running mix test apps/other/test/contract apps/shop/test/contract\n"

    assert output =~ ~r/(1 test, 0 failures|Result: 1 passed)/
    assert output =~ ~r/(2 tests, 0 failures|Result: 2 passed)/
    assert output =~ ~r/total\s+3\/3\s+100\.0%/
    assert output =~ "covenant.check: the Contract holds"
  end

  @tag obligation: "covenant.tasks.I9"
  test "mix covenant.check run from an app counts a glob ceiling against the root" do
    scope = Path.join(@umbrella, "contracts/system/scope.yml")
    File.mkdir_p!(Path.dirname(scope))
    on_exit(fn -> File.rm_rf!(Path.dirname(scope)) end)

    File.write!(scope, """
    - name: shop-lib
      ceiling: 0
      counter: { kind: glob, pattern: "apps/*/lib/**/*.ex" }
      why: A ceiling only the root can count.
    """)

    {output, status} = mix(["covenant.check"])
    assert status == 1, output
    assert output =~ "scope ceiling `shop-lib` exceeded: 3 > 0"

    {output, status} = mix(["covenant.check", "--static"])
    assert status == 1, output
    assert output =~ "scope ceiling `shop-lib` exceeded: 3 > 0"
  end

  @tag obligation: "covenant.tasks.I9"
  test "a --test-path typed on the command line is relative to the working directory" do
    # from apps/shop, `test/contract` is the app's own tests and `apps/*/test/contract` is nothing
    # (the configured path of the same spelling finds them: it is relative to the root)
    # only shop's tests are read, so the other app's obligation has no test: exit 1
    {output, status} = mix(["covenant.check", "--static", "--test-path", "test/contract"])
    assert status == 1, output
    assert output =~ "read 2 file(s)"
    assert output =~ "active obligation `other.thing.I1` has no tagged test"

    {output, _status} = mix(["covenant.check", "--static", "--test-path", "apps/*/test/contract"])
    assert output =~ "read 0 file(s)"
  end

  @tag obligation: "covenant.tasks.I9"
  test "mix covenant.conditions run from an app resolves file conditions and mix.lock against the root" do
    contracts = Path.join(@umbrella, "tmp/conditions-contracts")
    File.mkdir_p!(contracts)
    File.cp_r!(Path.join(@umbrella, "contracts"), contracts)
    records = Path.join(contracts, "shop/cart.decisions.yml")

    record = """
    - id: lives-at-the-root
      date: "2026-10-10"
      decision: The umbrella root holds the lock and the apps.
      driver: A premise checked against the root, not against the app mix runs in.
      approved_by: lead (fixture, 2026-10-10)
      conditions:
        - text: The umbrella root holds mix.lock
          check: { kind: file, path: mix.lock }
        - text: The shop app lives under apps
          check: { kind: file, path: apps/shop/mix.exs }
        - text: yaml_elixir is locked by the root lock
          check: { kind: dep, name: yaml_elixir, version: "~> 2.12" }
    """

    File.write!(records, record)

    {output, status} = mix(["covenant.conditions", "--verbose", "--contracts", contracts])
    assert status == 0, output
    assert output =~ "ok The umbrella root holds mix.lock — file `mix.lock` exists"
    assert output =~ "ok The shop app lives under apps — file `apps/shop/mix.exs` exists"
    assert output =~ "ok yaml_elixir is locked by the root lock"
    assert output =~ "1 record(s), 3 machine-checkable condition(s), 0 suspect record(s)"

    File.write!(
      records,
      record <>
        """
            - text: A file the root does not hold
              check: { kind: file, path: docs/missing.md }
        """
    )

    {output, status} = mix(["covenant.conditions", "--contracts", contracts])
    assert status == 1
    assert output =~ "record `lives-at-the-root` is suspect"
    assert output =~ "A file the root does not hold: file `docs/missing.md` does not exist"
    refute output =~ "file `mix.lock` does not exist"
    assert output =~ "1 suspect record(s)"
  end

  @tag obligation: "covenant.tasks.I9"
  test "mix covenant.mutate run from an app finds the app's contract tests and mutates its module" do
    {output, status} = mix(["covenant.mutate", "shop.cart", "--out", "tmp/kill_matrix.json"])
    assert status == 0, output

    assert output =~ "covenant.mutate: tests: test/contract/shop/cart_contract_test.exs\n"
    assert output =~ "covenant.mutate: Shop.Cart (lib/shop/cart.ex)"
    refute output =~ "no contract test file declares"
  end

  @tag obligation: "covenant.tasks.I9"
  test "a relative --contracts typed in an app means the same Contract to the workers" do
    {output, status} =
      mix([
        "covenant.mutate",
        "shop.cart",
        "--contracts",
        "../../contracts",
        "--out",
        "tmp/kill_matrix_contracts.json"
      ])

    assert status == 0, output
    assert output =~ "covenant.mutate: Shop.Cart (lib/shop/cart.ex)"
    refute output =~ "exited with status"
  end
end
