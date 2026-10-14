alias Covenant.Mutate.{Mutator, Runner}

[mode] = System.argv()
root = Path.join(System.tmp_dir!(), "covenant-macro-restore-#{System.pid()}")
File.mkdir!(root)
provider = Path.join(root, "provider.ex")
caller = Path.join(root, "caller.ex")
tests = Path.join(root, "contract_test.exs")

try do
  File.cp_r!("contracts", Path.join(root, "contracts"))

  provider_source =
    if mode == "snapshot" do
      """
      defmodule RestoreProbe.Provider do
        defmacro __using__(_opts) do
          quote do
            def enabled?, do: true
          end
        end
      end
      """
    else
      """
      defmodule RestoreProbe.Provider do
        defmacro __using__(_opts) do
          if true do
            :ok
          else
            Module.create(RestoreProbe.Generated, quote(do: def(value, do: :generated)),
              file: "virtual_generated_source.ex", line: 1)
            #{if mode == "partial", do: ~s(raise "expansion failed"), else: ":ok"}
          end
          quote do
            def enabled?, do: true
          end
        end
      end
      """
    end

  File.write!(provider, provider_source)
  {:ok, provider_ast} = Mutator.parse(provider_source, provider)
  {:ok, _} = Mutator.compile(provider_ast, provider)

  caller_source = fn value ->
    """
    defmodule RestoreProbe.Caller do
      use RestoreProbe.Provider
      def value, do: #{value}
    end
    """
  end

  if mode == "snapshot" do
    {:ok, disk_ast} = Mutator.parse(caller_source.(1), caller)
    {:ok, [{RestoreProbe.Caller, binary}]} = Mutator.compile(disk_ast, caller)
    beamdir = Path.join(root, "ebin")
    File.mkdir!(beamdir)
    File.write!(Path.join(beamdir, "Elixir.RestoreProbe.Caller.beam"), binary)
    Code.prepend_path(beamdir)
  end

  File.write!(caller, caller_source.(2))
  {:ok, caller_ast} = Mutator.parse(caller_source.(2), caller)
  {:ok, _} = Mutator.compile(caller_ast, caller)

  File.write!(tests, """
  defmodule RestoreProbe.Contract do
    use Covenant.Case, component: "vm.macro", async: false
    @tag obligation: "vm.macro.I1"
    test "the original caller remains intact" do
      assert RestoreProbe.Caller.value() == 2
      assert RestoreProbe.Caller.enabled?()
      refute Code.ensure_loaded?(RestoreProbe.Generated)
    end
  end
  """)

  line = if mode == "snapshot", do: 4, else: 3

  plan = %{
    component: "vm.macro",
    modules: [{RestoreProbe.Provider, provider}],
    test_files: [tests],
    root: root,
    seed: 0,
    timeout: 1_000,
    slice: {1, 1},
    macros: true,
    recompile: [caller],
    keep: fn mutant -> mutant.operator == :boolean_flip and mutant.line == line end,
    on_progress: fn _ -> :ok end
  }

  {:ok, %{mutants: [mutant]}} = Runner.run(plan)
  if mode == "partial", do: [] = mutant.killed_by
  false = Code.ensure_loaded?(RestoreProbe.Generated)
  IO.puts("MACRO_RESTORED #{mode} #{mutant.verdict}")
after
  File.rm_rf!(root)
end
