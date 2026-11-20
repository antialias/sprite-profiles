defmodule SpriteProfiles.OutputLinesTest do
  use ExUnit.Case, async: true

  alias SpriteProfiles.OutputLines

  test "a partial line waits for its newline, and the last one for the end" do
    assert {[], "Open htt"} = OutputLines.split("", "Open htt")
    assert {["Open https://x"], "enter "} = OutputLines.split("Open htt", "ps://x\nenter ")
    assert {["enter CODE", ""], ""} = OutputLines.split("enter ", "CODE\n\n")
    assert OutputLines.flush("") == []
    assert OutputLines.flush("no newline") == ["no newline"]
  end

  test "lines lose control sequences, carriage returns and other control characters" do
    assert OutputLines.clean("\e[1;32mok\e[0m done\r") == "ok done"
    assert OutputLines.clean("\e[2J\e[Hclear\e[?25l") == "clear"
    assert OutputLines.clean("\e]0;title\atext \e]8;;http://x\e\\link\e]8;;\e\\") == "text link"
    assert OutputLines.clean("10%\r20%\r") == "10%20%"
    assert OutputLines.clean("bell\a back\b \u009b31m") == "bell back 31m"
    assert OutputLines.clean("tab\tkept, ünïcode kept") == "tab\tkept, ünïcode kept"
    assert OutputLines.clean(<<"bad ", 0xFF, " byte">>) == "bad � byte"
  end
end
