defmodule SpriteProfiles.PathPickTest do
  # Path picks (`./x`, `../x`, `/x`, `~/x`): a profile folder named directly, loaded as a
  # local profile, beside the search path rather than instead of it. Not async: the CLI
  # tests read the default search path from the environment.
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias SpriteProfiles.{CLI, Lock, Merge, Pick, ProjectFile, Resolver}

  @profiles Path.expand("../../profiles", __DIR__)
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    project = Path.join(tmp, "project")
    profile!(project, "weekend")
    {:ok, project: project}
  end

  defp profile!(parent, folder, name \\ nil) do
    dir = Path.join(parent, folder)
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "profile.toml"), """
    name    = "#{name || folder}"
    summary = "a project's own profile"
    """)

    dir
  end

  defp run(argv, ctx) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(parent, {:status, CLI.run_main(argv, ctx)}) end)
        send(parent, {:stdout, stdout})
      end)

    assert_received {:status, status}
    assert_received {:stdout, stdout}
    {status, stdout, stderr}
  end

  defp codes({:error, problems}), do: Enum.map(problems, & &1.code)

  ## the grammar

  test "kind/1: ./, ../, / and ~/ start a path, checked before the address rule" do
    assert Pick.kind("./weekend") == :path
    assert Pick.kind("../demo/weekend") == :path
    assert Pick.kind("/srv/profiles/weekend") == :path
    assert Pick.kind("~/profiles/weekend") == :path
    assert Pick.kind("./has@sign") == :path

    # What worked before keeps its meaning.
    assert Pick.kind("demo/weekend") == :address
    assert Pick.kind("acme/profiles/linear@v1") == :address
    assert Pick.kind("@acme/linear") == :name
    assert Pick.kind("weekend") == :local
    assert Pick.kind(".weekend") == :local
    assert Pick.kind("~weekend") == :local
  end

  test "path_identity/1 folds spellings of one path; rebase/3 moves a relative one" do
    assert Pick.path_identity("./weekend/") == Pick.path_identity("./weekend")
    assert Pick.path_identity("./a/../weekend") == Pick.path_identity("./weekend")
    assert Pick.path_identity("../weekend") != Pick.path_identity("/weekend")
    assert Pick.path_identity("~/weekend") != Pick.path_identity("./weekend")

    assert Pick.rebase("./demo/weekend", "/p", "/p/out") == "../demo/weekend"
    assert Pick.rebase("./weekend", "/p/sub", "/p") == "./sub/weekend"
    assert Pick.rebase("./weekend", "/p", "/p") == "./weekend"
    assert Pick.rebase("/abs/weekend", "/p", "/q") == "/abs/weekend"
    assert Pick.rebase("claude-code", "/p", "/q") == "claude-code"
  end

  ## resolving

  test "a path pick resolves absolute, ./ from the base, and ~/ from home", %{project: dir} do
    abs = Path.join(dir, "weekend")

    assert {:ok, [p]} = Resolver.find([abs], [])
    assert {p.name, p.qualified, p.pick, p.source} == {"weekend", "weekend", abs, nil}

    assert {:ok, [p]} = Resolver.find(["./weekend"], [], base: dir)
    assert {p.qualified, p.pick, p.path} == {"weekend", "./weekend", abs}

    assert {:ok, [_]} = Resolver.find(["../weekend/"], [], base: Path.join(dir, "x"))

    assert Pick.resolve_path("~/profiles/weekend", "/elsewhere") ==
             Path.join(System.user_home!(), "profiles/weekend")
  end

  test "a missing folder is profile_not_found; one without profile.toml is refused",
       %{project: dir} do
    assert {:error, [r]} = Resolver.find(["./nope"], [], base: dir)
    assert r.code == :profile_not_found
    assert r.message =~ Path.join(dir, "nope")
    assert r.message =~ "./nope"

    File.mkdir_p!(Path.join(dir, "empty"))
    assert codes(Resolver.find(["./empty"], [], base: dir)) == [:missing_profile_toml]
  end

  test "the folder's name must be the profile's, as on the search path", %{project: dir} do
    profile!(dir, "wkend", "weekend")
    assert codes(Resolver.find(["./wkend"], [], base: dir)) == [:name_mismatch]
  end

  ## in a set

  test "a path pick composes with search-path profiles, which stay found", %{project: dir} do
    {0, out, ""} = run(["plan", "claude-code", "./weekend", "--dir", @profiles], cwd: dir)
    assert out =~ "Plan for claude-code+./weekend"
    assert out =~ "profile:weekend"
    assert out =~ "profile:claude-code"

    # With no --dir the default path (the bundled examples in a release) is untouched.
    saved = System.get_env("SPRITE_PROFILES_PATH")
    System.delete_env("SPRITE_PROFILES_PATH")
    on_exit(fn -> if saved, do: System.put_env("SPRITE_PROFILES_PATH", saved) end)

    {0, out, ""} = run(["plan", "claude-code", "./weekend"], cwd: dir)
    assert out =~ "profile:claude-code"
    assert out =~ "profile:weekend"
  end

  test "a path pick and a local pick of the same name are refused, not merged",
       %{project: dir} do
    assert {:ok, profiles} =
             Resolver.find(["./weekend", "weekend"], [dir], base: dir)

    assert {:error, [r]} = Merge.merge(profiles)
    assert r.code == :profile_collision
    assert r.profiles == ["./weekend", "weekend"]

    assert {:error, [r]} = Merge.check_picks(["./weekend", "./weekend/"])
    assert r.code == :duplicate_pick
  end

  ## the project file and the lock

  test "add stores the path as written, remove matches it, and the file's folder is the base",
       %{project: dir} do
    file = ProjectFile.path(dir)

    {0, out, ""} = run(["add", "claude-code", "./weekend", "--dir", @profiles], cwd: dir)
    assert out =~ "Added ./weekend  (local)"
    assert {:ok, %{profiles: ["claude-code", "./weekend"]}} = ProjectFile.read(file)

    # The test process runs elsewhere, so this resolves from the file's folder.
    refute File.cwd!() == dir
    {0, out, ""} = run(["plan", "--dir", @profiles], cwd: dir)
    assert out =~ "Plan for claude-code+./weekend"

    {0, out, ""} = run(["remove", "./weekend/"], cwd: dir)
    assert out =~ "Removed ./weekend\n"
    assert {:ok, %{profiles: ["claude-code"]}} = ProjectFile.read(file)
  end

  test "a lock records a path pick as written and resolves it from the lock's folder",
       %{project: dir, tmp_dir: tmp} do
    File.write!(ProjectFile.path(dir), ~s(profiles = ["claude-code", "./weekend"]\n))
    {0, out, ""} = run(["lock", "--dir", @profiles], cwd: dir)
    assert out =~ "./weekend  (local)"

    lock = Path.join(dir, "sprite-profiles.lock")
    text = File.read!(lock)
    assert text =~ "format    = 4"
    assert text =~ ~r/pick += "\.\/weekend"/
    assert {:ok, [%{pick: "claude-code"}, %{pick: "./weekend"}]} = Lock.read(lock)

    elsewhere = Path.join(tmp, "elsewhere")
    File.mkdir_p!(elsewhere)
    {0, out, ""} = run(["plan", "--lock", lock, "--dir", @profiles], cwd: elsewhere)
    assert out =~ "profile:weekend"
  end

  test "lock --output elsewhere rewrites a relative path for the lock's folder",
       %{project: dir} do
    out_dir = Path.join(dir, "locks")
    File.mkdir_p!(out_dir)
    output = Path.join(out_dir, "set.lock")

    {0, _, ""} =
      run(["lock", "claude-code", "./weekend", "--dir", @profiles, "--output", output], cwd: dir)

    assert {:ok, [_, %{pick: "../weekend"}]} = Lock.read(output)
    {0, out, ""} = run(["plan", "--lock", output, "--dir", @profiles], cwd: dir)
    assert out =~ "profile:weekend"
  end

  test "a lock round trip keeps a path pick; an older format holding one is bad_lock",
       %{tmp_dir: tmp} do
    path = Path.join(tmp, "round.lock")
    entries = [%{pick: "claude-code"}, %{pick: "../shared/weekend"}, %{pick: "/srv/weekend"}]
    File.write!(path, Lock.encode(entries))
    assert Lock.read(path) == {:ok, entries}

    File.write!(path, "format = 3\n[[picks]]\npick = \"./weekend\"\n")
    assert codes(Lock.read(path)) == [:bad_lock]

    File.write!(path, "format = 4\n[[picks]]\npick = \"./weekend\"\nsha = \"x\"\n")
    assert codes(Lock.read(path)) == [:bad_lock]
  end
end
