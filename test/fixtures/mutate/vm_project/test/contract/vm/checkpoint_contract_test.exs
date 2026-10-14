defmodule Vm.CheckpointContractTest do
  use Covenant.Case, component: "vm.checkpoint", async: false
  @tag obligation: "vm.checkpoint.I1"
  test "the first verdict is saved before the next mutation crashes the VM" do
    case Vm.Checkpoint.value() do
      43 ->
        if System.get_env("COVENANT_CHECKPOINT_WAIT") do
          IO.puts("CHECKPOINT_WAIT #{System.pid()} #{File.cwd!()}")

          receive do
            :never -> :ok
          end
        else
          System.halt(String.to_integer(System.get_env("COVENANT_CHECKPOINT_EXIT", "7")))
        end

      value ->
        assert value == 42
    end
  end
end
