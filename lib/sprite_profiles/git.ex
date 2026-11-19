defmodule SpriteProfiles.Git do
  @moduledoc """
  Fetches profiles from any git host with the `git` command: Gitea, Forgejo, GitLab,
  Codeberg, private GitHub repositories, folders deep in a monorepo.

    * `ls_remote/2` lists a repository's refs as `%{ref_name => sha}`, the shape
      `SpriteProfiles.GitHub.parse_refs/1` gives: an annotated tag appears twice, as
      `refs/tags/<t>` (the tag object) and `refs/tags/<t>^{}` (the commit it points at).
    * `fetch/5` puts one folder of one commit into a destination. It makes a shallow,
      blob-less fetch of that commit alone (`git fetch --depth 1 --filter=blob:none origin
      <sha>`) with a sparse checkout of the folder, checks the folder, then moves it into
      place. A server that will not hand over a commit by its sha (protocol v0 without
      `uploadpack.allowAnySHA1InWant`) is asked instead for the tag or branch that points at
      it, and the commit it gives is checked against the sha.
    * `fetch_cached/4` does the same through the cache.

  ## What is refused

  Inside the fetched folder: a symlink or a submodule (`bad_archive`), and more than
  32 MB of files (`archive_too_large`). The rest of the repository is never checked out, so
  it may hold anything. A folder the commit lacks is `profile_dir_missing`. Git itself gives
  `git_missing` (no `git` on PATH), `repo_not_found` (no such repository, or it needs
  credentials git does not have), `ref_not_found` (no such commit) and `fetch_failed`
  (anything else, and the timeout). A URL git should not be handed is `bad_address`.

  ## How git is run

  Directly, never through a shell, with the URL as one argument, in a fresh temporary
  folder that is removed afterwards. Every run has `GIT_TERMINAL_PROMPT=0`, no
  `GIT_ASKPASS`, `SSH_ASKPASS` or `core.askPass`, and (for SSH, unless the user configured
  their own SSH command) `ssh -o BatchMode=yes`, so a repository that needs credentials
  git does not already have fails at once instead of waiting at a prompt. Credentials are
  whatever the user's git has (a credential helper, an SSH key); this module never reads,
  asks for or logs them, and strips any `user:password@` from URLs it puts in a sentence.

  ## The cache

  `<root>/<host>/<path…>/<sha>/`, the root as `SpriteProfiles.GitHub.cache_root/1` gives
  it (`SPRITE_PROFILES_CACHE`, `XDG_CACHE_HOME`, `~/.cache/sprite-profiles`). `<path…>` is
  the repository's path on the host without `.git` (`acme/profiles`, or deeper for GitLab
  subgroups); a port is written `host-port`. Each fetched folder is its own entry under the
  commit, named by `URI.encode_www_form("/" <> folder)` (the root is `%2F`, `tools/linear`
  is `%2Ftools%2Flinear`), so the entries a commit has are the folders fetched from it. A
  folder is cached when it or a folder above it has an entry; any other folder of the same
  commit is fetched again. An entry lands by one rename, so a partial fetch never shows.

  ## Options

  `:pick` (the pick as written, for sentences; the URL and folder otherwise), `:cache_dir`
  (the cache root), `:offline` (`fetch_cached/4` refuses anything not cached,
  `not_cached`), `:timeout` (milliseconds for the whole operation, 120 000 by default),
  `:max_bytes` (the folder's size limit), `:git` (the git executable, a name on PATH or a
  path) and `:git_config` (extra `name=value` settings passed as `-c`; tests use
  `protocol.version=0`).
  """

  alias SpriteProfiles.{GitHub, Refusal}

  @max_bytes 32 * 1024 * 1024
  @timeout 120_000

  # Settings for every run: no prompt from any helper, no background work, no templates.
  @base_config [
    "core.askPass=",
    "credential.interactive=never",
    "core.fsmonitor=false",
    "gc.auto=0",
    "maintenance.auto=false",
    "init.defaultBranch=main",
    "advice.detachedHead=false"
  ]

  @default_ports %{"http" => 80, "https" => 443, "ssh" => 22, "git" => 9418}

  @doc "The largest folder fetched, in bytes (the sum of its files)."
  def max_bytes, do: @max_bytes

  @doc "The cache root (see `SpriteProfiles.GitHub.cache_root/1`)."
  def cache_root(opts \\ []), do: GitHub.cache_root(opts)

  ## addresses

  @doc """
  The cache segments of a git URL, `{:ok, [host | path]}`, or `:error` for a URL this
  module will not hand to git. Accepted: `https://`, `http://`, `ssh://`, `git://`,
  `file://` and the scp-like `user@host:path`. The host is lowercased, a port is appended
  as `host-port`, userinfo is dropped, and a trailing `.git` is removed.

      iex> SpriteProfiles.Git.repo_key("https://git.example.com/acme/profiles.git")
      {:ok, ["git.example.com", "acme", "profiles"]}
  """
  @spec repo_key(String.t()) :: {:ok, [String.t()]} | :error
  def repo_key(url) when is_binary(url) do
    with {:ok, host, path} <- split_url(url),
         segs when segs != [] <- path |> String.split("/", trim: true) |> strip_dot_git(),
         true <- Enum.all?(segs, &safe_segment?/1) do
      {:ok, [host | segs]}
    else
      _ -> :error
    end
  end

  def repo_key(_), do: :error

  defp split_url(url) do
    cond do
      String.starts_with?(url, "-") or String.contains?(url, ["\n", "\r", <<0>>]) ->
        :error

      Regex.match?(~r{^(https?|ssh|git|file)://}i, url) ->
        uri = URI.parse(url)
        scheme = String.downcase(uri.scheme)

        host =
          case uri.host do
            h when h in [nil, ""] and scheme == "file" -> "file"
            h when h in [nil, ""] -> nil
            h -> String.downcase(h)
          end

        host =
          if host && uri.port && uri.port != @default_ports[scheme],
            do: "#{host}-#{uri.port}",
            else: host

        if host, do: {:ok, host, uri.path || ""}, else: :error

      String.contains?(url, "://") ->
        :error

      m = Regex.run(~r{^(?:[^@/:\s]+@)?([A-Za-z0-9][A-Za-z0-9.\-_]*):([^:].*)$}, url) ->
        [_, host, path] = m
        {:ok, String.downcase(host), path}

      true ->
        :error
    end
  end

  defp strip_dot_git(segs) do
    case List.pop_at(segs, -1) do
      {nil, _} -> []
      {last, rest} -> rest ++ [String.replace_suffix(last, ".git", "")]
    end
  end

  defp safe_segment?(s), do: s not in ["", ".", ".."] and not String.contains?(s, "\\")

  @doc """
  The URL with any `user:password@` (or `token@`) removed, for sentences. Also applied to
  everything git prints before it is quoted.
  """
  @spec redact(String.t()) :: String.t()
  def redact(text), do: Regex.replace(~r{(://)[^/@\s]*@}, text, "\\1")

  ## cache

  @doc """
  Where the folders of the repository at `url`, commit `sha`, are (or would be) cached.
  Raises `ArgumentError` for a URL `repo_key/1` refuses.
  """
  @spec cache_path(String.t(), String.t(), keyword()) :: Path.t()
  def cache_path(url, sha, opts \\ []) do
    case repo_key(url) do
      {:ok, segs} -> Path.join([cache_root(opts) | segs] ++ [String.downcase(sha)])
      :error -> raise ArgumentError, "not a git URL: #{redact(url)}"
    end
  end

  @doc """
  The cached copy of folder `path` of `sha`: `{:ok, dir}` when that folder, or a folder
  above it, was fetched and the folder is there; `:error` otherwise.
  """
  @spec cached_dir(String.t(), String.t(), String.t(), keyword()) :: {:ok, Path.t()} | :error
  def cached_dir(url, sha, path, opts \\ []) do
    with {:ok, _} <- repo_key(url),
         {:ok, parts} <- path_parts(path) do
      base = cache_path(url, sha, opts)

      Enum.find_value(length(parts)..0//-1, :error, fn n ->
        {above, below} = Enum.split(parts, n)
        entry = Path.join(base, entry_name(above))
        dir = Path.join([entry | below])
        if File.dir?(entry) and File.dir?(dir), do: {:ok, dir}
      end)
    else
      _ -> :error
    end
  end

  @doc "True when folder `path` of `sha` is in the cache (see `cached_dir/4`)."
  @spec cached?(String.t(), String.t(), String.t(), keyword()) :: boolean()
  def cached?(url, sha, path, opts \\ []), do: match?({:ok, _}, cached_dir(url, sha, path, opts))

  defp entry_name(parts), do: URI.encode_www_form("/" <> Enum.join(parts, "/"))

  @doc """
  Makes sure folder `path` (`""` for the root) of commit `sha` of `url` is in the cache and
  returns `{:ok, dir}`. A cached folder runs no git.
  """
  @spec fetch_cached(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Path.t()} | {:error, Refusal.t()}
  def fetch_cached(url, sha, path, opts \\ []) do
    pick = opts[:pick] || display(url, path)

    with {:ok, parts} <- clean_path(path, url, pick) do
      case cached_dir(url, sha, path, opts) do
        {:ok, dir} ->
          {:ok, dir}

        :error ->
          cond do
            repo_key(url) == :error ->
              {:error, bad_url(url, pick)}

            opts[:offline] ->
              base = cache_path(url, sha, opts)

              {:error,
               Refusal.new(
                 :not_cached,
                 [pick],
                 "profile '#{pick}' is pinned to #{short(sha)}, whose #{folder(parts)} is not in the cache (#{base}), and --offline forbids fetching it; run once without --offline."
               )}

            true ->
              dest = Path.join(cache_path(url, sha, opts), entry_name(parts))
              fetch(url, sha, Enum.join(parts, "/"), dest, opts)
          end
      end
    end
  end

  ## ls-remote

  @doc """
  Lists the refs of the repository at `url`: `{:ok, %{ref_name => sha}}`, including `HEAD`
  and, for each annotated tag, `refs/tags/<t>^{}` with the commit it points at.
  """
  @spec ls_remote(String.t(), keyword()) ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, Refusal.t()}
  def ls_remote(url, opts \\ []) do
    with {:ok, st} <- start(url, "", opts) do
      tmp = make_tmp(System.tmp_dir!())

      try do
        list_refs(st, tmp)
      after
        File.rm_rf(tmp)
      end
    end
  end

  defp list_refs(st, cwd) do
    case git(st, ["ls-remote", st.url], cwd) do
      {:ok, out} -> {:ok, parse_ls_remote(out)}
      error -> {:error, git_refusal(st, "ls-remote", error)}
    end
  end

  @doc "Parses `git ls-remote` output (`<sha>\\t<ref>` lines; anything else is skipped)."
  @spec parse_ls_remote(String.t()) :: %{optional(String.t()) => String.t()}
  def parse_ls_remote(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^([0-9a-f]{40}|[0-9a-f]{64})\t(\S+)$/, String.trim_trailing(line)) do
        [_, sha, name] -> [{name, sha}]
        nil -> []
      end
    end)
    |> Map.new()
  end

  ## fetch

  @doc """
  Puts folder `path` (`""` for the repository's root) of commit `sha` of `url` into `dest`,
  which must not exist yet; its parent is created. Returns `{:ok, dest}`. Nothing lands at
  `dest` unless every check passed.
  """
  @spec fetch(String.t(), String.t(), String.t(), Path.t(), keyword()) ::
          {:ok, Path.t()} | {:error, Refusal.t()}
  def fetch(url, sha, path, dest, opts \\ []) do
    pick = opts[:pick] || display(url, path)

    with {:ok, parts} <- clean_path(path, url, pick),
         :ok <- check_sha(sha, url, pick),
         {:ok, st} <- start(url, pick, opts) do
      st = Map.merge(st, %{sha: String.downcase(sha), parts: parts})
      parent = Path.dirname(dest)
      File.mkdir_p!(parent)
      tmp = make_tmp(parent)
      work = Path.join(tmp, "repo")
      File.mkdir_p!(work)

      try do
        with :ok <- step(st, ["init", "-q", "--template="], work),
             :ok <- step(st, ["remote", "add", "origin", url], work),
             :ok <- sparse(st, work),
             :ok <- fetch_commit(st, work),
             :ok <- check_tree(st, work),
             :ok <- step(st, ["checkout", "-q", "--detach", st.sha], work),
             {:ok, src} <- folder_on_disk(st, work),
             :ok <- check_folder(st, src, Keyword.get(opts, :max_bytes, @max_bytes)) do
          place(st, src, dest)
        end
      after
        File.rm_rf(tmp)
      end
    end
  end

  defp sparse(%{parts: []}, _work), do: :ok

  defp sparse(st, work),
    do: step(st, ["sparse-checkout", "set", "--cone", "--", Enum.join(st.parts, "/")], work)

  defp fetch_args(ref),
    do: ["fetch", "-q", "--depth", "1", "--filter=blob:none", "--no-tags", "origin", ref]

  defp fetch_commit(st, work) do
    case git(st, fetch_args(st.sha), work) do
      {:ok, _} ->
        verify(st, st.sha, work)

      {:error, {:exit, _, out}} = error ->
        case classify(out) do
          :refused -> fetch_by_ref(st, work)
          _ -> {:error, git_refusal(st, "fetch", error)}
        end

      error ->
        {:error, git_refusal(st, "fetch", error)}
    end
  end

  # The server would not give the commit by its sha; ask for a tag or branch pointing at it.
  defp fetch_by_ref(st, work) do
    with {:ok, refs} <- list_refs(st, work) do
      case refs_at(refs, st.sha) do
        [] ->
          {:error, ref_not_found(st)}

        [ref | _] ->
          case git(st, fetch_args(ref), work) do
            {:ok, _} -> verify(st, "FETCH_HEAD", work)
            error -> {:error, git_refusal(st, "fetch", error)}
          end
      end
    end
  end

  defp refs_at(refs, sha) do
    refs
    |> Enum.filter(fn {name, target} ->
      not String.ends_with?(name, "^{}") and
        String.starts_with?(name, ["refs/tags/", "refs/heads/"]) and
        Map.get(refs, name <> "^{}", target) == sha
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort_by(&{not String.starts_with?(&1, "refs/tags/"), &1})
  end

  defp verify(st, rev, work) do
    case git(st, ["rev-parse", "--verify", "-q", rev <> "^{commit}"], work) do
      {:ok, out} ->
        case String.trim(out) do
          sha when sha == st.sha -> :ok
          commit when rev == st.sha -> {:error, tag_object(st, commit)}
          _ -> {:error, ref_not_found(st)}
        end

      _ ->
        {:error, ref_not_found(st)}
    end
  end

  # The sha named an annotated tag, not the commit it points at.
  defp tag_object(st, commit) do
    Refusal.new(
      :ref_not_found,
      [st.pick],
      "profile '#{st.pick}' is pinned to #{st.sha}, which in #{redact(st.url)} is a tag rather than a commit; pin the commit it points at, #{commit}."
    )
  end

  # Symlinks and submodules are read from the tree, before any file is downloaded.
  defp check_tree(st, work) do
    tree =
      if st.parts == [], do: st.sha <> "^{tree}", else: st.sha <> ":" <> Enum.join(st.parts, "/")

    case git(st, ["ls-tree", "-r", "-z", tree], work) do
      {:ok, out} ->
        bad =
          out
          |> String.split(<<0>>, trim: true)
          |> Enum.find_value(fn entry ->
            case String.split(entry, ["\t"], parts: 2) do
              ["120000 " <> _, name] -> "#{name}, a symlink rather than a file"
              ["160000 " <> _, name] -> "#{name}, a submodule rather than a file"
              _ -> nil
            end
          end)

        if bad, do: {:error, bad_folder(st, "holds #{bad}")}, else: :ok

      {:error, {:exit, _, _}} ->
        {:error,
         Refusal.new(
           :profile_dir_missing,
           [st.pick],
           "profile '#{st.pick}' names #{folder(st.parts)}, which #{redact(st.url)} does not have at #{short(st.sha)}; check the path."
         )}

      error ->
        {:error, git_refusal(st, "ls-tree", error)}
    end
  end

  defp folder_on_disk(%{parts: []}, work) do
    File.rm_rf!(Path.join(work, ".git"))
    {:ok, work}
  end

  defp folder_on_disk(st, work) do
    src = Path.join([work | st.parts])
    if File.dir?(src), do: {:ok, src}, else: {:error, bad_folder(st, "did not check out")}
  end

  # The tree was checked already; this checks what landed on disk, and its size.
  defp check_folder(st, src, max) do
    case walk(src, 0, max) do
      {:ok, _} -> :ok
      {:symlink, rel} -> {:error, bad_folder(st, "holds #{rel}, a symlink rather than a file")}
      :too_large -> {:error, too_large(st, max)}
    end
  end

  defp walk(dir, total, max, rel \\ "") do
    dir
    |> File.ls!()
    |> Enum.reduce_while({:ok, total}, fn name, {:ok, acc} ->
      path = Path.join(dir, name)
      rel = if rel == "", do: name, else: rel <> "/" <> name

      case File.lstat!(path) do
        %{type: :symlink} ->
          {:halt, {:symlink, rel}}

        %{type: :directory} ->
          case walk(path, acc, max, rel) do
            {:ok, acc} -> {:cont, {:ok, acc}}
            other -> {:halt, other}
          end

        %{size: size} when acc + size > max ->
          {:halt, :too_large}

        %{size: size} ->
          {:cont, {:ok, acc + size}}
      end
    end)
  end

  defp place(st, src, dest) do
    case File.rename(src, dest) do
      :ok ->
        {:ok, dest}

      {:error, _} ->
        # Another run got there first; a commit's folder is the same either way.
        if File.dir?(dest),
          do: {:ok, dest},
          else: {:error, bad_folder(st, "could not be moved into #{dest}")}
    end
  end

  ## running git

  defp start(url, pick, opts) do
    pick = if pick == "", do: opts[:pick] || redact(url), else: pick

    cond do
      repo_key(url) == :error ->
        {:error, bad_url(url, pick)}

      git = find_git(opts) ->
        {:ok,
         %{
           git: git,
           url: url,
           pick: pick,
           config: @base_config ++ List.wrap(opts[:git_config]),
           env: env(url, git),
           deadline: now() + Keyword.get(opts, :timeout, @timeout),
           timeout: Keyword.get(opts, :timeout, @timeout)
         }}

      true ->
        {:error,
         Refusal.new(
           :git_missing,
           [pick],
           "profile '#{pick}' comes from #{redact(url)}, which is fetched with git, and git is not on PATH; install git and try again."
         )}
    end
  end

  defp find_git(opts) do
    case opts[:git] || "git" do
      "/" <> _ = path -> if File.regular?(path), do: path
      name -> System.find_executable(name)
    end
  end

  defp env(url, git) do
    base = [
      {~c"GIT_TERMINAL_PROMPT", ~c"0"},
      {~c"GIT_ASKPASS", false},
      {~c"SSH_ASKPASS", false},
      {~c"GCM_INTERACTIVE", ~c"never"},
      {~c"GIT_DIR", false},
      {~c"GIT_WORK_TREE", false},
      {~c"GIT_INDEX_FILE", false},
      {~c"GIT_OBJECT_DIRECTORY", false},
      {~c"LC_ALL", ~c"C"}
    ]

    if ssh?(url) and own_ssh_command?(git) == false,
      do: [{~c"GIT_SSH_COMMAND", ~c"ssh -o BatchMode=yes"} | base],
      else: base
  end

  defp ssh?(url), do: String.starts_with?(url, "ssh://") or not String.contains?(url, "://")

  defp own_ssh_command?(git) do
    System.get_env("GIT_SSH_COMMAND") not in [nil, ""] or
      System.get_env("GIT_SSH") not in [nil, ""] or
      match?(
        {out, 0} when out != "",
        System.cmd(git, ["config", "--global", "--get", "core.sshCommand"],
          stderr_to_stdout: true,
          cd: System.tmp_dir!()
        )
      )
  end

  defp step(st, args, cwd) do
    case git(st, args, cwd) do
      {:ok, _} -> :ok
      error -> {:error, git_refusal(st, hd(args), error)}
    end
  end

  # Runs git with no shell; output and errors are collected together. On the deadline the
  # process is killed.
  defp git(st, args, cwd) do
    if now() >= st.deadline do
      {:error, :timeout}
    else
      port =
        Port.open({:spawn_executable, st.git}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          args: Enum.flat_map(st.config, &["-c", &1]) ++ args,
          cd: cwd,
          env: st.env
        ])

      collect(port, [], st.deadline)
    end
  end

  defp collect(port, acc, deadline) do
    receive do
      {^port, {:data, data}} ->
        collect(port, [acc, data], deadline)

      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(acc)}

      {^port, {:exit_status, status}} ->
        {:error, {:exit, status, IO.iodata_to_binary(acc)}}
    after
      max(deadline - now(), 0) ->
        kill(port)
        {:error, :timeout}
    end
  end

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp make_tmp(parent) do
    tmp = Path.join(parent, ".tmp-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    tmp
  end

  ## refusals

  defp classify(out) do
    o = String.downcase(out)

    cond do
      String.contains?(o, [
        "not our ref",
        "unadvertised object",
        "couldn't find remote ref",
        "no such remote ref",
        "no matching remote head"
      ]) ->
        :refused

      String.contains?(o, [
        "repository not found",
        "does not appear to be a git repository",
        "correct access rights",
        "could not read username",
        "could not read password",
        "authentication failed",
        "terminal prompts disabled",
        "permission denied",
        "access denied",
        "could not be found",
        "the requested url returned error: 401",
        "the requested url returned error: 403",
        "the requested url returned error: 404"
      ]) ->
        :repo_not_found

      true ->
        :other
    end
  end

  defp git_refusal(st, _verb, {:error, :timeout}) do
    Refusal.new(
      :fetch_failed,
      [st.pick],
      "profile '#{st.pick}' could not be fetched: git took longer than #{div(st.timeout, 1000)} s with #{redact(st.url)} and was stopped; try again, or check the network."
    )
  end

  defp git_refusal(st, verb, {:error, {:exit, status, out}}) do
    case classify(out) do
      :repo_not_found ->
        Refusal.new(
          :repo_not_found,
          [st.pick],
          "profile '#{st.pick}' comes from #{redact(st.url)}, which git could not open (#{reason(out, status)}); check the address, and for a private repository give git its own credentials for the host (a credential helper or an SSH key): sprite-profiles never asks for them."
        )

      _ ->
        Refusal.new(
          :fetch_failed,
          [st.pick],
          "profile '#{st.pick}' could not be fetched: git #{verb} #{redact(st.url)} failed (#{reason(out, status)}); try again, or check the network."
        )
    end
  end

  defp reason(out, status) do
    lines = out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)

    line =
      Enum.find(lines, &String.starts_with?(&1, ["fatal:", "error:"])) || List.last(lines) ||
        "exit status #{status}"

    line
    |> String.replace(~r/^(fatal|error): /, "")
    |> redact()
    |> String.slice(0, 200)
  end

  defp ref_not_found(st) do
    Refusal.new(
      :ref_not_found,
      [st.pick],
      "profile '#{st.pick}' is pinned to commit #{st.sha}, which #{redact(st.url)} does not have, or will give only through a tag or branch and none points at it; check the commit."
    )
  end

  defp bad_folder(st, what) do
    Refusal.new(
      :bad_archive,
      [st.pick],
      "profile '#{st.pick}' comes from #{redact(st.url)}, whose #{folder(st.parts)} #{what}; nothing was fetched."
    )
  end

  defp too_large(st, max) do
    Refusal.new(
      :archive_too_large,
      [st.pick],
      "profile '#{st.pick}' comes from #{redact(st.url)}, whose #{folder(st.parts)} is over #{size_text(max)}, the most fetched; keep profiles small."
    )
  end

  defp bad_url(url, pick) do
    Refusal.new(
      :bad_address,
      [pick],
      "profile '#{pick}' comes from #{redact(url)}, which is not a git URL this fetches; use https://, ssh://, git://, file:// or host:path."
    )
  end

  defp check_sha(sha, url, pick) do
    if is_binary(sha) and Regex.match?(~r/^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$/, sha) do
      :ok
    else
      {:error,
       Refusal.new(
         :ref_not_found,
         [pick],
         "profile '#{pick}' is pinned to #{inspect(sha)} in #{redact(url)}, which is not a full commit id; resolve the ref first."
       )}
    end
  end

  defp clean_path(path, url, pick) do
    case path_parts(path) do
      {:ok, parts} ->
        {:ok, parts}

      :error ->
        {:error,
         Refusal.new(
           :bad_address,
           [pick],
           "profile '#{pick}' names the folder #{inspect(path)} in #{redact(url)}, which climbs out of the repository; use a path inside it."
         )}
    end
  end

  defp path_parts(path) when is_binary(path) do
    parts = path |> String.split("/", trim: true) |> Enum.reject(&(&1 == "."))

    if Enum.any?(parts, &(&1 == ".." or String.contains?(&1, ["\\", <<0>>]))),
      do: :error,
      else: {:ok, parts}
  end

  defp path_parts(_), do: :error

  defp display(url, path) do
    case path_parts(path) do
      {:ok, [_ | _] = parts} -> redact(url) <> "//" <> Enum.join(parts, "/")
      _ -> redact(url)
    end
  end

  defp folder([]), do: "repository root"
  defp folder(parts), do: "folder #{Enum.join(parts, "/")}"

  defp size_text(bytes) when bytes >= 1024 * 1024, do: "#{div(bytes, 1024 * 1024)} MB"
  defp size_text(bytes), do: "#{bytes} bytes"

  defp short(sha), do: String.slice(to_string(sha), 0, 8)
end
