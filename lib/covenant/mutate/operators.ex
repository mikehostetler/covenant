defmodule Covenant.Mutate.Operators do
  @moduledoc """
  The mutation operators: given one AST node, every replacement each operator
  can make there.

  Nodes come from `Code.string_to_quoted/2` with `columns: true`,
  `token_metadata: true` and the literal encoder
  `&{:ok, {:__block__, &2, [&1]}}`, so every literal is wrapped in a
  `__block__` that carries its position (`token:` for numbers and bare atoms,
  `delimiter:` for strings, `closing:` for bracketed lists). The operators
  match on those wrappers.

  | operator              | change                                                       |
  |-----------------------|--------------------------------------------------------------|
  | `boolean_flip`        | `true` ↔ `false`                                             |
  | `comparison_swap`     | `==` ↔ `!=`, `===` ↔ `!==`, `<` → `<=` and `>=`, and so on   |
  | `arithmetic_swap`     | `+` ↔ `-`, `*` ↔ `/`                                         |
  | `logical_swap`        | `and` ↔ `or`, `&&` ↔ `\\|\\|`                                 |
  | `condition_negate`    | `if c` → `if !c`, `unless c` → `unless !c`                   |
  | `statement_removal`   | drop a non-final function call from a block                  |
  | `return_nil`          | replace the last expression of a `def`/`defp` body with `nil`|
  | `integer_shift`       | `n` → `n + 1` and `n - 1`                                    |
  | `string_empty`        | a non-empty string (interpolated or not) → `""`              |
  | `guard_removal`       | drop the `when` guard of a clause                            |
  | `clause_removal`      | drop one clause of a `case`, `cond` or multi-clause `fn`     |
  | `element_removal`     | drop one element of a bracketed list or one pair of a map    |
  | `ecto_where_removal`  | drop a `\\|> where(...)` stage or a `where:` key of `from`     |
  """

  alias Covenant.Mutate.Mutant

  @typedoc """
  One possible change at a node. `anchor` is the node whose position the
  mutant reports (the removed statement, clause or element rather than the
  block that held it).
  """
  @type variant :: %{
          operator: Mutant.operator(),
          from: String.t(),
          to: String.t(),
          replacement: Macro.t(),
          anchor: Macro.t()
        }

  @comparisons %{
    ==: [:!=],
    !=: [:==],
    ===: [:!==],
    !==: [:===],
    <: [:<=, :>=],
    <=: [:<, :>],
    >: [:>=, :<=],
    >=: [:>, :<]
  }

  @arithmetic %{+: :-, -: :+, *: :/, /: :*}
  @logical %{and: :or, or: :and, &&: :||, ||: :&&}

  @not_statements [
    :=,
    :@,
    :def,
    :defp,
    :defmacro,
    :defmacrop,
    :defguard,
    :defguardp,
    :defmodule,
    :defstruct,
    :defexception,
    :defimpl,
    :defprotocol,
    :defdelegate,
    :defoverridable,
    :use,
    :import,
    :alias,
    :require,
    :__block__,
    :__aliases__,
    :case,
    :cond,
    :if,
    :unless,
    :with,
    :for,
    :receive,
    :try,
    :fn,
    :quote,
    :<<>>,
    :%{},
    :%,
    :{},
    :->,
    :when,
    :|,
    :&,
    :^
  ]

  @doc "Every variant the operators produce at `node`, in operator order."
  @spec variants(Macro.t()) :: [variant()]
  def variants(node) do
    [
      boolean_flip(node),
      comparison_swap(node),
      arithmetic_swap(node),
      logical_swap(node),
      condition_negate(node),
      statement_removal(node),
      return_nil(node),
      integer_shift(node),
      string_empty(node),
      guard_removal(node),
      clause_removal(node),
      element_removal(node),
      ecto_where_removal(node)
    ]
    |> List.flatten()
    |> Enum.map(fn
      {operator, from, to, replacement} ->
        %{operator: operator, from: from, to: to, replacement: replacement, anchor: node}

      {operator, from, to, replacement, anchor} ->
        %{operator: operator, from: from, to: to, replacement: replacement, anchor: anchor}
    end)
  end

  # -- literals ---------------------------------------------------------------

  defp boolean_flip({:__block__, meta, [bool]}) when is_boolean(bool) do
    [{:boolean_flip, to_string(bool), to_string(not bool), {:__block__, meta, [not bool]}}]
  end

  defp boolean_flip(_), do: []

  defp integer_shift({:__block__, meta, [n]}) when is_integer(n) do
    if Keyword.has_key?(meta, :token) do
      for delta <- [1, -1] do
        {:integer_shift, Integer.to_string(n), Integer.to_string(n + delta),
         {:__block__, meta, [n + delta]}}
      end
    else
      []
    end
  end

  defp integer_shift(_), do: []

  defp string_empty({:__block__, meta, [string]}) when is_binary(string) and string != "" do
    if Keyword.has_key?(meta, :delimiter),
      do: [{:string_empty, inspect(string), ~s(""), {:__block__, meta, [""]}}],
      else: []
  end

  # An interpolated string is a binary construction whose parts include raw segments.
  defp string_empty({:<<>>, meta, parts} = node) when is_list(parts) do
    if Keyword.has_key?(meta, :delimiter) and Enum.any?(parts, &is_binary/1),
      do: [{:string_empty, describe(node), ~s(""), {:__block__, meta, [""]}}],
      else: []
  end

  defp string_empty(_), do: []

  # -- operators --------------------------------------------------------------

  defp comparison_swap({op, meta, [a, b]}) when is_map_key(@comparisons, op) do
    for to <- Map.fetch!(@comparisons, op) do
      {:comparison_swap, Atom.to_string(op), Atom.to_string(to), {to, meta, [a, b]}}
    end
  end

  defp comparison_swap(_), do: []

  defp arithmetic_swap({op, meta, [a, b]}) when is_map_key(@arithmetic, op) do
    to = Map.fetch!(@arithmetic, op)
    [{:arithmetic_swap, Atom.to_string(op), Atom.to_string(to), {to, meta, [a, b]}}]
  end

  defp arithmetic_swap(_), do: []

  defp logical_swap({op, meta, [a, b]}) when is_map_key(@logical, op) do
    to = Map.fetch!(@logical, op)
    [{:logical_swap, Atom.to_string(op), Atom.to_string(to), {to, meta, [a, b]}}]
  end

  defp logical_swap(_), do: []

  defp condition_negate({form, meta, [condition, blocks]}) when form in [:if, :unless] do
    negated = {:!, [line: meta[:line], column: meta[:column]], [condition]}

    [
      {:condition_negate, "#{form} #{describe(condition)}", "#{form} !(#{describe(condition)})",
       {form, meta, [negated, blocks]}}
    ]
  end

  defp condition_negate(_), do: []

  # -- blocks and bodies ------------------------------------------------------

  defp statement_removal({:__block__, meta, exprs}) when is_list(exprs) and length(exprs) > 1 do
    last = length(exprs) - 1

    exprs
    |> Enum.with_index()
    |> Enum.filter(fn {expr, i} -> i < last and call_statement?(expr) end)
    |> Enum.map(fn {expr, i} ->
      {:statement_removal, describe(expr), "(removed)",
       {:__block__, meta, List.delete_at(exprs, i)}, expr}
    end)
  end

  defp statement_removal(_), do: []

  defp call_statement?({{:., _, _}, _, args}) when is_list(args), do: true

  defp call_statement?({name, _, args}) when is_atom(name) and is_list(args),
    do: name not in @not_statements and not String.starts_with?(Atom.to_string(name), "sigil_")

  defp call_statement?(_), do: false

  defp return_nil({form, meta, [head, body_keyword]})
       when form in [:def, :defp, :defmacro, :defmacrop] and is_list(body_keyword) do
    case Enum.find_index(body_keyword, fn {key, _} -> key_name(key) == :do end) do
      nil ->
        []

      index ->
        {key, body} = Enum.at(body_keyword, index)

        case replace_last(body) do
          nil ->
            []

          {last, new_body} ->
            [
              {:return_nil, describe(last), "nil",
               {form, meta, [head, List.replace_at(body_keyword, index, {key, new_body})]}, last}
            ]
        end
    end
  end

  defp return_nil(_), do: []

  defp replace_last({:__block__, meta, exprs}) when is_list(exprs) and length(exprs) > 1 do
    last = List.last(exprs)

    if nil_literal?(last),
      do: nil,
      else: {last, {:__block__, meta, List.replace_at(exprs, -1, nil_node(last))}}
  end

  defp replace_last(body) do
    if nil_literal?(body), do: nil, else: {body, nil_node(body)}
  end

  defp nil_literal?(nil), do: true
  defp nil_literal?({:__block__, _, [nil]}), do: true
  defp nil_literal?(_), do: false

  defp nil_node({_, meta, _}) when is_list(meta),
    do: {:__block__, Keyword.take(meta, [:line, :column]), [nil]}

  defp nil_node(_), do: nil

  # -- clauses ----------------------------------------------------------------

  defp guard_removal({:when, _meta, [head, guard]}) do
    [{:guard_removal, "when #{describe(guard)}", "(no guard)", head}]
  end

  defp guard_removal(_), do: []

  defp clause_removal({:case, meta, [subject, blocks]}) when is_list(blocks),
    do: remove_clauses(blocks, &{:case, meta, [subject, &1]}, "case")

  defp clause_removal({:cond, meta, [blocks]}) when is_list(blocks),
    do: remove_clauses(blocks, &{:cond, meta, [&1]}, "cond")

  defp clause_removal({:fn, meta, clauses}) when is_list(clauses) and length(clauses) > 1 do
    clauses
    |> Enum.with_index()
    |> Enum.map(fn {clause, i} ->
      {:clause_removal, "fn #{describe_clause(clause)}", "(removed)",
       {:fn, meta, List.delete_at(clauses, i)}, clause}
    end)
  end

  defp clause_removal(_), do: []

  defp remove_clauses(blocks, rebuild, what) do
    case Enum.find_index(blocks, fn {key, _} -> key_name(key) == :do end) do
      nil ->
        []

      index ->
        {key, clauses} = Enum.at(blocks, index)

        if is_list(clauses) and length(clauses) > 1 do
          clauses
          |> Enum.with_index()
          |> Enum.map(fn {clause, i} ->
            {:clause_removal, "#{what} #{describe_clause(clause)}", "(removed)",
             rebuild.(List.replace_at(blocks, index, {key, List.delete_at(clauses, i)})), clause}
          end)
        else
          []
        end
    end
  end

  defp describe_clause({:->, _, [patterns, _body]}) when is_list(patterns),
    do: Enum.map_join(patterns, ", ", &describe/1) <> " ->"

  defp describe_clause(other), do: describe(other)

  # -- collections ------------------------------------------------------------

  defp element_removal({:__block__, meta, [list]}) when is_list(list) and list != [] do
    if Keyword.has_key?(meta, :closing) and not Enum.any?(list, &cons?/1) do
      list
      |> Enum.with_index()
      |> Enum.map(fn {element, i} ->
        {:element_removal, describe_element(element), "(removed)",
         {:__block__, meta, [List.delete_at(list, i)]}, anchor(element, meta)}
      end)
    else
      []
    end
  end

  defp element_removal({:%{}, meta, pairs}) when is_list(pairs) and pairs != [] do
    if Enum.any?(pairs, &cons?/1) do
      []
    else
      pairs
      |> Enum.with_index()
      |> Enum.map(fn {pair, i} ->
        {:element_removal, describe_element(pair), "(removed)",
         {:%{}, meta, List.delete_at(pairs, i)}, anchor(pair, meta)}
      end)
    end
  end

  defp element_removal(_), do: []

  defp cons?({:|, _, _}), do: true
  defp cons?(_), do: false

  # -- Ecto -------------------------------------------------------------------

  defp ecto_where_removal({:|>, _meta, [left, {where, _, args} = stage]})
       when where in [:where, :or_where] and is_list(args) do
    [{:ecto_where_removal, "|> #{describe(stage)}", "(removed)", left}]
  end

  defp ecto_where_removal({:from, meta, args}) when is_list(args) do
    case List.last(args) do
      keywords when is_list(keywords) and keywords != [] ->
        keywords
        |> Enum.with_index()
        |> Enum.filter(fn {{key, _}, _} -> key_name(key) in [:where, :or_where] end)
        |> Enum.map(fn {{key, value}, i} ->
          {:ecto_where_removal, "#{key_name(key)}: #{describe(value)}", "(removed)",
           {:from, meta, List.replace_at(args, -1, List.delete_at(keywords, i))},
           anchor(key, meta)}
        end)

      _ ->
        []
    end
  end

  defp ecto_where_removal(_), do: []

  # -- helpers ----------------------------------------------------------------

  @doc "The atom behind a keyword key, which the literal encoder may have wrapped."
  @spec key_name(Macro.t()) :: atom() | nil
  def key_name({:__block__, _, [key]}) when is_atom(key), do: key
  def key_name(key) when is_atom(key), do: key
  def key_name(_), do: nil

  # A pair's position is its key's; a bare element without metadata borrows the collection's.
  defp anchor({key, _value}, meta), do: anchor(key, meta)
  defp anchor({_, node_meta, _} = node, _meta) when is_list(node_meta), do: node
  defp anchor(_other, meta), do: {:__block__, meta, [nil]}

  defp describe_element({key, value}) do
    case key_name(key) do
      nil -> "#{describe(key)} => #{describe(value)}"
      name -> "#{name}: #{describe(value)}"
    end
  end

  defp describe_element(element), do: describe(element)

  @max_description 60

  @doc "A one-line, bounded rendering of a node for messages and the kill matrix."
  @spec describe(Macro.t()) :: String.t()
  def describe(node) do
    text =
      node
      |> Covenant.Mutate.Mutator.unwrap()
      |> Macro.to_string()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.join(" ")

    if String.length(text) > @max_description,
      do: String.slice(text, 0, @max_description - 1) <> "…",
      else: text
  end
end
