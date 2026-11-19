defmodule SpriteProfiles.SetArgsTest do
  use ExUnit.Case, async: true

  alias SpriteProfiles.{Lock, SetArgs}

  @moduletag :tmp_dir

  test "-i values become the inputs, split at the first '='" do
    assert {:ok, ["a"], opts} =
             SetArgs.picks(profile: "a", input: "mode=x=y", input: "empty=")

    assert opts[:inputs] == %{"mode" => "x=y", "empty" => ""}
  end

  test "an -i without '=' or given twice is bad usage" do
    assert {:usage, _} = SetArgs.picks(profile: "a", input: "mode")
    assert {:usage, _} = SetArgs.picks(profile: "a", input: "=x")
    assert {:usage, m} = SetArgs.picks(profile: "a", input: "m=1", input: "m=2")
    assert m =~ "given twice"
  end

  test "--lock with -i is bad usage; a lock's own inputs pass through", %{tmp_dir: tmp} do
    path = Path.join(tmp, "x.lock")
    File.write!(path, Lock.encode([%{pick: "preview"}], DateTime.utc_now(), %{"mode" => "a"}))

    assert {:usage, m} = SetArgs.picks(lock: path, input: "mode=b")
    assert m =~ "lock the set again"

    assert {:ok, ["preview"], opts} = SetArgs.picks(lock: path)
    assert opts[:inputs] == %{"mode" => "a"}
  end
end
