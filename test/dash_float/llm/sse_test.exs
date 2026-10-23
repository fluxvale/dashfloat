defmodule DashFloat.LLM.SSETest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.LLM.SSE

  @fixture_dir Path.expand("../../fixtures/sse", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixture_dir, name))

  defp parse(chunks) do
    {frames, parser} = Enum.reduce(chunks, {[], SSE.new()}, &feed/2)
    {Enum.reverse(frames), parser}
  end

  defp feed(chunk, {acc, parser}) do
    {frames, parser} = SSE.feed(parser, chunk)
    {Enum.reverse(frames) ++ acc, parser}
  end

  defp data(frames), do: Enum.map(frames, & &1.data)

  test "happy.txt fed whole yields every data frame, comments dropped" do
    {frames, parser} = parse([fixture("happy.txt")])

    assert length(frames) == 7
    assert hd(frames).data =~ ~s("role":"assistant")
    assert List.last(frames).data == "[DONE]"
    refute Enum.any?(frames, &(&1.data =~ "keepalive"))
    assert parser.buffer == ""
  end

  test "happy.txt fed byte-by-byte yields the same frames" do
    whole = fixture("happy.txt")
    {frames, parser} = whole |> :binary.bin_to_list() |> Enum.map(&<<&1>>) |> parse()

    assert data(frames) == data(elem(parse([whole]), 0))
    assert parser.buffer == ""
  end

  test "CRLF line endings parse identically to LF" do
    {crlf, parser} = parse([fixture("happy_crlf.txt")])
    {lf, _} = parse([fixture("happy.txt")])

    assert data(crlf) == data(lf)
    assert parser.buffer == ""
  end

  test "frames split mid-field and mid-JSON complete across chunks" do
    {frames, _} = parse(["data: {\"a\":", "1}\n", "\n"])

    assert data(frames) == [~s({"a":1})]
  end

  test "a CRLF split across chunks still delimits the frame" do
    {frames, _} =
      parse([
        "data: one\n\r",
        "\ndata: two\r\n\r\n"
      ])

    assert data(frames) == ["one", "two"]
  end

  test "a CRLF split after multi-byte content still delimits the frame" do
    {frames, parser} = parse(["data: héllo\r", "\n\r\n"])

    assert data(frames) == ["héllo"]
    assert parser.buffer == ""
  end

  test "invalid UTF-8 bytes survive the parser without raising" do
    {frames, _} = parse(["data: ", <<0xFF, 0xFE>>, "\n\n"])

    assert [%{data: <<0xFF, 0xFE>>}] = frames
  end

  test "multiple data lines in one frame join with a newline" do
    {frames, _} = parse(["data: first\ndata: second\n\n"])

    assert data(frames) == ["first\nsecond"]
  end

  test "event, id, retry, and unknown fields are dropped" do
    {frames, _} =
      parse(["event: message\nid: 7\nretry: 100\nfoo: bar\ndata: kept\n\n"])

    assert data(frames) == ["kept"]
  end

  test "a frame with no data line emits nothing" do
    {frames, parser} = parse([": comment only\n\nevent: ping\n\n"])

    assert frames == []
    assert parser.buffer == ""
  end

  test "an incomplete trailing frame stays buffered until completed" do
    {frames, parser} = parse(["data: partial"])
    assert frames == []
    assert parser.buffer == "data: partial"

    {frames, parser} = SSE.feed(parser, "\n\n")
    assert data(frames) == ["partial"]
    assert parser.buffer == ""
  end

  test "data without a leading space keeps its value intact" do
    {frames, _} = parse(["data:no-space\n\n"])

    assert data(frames) == ["no-space"]
  end
end
