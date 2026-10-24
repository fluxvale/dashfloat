defmodule DashFloat.ToolsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.Tools

  describe "schema/0" do
    test "returns the five tools in the exact OpenAI shape" do
      assert Tools.schema() == [
               %{
                 "type" => "function",
                 "function" => %{
                   "name" => "read_file",
                   "description" =>
                     "Read a window of lines from a text file. Lines are 1-based; without offset or limit the first 2000 lines are returned. Output is byte-capped, so very long files come back truncated — re-read with offset/limit for the rest.",
                   "parameters" => %{
                     "type" => "object",
                     "properties" => %{
                       "path" => %{
                         "type" => "string",
                         "description" =>
                           "File path, relative to the working directory or absolute inside it.",
                         "minLength" => 1
                       },
                       "offset" => %{
                         "type" => "integer",
                         "description" => "First line to return, counting from 1.",
                         "minimum" => 1,
                         "default" => 1
                       },
                       "limit" => %{
                         "type" => "integer",
                         "description" => "Maximum number of lines to return.",
                         "minimum" => 1,
                         "maximum" => 10_000,
                         "default" => 2_000
                       }
                     },
                     "required" => ["path"]
                   }
                 }
               },
               %{
                 "type" => "function",
                 "function" => %{
                   "name" => "write_file",
                   "description" =>
                     "Create or overwrite a file with the given full content. Parent directories are created automatically. The user confirms before it runs.",
                   "parameters" => %{
                     "type" => "object",
                     "properties" => %{
                       "path" => %{
                         "type" => "string",
                         "description" => "File path to write. Parent directories are created.",
                         "minLength" => 1
                       },
                       "content" => %{
                         "type" => "string",
                         "description" => "Full new content of the file."
                       }
                     },
                     "required" => ["path", "content"]
                   }
                 }
               },
               %{
                 "type" => "function",
                 "function" => %{
                   "name" => "edit_file",
                   "description" =>
                     "Replace an exact block of text in a file. search_block must match the file exactly once — include surrounding lines to make it unique. The user confirms before it runs.",
                   "parameters" => %{
                     "type" => "object",
                     "properties" => %{
                       "path" => %{
                         "type" => "string",
                         "description" => "File path to edit.",
                         "minLength" => 1
                       },
                       "search_block" => %{
                         "type" => "string",
                         "description" =>
                           "Exact text to replace. Must match the file exactly once."
                       },
                       "replace_block" => %{
                         "type" => "string",
                         "description" => "Replacement text for the matched block."
                       }
                     },
                     "required" => ["path", "search_block", "replace_block"]
                   }
                 }
               },
               %{
                 "type" => "function",
                 "function" => %{
                   "name" => "execute_command",
                   "description" =>
                     "Run a shell command line and return its combined output (stdout and stderr, capped). Prefer it for builds, tests, and searches. The user confirms before it runs.",
                   "parameters" => %{
                     "type" => "object",
                     "properties" => %{
                       "command" => %{
                         "type" => "string",
                         "description" => "Shell command line to run.",
                         "minLength" => 1
                       },
                       "cwd" => %{
                         "type" => "string",
                         "description" =>
                           "Directory to run the command in, relative to the working directory.",
                         "default" => ".",
                         "minLength" => 1
                       }
                     },
                     "required" => ["command"]
                   }
                 }
               },
               %{
                 "type" => "function",
                 "function" => %{
                   "name" => "list_directory",
                   "description" =>
                     "List a directory's entries: directories first, then files, each alphabetical.",
                   "parameters" => %{
                     "type" => "object",
                     "properties" => %{
                       "path" => %{
                         "type" => "string",
                         "description" => "Directory to list, relative to the working directory.",
                         "default" => ".",
                         "minLength" => 1
                       }
                     },
                     "required" => []
                   }
                 }
               }
             ]
    end

    test "the schema is JSON-encodable exactly as advertised" do
      assert {:ok, _encoded} = Jason.encode(Tools.schema())
    end
  end

  describe "validate/2" do
    test "read_file fills offset and limit defaults" do
      assert Tools.validate("read_file", %{"path" => "lib/a.ex"}) ==
               {:ok, %{"path" => "lib/a.ex", "offset" => 1, "limit" => 2_000}}
    end

    test "read_file keeps explicit valid values" do
      assert Tools.validate("read_file", %{"path" => "a", "offset" => 10, "limit" => 50}) ==
               {:ok, %{"path" => "a", "offset" => 10, "limit" => 50}}
    end

    test "execute_command defaults cwd to ." do
      assert Tools.validate("execute_command", %{"command" => "mix test"}) ==
               {:ok, %{"command" => "mix test", "cwd" => "."}}
    end

    test "list_directory defaults path to ." do
      assert Tools.validate("list_directory", %{}) == {:ok, %{"path" => "."}}
    end

    test "write_file and edit_file return their required strings" do
      assert Tools.validate("write_file", %{"path" => "a", "content" => "b"}) ==
               {:ok, %{"path" => "a", "content" => "b"}}

      assert Tools.validate("edit_file", %{
               "path" => "a",
               "search_block" => "b",
               "replace_block" => "c"
             }) ==
               {:ok, %{"path" => "a", "search_block" => "b", "replace_block" => "c"}}
    end

    test "unknown tool names are rejected, whatever their type" do
      assert Tools.validate("foo", %{}) == {:error, ~s(unknown tool "foo")}
      assert Tools.validate(:read_file, %{}) == {:error, "unknown tool :read_file"}
      assert Tools.validate(42, %{}) == {:error, "unknown tool 42"}
    end

    test "missing required arguments name the tool and the argument" do
      assert Tools.validate("read_file", %{}) ==
               {:error, ~s(read_file: missing required argument "path")}

      assert Tools.validate("write_file", %{"path" => "a"}) ==
               {:error, ~s(write_file: missing required argument "content")}

      assert Tools.validate("execute_command", %{}) ==
               {:error, ~s(execute_command: missing required argument "command")}

      assert Tools.validate("edit_file", %{"path" => "a"}) ==
               {:error, ~s(edit_file: missing required argument "search_block")}
    end

    test "string parameters must be strings" do
      assert Tools.validate("read_file", %{"path" => 3}) ==
               {:error, "read_file: path must be a string"}

      assert Tools.validate("write_file", %{"path" => "a", "content" => nil}) ==
               {:error, "write_file: content must be a string"}
    end

    test "ranged integers must land inside the range" do
      assert Tools.validate("read_file", %{"path" => "a", "limit" => 0}) ==
               {:error, "read_file: limit must be an integer between 1 and 10000"}

      assert Tools.validate("read_file", %{"path" => "a", "limit" => 10_001}) ==
               {:error, "read_file: limit must be an integer between 1 and 10000"}

      assert Tools.validate("read_file", %{"path" => "a", "limit" => "lots"}) ==
               {:error, "read_file: limit must be an integer between 1 and 10000"}
    end

    test "minimum-only integers must respect the minimum" do
      assert Tools.validate("read_file", %{"path" => "a", "offset" => 0}) ==
               {:error, "read_file: offset must be an integer of at least 1"}

      assert Tools.validate("read_file", %{"path" => "a", "offset" => 1.5}) ==
               {:error, "read_file: offset must be an integer of at least 1"}
    end

    test "non-object arguments never raise" do
      assert Tools.validate("read_file", nil) ==
               {:error, "read_file: arguments must be an object"}

      assert Tools.validate("read_file", "path") ==
               {:error, "read_file: arguments must be an object"}
    end

    test "paths and commands must not be empty strings" do
      assert Tools.validate("read_file", %{"path" => ""}) ==
               {:error, "read_file: path must not be empty"}

      assert Tools.validate("execute_command", %{"command" => ""}) ==
               {:error, "execute_command: command must not be empty"}

      # content may legitimately be empty (truncate a file); replace may delete.
      assert Tools.validate("write_file", %{"path" => "a", "content" => ""}) ==
               {:ok, %{"path" => "a", "content" => ""}}
    end

    test "unknown argument keys are dropped from the result" do
      assert Tools.validate("list_directory", %{"path" => "src", "recursive" => true}) ==
               {:ok, %{"path" => "src"}}
    end

    test "file write targets with a trailing slash are refused" do
      # The OS would strip the slash and create a FILE named "newdir" — the
      # result must not report ok for a path that names a directory.
      for tool <- ["write_file", "edit_file"] do
        assert Tools.validate(tool, %{
                 "path" => "newdir/",
                 "content" => "x",
                 "search_block" => "a",
                 "replace_block" => "b"
               }) == {:error, "#{tool}: path must name a file, not end in \"/\""}
      end
    end
  end
end
