plan = %{
  component: "vm.macro",
  modules: [{Vm.MacroBuilder, Path.expand("lib/vm/macro_builder.ex")}],
  test_files: ["test/contract/vm/macro_contract_test.exs"],
  root: File.cwd!(),
  seed: 0,
  timeout: 1_000,
  slice: {1, 1},
  macros: true,
  recompile: [
    "lib/vm/macro_consumer.ex",
    "lib/vm/macro_derived.ex",
    "test/support/macro_hang.exs"
  ],
  keep: &(&1.operator == :boolean_flip),
  on_progress: fn _ -> :ok end,
  on_timeout: fn result, mutant ->
    IO.puts("MACRO_TIMEOUT #{mutant.verdict} #{length(result.mutants)}")
    IO.puts("MACRO_WORKDIR #{File.cwd!()}")
  end
}

IO.inspect(Covenant.Mutate.Runner.run(plan), label: "UNEXPECTED_RETURN")
