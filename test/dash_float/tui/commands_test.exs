defmodule DashFloat.TUI.CommandsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.TUI.Commands

  describe "all/0" do
    test "the seven registry commands, each described, none aliased" do
      commands = Commands.all()

      assert Enum.map(commands, & &1.name) == ~w(clear help mode model profile quit title)
      assert Enum.all?(commands, &(&1.description != "" and &1.aliases == []))
    end
  end

  describe "parse/1" do
    test "delegates to the widget" do
      assert Commands.parse("/he") == {:command, "he"}
      assert Commands.parse("/") == {:command, ""}
      assert Commands.parse("hello") == :no_command
    end
  end

  describe "match/1" do
    test "case-insensitive prefix over name; empty prefix matches all" do
      assert [%{name: "help"}] = Commands.match("he")
      assert [%{name: "clear"}] = Commands.match("CLEAR")
      assert length(Commands.match("")) == length(Commands.all())
      assert [] = Commands.match("zz")
    end
  end

  describe "split_command/1" do
    test "an exact bare name with empty rest" do
      assert Commands.split_command("/clear") == {"clear", ""}
    end

    test "name plus args: the rest is the trimmed remainder" do
      assert Commands.split_command("/mode plan") == {"mode", "plan"}
      assert Commands.split_command("/title  fix the login ") == {"title", "fix the login"}
    end

    test "argless commands still split their ignored rest" do
      assert Commands.split_command("/clear oops") == {"clear", "oops"}
    end

    test "leading whitespace trims away" do
      assert Commands.split_command("  /help") == {"help", ""}
    end

    test "an unknown first token is not a command" do
      assert Commands.split_command("/nope") == nil
      assert Commands.split_command("/etc/hosts is weird") == nil
    end

    test "a prefix of a name is not the name" do
      assert Commands.split_command("/clea") == nil
      assert Commands.split_command("/modes") == nil
    end

    test "plain text is never a command" do
      assert Commands.split_command("hello /clear") == nil
      assert Commands.split_command("") == nil
    end
  end
end
