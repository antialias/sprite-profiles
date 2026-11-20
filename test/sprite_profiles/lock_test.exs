defmodule SpriteProfiles.LockTest do
  use ExUnit.Case, async: true

  import SpriteProfiles.GitHubFixtures

  alias SpriteProfiles.{Lock, Resolver}

  @moduletag :tmp_dir

  defp entries do
    [
      %{pick: "claude-code"},
      %{
        pick: "acme/profiles/linear@v1",
        owner: "acme",
        repo: "profiles",
        path: "linear",
        ref: "v1",
        sha: sha1(),
        name: "linear"
      }
    ]
  end

  defp write(tmp, text) do
    path = Path.join(tmp, "x.lock")
    File.write!(path, text)
    path
  end

  test "encode then read is a round trip", %{tmp_dir: tmp} do
    text = Lock.encode(entries(), ~U[2026-11-19 10:00:00.123Z])
    assert text =~ ~s(locked_at = "2026-11-19T10:00:00Z")
    assert Lock.read(write(tmp, text)) == {:ok, entries()}
    assert Lock.picks(entries()) == ["claude-code", "acme/profiles/linear@v1"]
    assert Lock.pins(entries()) == %{"acme/profiles/linear@v1" => %{sha: sha1(), name: "linear"}}
  end

  test "the lock of resolved profiles", %{tmp_dir: tmp} do
    stub_acme()

    {:ok, profiles} =
      Resolver.find(["claude-code", "acme/profiles/linear@v1"], ["profiles"], cache_dir: tmp)

    assert Lock.entries(profiles) == entries()
  end

  test "a lock that cannot be used is bad_lock", %{tmp_dir: tmp} do
    good = Lock.encode(entries())

    for {why, text} <- [
          {"not TOML", "format = = 1"},
          {"newer format", String.replace(good, "format    = 1", "format = 5")},
          {"no format", String.replace(good, "format    = 1", "")},
          {"missing sha", String.replace(good, ~s(sha   = "#{sha1()}"\n), "")},
          {"short sha", String.replace(good, sha1(), "1a2b3c4")},
          {"ref disagrees with the pick",
           String.replace(good, ~s(ref   = "v1"), ~s(ref   = "v2"))},
          {"local pick with extra fields",
           good <> "\n[[picks]]\npick = \"preview\"\nsha = \"x\"\n"},
          {"a pick that is no pick", good <> "\n[[picks]]\nnope = 1\n"}
        ] do
      assert {:error, [r]} = Lock.read(write(tmp, text)), why
      assert r.code == :bad_lock, why
    end

    assert {:error, [%{code: :bad_lock}]} = Lock.read(Path.join(tmp, "missing.lock"))
  end

  test "diff reports each commit that moved, and how" do
    old = entries()
    new = List.update_at(entries(), 1, &%{&1 | sha: sha2()})

    assert Lock.diff(old, new, %{"acme/profiles/linear@v1" => :tag}) ==
             ["acme/profiles/linear@v1: 1a2b3c4d → 4d5e6f7a (tag moved)"]

    assert Lock.diff(old, old) == []
  end

  describe "inputs" do
    test "a lock with inputs is format 2 and round-trips them; without, format 1", %{tmp_dir: tmp} do
      with_inputs = Lock.encode(entries(), ~U[2026-11-19 10:00:00Z], %{"mode" => "a \"b\""})
      assert with_inputs =~ "format    = 2"
      assert with_inputs =~ "[inputs]\nmode = \"a \\\"b\\\"\"\n"

      assert Lock.load(write(tmp, with_inputs)) ==
               {:ok, %{picks: entries(), inputs: %{"mode" => "a \"b\""}}}

      assert Lock.read(write(tmp, with_inputs)) == {:ok, entries()}

      plain = Lock.encode(entries())
      assert plain =~ "format    = 1"
      assert Lock.load(write(tmp, plain)) == {:ok, %{picks: entries(), inputs: %{}}}
    end

    test "a bad [inputs] is bad_lock", %{tmp_dir: tmp} do
      good = Lock.encode(entries(), DateTime.utc_now(), %{"mode" => "a"})

      for {why, text} <- [
            {"a value that is not a string", String.replace(good, ~s(mode = "a"), "mode = 1")},
            {"a bad name", String.replace(good, ~s(mode = "a"), ~s(Mode = "a"))},
            {"a value too long",
             String.replace(good, ~s(mode = "a"), ~s(mode = "#{String.duplicate("a", 257)}"))},
            {"inputs in a format-1 lock", String.replace(good, "format    = 2", "format = 1")}
          ] do
        assert {:error, [r]} = Lock.load(write(tmp, text)), why
        assert r.code == :bad_lock, why
      end
    end
  end
end
