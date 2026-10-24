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
end
