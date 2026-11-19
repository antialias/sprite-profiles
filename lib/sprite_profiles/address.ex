defmodule SpriteProfiles.Address do
  @moduledoc """
  A profile's address on GitHub, in the form GitHub Actions uses: `owner/repo[/path]@ref`.

  `owner/repo` is the repository, `path` (optional) the folder in it that holds
  `profile.toml`, and `ref` a tag, a branch or a 40-hex commit. The ref is required. Owner
  and repository are compared case-insensitively and kept lowercase; the path and the ref
  are kept as written.

  A first segment holding a `.` is refused: it is reserved for a host prefix later
  (`gitlab.example/...`), and a GitHub owner cannot contain one.
  """

  @enforce_keys [:owner, :repo, :path, :ref]
  defstruct [:owner, :repo, :path, :ref]

  @type t :: %__MODULE__{owner: String.t(), repo: String.t(), path: String.t(), ref: String.t()}

  @owner_re ~r/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$/
  @repo_re ~r/^[A-Za-z0-9._-]{1,100}$/
  @segment_re ~r/^[A-Za-z0-9._-]+$/
  @ref_re ~r/^[A-Za-z0-9._\/-]+$/
  @sha_re ~r/^[0-9a-fA-F]{40}$/

  @doc "True when `pick` is written as an address (it holds a `/` or an `@`), not a name."
  def address?(pick) when is_binary(pick), do: String.contains?(pick, ["/", "@"])
  def address?(_), do: false

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

    with {:ok, owner, repo, path} <- parse_where(where),
         :ok <- check_ref(ref) do
      {:ok,
       %__MODULE__{
         owner: String.downcase(owner),
         repo: String.downcase(repo),
         path: Enum.join(path, "/"),
         ref: ref
       }}
    end
  end

  def parse(_), do: {:error, :bad_address}

  defp parse_where(where) do
    case String.split(where, "/") do
      [owner, repo | path] ->
        cond do
          String.contains?(owner, ".") -> {:error, :bad_address}
          not Regex.match?(@owner_re, owner) -> {:error, :bad_address}
          not good_segment?(repo, @repo_re) -> {:error, :bad_address}
          not Enum.all?(path, &good_segment?(&1, @segment_re)) -> {:error, :bad_address}
          true -> {:ok, owner, repo, path}
        end

      _ ->
        {:error, :bad_address}
    end
  end

  defp good_segment?(s, re), do: s not in [".", ".."] and Regex.match?(re, s)

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

  @doc """
  The name the profile must declare: the last path segment, or nil at a repository root
  (where any name is allowed).
  """
  def expected_name(%__MODULE__{path: ""}), do: nil
  def expected_name(%__MODULE__{path: path}), do: path |> String.split("/") |> List.last()

  @doc "A fetched profile's qualified name: `<owner>.<name>`."
  def qualified(%__MODULE__{owner: owner}, name), do: "#{owner}.#{name}"

  @doc "The address without its ref: what makes two picks the same profile."
  def identity(%__MODULE__{} = a), do: Enum.join([a.owner, a.repo | path_parts(a)], "/")

  @doc "`owner/repo`."
  def repo_slug(%__MODULE__{owner: o, repo: r}), do: "#{o}/#{r}"

  @doc "The address as written, with owner and repository lowercased."
  def to_string(%__MODULE__{} = a), do: identity(a) <> "@" <> a.ref

  defp path_parts(%{path: ""}), do: []
  defp path_parts(%{path: p}), do: [p]
end
