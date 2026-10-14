defmodule Covenant.Mutate.Mutant do
  @moduledoc """
  One mutant: a single AST change at one location of one implementation
  module, and (after a run) its verdict.

  Mutants are enumerated by `Covenant.Mutate.Mutator.sites/2` in source order,
  so the same source always yields the same list, with the same ids. The
  `index` is the position of the mutated node in a `Macro.traverse/4` walk of
  the file's AST; `replacement` is the node that takes its place and is never
  serialized.

  ## Verdicts

  * `:killed` — at least one contract test failed with a real failure;
  * `:survived` — every contract test passed;
  * `:timeout` — the only failures were `ExUnit.TimeoutError`s; counted as a
    survivor, never as a kill (record `timeouts-are-survivors`);
  * `:invalid` — the mutant does not compile; excluded from the denominator.

  ## Credit

  `credit` says how much of `killed_by` can be trusted. `:exact` (the default):
  the whole suite ran against the mutant, so `killed_by` lists every test that
  caught it. `:partial`: the run stopped at its first failing test
  (`--fail-fast`), so the verdict is exact but `killed_by` names only the tests
  that failed before the stop.
  """

  @type operator ::
          :boolean_flip
          | :comparison_swap
          | :arithmetic_swap
          | :logical_swap
          | :condition_negate
          | :statement_removal
          | :return_nil
          | :integer_shift
          | :string_empty
          | :guard_removal
          | :clause_removal
          | :element_removal
          | :ecto_where_removal

  @type verdict :: :killed | :survived | :timeout | :invalid

  @type credit :: :exact | :partial

  @type t :: %__MODULE__{
          id: String.t() | nil,
          file: Path.t(),
          line: pos_integer(),
          column: pos_integer(),
          operator: operator(),
          from: String.t(),
          to: String.t(),
          module: String.t() | nil,
          modules: [String.t()],
          function: String.t() | nil,
          index: pos_integer(),
          replacement: Macro.t() | nil,
          verdict: verdict() | nil,
          killed_by: [String.t()],
          obligations: [String.t()],
          timeouts: [String.t()],
          reason: String.t() | nil,
          credit: credit()
        }

  @enforce_keys [:file, :line, :column, :operator, :from, :to, :index]
  defstruct [
    :id,
    :file,
    :line,
    :column,
    :operator,
    :from,
    :to,
    :module,
    :function,
    :index,
    :replacement,
    :verdict,
    :reason,
    modules: [],
    killed_by: [],
    obligations: [],
    timeouts: [],
    credit: :exact
  ]

  @operators ~w(boolean_flip comparison_swap arithmetic_swap logical_swap condition_negate
    statement_removal return_nil integer_shift string_empty guard_removal clause_removal
    element_removal ecto_where_removal)a

  @doc false
  @spec modules(t()) :: [String.t()]
  def modules(%{modules: [_ | _] = modules}), do: modules
  def modules(%{module: module}), do: List.wrap(module)

  @doc "Every operator, in the order variants are generated at a node."
  @spec operators() :: [operator()]
  def operators, do: @operators

  @doc "The location key used by survivor annotations: `file:line:column`."
  @spec at(t()) :: String.t()
  def at(%__MODULE__{file: file, line: line, column: column}), do: "#{file}:#{line}:#{column}"

  @doc "The change as one line: `` `from` → `to` ``."
  @spec mutation(t()) :: String.t()
  def mutation(%__MODULE__{from: from, to: to}), do: "`#{from}` → `#{to}`"

  @doc "The JSON-ready map (no AST, no timing)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = mutant) do
    %{
      "id" => mutant.id,
      "at" => at(mutant),
      "file" => mutant.file,
      "line" => mutant.line,
      "column" => mutant.column,
      "operator" => Atom.to_string(mutant.operator),
      "from" => mutant.from,
      "to" => mutant.to,
      "module" => mutant.module,
      "function" => mutant.function,
      "verdict" => mutant.verdict && Atom.to_string(mutant.verdict),
      "killed_by" => mutant.killed_by,
      "timeouts" => mutant.timeouts,
      "reason" => mutant.reason,
      "credit" => Atom.to_string(mutant.credit)
    }
    |> then(fn map ->
      if length(mutant.modules) > 1, do: Map.put(map, "modules", mutant.modules), else: map
    end)
  end

  defp verdict("killed"), do: :killed
  defp verdict("survived"), do: :survived
  defp verdict("timeout"), do: :timeout
  defp verdict("invalid"), do: :invalid
  defp verdict(_), do: nil

  defp credit("partial"), do: :partial
  defp credit(_), do: :exact

  @doc """
  Rebuilds a mutant from `to_map/1` output (without its replacement AST), or
  answers an error naming the operator when it is not one of the thirteen.
  """
  @spec decode(map()) :: {:ok, t()} | {:error, String.t()}
  def decode(map) do
    case Enum.find(@operators, &(Atom.to_string(&1) == map["operator"])) do
      nil ->
        {:error, "mutant #{inspect(map["id"])}: unknown operator #{inspect(map["operator"])}"}

      operator ->
        {:ok, build(map, operator)}
    end
  end

  @doc "`decode/1`, raising `ArgumentError` for an unknown operator instead of guessing one."
  @spec from_map(map()) :: t()
  def from_map(map) do
    case decode(map) do
      {:ok, mutant} -> mutant
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp build(map, operator) do
    %__MODULE__{
      id: map["id"],
      file: map["file"],
      line: map["line"],
      column: map["column"],
      operator: operator,
      from: map["from"],
      to: map["to"],
      module: map["module"],
      modules: List.wrap(map["modules"]),
      function: map["function"],
      index: map["index"] || 0,
      verdict: verdict(map["verdict"]),
      killed_by: List.wrap(map["killed_by"]),
      timeouts: List.wrap(map["timeouts"]),
      reason: map["reason"],
      credit: credit(map["credit"])
    }
  end
end
