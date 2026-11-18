defmodule Mix.Tasks.Profiles.PlanTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.Profiles.Plan

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

  test "prints the plan with privileged profiles after the checkpoint" do
    Plan.run(["--profile", "claude-code", "--profile", "anthropic-key"])
    out = output()
    assert out =~ "Plan for claude-code+anthropic-key (privileged"
    assert out =~ ~r/1\. claude-code.*\n.*checkpoint.*\n  2\. anthropic-key/
  end

  test "exits 1 with the refusal for an agent asking for a privileged set" do
    assert catch_exit(Plan.run(["-p", "claude-code", "-p", "anthropic-key", "--agent"])) ==
             {:shutdown, 1}

    assert output() =~ "[not_for_agents] profile 'anthropic-key' is privileged"
  end

  test "exits 1 for a profile that does not exist" do
    assert catch_exit(Plan.run(["-p", "nope"])) == {:shutdown, 1}
    assert output() =~ "[profile_not_found]"
  end

  @tag :tmp_dir
  test "searches every --dir, and refuses a name found in two of them", %{tmp_dir: tmp} do
    private = Path.join(tmp, "private")
    File.mkdir_p!(Path.join(private, "my-model"))

    File.write!(
      Path.join([private, "my-model", "profile.toml"]),
      ~s(name = "my-model"\nsummary = "a private profile"\n)
    )

    Plan.run(["-p", "claude-code", "-p", "my-model", "--dir", "profiles", "--dir", private])
    assert output() =~ "Plan for claude-code+my-model"

    File.cp_r!("profiles/preview", Path.join(private, "preview"))

    assert catch_exit(Plan.run(["-p", "preview", "--dir", "profiles", "--dir", private])) ==
             {:shutdown, 1}

    out = output()
    assert out =~ "[profile_ambiguous]"
    assert out =~ Path.join(private, "preview")
    assert out =~ Path.expand("profiles/preview")
  end

  test "exits 2 on bad usage" do
    capture_io(:stderr, fn ->
      assert catch_exit(Plan.run(["--bogus"])) == {:shutdown, 2}
    end)
  end
end
