defmodule Mix.Tasks.Profiles.LaunchTest do
  # Only the paths that create nothing: a live launch needs a Sprite (see README, "Try it").
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.Profiles.Launch

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  defp output do
    Stream.repeatedly(fn ->
      receive do
        {:mix_shell, _kind, [line]} -> line
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
    |> Enum.join("\n")
  end

  test "--dry-run prints the plan and creates nothing" do
    Launch.run(["-p", "claude-code", "-p", "preview", "--dry-run"])
    out = output()
    assert out =~ "Plan for claude-code+preview"
    assert out =~ "Dry run: nothing was created."
  end

  @tag :tmp_dir
  test "--secrets-dir says where a privileged profile's secret is read from", %{tmp_dir: tmp} do
    assert catch_exit(
             Launch.run(["-p", "claude-code", "-p", "anthropic-key", "--secrets-dir", tmp])
           ) == {:shutdown, 1}

    out = output()
    assert out =~ "[secret_missing]"
    assert out =~ Path.join(tmp, "ANTHROPIC_API_KEY")

    File.write!(Path.join(tmp, "ANTHROPIC_API_KEY"), "sk-test-not-real\n")

    Launch.run(~w(-p claude-code -p anthropic-key --dry-run --secrets-dir) ++ [tmp])

    out = output()
    assert out =~ "Dry run: nothing was created."
    refute out =~ "sk-test-not-real"
  end

  test "the record path is shown relative to home" do
    assert Launch.home_relative(Path.expand("~/.local/state/x.json")) == "~/.local/state/x.json"
    assert Launch.home_relative("/elsewhere/x.json") == "/elsewhere/x.json"
  end

  test "a refused set exits 1 before any Sprite call" do
    assert catch_exit(Launch.run(["-p", "preview", "-p", "preview"])) == {:shutdown, 1}
    assert output() =~ "[duplicate_pick]"
  end

  test "exits 2 on bad usage and on an unknown adapter" do
    capture_io(:stderr, fn ->
      assert catch_exit(Launch.run(["--bogus"])) == {:shutdown, 2}
    end)

    assert catch_exit(Launch.run(["-p", "preview", "--adapter", "ftp"])) == {:shutdown, 2}
  end

  test "--adapter api without a token exits 2 and says which variable to set" do
    saved = for v <- ["SPRITES_TOKEN", "SPRITE_TOKEN"], do: {v, System.get_env(v)}
    Enum.each(saved, fn {v, _} -> System.delete_env(v) end)

    on_exit(fn ->
      Enum.each(saved, fn
        {v, nil} -> System.delete_env(v)
        {v, val} -> System.put_env(v, val)
      end)
    end)

    assert catch_exit(Launch.run(["-p", "preview", "--adapter", "api"])) == {:shutdown, 2}
    assert output() =~ "SPRITES_TOKEN"
  end
end
