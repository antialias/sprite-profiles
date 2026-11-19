defmodule SpriteProfiles.Out do
  @moduledoc """
  Where a command writes, so one implementation serves the `sprite-profiles` binary and
  the Mix tasks: `info` (a line of results), `error` (a line of trouble) and `usage` (a
  bad-usage message: the caller prints its own usage text with it).

  `io/1` writes to stdout and stderr with `IO`, as the binary does; a Mix task passes
  functions that write through `Mix.shell()`. Nothing here refers to Mix, so the binary can
  load it.
  """

  @enforce_keys [:info, :error, :usage]
  defstruct [:info, :error, :usage]

  @type t :: %__MODULE__{
          info: (String.t() -> any()),
          error: (String.t() -> any()),
          usage: (String.t() -> any())
        }

  @doc "Lines to stdout, trouble to stderr; `usage` prints `usage_text` and the message."
  def io(usage_text \\ "") do
    %__MODULE__{
      info: &IO.puts/1,
      error: &IO.puts(:stderr, &1),
      usage: fn message ->
        IO.write(:stderr, usage_text)
        if message != "", do: IO.puts(:stderr, "\n" <> message)
      end
    }
  end

  @doc "Writes a line of results."
  def info(%__MODULE__{info: f}, line), do: f.(line)

  @doc "Writes a line of trouble."
  def error(%__MODULE__{error: f}, line), do: f.(line)

  @doc "Reports bad usage and returns 2, the exit status for it."
  def usage(%__MODULE__{usage: f}, message) do
    f.(message)
    2
  end

  @doc "Prints `Refused:` and each problem's code and sentence; returns 1."
  def refused(%__MODULE__{} = out, problems) do
    error(out, "Refused:")
    Enum.each(problems, &error(out, "  [#{&1.code}] #{&1.message}"))
    1
  end

  @doc "Shown as `~/...`, so a pasted or recorded run does not carry the local user name."
  def home_relative(nil), do: nil

  def home_relative(path) do
    home = Path.expand("~")

    case Path.relative_to(path, home) do
      ^path -> path
      rel -> Path.join("~", rel)
    end
  end
end
