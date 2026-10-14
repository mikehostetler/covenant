defmodule Covenant.Mutate.Runner do
  @moduledoc """
  Runs a component's contract tests against every mutant, in one VM.

  The test environment is booted once: ExUnit is started with `autorun: false`
  **before** the project's `test_helper.exs` is required (the helper's own
  `ExUnit.start` then cannot arm the at-exit run), the component's contract
  test files are required, and the formatters are replaced by `Collector` so
  that `Covenant.Formatter` never overwrites the real results with a mutant's.

  Then, per mutant: the implementation modules of the file are purged, the
  mutated AST is compiled and loaded in memory (`Covenant.Mutate.Mutator.compile/2`),
  `ExUnit.run/1` runs the test modules, and the originals are reloaded from
  their beam files. No file is written by a mutant.

  With `macros: true`, the explicit `recompile` sources and then the contract
  test sources are compiled against every mutant. Caller files must be listed
  in dependency order; discovery is not automatic. Caller and test modules are
  restored with the target modules. A caller compile error is an invalid mutant,
  and target plus caller compilation share the watchdog budget. Caller and test
  modules retain their compiled baseline binaries. New modules compiled in memory
  are removed after each mutant, including modules with virtual source filenames.

  The baseline (unmutated) run must be green; otherwise nothing is mutated.
  Every test runs with the plan's `timeout` — or, when the plan gives none,
  with `Covenant.Mutate.default_timeout/1` of the baseline's own durations —
  and a failure that is only an `ExUnit.TimeoutError` never counts as a kill
  (record `timeouts-are-survivors`).

  ## The watchdog

  A suite run is bounded by a **progress** watchdog: `budget_ms/2` is the
  longest it may go without finishing a test (the collector sends a heartbeat
  at each finished test, and the timer starts over). A loop in `setup_all` and
  a test tagged `timeout: :infinity` finish nothing and trip it; a mutant that
  makes every one of many tests hit ExUnit's per-test timeout does not, since
  each of those is a finished test (a failure by `:timeout`, which is not a
  kill but is not a hang either). The allowed gap is the per-test timeout (the
  longest a test legitimately takes to be declared finished), plus ten times
  the baseline's whole duration (a `setup_all` or teardown that is slow in
  the baseline is never slower than that by a factor of ten), plus five seconds.

  When a mutant trips it, its processes are still running mutated code: killing
  the task that called `ExUnit.run/1` does not stop the test and module
  processes ExUnit spawned. So the working directory is **never** restored to
  the project root. The tests that finished before the watchdog fired count: if
  one failed or was invalid for a reason other than a timeout, the mutant is
  `:killed` with `credit: :partial`, else `:timeout`. The plan's `:on_timeout` is
  called from inside the isolated working directory (`cwd` is the workdir; give
  it an ABSOLUTE path to write to); then the workdir is removed without raising
  (a stray relative write into the deleted directory fails with `:enoent`) and
  the runner halts the VM with `timeout_exit/0` (plan key `:halt`,
  `System.halt/1` by default), leaving no directory behind. If it does not halt
  (a `:halt` that returns, or no `:on_timeout`), the run returns an error with
  the cwd in a new, empty, read-only directory at the same path, not the project
  root: restoring it would let the stray processes write into the project, and
  a leaked empty temp dir is a small price.

  ## Timing, and the unmutated re-runs

  A test's duration (`entry.ms`, which the default timeout is measured from) is
  the larger of ExUnit's `test.time` and the wall time between the test's start
  and finish: `test.time` leaves out `on_exit` callbacks and the shutdown of
  supervised processes, which the per-test timeout still bounds. The unmutated
  re-runs (after the last mutant, and after a restart of applications a mutant
  stopped) use the timeout of the baseline, not the mutants'; a red one is run
  once more after 200 ms before the worker is called unreliable. Before every
  suite run the directories under the copy's `tmp/` are made owner-writable
  (`Workdir.unlock/1`), so that ExUnit can clear the `:tmp_dir` of a test that
  an earlier run left a read-only directory in.

  With `fail_fast: true` a mutant's run stops at its first failing test
  (`max_failures: 1`): the verdict is the same, the credit is `:partial`. A
  timeout counts as a failure to ExUnit, so a run that stopped on nothing but a
  timeout says nothing about the tests it skipped, and is run again in full.
  """

  alias Covenant.Mutate
  alias Covenant.Mutate.{Mutant, Mutator, Recompile, Workdir}

  # what the baseline runs under when the plan gives no timeout: ExUnit's own default
  @baseline_timeout 60_000

  # a mutant's progress budget: the longest the suite may go without finishing a
  # test. ExUnit's per-test timeout does not bound a `setup_all`, nor a test
  # tagged `timeout: :infinity`
  @budget_factor 10
  @budget_extra_ms 5_000
  @timeout_exit 3
  @sanity_pause_ms 200

  defmodule Collector do
    @moduledoc """
    The ExUnit formatter of a mutant run: collects every finished test and
    sends them to the `:covenant_sink` process at suite end.
    """

    use GenServer

    @impl true
    def init(opts) do
      {:ok,
       %{
         sink: Keyword.fetch!(opts, :covenant_sink),
         root: Keyword.fetch!(opts, :covenant_root),
         started: %{},
         finished: []
       }}
    end

    @impl true
    def handle_cast({:test_started, %ExUnit.Test{} = test}, state) do
      # `test.time` leaves out `on_exit` callbacks and the shutdown of supervised
      # processes, which still run under the per-test timeout: the wall time from here
      # to `:test_finished` is what the test really took
      started =
        Map.put(state.started, {test.module, test.name}, System.monotonic_time(:microsecond))

      {:noreply, %{state | started: started}}
    end

    def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
      {start, started} = Map.pop(state.started, {test.module, test.name})
      wall = if start, do: System.monotonic_time(:microsecond) - start, else: 0
      entry = Covenant.Mutate.Runner.entry(test, state.root, wall)

      # the heartbeat of the progress watchdog (`Covenant.Mutate.Runner.run_tests/3`); it
      # carries the entry, so that a run the watchdog stops keeps the tests that finished
      send(state.sink, {:covenant_heartbeat, entry})

      {:noreply, %{state | started: started, finished: [entry | state.finished]}}
    end

    def handle_cast({:suite_finished, _}, state) do
      send(state.sink, {:covenant_mutate_run, Enum.reverse(state.finished)})
      {:noreply, state}
    end

    def handle_cast(_event, state), do: {:noreply, state}
  end

  @typedoc "A finished test: identity, obligations and outcome."
  @type entry :: %{
          key: String.t(),
          module: String.t(),
          name: String.t(),
          file: String.t() | nil,
          line: pos_integer() | nil,
          obligations: [String.t()],
          mutation_blind: String.t() | nil,
          outcome: :passed | :failed | :timeout | :invalid | :skipped | :excluded,
          ms: non_neg_integer()
        }

  @typedoc """
  What a run needs:

  * `:component` — the component id;
  * `:modules` — `{module, source file}` pairs (`Covenant.Mutate.Modules.locate/3`);
  * `:test_files` — the component's contract test files;
  * `:root` — the project root (files are reported relative to it);
  * `:seed` — the ExUnit seed;
  * `:timeout` — per-test timeout in ms for the mutant runs, or `nil` to
    measure it from the baseline (`Covenant.Mutate.default_timeout/1`);
  * `:slice` — `{i, n}`: run every n-th mutant starting at the i-th (1-based);
  * `:on_progress` — called with each mutant once it has a verdict;
  * `:on_eta` — (optional) called with `%{done: d, total: t, elapsed_ms: ms}`
    after every 25th mutant of the slice (`Covenant.Mutate.progress_due?/2`);
  * `:fail_fast` — (optional, default `false`) stop each mutant's run at its
    first failing test: exact verdict, `credit: :partial` on a kill;
  * `:on_checkpoint` — (optional) receives results after each completed verdict,
    before progress is printed; partial results require final verification;
  * `:on_timeout` — (optional) called with the results so far, the timed-out
    mutant included with the verdict `:timeout`, and that mutant when a
    mutant's run goes longer than `budget_ms/2` without finishing a test. It
    runs with the working directory set to the worker's private copy, so it
    must write the results to an ABSOLUTE path; it need not halt: when it
    returns the runner removes the copy and halts with `timeout_exit/0`;
  * `:halt` — (optional, default `&System.halt/1`) what the runner calls with
    `timeout_exit/0` after `:on_timeout`; when it returns, the run is an error;
  * `:skip` — (optional) ids of mutants not to run (those a worker that was
    stopped had already judged);
  * `:max_mutants` — (optional) maximum verdicts in this VM. Verify the original
    suite after this group; `result.remaining` counts the slice's unjudged sites.
    Without this option the runner checks the whole slice;
  * `:isolate` — (optional, default `true`) run the tests from a private copy
    of the project;
  * `:macros` — (optional, default `false`) include macro bodies and quoted
    code in macros, recompiling callers and contract test files per mutant;
  * `:recompile` — (optional) caller source paths or globs, in dependency order,
    relative to `root`; used only with `macros: true`.

  Isolation uses `Covenant.Mutate.Workdir` so that relative writes and deletes
  stay in the private copy and workers have separate ExUnit `:tmp_dir` paths.
  With `isolate: false`, tests run in the project root.
  """
  @type plan :: %{
          required(:component) => String.t(),
          required(:modules) => [{module(), Path.t()}],
          required(:test_files) => [Path.t()],
          required(:root) => Path.t(),
          required(:seed) => non_neg_integer(),
          required(:timeout) => pos_integer() | nil,
          required(:slice) => {pos_integer(), pos_integer()},
          required(:on_progress) => (Mutant.t() -> any()),
          optional(:on_eta) => (map() -> any()),
          optional(:fail_fast) => boolean(),
          optional(:keep) => (Mutant.t() -> boolean()),
          optional(:on_checkpoint) => (result() -> any()),
          optional(:on_timeout) => (result(), Mutant.t() -> any()),
          optional(:halt) => (pos_integer() -> any()),
          optional(:skip) => [String.t()],
          optional(:max_mutants) => pos_integer(),
          optional(:macros) => boolean(),
          optional(:recompile) => [Path.t()],
          optional(:isolate) => boolean()
        }

  @type result :: %{
          tests: [entry()],
          mutants: [Mutant.t()],
          all: non_neg_integer(),
          remaining: non_neg_integer(),
          baseline_ms: non_neg_integer(),
          timeout_ms: pos_integer(),
          files: [Path.t()]
        }

  @doc "Boots the suite, checks the baseline and runs the plan's slice of mutants."
  @spec run(plan()) :: {:ok, result()} | {:error, String.t()}
  def run(plan) do
    with {:ok, files} <- prepare_files(plan),
         {:ok, modules, project_timeout} <- boot_suite(plan),
         {:ok, callers} <- prepare_callers(plan, files) do
      isolated(plan, fn -> run_suite(plan, files, modules, project_timeout, callers) end)
    end
  end

  defp run_suite(plan, files, modules, project_timeout, callers) do
    with {:ok, tests, baseline_ms} <- baseline(modules) do
      timeout = plan.timeout || Mutate.default_timeout(tests)
      ExUnit.configure(timeout: timeout)
      apps = started_apps()
      budget = budget_ms(baseline_ms, timeout)

      mutants =
        files
        |> Enum.flat_map(& &1.mutants)
        |> Enum.filter(Map.get(plan, :keep, fn _ -> true end))
        |> Mutator.numbered()

      {i, n} = plan.slice
      skip = Map.get(plan, :skip, [])

      slice =
        mutants
        |> Enum.with_index()
        |> Enum.filter(fn {_, position} -> rem(position, n) == i - 1 end)
        |> Enum.reject(fn {mutant, _} -> mutant.id in skip end)

      batch = Enum.take(slice, Map.get(plan, :max_mutants, length(slice)))

      result = fn verdicts ->
        %{
          tests: tests,
          mutants: verdicts,
          all: length(mutants),
          remaining: length(slice) - length(verdicts),
          baseline_ms: baseline_ms,
          timeout_ms: timeout,
          files: Enum.map(files, & &1.relative)
        }
      end

      env = %{
        plan: plan,
        files: files,
        callers: callers,
        modules: modules,
        apps: apps,
        budget: budget,
        baseline_timeout: baseline_timeout(plan.timeout, project_timeout),
        total: length(slice),
        started: System.monotonic_time(:millisecond),
        result: result
      }

      batch
      |> Enum.with_index(1)
      |> Enum.reduce_while([], fn {{mutant, _}, done}, verdicts ->
        case step(mutant, done, verdicts, env) do
          {:ok, ran} -> {:cont, [ran | verdicts]}
          other -> {:halt, other}
        end
      end)
      |> finish(modules, env)
      |> expire(plan)
    end
  end

  # One mutant: run it, then check that the VM still holds what the baseline had.
  defp step(mutant, done, verdicts, env) do
    file = Enum.find(env.files, &(&1.relative == mutant.file))
    fail_fast = Map.get(env.plan, :fail_fast, false)

    case run_mutant(mutant, file, env.modules, fail_fast, env.budget, env.callers) do
      {:ok, ran} ->
        with :ok <- healthy(ran, env) do
          if checkpoint = Map.get(env.plan, :on_checkpoint),
            do: checkpoint.(env.result.(Enum.reverse([ran | verdicts])))

          env.plan.on_progress.(ran)
          eta(env.plan, done, env.total, env.started)
          {:ok, ran}
        end

      {:error, reason} ->
        {:error, reason}

      {:budget, entries} ->
        timed_out(mutant, entries, verdicts, env)
    end
  end

  defp finish({:error, reason}, _modules, _env), do: {:error, reason}
  defp finish({:timeout, _, _} = timeout, _modules, _env), do: timeout
  defp finish({:suspect, _} = suspect, _modules, _env), do: suspect

  defp finish([], _modules, env), do: {:ok, env.result.([])}

  defp finish([last | _] = verdicts, modules, env) do
    case sanity(%{env | modules: modules}) do
      {:ok, tests} ->
        if red(tests) == [] do
          {:ok, env.result.(Enum.reverse(verdicts))}
        else
          {:error,
           "the unmutated suite is red after the last mutant, #{describe(last)}; " <>
             "this worker's results are unreliable:\n#{format_red(tests)}"}
        end

      {:error, reason} ->
        {:error, "after the last mutant, #{describe(last)}: #{reason}"}

      {:budget, _} ->
        {:suspect,
         "the unmutated suite did not finish within #{env.budget} ms after the last mutant, " <>
           "#{describe(last)}; this worker's results are unreliable"}
    end
  end

  # What the mutant that outran its time budget leaves behind. The tests that finished
  # before the watchdog fired count: one that failed (or was invalid) for a reason other
  # than a timeout killed the mutant (partial credit: the run did not finish); otherwise
  # it is a timeout (a survivor, never a kill). The VM is suspect (a test may still be
  # spinning), so nothing more runs: `run/1` hands the results to the plan's `:on_timeout`.
  defp timed_out(mutant, entries, verdicts, env) do
    reason = "no test finished within #{env.budget} ms (a watchdog stopped the worker)"

    judged =
      case verdict(mutant, entries) do
        %Mutant{verdict: :killed} = killed ->
          %{killed | credit: :partial}

        other ->
          %{other | verdict: :timeout}
      end

    timed_out = %{judged | reason: reason, replacement: nil}

    {:timeout, env.result.(Enum.reverse([timed_out | verdicts])), timed_out}
  end

  # Still inside the isolated directory, and the mutant's processes may still run:
  # `:on_timeout` persists the results (to an absolute path), then `isolated/2`
  # abandons the directory and `halt` stops the VM. Without a `:halt` that
  # returns, no error comes back before that.
  defp expire({:timeout, result, mutant}, plan) do
    with %{on_timeout: on_timeout} <- plan, do: notify(on_timeout, result, mutant)

    {:abandon, plan,
     {:error,
      "#{describe(mutant)} ran past its time budget (#{mutant.reason}); a test loops outside " <>
        "ExUnit's per-test timeout"}}
  end

  # An unmutated re-run that outran its budget is no mutant's verdict, but its processes
  # may still run just the same: the same abandon-and-halt, with no results to persist.
  defp expire({:suspect, message}, plan), do: {:abandon, plan, {:error, message}}

  defp expire(other, _plan), do: other

  # A callback that fails must not end the run here: the abandon path (the copy
  # removed, the cwd parked, the halt) is what keeps the mutant's processes out of
  # the project.
  defp notify(on_timeout, result, mutant) do
    on_timeout.(result, mutant)
  catch
    kind, reason ->
      IO.puts(
        :stderr,
        "covenant.mutate: the :on_timeout callback failed: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )
  end

  @doc """
  The progress budget of one mutant's run, in ms: the longest the suite may go
  without finishing a test, given the baseline's duration and per-test timeout.
  """
  @spec budget_ms(non_neg_integer(), pos_integer()) :: pos_integer()
  def budget_ms(baseline_ms, timeout_ms),
    do: @budget_factor * baseline_ms + @budget_extra_ms + timeout_ms

  @doc "The exit status of a worker its watchdog stopped."
  @spec timeout_exit() :: pos_integer()
  def timeout_exit, do: @timeout_exit

  # -- health -----------------------------------------------------------------

  defp started_apps,
    do: 10_000 |> Application.started_applications() |> MapSet.new(&elem(&1, 0))

  # A mutant can take the VM with it: purging its module kills a process running
  # the old code, a supervisor gives up, an application stops, and every later
  # mutant then "fails" its tests, which would be credited as kills. So after each
  # mutant's restore the applications the baseline had must all still run (else
  # they are restarted and the unmutated suite must be green again), and the
  # worker's directory must still exist. The mutant whose run did it keeps its verdict.
  defp healthy(mutant, env) do
    with :ok <- directory(mutant) do
      case MapSet.to_list(MapSet.difference(env.apps, started_apps())) do
        [] -> :ok
        missing -> recover(mutant, missing, env)
      end
    end
  end

  defp directory(mutant) do
    case File.cwd() do
      {:ok, cwd} ->
        if File.dir?(cwd),
          do: :ok,
          else: {:error, "#{describe(mutant)} broke the VM: it deleted the working directory"}

      {:error, _} ->
        {:error, "#{describe(mutant)} broke the VM: it deleted the working directory"}
    end
  end

  defp recover(mutant, missing, env) do
    names = Enum.map_join(missing, ", ", &inspect/1)

    failed =
      Enum.find_value(missing, fn app ->
        case Application.ensure_all_started(app) do
          {:ok, _} -> nil
          {:error, reason} -> {app, reason}
        end
      end)

    with nil <- failed,
         {:ok, tests} <- sanity(env),
         [] <- red(tests) do
      :ok
    else
      {:error, reason} ->
        {:error, "#{describe(mutant)} broke the VM: it stopped #{names}: #{reason}"}

      {:budget, _} ->
        {:suspect,
         "#{describe(mutant)} broke the VM: it stopped #{names}, and the unmutated suite " <>
           "did not finish within #{env.budget} ms after they restarted"}

      {app, reason} ->
        {:error,
         "#{describe(mutant)} broke the VM: it stopped #{names} and #{inspect(app)} " <>
           "would not restart (#{inspect(reason)})"}

      red ->
        {:error,
         "#{describe(mutant)} broke the VM: it stopped #{names}, and the unmutated suite " <>
           "is red after they restarted:\n#{format_red(red)}"}
    end
  end

  # The unmutated suite once more, under the timeout the baseline had (a mutant's is
  # shorter, and says nothing about a suite that is slow to tear down). A red run is run
  # once more after a short pause: a leftover process of an earlier mutant may still be
  # writing where a test of this run wants to clean up (`tmp/<module>/<test>`).
  defp sanity(env) do
    previous = ExUnit.configuration()[:timeout]
    ExUnit.configure(timeout: env.baseline_timeout)

    try do
      case run_tests(env.modules, :infinity, env.budget) do
        {:ok, tests} = ok ->
          if red(tests) == [], do: ok, else: retry_sanity(env)

        other ->
          other
      end
    after
      ExUnit.configure(timeout: previous)
    end
  end

  defp retry_sanity(env) do
    Process.sleep(@sanity_pause_ms)
    run_tests(env.modules, :infinity, env.budget)
  end

  defp red(tests), do: Enum.filter(tests, &(&1.outcome in [:failed, :timeout, :invalid]))

  defp format_red(tests),
    do:
      Enum.map_join(red(tests) |> List.wrap(), "\n", &"  #{&1.name} (#{&1.module}) #{&1.outcome}")

  defp describe(%Mutant{} = mutant),
    do: "mutant #{mutant.id} (#{Mutant.at(mutant)} #{mutant.operator})"

  defp eta(%{on_eta: on_eta}, done, total, started) do
    if Mutate.progress_due?(done, total) do
      on_eta.(%{
        done: done,
        total: total,
        elapsed_ms: System.monotonic_time(:millisecond) - started
      })
    end
  end

  defp eta(_plan, _done, _total, _started), do: :ok

  # A mutant runs the project's own code, so it must not run in the project
  # root, and ExUnit puts a test's `:tmp_dir` under `tmp/` in the OS process's
  # working directory, so workers running side by side must not share it. The
  # suite is already compiled and loaded, so only what the tests do at run time
  # sees the private copy.
  defp isolated(%{isolate: false} = plan, fun), do: settle(plan, fun.())

  defp isolated(%{root: root} = plan, fun) do
    # registered while it is built: the stdin watcher of the task finds it, should the parent die
    workdir = Workdir.build(root, System.tmp_dir!(), Workdir.suffix(), true)
    previous = File.cwd!()
    File.cd!(workdir)

    outcome =
      try do
        {:returned, fun.()}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    case outcome do
      {:returned, {:abandon, _, _} = abandon} ->
        # a mutant's processes may still run: the cwd never goes back to the project.
        # It leaves the copy first, for a directory that is gone at once: a stray relative
        # write gets `:enoent` and cannot put back what the removal takes away
        Workdir.leave(workdir)
        Workdir.remove(workdir)
        Workdir.unregister()
        settle(plan, abandon, workdir)

      {:returned, result} ->
        File.cd!(previous)
        Workdir.remove(workdir)
        Workdir.unregister()
        result

      {:raised, kind, reason, stacktrace} ->
        File.cd!(previous)
        Workdir.remove(workdir)
        Workdir.unregister()
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  @doc """
  Removes the private copy of the running worker, if there is one (it never raises),
  after taking the working directory out of it: the suite may be in the middle of a
  run, and its processes must not put back what is being removed. The task's stdin
  watcher calls it before halting when the parent has died.
  """
  @spec remove_workdir() :: :ok
  def remove_workdir do
    with dir when is_binary(dir) <- Workdir.registered(), do: Workdir.leave(dir)
    Workdir.remove_registered()
  end

  # With an `:on_timeout` the VM halts and the deleted directory is all that is left of
  # the copy. When nothing halts (no callback, or a `:halt` that returns) the VM goes on,
  # so it gets a working directory again: a new, empty, read-only one at the same path.
  defp settle(plan, {:abandon, _, {:error, message} = error}, workdir) do
    if Map.has_key?(plan, :on_timeout) do
      IO.puts(:stderr, "covenant.mutate: #{message}")
      Map.get(plan, :halt, &System.halt/1).(@timeout_exit)
    end

    if workdir, do: Workdir.abandon(workdir)
    error
  end

  defp settle(plan, {:abandon, _, _} = abandon), do: settle(plan, abandon, nil)

  defp settle(_plan, result), do: result

  # -- files ------------------------------------------------------------------

  defp prepare_files(plan) do
    root = Path.expand(plan.root)

    plan.modules
    |> Enum.group_by(fn {_, file} -> file end, fn {module, _} -> module end)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {file, modules}, {:ok, acc} ->
      case prepare_file(file, modules, root, Map.get(plan, :macros, false)) do
        {:ok, prepared} -> {:cont, {:ok, acc ++ [prepared]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> nothing_to_mutate(plan)
  end

  # A run without a single mutant site proves nothing, and is usually a module
  # that is not defined where it was said to be.
  defp nothing_to_mutate({:ok, files}, plan) do
    if Enum.all?(files, &(&1.mutants == [])) do
      {:error,
       "no mutant to run: there is nothing to mutate in #{Enum.map_join(plan.modules, ", ", fn {m, _} -> inspect(m) end)} " <>
         "where #{if match?([_], plan.modules), do: "it was", else: "they were"} found"}
    else
      {:ok, files}
    end
  end

  defp nothing_to_mutate(error, _plan), do: error

  defp prepare_file(file, modules, root, macros) do
    relative = Path.relative_to(file, root)

    with {:ok, source} <- read(file),
         {:ok, ast} <- Mutator.parse(source, file),
         {:ok, compiled} <- roundtrip(ast, file) do
      originals = Enum.map(compiled, fn {module, bin} -> original(module, bin) end)
      targets = Enum.map(modules, &inspect/1)
      mutants = Mutator.sites(ast, file: relative, modules: targets, macros: macros)

      with :ok <- restore(originals) do
        for module <- without_mutants(targets, mutants) do
          IO.puts(
            :stderr,
            "warning: no mutant in #{module} (#{relative}): it is not defined there or has nothing to mutate"
          )
        end

        {:ok, %{file: file, relative: relative, ast: ast, originals: originals, mutants: mutants}}
      end
    end
  end

  defp prepare_callers(%{macros: true} = plan, files) do
    paths = Map.get(plan, :recompile, []) ++ plan.test_files

    case Recompile.prepare(paths, plan.root, Enum.map(files, & &1.file)) do
      {:ok, callers} -> {:ok, callers}
      {:error, reason} -> {:error, "the unmutated macro callers do not compile: #{reason}"}
    end
  end

  defp prepare_callers(_plan, _files), do: {:ok, %{files: [], originals: []}}

  @doc false
  @spec without_mutants([String.t()], [Mutant.t()]) :: [String.t()]
  def without_mutants(targets, mutants) do
    present = mutants |> Enum.flat_map(&Mutant.modules/1) |> MapSet.new()
    Enum.reject(targets, &MapSet.member?(present, &1))
  end

  defp read(file) do
    case File.read(file) do
      {:ok, source} -> {:ok, source}
      {:error, reason} -> {:error, "cannot read #{file}: #{:file.format_error(reason)}"}
    end
  end

  # The unmutated AST must compile: otherwise every mutant would be "invalid"
  # for a reason that has nothing to do with the mutation.
  defp roundtrip(ast, file) do
    case Mutator.compile(ast, file) do
      {:ok, compiled} -> {:ok, compiled}
      {:error, reason} -> {:error, "#{file} does not compile from its own AST: #{reason}"}
    end
  end

  # The beam Mix compiled is the version to restore; a module without one
  # (defined in-memory) falls back to the roundtrip binary.
  defp original(module, roundtrip_bin) do
    case :code.get_object_code(module) do
      {^module, bin, beam} -> {module, bin, beam}
      :error -> {module, roundtrip_bin, ~c"nofile"}
    end
  end

  defp purge(originals), do: Enum.each(originals, fn {module, _, _} -> :code.purge(module) end)

  # Loads every original back and answers an error naming those that would not
  # load (a NIF `on_load` that fails on a second load, say); the others are restored.
  @doc false
  @spec restore([{module(), binary(), charlist()}]) :: :ok | {:error, String.t()}
  def restore(originals) do
    purge(originals)

    failed =
      Enum.flat_map(originals, fn {module, bin, beam} ->
        case :code.load_binary(module, beam, bin) do
          {:module, ^module} -> []
          {:error, reason} -> ["#{inspect(module)} (#{inspect(reason)})"]
        end
      end)

    case failed do
      [] -> :ok
      _ -> {:error, "cannot reload #{Enum.join(failed, ", ")}; the module is left unloaded"}
    end
  end

  # -- suite ------------------------------------------------------------------

  defp boot_suite(plan) do
    ExUnit.start(autorun: false, formatters: [])

    (Mix.Project.config()[:test_paths] || ["test"])
    |> Enum.map(&Path.join([plan.root, &1, "test_helper.exs"]))
    |> Enum.filter(&File.exists?/1)
    |> Enum.each(&Code.require_file/1)

    # the project's own timeout (`test_helper.exs`, `mix test --timeout`), read before this run sets its own
    project_timeout = ExUnit.configuration()[:timeout]

    ExUnit.configure(
      autorun: false,
      formatters: [Collector],
      covenant_sink: self(),
      covenant_root: Path.expand(plan.root),
      seed: plan.seed,
      timeout: baseline_timeout(plan.timeout, project_timeout),
      capture_log: true,
      max_failures: :infinity,
      colors: [enabled: false]
    )

    modules =
      plan.test_files
      |> Enum.map(&Path.expand(&1, plan.root))
      |> Enum.flat_map(fn file -> Code.require_file(file) || [] end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&contract_module?(&1, plan.component))

    if modules == [] do
      {:error,
       "no contract test module declares `use Covenant.Case, component: \"#{plan.component}\"` " <>
         "in #{Enum.join(plan.test_files, ", ")}"}
    else
      {:ok, modules, project_timeout}
    end
  end

  @doc false
  @spec baseline_timeout(timeout() | nil, timeout() | nil) :: timeout()
  def baseline_timeout(plan_timeout, project_timeout),
    do: plan_timeout || project_timeout || @baseline_timeout

  defp contract_module?(module, component) do
    function_exported?(module, :__ex_unit__, 0) and
      module.__ex_unit__().tags[:covenant_component] == component
  end

  defp baseline(modules) do
    {us, ran} = :timer.tc(fn -> run_tests(modules, :infinity, :infinity) end)

    with {:ok, tests} <- ran do
      red = red(tests)

      cond do
        tests == [] ->
          {:error, "the contract test modules #{inspect(modules)} define no tests"}

        red != [] ->
          {:error,
           "the baseline is red; fix the suite before mutating:\n" <>
             Enum.map_join(red, "\n", &"  #{&1.name} (#{&1.module}) #{&1.outcome}")}

        true ->
          {:ok, tests, div(us, 1000)}
      end
    end
  end

  # The suite runs in a task, so a suite that never ends (a `setup_all` that loops) is
  # `:budget`, not a hang; `budget` is the allowed gap between two finished tests (the
  # collector's heartbeats start the timer over). A run that ends without the collector's
  # report is an error, not a wait.
  @doc false
  @spec run_tests([module()], pos_integer() | :infinity, pos_integer() | :infinity) ::
          {:ok, [entry()]} | {:error, String.t()} | {:budget, [entry()]}
  def run_tests(modules, max_failures, budget) do
    Recompile.with_cleanup(fn -> do_run_tests(modules, max_failures, budget) end)
  end

  defp do_run_tests(modules, max_failures, budget) do
    ExUnit.configure(max_failures: max_failures)
    unlock_tmp()
    flush_heartbeats()
    task = Task.async(fn -> ExUnit.run(modules) end)

    case await(task, budget) do
      {:ok, _} ->
        receive do
          {:covenant_mutate_run, tests} ->
            flush_heartbeats()
            {:ok, tests}
        after
          5_000 -> {:error, "the mutant run finished but the collector reported nothing"}
        end

      {:budget, _} = budget ->
        budget

      {:exit, reason} ->
        exit(reason)
    end
  end

  # A test that left a read-only directory in its `:tmp_dir` would make ExUnit's
  # `File.rm_rf!` of it fail in the next run of that test, in this VM
  defp unlock_tmp do
    with dir when is_binary(dir) <- Workdir.registered(),
         do: Workdir.unlock(Path.join(dir, "tmp"))
  end

  defp await(%Task{ref: ref} = task, gap, seen \\ []) do
    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        {:ok, reply}

      {:DOWN, ^ref, _, _, reason} ->
        {:exit, reason}

      {:covenant_heartbeat, entry} ->
        await(task, gap, [entry | seen])
    after
      gap ->
        Task.shutdown(task, :brutal_kill)
        {:budget, Enum.reverse(seen)}
    end
  end

  defp flush_heartbeats do
    receive do
      {:covenant_heartbeat, _} -> flush_heartbeats()
    after
      0 -> :ok
    end
  end

  # -- mutants ----------------------------------------------------------------

  defp run_mutant(mutant, file, modules, fail_fast, budget, callers) do
    originals = Enum.uniq_by(file.originals ++ callers.originals, &elem(&1, 0))

    Recompile.with_cleanup(fn ->
      purge(originals)

      judged =
        case compile(Mutator.apply(file.ast, mutant), file.file, budget, callers) do
          {:error, reason} -> {:ok, %{mutant | verdict: :invalid, reason: reason}}
          {:ok, _} -> judge(mutant, modules, fail_fast, budget)
          :budget -> {:budget, []}
        end

      case {judged, restore(originals)} do
        {_, {:error, reason}} -> {:error, "#{describe(mutant)}: #{reason}"}
        {{:error, reason}, :ok} -> {:error, "#{describe(mutant)}: #{reason}"}
        {{:ok, result}, :ok} -> {:ok, %{result | replacement: nil}}
        {{:budget, entries}, :ok} -> {:budget, entries}
      end
    end)
  end

  # Compiling runs the mutant's own macros and module bodies, so a mutant can hang here
  # as well: the compile gets the same budget as a run of the suite.
  defp compile(ast, file, budget, callers) do
    task =
      Task.async(fn ->
        with {:ok, _} <- Mutator.compile(ast, file), do: Recompile.compile(callers)
      end)

    case Task.yield(task, budget) || Task.shutdown(task, :brutal_kill) do
      {:ok, compiled} -> compiled
      {:exit, reason} -> exit(reason)
      nil -> :budget
    end
  end

  defp judge(mutant, modules, false, budget) do
    with {:ok, tests} <- run_tests(modules, :infinity, budget), do: {:ok, verdict(mutant, tests)}
  end

  # Stopping at the first failure leaves a kill's credit partial; a survivor ran every test.
  # A timeout is a failure to ExUnit, so a run that stopped on one proves nothing about the
  # tests it skipped (a later one may kill the mutant): the whole suite settles it.
  defp judge(mutant, modules, true, budget) do
    with {:ok, tests} <- run_tests(modules, 1, budget) do
      case verdict(mutant, tests) do
        %Mutant{verdict: :killed} = killed -> {:ok, %{killed | credit: :partial}}
        %Mutant{verdict: :timeout} -> judge(mutant, modules, false, budget)
        survived -> {:ok, survived}
      end
    end
  end

  @doc "The verdict of a mutant given the tests that ran against it."
  @spec verdict(Mutant.t(), [entry()]) :: Mutant.t()
  def verdict(%Mutant{} = mutant, tests) do
    killers = for t <- tests, t.outcome in [:failed, :invalid], do: t.key
    timeouts = for t <- tests, t.outcome == :timeout, do: t.key

    verdict =
      cond do
        killers != [] -> :killed
        timeouts != [] -> :timeout
        true -> :survived
      end

    %{mutant | verdict: verdict, killed_by: killers, timeouts: timeouts}
  end

  @doc """
  The identity, obligations, outcome and duration (`ms`, rounded up) of a finished
  `ExUnit.Test`; files are relative to `root`. The duration is the larger of
  `test.time` (setup and body) and `wall_us`, the microseconds the test was seen
  to run, teardown included.
  """
  @spec entry(ExUnit.Test.t(), Path.t(), non_neg_integer()) :: entry()
  def entry(%ExUnit.Test{tags: tags} = test, root, wall_us \\ 0) do
    module = inspect(test.module)
    name = Atom.to_string(test.name)

    %{
      key: module <> ":" <> name,
      module: module,
      name: name,
      file: tags[:file] && Path.relative_to(tags[:file], root),
      line: tags[:line],
      obligations: tags[:obligation] |> List.wrap() |> Enum.map(&to_string/1),
      mutation_blind: tags[:mutation_blind] && to_string(tags[:mutation_blind]),
      outcome: outcome(test.state),
      ms: div(max(test.time, wall_us) + 999, 1000)
    }
  end

  defp outcome(nil), do: :passed
  defp outcome({:skipped, _}), do: :skipped
  defp outcome({:excluded, _}), do: :excluded
  defp outcome({:invalid, _}), do: :invalid

  defp outcome({:failed, failures}) do
    if Enum.all?(failures, &match?({_, %ExUnit.TimeoutError{}, _}, &1)),
      do: :timeout,
      else: :failed
  end
end
