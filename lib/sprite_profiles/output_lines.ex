defmodule SpriteProfiles.OutputLines do
  @moduledoc """
  Turns a command's output, arriving in chunks, into clean lines to show a person while it
  runs: a partial line waits for its newline (or the end), and each line loses its ANSI
  control sequences, carriage returns and other control characters, so a Sprite cannot
  move the cursor, recolour or clear the terminal it is shown in. Pure.
  """

  @doc """
  Adds `chunk` to the partial line in `buffer`. Returns `{lines, rest}`: the complete lines,
  cleaned, and what is left waiting for its newline.
  """
  @spec split(binary(), binary()) :: {[String.t()], binary()}
  def split(buffer, chunk) do
    {complete, [rest]} = (buffer <> chunk) |> String.split("\n") |> Enum.split(-1)
    {Enum.map(complete, &clean/1), rest}
  end

  @doc "The last partial line, cleaned, once the output has ended; `[]` when there is none."
  @spec flush(binary()) :: [String.t()]
  def flush(""), do: []
  def flush(buffer), do: [clean(buffer)]

  @doc "One line without control sequences, carriage returns or trailing whitespace."
  @spec clean(binary()) :: String.t()
  def clean(line) do
    line = String.replace_invalid(line)

    [
      # CSI (colours, cursor moves, clearing), OSC (titles, links), the other ESC sequences
      ~r/\e\[[0-?]*[ -\/]*[@-~]/,
      ~r/\e\][^\a\e]*(?:\a|\e\\)?/,
      ~r/\e[ -\/]*[0-~]?/,
      # C0 controls but tab, DEL, and the C1 controls (U+0080..U+009F) a terminal may obey
      ~r/[\x{00}-\x{08}\x{0b}-\x{1f}\x{7f}-\x{9f}]/u
    ]
    |> Enum.reduce(line, &Regex.replace(&1, &2, ""))
    |> String.trim_trailing()
  end
end
