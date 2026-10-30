defmodule DashFloat.ToolsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.Synthetic
  alias DashFloat.Tools

  describe "schema/1" do
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
                     "Create or overwrite a file with the given full content. Parent directories are created automatically. The user may confirm before it runs, depending on the session mode.",
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
                     "Replace an exact block of text in a file. search_block must match the file exactly once — include surrounding lines to make it unique. The user may confirm before it runs, depending on the session mode.",
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
                     "Run a shell command line and return its combined output (stdout and stderr, capped). Prefer it for builds, tests, and searches. The user may confirm before it runs, depending on the session mode.",
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

    test "an explicit nil context is the same five-tool list" do
      assert Tools.schema(nil) == Tools.schema()
    end

    test "a synthetic context advertises web_search last, with its required query" do
      ctx = %Synthetic{base_url: "https://api.synthetic.new/v1", api_key: "sk"}

      names =
        ctx
        |> Tools.schema()
        |> Enum.map(& &1["function"]["name"])

      assert names == [
               "read_file",
               "write_file",
               "edit_file",
               "execute_command",
               "list_directory",
               "web_search"
             ]

      search = %{
        "type" => "function",
        "function" => %{
          "name" => "web_search",
          "description" =>
            "Search the web. Use this to find information you are not sure about, to look up documentation, or to find data created after your training knowledge cutoff. Returns a list of results with url, title, and highlights.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "query" => %{
                "type" => "string",
                "description" => "The search query.",
                "minLength" => 1
              }
            },
            "required" => ["query"]
          }
        }
      }

      advertised = Tools.schema(ctx)
      assert List.last(advertised) == search
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

    test "web_search validates its query — total over the table, key or no key" do
      assert Tools.validate("web_search", %{"query" => "x"}) == {:ok, %{"query" => "x"}}

      assert Tools.validate("web_search", %{}) ==
               {:error, ~s(web_search: missing required argument "query")}

      assert Tools.validate("web_search", %{"query" => ""}) ==
               {:error, "web_search: query must not be empty"}

      assert Tools.validate("web_search", %{"query" => 3}) ==
               {:error, "web_search: query must be a string"}
    end
  end

  describe "class/1" do
    test "declares the risk class per ADR 0016 §2" do
      assert Tools.class("read_file") == :safe
      assert Tools.class("list_directory") == :safe
      assert Tools.class("write_file") == :mutating
      assert Tools.class("edit_file") == :mutating
      assert Tools.class("execute_command") == :risky
      assert Tools.class("web_search") == :safe
    end

    test "unknown names fail closed to :risky" do
      assert Tools.class("rm_rf") == :risky
    end
  end

  describe "cancelled_result/0" do
    test "is the cancelled result the agent writes and the loader synthesizes" do
      assert Tools.cancelled_result() == %{ok: false, cancelled: true}
      assert Jason.encode!(Tools.cancelled_result()) == ~s({"ok":false,"cancelled":true})
    end
  end

  describe "display_status/1" do
    test "derives the row status from the result shape" do
      assert Tools.display_status(%{rejected: true}) == "rejected"
      assert Tools.display_status(%{cancelled: true}) == "cancelled"
      assert Tools.display_status(%{ok: true}) == "ok"
      assert Tools.display_status(%{ok: false, error: "boom"}) == "error: boom"
    end

    test "caps the error message at 160 characters" do
      assert Tools.display_status(%{error: String.duplicate("x", 200)}) ==
               "error: " <> String.duplicate("x", 160)
    end

    test "anything else is a plain error" do
      assert Tools.display_status(%{}) == "error"
      assert Tools.display_status(%{ok: false}) == "error"
    end
  end

  describe "display_excerpt/1" do
    test "passes a body of at most 30 lines through whole" do
      assert Tools.display_excerpt(%{output: "a\nb"}) == "a\nb"
      assert Tools.display_excerpt(%{content: "one line"}) == "one line"

      body = Enum.map_join(1..30, "\n", &to_string/1)
      assert Tools.display_excerpt(%{output: body}) == body
    end

    test "caps longer bodies at 30 lines" do
      body = Enum.map_join(1..31, "\n", &to_string/1)

      assert Tools.display_excerpt(%{output: body}) == Enum.map_join(1..30, "\n", &to_string/1)
    end

    test "output wins over content; neither means nil" do
      assert Tools.display_excerpt(%{output: "out", content: "in"}) == "out"
      assert Tools.display_excerpt(%{ok: true}) == nil
    end
  end
end
