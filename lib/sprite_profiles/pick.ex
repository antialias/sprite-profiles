defmodule SpriteProfiles.Pick do
  @moduledoc """
  What a pick is, told apart by its first characters:

    * a **name**, `@[HOST/]NS/NAME[@V]`, starts with `@`: a published profile found by
      convention (`SpriteProfiles.Names`);
    * a **path**, starting with `./`, `../`, `/` or `~/`: a profile folder on disk, loaded as
      a local profile without touching the search path (`resolve_path/2`);
    * an **address**, `owner/repo[/path]@ref`, holds a `/` or an `@`
      (`SpriteProfiles.Address`);
    * anything else is **local**, a profile name on the search path.

  In a name, `HOST` is `host` or `host:port` and is told by a `.` or `:` in the first
  segment; `github.com`, or no host, is GitHub. On GitHub `NS` is one segment in the owner
  alphabet; on another host it is one or more segments of `[A-Za-z0-9._-]`. `NAME` uses
  the profile name alphabet. `V` is a version prefix (`1`, `1.2`, `1.2.3`) or, written any
  other way, a ref (a branch, a tag or a 40-hex commit, which is a ref even when all its
  digits are decimal). The host is lowercased; the namespace is kept as written, so a
  server that tells case apart is asked for what was written, and compared
  case-insensitively (`identity/1`).
  """

  alias SpriteProfiles.Profile

  @enforce_keys [:host, :ns, :name, :version]
  defstruct [:host, :ns, :name, :version]

  @typedoc "`nil` is the newest version; `{:prefix, [major | ...]}`; `{:ref, ref}`."
  @type version :: nil | {:prefix, [non_neg_integer()]} | {:ref, String.t()}

  @type t :: %__MODULE__{
          host: String.t(),
          ns: [String.t()],
          name: String.t(),
          version: version()
        }

  @github "github.com"
  @owner_re ~r/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$/
  @segment_re ~r/^[A-Za-z0-9._-]+$/
  @host_re ~r/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::[0-9]{1,5})?$/
  # Numbers as semver writes them: no leading zeros.
  @prefix_re ~r/^(?:0|[1-9]\d*)(?:\.(?:0|[1-9]\d*)){0,2}$/
  @ref_re ~r/^[A-Za-z0-9._\/-]+$/
  @sha_re ~r/^[0-9a-fA-F]{40}$/

  @doc "The host GitHub names are on."
  def github, do: @github

  @doc """
  The kind of pick: `:name` when it starts with `@`; `:path` when it starts with `./`,
  `../`, `/` or `~/`; otherwise `:address` when it holds a `/` or an `@`; otherwise
  `:local`.
  """
  @spec kind(String.t()) :: :local | :name | :address | :path
  def kind("@" <> _), do: :name
  def kind("./" <> _), do: :path
  def kind("../" <> _), do: :path
  def kind("/" <> _), do: :path
  def kind("~/" <> _), do: :path

  def kind(pick) when is_binary(pick),
    do: if(String.contains?(pick, ["/", "@"]), do: :address, else: :local)

  @doc """
  The folder a path pick names: `~/` is the home folder, and a relative path (`./`, `../`)
  is taken from `base`, the folder it was written in (the working directory on the command
  line, the project file's or the lock's folder when it comes from one).
  """
  @spec resolve_path(String.t(), Path.t()) :: Path.t()
  def resolve_path("~/" <> _ = pick, _base), do: Path.expand(pick)
  def resolve_path(pick, base), do: Path.expand(pick, base)

  @doc """
  What makes two path picks the same folder as written: the path with `.` segments,
  repeated and trailing slashes dropped and `dir/..` folded, keeping how it starts
  (`/`, `~/`, or relative). It reads no disk, so two spellings through a symlink differ.
  """
  @spec path_identity(String.t()) :: String.t()
  def path_identity(pick) do
    {root, rest} =
      case pick do
        "/" <> rest -> {"/", rest}
        "~/" <> rest -> {"~/", rest}
        rest -> {"./", rest}
      end

    segments =
      rest
      |> String.split("/", trim: true)
      |> Enum.reduce([], fn
        ".", acc -> acc
        "..", [top | acc] when top != ".." -> acc
        "..", acc when root == "./" -> [".." | acc]
        "..", acc -> acc
        seg, acc -> [seg | acc]
      end)
      |> Enum.reverse()

    root <> Enum.join(segments, "/")
  end

  @doc """
  A relative path pick written in `from`, rewritten to name the same folder from `to` (as
  `./x` or `../x`); any other pick is returned unchanged.
  """
  @spec rebase(String.t(), Path.t(), Path.t()) :: String.t()
  def rebase(pick, from, to) do
    from = Path.expand(from)
    to = Path.expand(to)

    if kind(pick) == :path and relative_path?(pick) and from != to do
      case Path.relative_to(resolve_path(pick, from), to, force: true) do
        "." -> "./"
        "../" <> _ = rel -> rel
        ".." -> "../"
        rel -> "./" <> rel
      end
    else
      pick
    end
  end

  defp relative_path?("./" <> _), do: true
  defp relative_path?("../" <> _), do: true
  defp relative_path?(_), do: false

  @doc """
  Parses a name pick. Returns `{:ok, pick}` or `{:error, :bad_name}`.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, :bad_name}
  def parse("@" <> rest) do
    {where, version} =
      case String.split(rest, "@", parts: 2) do
        [where, v] -> {where, v}
        [where] -> {where, nil}
      end

    with {:ok, host, ns, name} <- parse_where(String.split(where, "/")),
         {:ok, version} <- parse_version(version) do
      {:ok, %__MODULE__{host: host, ns: ns, name: name, version: version}}
    end
  end

  def parse(_), do: {:error, :bad_name}

  defp parse_where([first | rest] = segments) do
    if String.contains?(first, [".", ":"]),
      do: parse_host(String.downcase(first), rest),
      else: parse_ns(@github, segments)
  end

  defp parse_host(host, rest) do
    cond do
      not Regex.match?(@host_re, host) -> {:error, :bad_name}
      host == @github -> parse_ns(@github, rest)
      true -> parse_ns(host, rest)
    end
  end

  defp parse_ns(@github, [owner, name]) do
    if Regex.match?(@owner_re, owner) and Profile.valid_name?(name),
      do: {:ok, @github, [owner], name},
      else: {:error, :bad_name}
  end

  defp parse_ns(@github, _), do: {:error, :bad_name}

  defp parse_ns(host, [_ | _] = segments) when length(segments) >= 2 do
    {ns, [name]} = Enum.split(segments, -1)

    if Enum.all?(ns, &good_segment?/1) and Profile.valid_name?(name),
      do: {:ok, host, ns, name},
      else: {:error, :bad_name}
  end

  defp parse_ns(_host, _), do: {:error, :bad_name}

  defp good_segment?(s), do: s not in [".", ".."] and Regex.match?(@segment_re, s)

  defp parse_version(nil), do: {:ok, nil}

  defp parse_version(v) do
    cond do
      # A commit is a ref even when its 40 hex digits are all decimal.
      Regex.match?(@sha_re, v) ->
        {:ok, {:ref, v}}

      Regex.match?(@prefix_re, v) ->
        {:ok, {:prefix, v |> String.split(".") |> Enum.map(&String.to_integer/1)}}

      Regex.match?(@ref_re, v) and Enum.all?(String.split(v, "/"), &(&1 not in ["", ".", ".."])) ->
        {:ok, {:ref, v}}

      true ->
        {:error, :bad_name}
    end
  end

  @doc "The namespace as written in a pick: its segments joined by `/`."
  def ns(%__MODULE__{ns: ns}), do: Enum.join(ns, "/")

  @doc """
  What makes two name picks the same profile, ignoring the version:
  `@HOST/NS/NAME`, lowercased. It never equals an address's identity.
  """
  def identity(%__MODULE__{} = p), do: String.downcase("@#{p.host}/#{ns(p)}/#{p.name}")

  @doc "The pick without its version, as a person writes it: `@NS/NAME` on GitHub."
  def base(%__MODULE__{host: @github} = p), do: "@#{ns(p)}/#{p.name}"
  def base(%__MODULE__{} = p), do: "@#{p.host}/#{ns(p)}/#{p.name}"

  @doc "True when `version` (`\"1.2.3\"`) matches the pick's prefix."
  def matches?(%__MODULE__{version: {:prefix, prefix}}, version) when is_binary(version) do
    case semver(version) do
      {:ok, parts} -> Enum.take(parts, length(prefix)) == prefix
      :error -> false
    end
  end

  def matches?(_, _), do: false

  @doc """
  Parses `MAJOR.MINOR.PATCH` (no pre-release, no leading zeros, as semver writes it) into a
  list of three integers.
  """
  def semver(v) when is_binary(v) do
    case Regex.run(~r/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/, v) do
      [_ | parts] -> {:ok, Enum.map(parts, &String.to_integer/1)}
      _ -> :error
    end
  end

  def semver(_), do: :error
end
