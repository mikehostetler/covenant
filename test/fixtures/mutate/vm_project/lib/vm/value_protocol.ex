defprotocol Vm.ValueProtocol do
  def value(input)
end

defimpl Vm.ValueProtocol, for: Map do
  def value(_input), do: 42
end
