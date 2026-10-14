defmodule Vm.MacroDerived do
  require Vm.MacroConsumer
  def value, do: Vm.MacroConsumer.answer()
end
