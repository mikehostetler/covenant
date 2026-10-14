defmodule Vm.MacroHang do
  if not Vm.MacroConsumer.enabled?() do
    receive do
      :never -> :ok
    end
  end
end
