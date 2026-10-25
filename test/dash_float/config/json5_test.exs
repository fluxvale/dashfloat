defmodule DashFloat.Config.JSON5Test do
  @moduledoc false
  # The octofriend-dialect constructs the config files rely on (ADR 0008),
  # plus the wrapper's guarantees: number normalization and error text that
  # never contains input content.
  use ExUnit.Case, async: true

  alias DashFloat.Config.JSON5

  test "decodes unquoted keys, single quotes, and trailing commas" do
    assert JSON5.decode("{ name: 'work', baseUrl: 'https://file.example/v1', }") ==
             {:ok, %{"name" => "work", "baseUrl" => "https://file.example/v1"}}
  end

  test "decodes line and block comments anywhere in the structure" do
    input = """
    {
      // a leading comment
      configVersion: 2, // a trailing comment
      models: [
        { nickname: 'a', /* block */ model: 'm', },
      ],
    }
    """

    assert {:ok, %{"configVersion" => 2, "models" => [%{"nickname" => "a", "model" => "m"}]}} =
             JSON5.decode(input)
  end

  test "decodes the compact single-line map shape (keys.json5 style)" do
    input = "{'work':'PLACEHOLDER-1','personal':'PLACEHOLDER-2'}"

    assert JSON5.decode(input) ==
             {:ok, %{"work" => "PLACEHOLDER-1", "personal" => "PLACEHOLDER-2"}}
  end

  test "numbers normalize to integers and floats, not Decimal" do
    assert JSON5.decode("{ context: 524288, ratio: 1.5, hex: 0x10 }") ==
             {:ok, %{"context" => 524_288, "ratio" => 1.5, "hex" => 16}}
  end

  test "escape sequences pass through verbatim (backend gap, documented in ADR 0008)" do
    # The Combine backend does not translate \n or \u escapes. Harmless here:
    # every value in the schema (URLs, ids, nicknames, keys) is plain, and a
    # literal backslash in a value round-trips as-is.
    assert JSON5.decode(~s({ nl: 'a\\nb', u: '\\u0041' })) ==
             {:ok, %{"nl" => "a\\nb", "u" => "\\u0041"}}
  end

  test "duplicate keys keep the last value, like Jason" do
    assert JSON5.decode("{ a: 1, a: 2 }") == {:ok, %{"a" => 2}}
  end

  test "nested maps and lists, including empty ones" do
    assert JSON5.decode("{ a: { b: [ {}, [], ], }, }") == {:ok, %{"a" => %{"b" => [%{}, []]}}}
  end

  test "garbage and empty input fail without echoing content" do
    for input <- ["{ a: ", "", "   \n\t  ", "{ a: NaN, }"] do
      assert {:error, "invalid JSON5"} = JSON5.decode(input)
    end
  end

  test "unrepresentable number literals are errors, not crashes (hostile-review P1)" do
    # decimal raises Decimal.Error (whose message quotes the literal) for
    # exponents it cannot represent — the wrapper must degrade that to the
    # fixed error string so the literal never reaches a log and startup
    # survives a hand-edited typo.
    for input <- ["{ context: 1e10000 }", "{ context: 1e-10000 }", "{ context: 1.5e-400 }"] do
      assert {:error, "invalid JSON5"} = JSON5.decode(input)
    end
  end

  test "values with one quote kind parse fine raw (the other style delimits)" do
    assert JSON5.decode(~s({ a: "k'x", b: 'y"z' })) == {:ok, %{"a" => "k'x", "b" => "y\"z"}}
  end

  ## Rendering (the general renderer both migrations rewrite through)

  test "read_map decodes an object file; missing is empty; errors name the path" do
    dir = Path.join("/tmp/opencode", "json5-read-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    file = Path.join(dir, "keys.json5")
    File.write!(file, "{'work':'PLACEHOLDER-1',}")

    assert JSON5.read_map(file) == {:ok, %{"work" => "PLACEHOLDER-1"}}

    missing_path = Path.join(dir, "absent.json5")
    assert JSON5.read_map(missing_path) == {:ok, %{}}

    File.write!(file, "{ broken")
    assert JSON5.read_map(file) == {:error, "invalid JSON5 in #{file}"}

    File.write!(file, "[1]")
    assert JSON5.read_map(file) == {:error, "invalid JSON5 in #{file}: expected an object"}
  end

  test "render pretty-prints sorted keys, bare identifier keys, and trailing commas" do
    assert {:ok, "{}"} = JSON5.render(%{})

    assert {:ok, text} =
             JSON5.render(%{
               "b" => [],
               "a" => %{},
               "configVersion" => 2,
               "x" => nil,
               "o" => false
             })

    assert text == "{\n  a: {},\n  b: [],\n  configVersion: 2,\n  o: false,\n  x: null,\n}"
  end

  test "render round-trips a decoded profile-shaped document" do
    original = %{
      "configVersion" => 2,
      "yourName" => "terry-placeholder",
      "profiles" => [
        %{
          "name" => "work",
          "baseUrl" => "https://provider.example/v1",
          "settings" => %{"defaultModel" => "Flash"},
          "models" => [
            %{"nickname" => "Sol", "model" => "glm-5.3", "context" => 524_288, "type" => true},
            %{"nickname" => "Flash", "model" => "glm-5.3-flash", "ratio" => 1.5}
          ]
        }
      ]
    }

    assert {:ok, text} = JSON5.render(original)
    assert JSON5.decode(text) == {:ok, original}

    # Hand-editing is the primary workflow: the shape is familiar JSON5.
    assert text =~ "configVersion: 2,"
    assert text =~ "settings: {"
    assert text =~ "'glm-5.3',"
  end

  test "render double-quotes values holding a single quote" do
    assert {:ok, "{\n  k: \"it's\",\n}"} = JSON5.render(%{"k" => "it's"})
  end

  test "render quotes keys that are not bare identifiers" do
    assert {:ok, text} = JSON5.render(%{"my key" => 1, "9lives" => 2})
    assert text == "{\n  '9lives': 2,\n  'my key': 1,\n}"
    assert {:ok, %{"my key" => 1, "9lives" => 2}} = JSON5.decode(text)
  end

  test "render quotes the parser's reserved words — a bare default: key is unreadable" do
    # Verified against the dep: the Combine backend rejects bare ECMA
    # reserved words as keys, and the legacy migration writes "default" as a
    # keys.json5 key. Quoting is always legal.
    assert JSON5.decode("{ default: 1 }") == {:error, "invalid JSON5"}

    assert {:ok, text} = JSON5.render(%{"default" => "PLACEHOLDER-legacy-key"})
    assert text == "{\n  'default': 'PLACEHOLDER-legacy-key',\n}"
    assert {:ok, %{"default" => "PLACEHOLDER-legacy-key"}} = JSON5.decode(text)
  end

  test "render fails naming the value's path, never its content" do
    assert {:error, "yourName"} = JSON5.render(%{"yourName" => "back\\slash"})

    assert {:error, "profiles[0].apiKey"} =
             JSON5.render(%{"profiles" => [%{"apiKey" => "both'kinds\""}]})

    assert {:error, ~s(["bad\\key"])} = JSON5.render(%{"bad\\key" => 1})

    assert {:error, "profiles[1].models[0].modalities[0]"} =
             JSON5.render(%{
               "profiles" => [
                 %{"name" => "a"},
                 %{"models" => [%{"modalities" => ["no'pe\"yes"]}]}
               ]
             })
  end
end
