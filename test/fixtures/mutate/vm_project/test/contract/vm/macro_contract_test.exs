defmodule Vm.MacroContractTest do
  use Covenant.Case, component: "vm.macro", async: false

  @cached_enabled Vm.MacroConsumer.enabled?()
  @cached_value Vm.MacroDerived.value()

  @tag obligation: "vm.macro.I1"
  test "the caller uses the generated function" do
    assert Vm.MacroConsumer.enabled?() == true
  end

  @tag obligation: "vm.macro.I2"
  test "the transitive caller uses the private macro" do
    assert Vm.MacroDerived.value() == 42
  end

  @tag obligation: "vm.macro.I3"
  test "compiled test values use the current macro expansion" do
    assert @cached_enabled == true
    assert @cached_value == 42
  end
end
