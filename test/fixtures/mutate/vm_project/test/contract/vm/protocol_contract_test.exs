defmodule Vm.ProtocolContractTest do
  use Covenant.Case, component: "vm.protocol", async: true

  @tag obligation: "vm.protocol.I1"
  test "protocol dispatch uses the implementation's current code" do
    assert Vm.ValueProtocol.value(%{}) == 42
  end
end
