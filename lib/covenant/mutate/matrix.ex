defmodule Covenant.Mutate.Matrix do
  @moduledoc """
  The kill matrix: who caught what.

  Built from the mutants' verdicts and the tests that produced them:

  * **per mutant** — location, operator, change, verdict, the tests that
    killed it and the obligations those tests are tagged with (the kill is
    credited to every one of them);
  * **per obligation** — `killed`: mutants caught by at least one of its
    tests; `unique`: mutants caught by *no* test tagged with another
    obligation, i.e. what the Contract would stop catching if this obligation
    lost its tests;
  * **per test** — `kills` and `unique_kills` (mutants no other test caught).
    A test with no unique kill proves nothing the rest of the suite does not;
    it is reported as *mutation blind*, warn-only, unless it carries
    `@tag mutation_blind: "reason"`;
  * **survivors** — every `:survived` and `:timeout` mutant with its sort
    (`Covenant.Mutate.Survivors`). A mutant inside the target of an active
    `kind: exception` is sorted `decision-hole` automatically: the Contract
    already records that hole. Every other survivor needs an annotation.

  **Fail-fast.** A mutant killed by a `--fail-fast` run has `credit: :partial`:
  the verdict is exact, but `killed_by` names only the tests that failed before
  the run stopped. Obligation and test totals (`killed`, `unique`, `kills`,
  `unique_kills`) therefore count the mutants with `:exact` credit only, and no
  test is judged mutation-blind (a unique kill cannot be told from a test that
  merely ran first). A fail-fast matrix proves kills, not obligation credit.

  `problems` lists what fails the task: unsorted survivors and annotations
  that match no survivor (stale). The mutation score is
  `killed / (killed + survived + timeouts)`; invalid mutants are excluded.
  """

  alias Covenant.Contract.Component
  alias Covenant.Error
  alias Covenant.Mutate.{Mutant, Survivors}
  alias Covenant.Mutate.Survivors.Annotation
  alias Covenant.Target

  @type survivor :: %{mutant: Mutant.t(), sort: String.t() | nil, reason: String.t() | nil}

  @type t :: %__MODULE__{
          component: String.t(),
          modules: [String.t()],
          files: [String.t()],
          seed: non_neg_integer(),
          timeout: pos_integer(),
          jobs: pos_integer(),
          fail_fast: boolean(),
          baseline_ms: non_neg_integer(),
          tests: [map()],
          mutants: [Mutant.t()],
          obligations: %{String.t() => map()},
          test_stats: %{String.t() => map()},
          survivors: [survivor()],
          blind: [map()],
          problems: [Error.t()],
          summary: map()
        }

  defstruct component: nil,
            modules: [],
            files: [],
            seed: 0,
            timeout: 0,
            jobs: 1,
            fail_fast: false,
            baseline_ms: 0,
            tests: [],
            mutants: [],
            obligations: %{},
            test_stats: %{},
            survivors: [],
            blind: [],
            problems: [],
            summary: %{}

  @doc """
  Builds the matrix. `results` is the merged worker output (`tests`,
  `mutants`, `modules`, `files`, `baseline_ms`); options:

  * `:component` — the `Covenant.Contract.Component` (its testable obligations
    are all listed, and its active exceptions auto-sort survivors);
  * `:annotations` — the parsed survivors file;
  * `:seed`, `:timeout`, `:jobs` — recorded for the report;
  * `:fail_fast` — the run was a `--fail-fast` one (default `false`).
  """
  @spec build(map(), keyword()) :: t()
  def build(results, opts) do
    component = Keyword.fetch!(opts, :component)
    annotations = Keyword.get(opts, :annotations, [])
    tests = results.tests
    mutants = Enum.sort_by(results.mutants, & &1.id)
    by_key = Map.new(tests, &{&1.key, &1})

    fail_fast = Keyword.get(opts, :fail_fast, false)

    credited = Enum.map(mutants, &credit(&1, by_key))
    exact = Enum.filter(credited, &(&1.credit == :exact))
    obligations = obligation_stats(component, exact)
    test_stats = test_stats(tests, exact)
    survivors = survivors(credited, annotations, component, results.files)
    stale = stale(annotations, credited)
    blind = if fail_fast, do: [], else: blind(tests, test_stats)

    unsorted =
      for %{mutant: m, sort: nil} <- survivors do
        Error.new(
          m.file,
          m.line,
          "mutant #{m.id} (#{m.operator} #{Mutant.mutation(m)}) #{verdict_word(m)}; " <>
            "add a test that catches it or annotate it in #{Keyword.get(opts, :survivors_path, "the survivors file")}"
        )
      end

    %__MODULE__{
      component: component.id,
      modules: results.modules,
      files: results.files,
      seed: Keyword.get(opts, :seed, 0),
      timeout: Keyword.get(opts, :timeout, 0),
      jobs: Keyword.get(opts, :jobs, 1),
      fail_fast: fail_fast,
      baseline_ms: results.baseline_ms,
      tests: tests,
      mutants: credited,
      obligations: obligations,
      test_stats: test_stats,
      survivors: survivors,
      blind: blind,
      problems: Error.sort(unsorted ++ stale),
      summary: summary(credited, survivors)
    }
  end

  @doc "True when nothing fails the task."
  @spec ok?(t()) :: boolean()
  def ok?(%__MODULE__{problems: []}), do: true
  def ok?(%__MODULE__{}), do: false

  # -- credit -----------------------------------------------------------------

  defp credit(%Mutant{} = mutant, by_key) do
    obligations =
      mutant.killed_by
      |> Enum.flat_map(fn key -> Map.get(by_key, key, %{obligations: []}).obligations end)
      |> Enum.uniq()
      |> Enum.sort()

    %{mutant | obligations: obligations}
  end

  defp obligation_stats(component, mutants) do
    ids = component |> Component.testable_obligations() |> Enum.map(& &1.id)
    tagged = mutants |> Enum.flat_map(& &1.obligations) |> Enum.uniq()

    Map.new(Enum.uniq(ids ++ tagged), fn id ->
      killed = Enum.filter(mutants, &(id in &1.obligations))
      unique = Enum.filter(killed, &(&1.obligations == [id]))

      {id,
       %{
         killed: length(killed),
         unique: length(unique),
         mutants: Enum.map(killed, & &1.id),
         unique_mutants: Enum.map(unique, & &1.id)
       }}
    end)
  end

  defp test_stats(tests, mutants) do
    Map.new(tests, fn test ->
      kills = Enum.filter(mutants, &(test.key in &1.killed_by))
      unique = Enum.filter(kills, &(&1.killed_by == [test.key]))

      {test.key,
       %{
         kills: length(kills),
         unique_kills: length(unique),
         mutants: Enum.map(kills, & &1.id),
         unique_mutants: Enum.map(unique, & &1.id)
       }}
    end)
  end

  defp blind(tests, stats) do
    for test <- tests,
        test.outcome == :passed,
        stats[test.key].unique_kills == 0 do
      %{test: test, kills: stats[test.key].kills, declared: test.mutation_blind}
    end
  end

  # -- survivors --------------------------------------------------------------

  defp survivors(mutants, annotations, component, _files) do
    exceptions =
      for exception <- Component.exceptions(component),
          {:ok, target} <- [Target.parse(exception.target || "")],
          do: {exception.id, target}

    for %Mutant{verdict: verdict} = mutant <- mutants, verdict in [:survived, :timeout] do
      case Survivors.find(annotations, mutant) do
        %Annotation{} = annotation ->
          %{mutant: mutant, sort: annotation.sort, reason: annotation.reason}

        nil ->
          case Enum.find(exceptions, fn {_, target} -> inside?(mutant, target) end) do
            {id, _} ->
              %{mutant: mutant, sort: "decision-hole", reason: "declared by exception `#{id}`"}

            nil ->
              %{mutant: mutant, sort: nil, reason: nil}
          end
      end
    end
  end

  # A single implementation exception cannot exempt a shared source body that
  # also changes another implementation. A file exception can cover the body.
  defp inside?(%Mutant{function: function} = mutant, {:function, mod, fun, arity}),
    do:
      Mutant.modules(mutant) != [] and Enum.all?(Mutant.modules(mutant), &(&1 == inspect(mod))) and
        function == "#{fun}/#{arity}"

  defp inside?(%Mutant{} = mutant, {:module, mod}),
    do: Mutant.modules(mutant) != [] and Enum.all?(Mutant.modules(mutant), &(&1 == inspect(mod)))

  defp inside?(%Mutant{file: file}, {:file, path}), do: file == path

  defp stale(annotations, mutants) do
    for %Annotation{} = annotation <- annotations,
        not Enum.any?(
          mutants,
          &(&1.verdict in [:survived, :timeout] and Survivors.matches?(annotation, &1))
        ) do
      case Enum.find(mutants, &Survivors.matches?(annotation, &1)) do
        nil when annotation.unit != nil ->
          Error.new(
            annotation.file,
            annotation.line,
            "declaration `#{declared(annotation)}` matches no surviving mutant; the code moved, the mutation changed or nothing survives there — delete or update it"
          )

        nil ->
          Error.new(
            annotation.file,
            annotation.line,
            "annotation for #{annotation.at} #{annotation.operator} matches no mutant; the code moved or the mutation changed — delete or update it"
          )

        %Mutant{id: id, verdict: verdict} when annotation.unit != nil ->
          Error.new(
            annotation.file,
            annotation.line,
            "declaration `#{declared(annotation)}` (#{id}) is contradicted: #{why_gone(verdict)} — delete it"
          )

        %Mutant{id: id, verdict: verdict} ->
          Error.new(
            annotation.file,
            annotation.line,
            "annotation for #{annotation.at} #{annotation.operator} (#{id}) is stale: that mutant is #{now_gone(verdict)} — delete it"
          )
      end
    end
  end

  defp why_gone(:invalid), do: "that mutant does not compile, so it cannot survive"
  defp why_gone(_), do: "a Contract test kills that mutant"

  defp now_gone(:invalid), do: "invalid (it does not compile)"
  defp now_gone(_), do: "now killed"

  defp declared(%Annotation{unit: unit, from: nil}), do: "#{unit}: *"
  defp declared(%Annotation{unit: unit, from: from, to: to}), do: "#{unit}: #{from} -> #{to}"

  defp summary(mutants, survivors) do
    count = fn verdict -> Enum.count(mutants, &(&1.verdict == verdict)) end
    killed = count.(:killed)
    survived = count.(:survived)
    timeouts = count.(:timeout)
    invalid = count.(:invalid)
    partial = Enum.count(mutants, &(&1.verdict == :killed and &1.credit == :partial))
    denominator = killed + survived + timeouts

    %{
      mutants: length(mutants),
      killed: killed,
      survived: survived,
      timeouts: timeouts,
      invalid: invalid,
      partial: partial,
      score: if(denominator == 0, do: nil, else: Float.round(killed / denominator, 4)),
      annotated: Enum.count(survivors, &(&1.sort != nil)),
      unsorted: Enum.count(survivors, &(&1.sort == nil))
    }
  end

  defp verdict_word(%Mutant{verdict: :timeout}), do: "timed out (a survivor)"
  defp verdict_word(%Mutant{}), do: "survived"

  # -- output -----------------------------------------------------------------

  @doc "The JSON-ready map written to the kill matrix file."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = matrix) do
    %{
      "covenant" => Covenant.version(),
      "component" => matrix.component,
      "modules" => matrix.modules,
      "files" => matrix.files,
      "seed" => matrix.seed,
      "timeout_ms" => matrix.timeout,
      "jobs" => matrix.jobs,
      "fail_fast" => matrix.fail_fast,
      "baseline" => %{"tests" => length(matrix.tests), "ms" => matrix.baseline_ms},
      "summary" => Map.new(matrix.summary, fn {k, v} -> {Atom.to_string(k), v} end),
      "mutants" =>
        Enum.map(matrix.mutants, fn mutant ->
          mutant |> Mutant.to_map() |> Map.put("obligations", mutant.obligations)
        end),
      "obligations" =>
        Map.new(matrix.obligations, fn {id, stats} ->
          {id,
           %{
             "killed" => stats.killed,
             "unique" => stats.unique,
             "mutants" => stats.mutants,
             "unique_mutants" => stats.unique_mutants
           }}
        end),
      "tests" =>
        Map.new(matrix.tests, fn test ->
          stats = matrix.test_stats[test.key]

          {test.key,
           %{
             "module" => test.module,
             "name" => test.name,
             "file" => test.file,
             "line" => test.line,
             "obligations" => test.obligations,
             "kills" => stats.kills,
             "unique_kills" => stats.unique_kills,
             "mutants" => stats.mutants,
             "unique_mutants" => stats.unique_mutants,
             "mutation_blind" => blind_value(matrix, test, stats)
           }}
        end),
      "survivors" =>
        Enum.map(matrix.survivors, fn %{mutant: mutant, sort: sort, reason: reason} ->
          %{
            "id" => mutant.id,
            "at" => Mutant.at(mutant),
            "operator" => Atom.to_string(mutant.operator),
            "mutation" => Mutant.mutation(mutant),
            "verdict" => Atom.to_string(mutant.verdict),
            "sort" => sort,
            "reason" => reason
          }
        end),
      "problems" => Enum.map(matrix.problems, &Error.format/1)
    }
  end

  # null: a fail-fast matrix cannot tell
  defp blind_value(matrix, test, stats) do
    cond do
      test.mutation_blind -> test.mutation_blind
      matrix.fail_fast -> nil
      stats.unique_kills == 0 and test.outcome == :passed -> true
      true -> false
    end
  end

  @doc "The readable report: summary, per-obligation table, survivors, blind tests."
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = matrix) do
    s = matrix.summary

    header =
      [
        "Kill matrix — #{matrix.component} (#{Enum.join(matrix.modules, ", ")})",
        "  #{s.mutants} mutants: #{s.killed} killed, #{s.survived} survived, " <>
          "#{s.timeouts} timed out, #{s.invalid} invalid — score #{percent(s.score)}",
        "  #{length(matrix.tests)} tests, baseline #{matrix.baseline_ms} ms, seed #{matrix.seed}, timeout #{matrix.timeout} ms"
      ] ++
        fail_fast_header(matrix) ++ [""]

    width =
      matrix.obligations |> Map.keys() |> Enum.map(&String.length/1) |> Enum.max(fn -> 10 end)

    width = max(width, 10)

    obligations =
      ["  #{String.pad_trailing("obligation", width)}  killed  unique"] ++
        (matrix.obligations
         |> Enum.sort_by(fn {id, _} -> id end)
         |> Enum.map(fn {id, stats} ->
           "  #{String.pad_trailing(id, width)}  #{String.pad_leading(Integer.to_string(stats.killed), 6)}  #{String.pad_leading(Integer.to_string(stats.unique), 6)}"
         end))

    survivors =
      case matrix.survivors do
        [] ->
          ["", "Survivors: none"]

        list ->
          ["", "Survivors (#{length(list)}; #{s.unsorted} unsorted)"] ++
            Enum.map(list, fn %{mutant: m, sort: sort, reason: reason} ->
              verdict = if m.verdict == :timeout, do: " [timeout]", else: ""

              "  #{m.id} #{Mutant.at(m)} #{m.operator} #{Mutant.mutation(m)}#{verdict}  " <>
                if(sort, do: "#{sort} — #{reason}", else: "UNSORTED")
            end)
      end

    blind =
      case matrix.blind do
        [] when matrix.fail_fast ->
          [
            "",
            "Mutation-blind tests: not judged (--fail-fast: a unique kill cannot be told apart)"
          ]

        [] ->
          ["", "Mutation-blind tests: none (every test has a unique kill)"]

        list ->
          ["", "Mutation-blind tests (warn): no mutant only this test catches"] ++
            Enum.map(list, fn %{test: test, kills: kills, declared: declared} ->
              "  #{test.name} (#{test.module}) — #{kills} kill(s), 0 unique" <>
                if(declared, do: " — declared: #{declared}", else: "")
            end)
      end

    Enum.join(header ++ obligations ++ survivors ++ blind, "\n")
  end

  defp fail_fast_header(%__MODULE__{fail_fast: false}), do: []

  defp fail_fast_header(%__MODULE__{summary: %{partial: partial}}),
    do: [
      "  --fail-fast: #{partial} kill(s) carry partial credit; the obligation table below counts " <>
        "exact kills only (a fail-fast matrix proves kills, not obligation credit)"
    ]

  defp percent(nil), do: "n/a"
  defp percent(ratio), do: :io_lib.format("~.1f%", [ratio * 100]) |> IO.iodata_to_binary()
end
