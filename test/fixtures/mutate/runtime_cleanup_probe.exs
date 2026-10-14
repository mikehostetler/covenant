alias Covenant.Mutate.{Mutator, Runner}
root = Path.join(System.tmp_dir!(), "covenant-runtime-cleanup-#{System.pid()}")
File.mkdir!(root)

try do
  File.cp_r!("contracts", Path.join(root, "contracts"))
  source = Path.join(root, "provider.ex")
  test_file = Path.join(root, "contract_test.exs")
  File.write!(source, "defmodule RuntimeCleanup.Provider do\n def value, do: true\nend")
  {:ok, ast} = Mutator.parse(File.read!(source), source)
  {:ok, _} = Mutator.compile(ast, source)

  File.write!(test_file, """
  defmodule RuntimeCleanup.Contract do
    use Covenant.Case, component: "vm.macro", async: false
    @tag obligation: "vm.macro.I1"
    test "deleted code is removed between runtime runs" do
      names = :persistent_term.get(:runtime_cleanup_names, [])
      for name <- names, do: refute(:erlang.check_old_code(name))
      name = Module.concat(RuntimeCleanup.Helper, "M\#{System.unique_integer([:positive])}")
      Module.create(name, quote(do: def(value, do: 42)), file: "virtual.ex", line: 1)
      :persistent_term.put(:runtime_cleanup_names, [name | names])
      on_exit(fn ->
        :code.purge(name)
        :code.delete(name)
      end)
      assert RuntimeCleanup.Provider.value() == true
    end
  end
  """)

  plan = %{
    component: "vm.macro",
    modules: [{RuntimeCleanup.Provider, source}],
    test_files: [test_file],
    root: root,
    seed: 0,
    timeout: 1000,
    slice: {1, 1},
    on_progress: fn _ ->
      for name <- :persistent_term.get(:runtime_cleanup_names),
          do: false = :erlang.check_old_code(name)
    end
  }

  {:ok, result} = Runner.run(plan)
  [:killed, :killed] = Enum.map(result.mutants, & &1.verdict)

  for name <- :persistent_term.get(:runtime_cleanup_names),
      do: false = :erlang.check_old_code(name)

  IO.puts("RUNTIME_CLEANUP_OK")
after
  File.rm_rf!(root)
end
