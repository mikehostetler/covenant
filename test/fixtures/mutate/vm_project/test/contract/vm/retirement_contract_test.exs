defmodule Vm.RetirementContractTest do
  use Covenant.Case, component: "vm.retirement", async: false

  @tag obligation: "vm.retirement.I1"
  test "the value is restored within each worker" do
    value = Vm.Retirement.value()

    if path = System.get_env("COVENANT_RETIREMENT_LEDGER") do
      record = %{pid: System.pid(), directory: File.cwd!(), value: value}
      File.write!(path, [JSON.encode!(record), "\n"], [:append, :sync])
    end

    if System.get_env("COVENANT_RETIREMENT_POLLUTE") && value != 42,
      do: :persistent_term.put({__MODULE__, :polluted}, true)

    refute :persistent_term.get({__MODULE__, :polluted}, false)
    assert value == 42
  end
end
