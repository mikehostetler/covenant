defmodule Vm.MacroBuilder do
  defmacrop private_value, do: 42

  defmacro __using__(_opts) do
    value = private_value()

    quote do
      def enabled?, do: true
      defmacro answer, do: unquote(value)
    end
  end
end
