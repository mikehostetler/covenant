defmodule Covenant.MutateMacroContractTest do
  use Covenant.Case, component: "covenant.mutate", async: false

  alias Covenant.Mutate.{Mutator, Recompile, Runner}

  @moduletag :tmp_dir

  @tag obligation: "covenant.mutate.I24"
  test "macro mode visits macro bodies and their quoted code without changing the default mode" do
    source = """
    defmodule MacroSample do
      @doc "Not a mutation site"
      defmacro __using__(_opts) do
        quote do
          @doc "Also not a mutation site"
          def enabled?, do: true
        end
      end

      defmacrop private_value, do: 42
      def ast, do: quote(do: false)
    end
    """

    assert {:ok, ast} = Mutator.parse(source, "macro_sample.ex")
    defaults = Mutator.sites(ast)
    refute Enum.any?(defaults, &(&1.operator == :boolean_flip))
    refute Enum.any?(defaults, &(&1.from == "42"))

    macros = Mutator.sites(ast, macros: true) |> Mutator.numbered()
    assert Enum.any?(macros, &(&1.operator == :boolean_flip and &1.function == "__using__/1"))

    assert Enum.any?(
             macros,
             &(&1.operator == :integer_shift and &1.function == "private_value/0")
           )

    assert Enum.any?(macros, &(&1.operator == :return_nil and &1.function == "__using__/1"))

    refute Enum.any?(
             macros,
             &(&1.from in ["false", ~s("Not a mutation site"), ~s("Also not a mutation site")])
           )

    assert macros == Mutator.sites(ast, macros: true) |> Mutator.numbered()
  end

  @tag obligation: "covenant.mutate.I24"
  test "quoted module definitions stay in the provider's mutation scope" do
    source = """
    defmodule Provider do
      defmacro build do
        quote do
          defmodule Generated do
            def value, do: true
          end
        end
      end
    end
    """

    assert {:ok, ast} = Mutator.parse(source, "provider.ex")
    sites = Mutator.sites(ast, modules: ["Provider"], macros: true)
    assert Enum.any?(sites, &(&1.operator == :boolean_flip and &1.module == "Provider"))
  end

  @tag obligation: "covenant.mutate.I24"
  test "quoted macros remain covered by the provider macro" do
    source = """
    defmodule Provider do
      defmacro __using__(_opts) do
        quote do
          defmacro answer, do: 42
          defmacrop enabled, do: true
          defmodule Generated do
            defmacro nested, do: false
          end
        end
      end
    end
    """

    covers = %Covenant.Covers{
      ref: {:function, "Provider", "__using__", 1},
      text: "Provider.__using__/1",
      file: "contract/provider/README.md",
      line: 1
    }

    component = %Covenant.Contract.Component{
      id: "provider",
      app: "contract",
      name: "provider",
      form: :primitive,
      file: covers.file,
      covers: [covers]
    }

    contract = %Covenant.Contract{components: %{"provider" => component}}
    assert {:ok, ast} = Mutator.parse(source, "provider.ex")
    sites = Mutator.sites(ast, modules: ["Provider"], macros: true)
    assert Enum.any?(sites, &(&1.operator == :integer_shift))
    assert Enum.any?(sites, &(&1.operator == :boolean_flip))
    assert Enum.all?(sites, &(&1.function == "__using__/1"))
    assert Enum.all?(sites, &Covenant.Mutate.covered_by?(contract, "provider", &1))
    assert Mutator.sites(ast) == []
  end

  @tag obligation: "covenant.mutate.I25"
  test "caller restoration uses the compiled baseline instead of a disk BEAM", %{tmp_dir: root} do
    module = Module.concat(Covenant.MacroBaseline, "M#{System.unique_integer([:positive])}")
    file = Path.join(root, "caller.ex")
    beamdir = Path.join(root, "ebin")
    File.mkdir_p!(beamdir)
    beam = Path.join(beamdir, "#{module}.beam")

    on_exit(fn ->
      Code.delete_path(beamdir)
      unload(module)
    end)

    assert {:ok, disk_ast} =
             Mutator.parse("defmodule #{inspect(module)} do\n def value, do: 1\nend", file)

    assert {:ok, [{^module, disk_binary}]} = Mutator.compile(disk_ast, file)
    File.write!(beam, disk_binary)
    Code.prepend_path(beamdir)
    File.write!(file, "defmodule #{inspect(module)} do\n def value, do: 2\nend")

    assert {:ok, callers} = Recompile.prepare([file], root, [])
    assert module.value() == 2
    assert :ok = Runner.restore(callers.originals)
    assert module.value() == 2
    assert File.read!(beam) == disk_binary
  end

  @tag obligation: "covenant.mutate.I25"
  test "caller preparation rejects missing, external and target sources", %{tmp_dir: root} do
    target = Path.join(root, "target.ex")
    File.write!(target, "defmodule ForbiddenMacroTarget do end")
    assert {:error, message} = Recompile.prepare(["missing.ex"], root, [])
    assert message =~ "not found"
    assert {:error, message} = Recompile.prepare([target], root, [target])
    assert message =~ "outside the mutation targets"
    assert {:error, message} = Recompile.prepare([__ENV__.file], root, [])
    assert message =~ "project source"
  end

  @tag obligation: "covenant.mutate.I25"
  test "partial caller compilation leaves no generated module after restoration", %{tmp_dir: root} do
    suffix = System.unique_integer([:positive])
    original = Module.concat(Covenant.MacroOriginal, "M#{suffix}")
    generated = Module.concat(Covenant.MacroGenerated, "M#{suffix}")
    file = Path.join(root, "caller.ex")
    File.write!(file, "defmodule #{inspect(original)} do\n def value, do: true\nend")
    assert {:ok, callers} = Recompile.prepare([file], root, [])

    broken = """
    defmodule #{inspect(original)} do
      def value, do: false
    end
    defmodule #{inspect(generated)} do
      def value, do: :generated
    end
    raise "caller expansion failed"
    """

    assert {:ok, ast} = Mutator.parse(broken, file)
    loaded = Recompile.loaded_modules()
    assert {:error, _} = Recompile.compile(%{files: [%{file: file, ast: ast}]})
    assert original.value() == false
    assert Code.ensure_loaded?(generated)
    assert :ok = Recompile.remove_generated(loaded)
    assert :ok = Runner.restore(callers.originals)
    assert original.value() == true
    refute Code.ensure_loaded?(generated)

    on_exit(fn ->
      :code.purge(original)
      :code.delete(original)
      :code.purge(original)
    end)
  end

  @tag obligation: "covenant.mutate.I25"
  test "virtual source modules are removed after successful and partial compilation", %{
    tmp_dir: root
  } do
    for fail? <- [false, true] do
      module = Module.concat(Covenant.MacroVirtual, "M#{System.unique_integer([:positive])}")
      file = Path.join(root, "virtual_caller.ex")
      File.write!(file, "")
      assert {:ok, _callers} = Recompile.prepare([file], root, [])
      on_exit(fn -> unload(module) end)

      source = """
      Module.create(#{inspect(module)}, quote(do: def(value, do: :generated)),
        file: "virtual_generated_source.ex", line: 1)
      #{if fail?, do: ~s(raise "expansion failed"), else: ":ok"}
      """

      assert {:ok, ast} = Mutator.parse(source, file)
      loaded = Recompile.loaded_modules()
      result = Recompile.compile(%{files: [%{file: file, ast: ast}]})
      if fail?, do: assert(match?({:error, _}, result)), else: assert(match?({:ok, _}, result))
      assert Code.ensure_loaded?(module)
      assert :ok = Recompile.remove_generated(loaded)
      refute Code.ensure_loaded?(module)
    end
  end

  @tag obligation: "covenant.mutate.I25"
  test "cleanup keeps prior in-memory modules and newly loaded disk modules", %{tmp_dir: root} do
    suffix = System.unique_integer([:positive])
    memory = Module.concat(Covenant.MacroExisting, "M#{suffix}")
    disk = Module.concat(Covenant.MacroDisk, "M#{suffix}")
    beamdir = Path.join(root, "ebin")
    File.mkdir_p!(beamdir)

    on_exit(fn ->
      Code.delete_path(beamdir)
      unload(memory)
      unload(disk)
    end)

    for module <- [memory, disk] do
      assert {:ok, ast} =
               Mutator.parse(
                 "defmodule #{inspect(module)} do\n def value, do: :kept\nend",
                 "virtual.ex"
               )

      assert {:ok, [{^module, binary}]} = Mutator.compile(ast, "virtual.ex")
      if module == disk, do: File.write!(Path.join(beamdir, "#{module}.beam"), binary)
    end

    unload(disk)
    Code.prepend_path(beamdir)
    loaded = Recompile.loaded_modules()
    assert Code.ensure_loaded?(disk)
    assert :ok = Recompile.remove_generated(loaded)
    assert memory.value() == :kept
    assert :code.is_loaded(disk) != false
    assert disk.value() == :kept
  end

  @tag obligation: "covenant.mutate.I25"
  test "cleanup tracks deleted helpers, including Module.create and exceptions" do
    previous = Code.get_compiler_option(:tracers)

    for create <- [:compile, :module_create] do
      module = Module.concat(Covenant.DeletedHelper, "M#{System.unique_integer([:positive])}")
      on_exit(fn -> unload(module) end)

      assert_raise RuntimeError, "probe", fn ->
        Recompile.with_cleanup(fn ->
          case create do
            :compile ->
              {:ok, ast} =
                Mutator.parse(
                  "defmodule #{inspect(module)} do\n def value, do: 42\nend",
                  "virtual.ex"
                )

              assert {:ok, _} = Mutator.compile(ast, "virtual.ex")

            :module_create ->
              Module.create(module, quote(do: def(value, do: 42)), file: "virtual.ex", line: 1)
          end

          :code.purge(module)
          :code.delete(module)
          assert :erlang.check_old_code(module)
          raise "probe"
        end)
      end

      refute :erlang.check_old_code(module)
      assert Code.get_compiler_option(:tracers) == previous
    end
  end

  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end
end

defmodule Covenant.MutateMacroE2EContractTest do
  use Covenant.Case, component: "covenant.mutate", async: false

  @moduletag :e2e
  @moduletag timeout: 300_000
  @project Path.expand("../../../fixtures/mutate/vm_project", __DIR__)

  @tag obligation: "covenant.mutate.I25"
  test "the runner restores caller baselines and removes virtual helpers even after compile errors" do
    probe = Path.expand("../../../fixtures/mutate/macro_restore_probe.exs", __DIR__)
    mix = System.find_executable("mix") || raise "mix not on PATH"

    for mode <- ["snapshot", "generated", "partial"] do
      {output, status} =
        System.cmd(mix, ["run", probe, mode],
          cd: @project,
          env: [{"MIX_ENV", "test"}, {"COVENANT_RESULTS_DIR", nil}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      expected = if mode == "partial", do: "invalid", else: "killed"
      assert output =~ "MACRO_RESTORED #{mode} #{expected}", output
    end
  end

  @tag obligation: "covenant.mutate.I25"
  test "a macro that hangs caller compilation is stopped without kill credit" do
    probe = Path.expand("../../../fixtures/mutate/macro_timeout_probe.exs", __DIR__)
    mix = System.find_executable("mix") || raise "mix not on PATH"

    {output, status} =
      System.cmd(mix, ["run", probe],
        cd: @project,
        env: [{"MIX_ENV", "test"}, {"COVENANT_RESULTS_DIR", nil}],
        stderr_to_stdout: true
      )

    assert status == 3, output
    assert output =~ "MACRO_TIMEOUT timeout 1"
    refute output =~ "UNEXPECTED_RETURN"
    assert [_, workdir] = Regex.run(~r/MACRO_WORKDIR ([^\n]+)/, output)
    refute File.exists?(workdir)
  end

  @tag obligation: ["covenant.mutate.I24", "covenant.mutate.I25", "covenant.mutate.I28"]
  test "macro workers rebuild direct callers, transitive callers and compiled test values" do
    mix = System.find_executable("mix") || raise "mix not on PATH"

    {output, status} =
      System.cmd(
        mix,
        [
          "covenant.mutate",
          "vm.macro",
          "--macros",
          "--jobs",
          "2",
          "--max-mutants-per-worker",
          "2",
          "--recompile",
          "test/contract/vm/macro_contract_test.exs",
          "--recompile",
          "lib/vm/macro_consumer.ex",
          "--recompile",
          "lib/vm/macro_derived.ex"
        ],
        cd: @project,
        env: [{"MIX_ENV", "dev"}, {"COVENANT_RESULTS_DIR", nil}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "retired after", output

    matrix =
      @project
      |> Path.join("tmp/covenant/mutate/vm.macro/kill_matrix.json")
      |> File.read!()
      |> JSON.decode!()

    assert matrix["summary"]["killed"] > 0
    assert matrix["macros"] == true

    assert matrix["recompile"] == [
             "test/contract/vm/macro_contract_test.exs",
             "lib/vm/macro_consumer.ex",
             "lib/vm/macro_derived.ex"
           ]

    assert matrix["summary"]["invalid"] > 0
    assert matrix["summary"]["survived"] == 0
    assert matrix["summary"]["timeouts"] == 0

    assert Enum.any?(
             matrix["mutants"],
             &(&1["function"] == "__using__/1" and &1["verdict"] == "killed")
           )

    assert Enum.any?(
             matrix["mutants"],
             &(&1["function"] == "private_value/0" and &1["verdict"] == "killed")
           )

    assert matrix["obligations"]["vm.macro.I1"]["killed"] > 0
    assert matrix["obligations"]["vm.macro.I2"]["killed"] > 0
    assert matrix["obligations"]["vm.macro.I3"]["killed"] > 0
    assert output =~ "every mutant is caught or sorted"
  end

  @tag obligation: "covenant.mutate.I24"
  test "caller sources require macro mode before workers start" do
    {output, status} =
      System.cmd(
        System.find_executable("mix"),
        ["covenant.mutate", "vm.macro", "--recompile", "lib/vm/macro_consumer.ex"],
        cd: @project,
        env: [{"MIX_ENV", "dev"}, {"COVENANT_RESULTS_DIR", nil}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "--recompile requires --macros"
    refute output =~ "raw results:"
  end
end
