defmodule SpriteProfiles.Address do
  @moduledoc """
  A profile's address: `owner/repo[/path]@ref` on GitHub, in the form GitHub Actions uses,
  or `HOST/OWNER/REPO[/path]@ref` on another git host.

  `owner/repo` is the repository, `path` (optional) the folder in it that holds
  `profile.toml`, and `ref` a tag, a branch or a 40-hex commit. The ref is required. Owner
  and repository are compared case-insensitively and kept lowercase; the path and the ref
  are kept as written.

  A first segment holding a `.` or a `:` is a host (`host` or `host:port`); `github.com` is
  the same as no host. On GitHub the owner is one segment in GitHub's owner alphabet. On
  another host the owner is one segment, unless the repository is marked by a `.git`
  ending, as Go does: everything before that segment is the namespace, so GitLab subgroups
  read `gitlab.example.com/group/sub/repo.git/path@ref`. A `.git` ending is dropped wherever
  it is written.

  `SpriteProfiles.Pick.kind/1` says whether a pick is an address at all.
  """

  @github "github.com"

  @enforce_keys [:owner, :repo, :path, :ref]
  defstruct [:owner, :repo, :path, :ref, host: @github]

  @typedoc "`owner` is the namespace, its segments joined by `/` (one segment on GitHub)."
  @type t :: %__MODULE__{
          host: String.t(),
          owner: String.t(),
          repo: String.t(),
          path: String.t(),
          ref: String.t()
        }

  @owner_re ~r/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$/
  @repo_re ~r/^[A-Za-z0-9._-]{1,100}$/
  @segment_re ~r/^[A-Za-z0-9._-]+$/
  @host_re ~r/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::[0-9]{1,5})?$/
  @ref_re ~r/^[A-Za-z0-9._\/-]+$/
  @sha_re ~r/^[0-9a-fA-F]{40}$/

  @doc "The host an address without one is on."
  def github, do: @github

  @doc """
  Parses an address. Returns `{:ok, address}`, or `{:error, :address_needs_ref}` when
  there is no `@ref`, or `{:error, :bad_address}`.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, :bad_address | :address_needs_ref}
  def parse(pick) when is_binary(pick) do
    {where, ref} =
      case String.split(pick, "@", parts: 2) do
        [where, ref] -> {where, ref}
        [where] -> {where, nil}
      end

    with {:ok, host, owner, repo, path} <- parse_where(String.split(where, "/")),
         :ok <- check_ref(ref) do
      {:ok,
       %__MODULE__{
         host: host,
         owner: String.downcase(owner),
         repo: String.downcase(repo),
         path: Enum.join(path, "/"),
         ref: ref
       }}
    end
  end

  def parse(_), do: {:error, :bad_address}

  defp parse_where([first | rest] = segments) do
    if String.contains?(first, [".", ":"]) do
      host = String.downcase(first)

      cond do
        not Regex.match?(@host_re, host) -> {:error, :bad_address}
        host == @github -> parse_github(rest)
        true -> parse_other(host, rest)
      end
    else
      parse_github(segments)
    end
  end

  defp parse_github([owner, repo | path]) do
    repo = strip_git(repo)

    cond do
      not Regex.match?(@owner_re, owner) -> {:error, :bad_address}
      not good_segment?(repo, @repo_re) -> {:error, :bad_address}
      not Enum.all?(path, &good_segment?(&1, @segment_re)) -> {:error, :bad_address}
      true -> {:ok, @github, owner, repo, path}
    end
  end

  defp parse_github(_), do: {:error, :bad_address}

  defp parse_other(host, segments) do
    # The repository ends at the first segment ending `.git`, after at least one
    # namespace segment; without one, the namespace is the first segment.
    marked = Enum.find_index(segments, &(String.ends_with?(&1, ".git") and &1 != ".git"))

    split =
      case marked do
        nil when length(segments) >= 2 ->
          {[hd(segments)], Enum.at(segments, 1), Enum.drop(segments, 2)}

        nil ->
          nil

        0 ->
          nil

        i ->
          {Enum.take(segments, i), Enum.at(segments, i), Enum.drop(segments, i + 1)}
      end

    with {ns, repo, path} <- split,
         repo = strip_git(repo),
         true <- Enum.all?(ns, &good_segment?(&1, @segment_re)),
         true <- good_segment?(repo, @repo_re),
         true <- Enum.all?(path, &good_segment?(&1, @segment_re)) do
      {:ok, host, Enum.join(ns, "/"), repo, path}
    else
      _ -> {:error, :bad_address}
    end
  end

  defp strip_git(repo), do: String.replace_suffix(repo, ".git", "")

  defp good_segment?(s, re), do: s not in ["", ".", ".."] and Regex.match?(re, s)

  defp check_ref(nil), do: {:error, :address_needs_ref}

  defp check_ref(ref) do
    parts = String.split(ref, "/")

    if Regex.match?(@ref_re, ref) and Enum.all?(parts, &(&1 not in ["", ".", ".."])) do
      :ok
    else
      {:error, :bad_address}
    end
  end

  @doc "True when `ref` is a full 40-hex commit, which needs no resolving."
  def sha?(ref) when is_binary(ref), do: Regex.match?(@sha_re, ref)
  def sha?(_), do: false

  @doc "True when the address is on GitHub."
  def github?(%__MODULE__{host: host}), do: host == @github

  @doc """
  The name the profile must declare: the last path segment, or nil at a repository root
  (where any name is allowed).
  """
  def expected_name(%__MODULE__{path: ""}), do: nil
  def expected_name(%__MODULE__{path: path}), do: path |> String.split("/") |> List.last()

  @doc """
  A fetched profile's qualified name: `<owner>.<name>` on GitHub; on another host
  `<host>.<ns…>.<name>`, lowercased, with a port's `:` written as `-`. A GitHub qualified
  name has exactly one `.` and another host's has at least two, so they never collide.
  """
  def qualified(%__MODULE__{host: @github, owner: owner}, name), do: "#{owner}.#{name}"

  def qualified(%__MODULE__{host: host, owner: owner}, name) do
    [host | String.split(owner, "/")]
    |> Enum.concat([name])
    |> Enum.join(".")
    |> String.downcase()
    |> String.replace(":", "-")
  end

  @doc """
  The address without its ref: what makes two picks the same profile. On another host the
  repository keeps its `.git`, so a namespace of several segments reads one way only.
  """
  def identity(%__MODULE__{} = a), do: Enum.join([where(a) | path_parts(a)], "/")

  @doc "The repository: `owner/repo` on GitHub, `host/ns…/repo` elsewhere."
  def repo_slug(%__MODULE__{host: @github, owner: o, repo: r}), do: "#{o}/#{r}"
  def repo_slug(%__MODULE__{host: h, owner: o, repo: r}), do: "#{h}/#{o}/#{r}"

  @doc """
  The address as written, with host, owner and repository lowercased; the host is left out
  on GitHub, and a namespace of several segments marks its repository with `.git`.
  """
  def to_string(%__MODULE__{} = a) do
    Enum.join([written(a) | path_parts(a)], "/") <> "@" <> a.ref
  end

  defp where(%{host: @github} = a), do: "#{a.owner}/#{a.repo}"
  defp where(a), do: "#{a.host}/#{a.owner}/#{a.repo}.git"

  defp written(%{host: @github} = a), do: "#{a.owner}/#{a.repo}"

  defp written(a) do
    if String.contains?(a.owner, "/"),
      do: "#{a.host}/#{a.owner}/#{a.repo}.git",
      else: "#{a.host}/#{a.owner}/#{a.repo}"
  end

  defp path_parts(%{path: ""}), do: []
  defp path_parts(%{path: p}), do: [p]
end
