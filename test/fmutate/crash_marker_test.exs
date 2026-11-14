defmodule FMutate.CrashMarkerTest do
  use ExUnit.Case, async: false

  alias FMutate.CrashMarker

  @key {CrashMarker, :crashed}

  setup do
    before = :persistent_term.get(@key, nil)
    :persistent_term.put(@key, ["obervave"])

    on_exit(fn ->
      if before == nil, do: :persistent_term.erase(@key), else: :persistent_term.put(@key, before)
      for id <- ["claim_a", "claim_b"], do: :persistent_term.erase({CrashMarker, :claimed, id})
    end)
  end

  # an instance restarted under its supervisor in the same launch must not count the same app crash again
  # (two counts quarantine the firmware)
  test "each instance gets the previous launch's crashes once per launch" do
    assert CrashMarker.claim("claim_a") == ["obervave"]
    assert CrashMarker.claim("claim_a") == []
    assert CrashMarker.claim("claim_b") == ["obervave"]
  end
end
