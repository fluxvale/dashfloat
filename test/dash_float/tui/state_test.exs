defmodule DashFloat.TUI.StateTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.Config.Onboarding
  alias DashFloat.Tools
  alias DashFloat.TUI.Render
  alias DashFloat.TUI.State
  alias DashFloat.TUI.Theme
  alias DashFloat.TUI.View
  alias DashFloat.TUI.Wrap

  defp new_state(opts \\ []) do
    [test_mode: {80, 24}]
    |> Keyword.merge(opts)
    |> State.new()
  end

  # Adopts the agent's context snapshot (ADR 0015 §2 amendment): the
  # {messages, anchor} pair the footer's usage read computes from.
  defp context_state(state, messages, anchor),
    do: State.stream_message(state, {:context, %{messages: messages, anchor: anchor}}, 1_000)

  defp type(state, text) do
    points = String.codepoints(text)

    Enum.reduce(points, state, fn c, acc ->
      {acc, nil} = State.handle_key(acc, c, [])
      acc
    end)
  end

  # Sends the key asserting it produces no action; returns the new state.
  defp press(state, code, modifiers) do
    {state, nil} = State.handle_key(state, code, modifiers)
    state
  end

  # Submits text and returns the state with the phase forced back to idle
  # (mid-stream submits are refused by design).
  defp idle_submit(state, text) do
    {state, action} =
      state
      |> type(text)
      |> State.handle_key("enter", [])

    assert {:submit, ^text, []} = action
    Map.put(state, :phase, :idle)
  end

  # Entries as `{kind, text}` pairs — the shape assertions care about.
  defp pairs(state), do: Enum.map(state.entries, &{&1.kind, &1.text})

  defp provider(context_tokens) do
    {:ok,
     %DashFloat.Config{
       base_url: "http://x",
       model: "m",
       api_key: "k",
       context_tokens: context_tokens
     }}
  end

  describe "new/1" do
    test "initial state is idle with empty log and test-mode size" do
      state = new_state()
      assert state.phase == :idle
      assert state.entries == []
      assert state.in_flight == nil
      assert state.in_flight_lines == nil
      assert state.in_flight_dirty == false
      assert state.anim_step == 0
      assert state.tick_ref == nil
      assert state.history == []
      assert state.follow? == true
      assert state.size == {80, 24}
      assert state.live? == false
      assert state.agent_ref == nil
      assert state.confirm == nil
      assert State.input_text(state) == ""
    end

    test "stats start empty and no context snapshot exists yet" do
      state = new_state()

      assert state.stats == %{
               tokens: 0,
               first_token_at: nil,
               last_token_at: nil,
               sent_at: nil,
               ttft_ms: nil,
               rate: nil,
               prompt_tokens: nil,
               completion_tokens: nil
             }

      assert state.context == nil
    end

    test "mount opts carry the provider; the agent defaults to the name" do
      provider = {:ok, %DashFloat.Config{base_url: "http://x", model: "m", api_key: "k"}}
      assert new_state(provider: provider).provider == provider
      assert new_state().provider == nil
      assert new_state().agent == DashFloat.Agent
      assert new_state(agent: self()).agent == self()
    end
  end

  describe "cwd_label/1" do
    test "the last two path segments, tilde-prefixed" do
      label = State.cwd_label(new_state())
      assert label =~ ~r|\A~/[^/]+/[^/]+\z| or label =~ ~r|\A~/[^/]+\z|
      assert label == expected_cwd()
    end

    test "a two-segment path keeps both, a deeper one keeps the tail" do
      # format/1 is private; assert through the public label's shape only.
      label = State.cwd_label(new_state())
      assert String.starts_with?(label, "~/")
    end
  end

  defp expected_cwd do
    tail =
      File.cwd!()
      |> Path.split()
      |> Enum.reject(&(&1 == "/"))
      |> Enum.take(-2)

    "~/" <> Path.join(tail)
  end

  describe "provider_label/1" do
    # The footer label is "<provider> - <model>" (ADR 0015 §2's amendment,
    # issue #109); the profile suffix is gone from the footer entirely.
    test "a preset base_url names the preset — zai with a nickname, synthetic with one too" do
      zai =
        {:ok,
         %DashFloat.Config{
           base_url: "https://api.z.ai/api/coding/paas/v4",
           model: "glm-5.3",
           api_key: "k",
           nickname: "Sol",
           profile: "demo"
         }}

      synthetic =
        {:ok,
         %DashFloat.Config{
           base_url: "https://api.synthetic.new/openai/v1",
           model: "glm-4.7",
           api_key: "k",
           nickname: "Sol"
         }}

      zai_state = new_state(provider: zai)
      synthetic_state = new_state(provider: synthetic)
      assert State.provider_label(zai_state) == "zai - Sol"
      assert State.provider_label(synthetic_state) == "synthetic - Sol"
    end

    test "a preset match survives a trailing slash and beats a settings label" do
      slashed =
        {:ok,
         %DashFloat.Config{
           base_url: "https://api.z.ai/api/coding/paas/v4/",
           model: "glm-5.3",
           api_key: "k",
           nickname: "Sol",
           # The settings entry's host-defaulted label loses to the preset:
           # the presets are the first-class providers (ADR 0015 §2).
           providers: [
             %{
               label: "api.z.ai",
               base_url: "https://api.z.ai/api/coding/paas/v4",
               api_key: "k"
             }
           ]
         }}

      slashed_state = new_state(provider: slashed)
      assert State.provider_label(slashed_state) == "zai - Sol"
    end

    test "a custom provider shows the settings label, trailing slashes trimmed on both sides" do
      custom =
        {:ok,
         %DashFloat.Config{
           base_url: "http://localhost:8080/v1/",
           model: "llama",
           api_key: "k",
           nickname: "Sol",
           providers: [
             %{label: "homelab", base_url: "http://localhost:8080/v1", api_key: "k"}
           ]
         }}

      mirrored =
        {:ok,
         %DashFloat.Config{
           base_url: "http://localhost:8080/v1",
           model: "llama",
           api_key: "k",
           nickname: "Sol",
           providers: [
             %{label: "homelab", base_url: "http://localhost:8080/v1/", api_key: "k"}
           ]
         }}

      custom_state = new_state(provider: custom)
      mirrored_state = new_state(provider: mirrored)
      assert State.provider_label(custom_state) == "homelab - Sol"
      assert State.provider_label(mirrored_state) == "homelab - Sol"
    end

    test "an unlabeled custom provider (env-only boots: providers []) degrades to the URL host" do
      unlabeled =
        {:ok,
         %DashFloat.Config{base_url: "http://127.0.0.1:8080/v1", model: "llama", api_key: "k"}}

      host_only =
        {:ok,
         %DashFloat.Config{base_url: "not a url", model: "llama", api_key: "k", nickname: "Sol"}}

      unlabeled_state = new_state(provider: unlabeled)
      host_only_state = new_state(provider: host_only)
      assert State.provider_label(unlabeled_state) == "127.0.0.1 - llama"
      assert State.provider_label(host_only_state) == "not a url - Sol"
    end

    test "nil for an error provider, no provider, no base_url, or no model part" do
      error_state = new_state(provider: {:error, "nope"})
      blank_state = new_state()
      # No base_url — nothing to classify the provider from (the settings
      # scan still compares each entry against a nil url harmlessly).
      no_url =
        new_state(
          provider:
            {:ok,
             %DashFloat.Config{
               model: "glm-5.3",
               api_key: "k",
               providers: [%{label: "kept", base_url: "http://x", models: []}]
             }}
        )

      # A Config with neither nickname nor model (hand-made, e.g. an
      # env-only shape) has no label — the view's placeholder takes over.
      nameless = new_state(provider: {:ok, %DashFloat.Config{base_url: "http://x", api_key: "k"}})

      assert State.provider_label(error_state) == nil
      assert State.provider_label(blank_state) == nil
      assert State.provider_label(no_url) == nil
      assert State.provider_label(nameless) == nil
    end
  end

  describe "provider_context_tokens/1" do
    test "the configured window, nil when absent" do
      configured = new_state(provider: provider(128_000))
      assert State.provider_context_tokens(configured) == 128_000

      unconfigured = new_state()
      assert State.provider_context_tokens(unconfigured) == nil

      errored = new_state(provider: {:error, "no"})
      assert State.provider_context_tokens(errored) == nil
    end
  end

  describe "status labels" do
    test "no rate until one is derived" do
      assert State.rate_label(new_state()) == nil
    end

    test "no ttft until a turn's first token lands" do
      assert State.ttft_label(new_state()) == nil
    end

    test "the frozen rate renders with one decimal, trailing .0 trimmed" do
      # 10 tokens over the 1.01 s decode window (first → last token) —
      # frozen at finalize, never live on the tick (issue #130).
      base = Map.put(new_state(), :phase, :streaming)

      streamed =
        Enum.reduce(1..10, base, fn i, acc ->
          State.stream_message(acc, {:token, "t#{i}"}, 1_000 + div((i - 1) * 1_010, 9))
        end)

      state = State.stream_message(streamed, {:phase, :idle}, 3_000)

      assert_in_delta state.stats.rate, 9.9009, 0.001
      assert State.rate_label(state) == "9.9"
    end

    test "ttft renders in seconds, trailing .0 trimmed" do
      state = %{new_state() | stats: %{new_state().stats | ttft_ms: 1_400}}
      assert State.ttft_label(state) == "1.4"

      whole = %{new_state() | stats: %{new_state().stats | ttft_ms: 2_000}}
      assert State.ttft_label(whole) == "2"
    end

    test "no context before the first snapshot lands" do
      assert State.context_label(new_state()) == nil
    end

    test "tokens-used alone with no display window, over the window with one" do
      messages = [%{role: "user", content: String.duplicate("a", 16_400)}]

      no_window = context_state(new_state(), messages, nil)
      assert State.context_label(no_window) == "4.1k"

      windowed = context_state(new_state(provider: provider(128_000)), messages, nil)
      assert State.context_label(windowed) == "4.1k/128k · 3.2%"
    end

    test "a stock config's window resolves without a configured context (issue #111)" do
      messages = [%{role: "user", content: String.duplicate("a", 16_400)}]

      # Seeded (Z.AI GLM stock shape): the real 1M window, stated plain.
      seeded =
        {:ok,
         %DashFloat.Config{
           base_url: "https://api.z.ai/api/coding/paas/v4",
           model: "glm-5.3-flash",
           api_key: "k"
         }}

      state = context_state(new_state(provider: seeded), messages, nil)
      assert State.provider_context_tokens(state) == 1_048_576
      assert State.context_label(state) == "4.1k/1m · 0.4%"

      # A model absent from every source: the documented default, marked.
      assumed =
        {:ok,
         %DashFloat.Config{
           base_url: "https://api.z.ai/api/coding/paas/v4",
           model: "glm-4.5",
           api_key: "k"
         }}

      assumed_state = context_state(new_state(provider: assumed), messages, nil)
      assert State.provider_context_tokens(assumed_state) == 131_072
      assert State.context_label(assumed_state) == "4.1k/~131.1k · 3.1%"
    end

    test "observed catalog metadata beats the seed, never an explicit config (issue #111)" do
      messages = [%{role: "user", content: String.duplicate("a", 16_400)}]
      base = "https://api.synthetic.new/openai/v1"

      seeded =
        {:ok, %DashFloat.Config{base_url: base, model: "syn:small:text", api_key: "k"}}

      # Before the sweep lands: the seed's 196_608.
      state = context_state(new_state(provider: seeded), messages, nil)
      assert State.provider_context_tokens(state) == 196_608

      # The sweep lands with a fresher truth: observed wins, unmarked.
      landed =
        State.catalog_arrived(state, %{base => [%{model: "syn:small:text", context: 262_144}]})

      assert State.provider_context_tokens(landed) == 262_144
      assert State.context_label(landed) == "4.1k/262.1k · 1.6%"

      # An explicit context always beats the catalog.
      explicit =
        {:ok,
         %DashFloat.Config{
           base_url: base,
           model: "syn:small:text",
           api_key: "k",
           context_tokens: 64_000
         }}

      explicit_state = context_state(new_state(provider: explicit), messages, nil)

      configured =
        State.catalog_arrived(explicit_state, %{
          base => [%{model: "syn:small:text", context: 262_144}]
        })

      assert State.provider_context_tokens(configured) == 64_000
    end

    test "an anchored snapshot reads the measurement, not the heuristic" do
      messages = [
        %{role: "user", content: String.duplicate("a", 400)},
        %{role: "assistant", content: String.duplicate("b", 400)}
      ]

      # The anchor measured the whole list at 4_100; the estimate is exactly
      # that (ADR 0022 §1).
      state =
        context_state(new_state(provider: provider(128_000)), messages, %{tokens: 4_100, index: 2})

      assert State.context_label(state) == "4.1k/128k · 3.2%"
    end

    test "percent reads one decimal, trailing .0 trimmed" do
      # 6_400 / 128_000 = 5.0% — trimmed; 65_000 / 128_000 = 50.8%.
      one =
        context_state(
          new_state(provider: provider(128_000)),
          [%{role: "user", content: String.duplicate("a", 25_600)}],
          %{tokens: 6_400, index: 1}
        )

      assert State.context_label(one) =~ "5%"

      two =
        context_state(new_state(provider: provider(128_000)), [%{role: "user", content: "x"}], %{
          tokens: 65_000,
          index: 1
        })

      assert State.context_label(two) =~ "50.8%"
    end

    test "totals in the millions read as m, in the billions b" do
      state =
        context_state(new_state(), [%{role: "user", content: "x"}], %{
          tokens: 4_100_000,
          index: 1
        })

      assert State.context_label(state) == "4.1m"

      big =
        context_state(new_state(), [%{role: "user", content: "x"}], %{
          tokens: 2_500_000_000,
          index: 1
        })

      assert State.context_label(big) == "2.5b"
    end

    test "humanize boundaries roll into the next unit" do
      # 999_999 rounds up and reads "1m", never "1000k".
      state =
        context_state(new_state(), [%{role: "user", content: "x"}], %{tokens: 999_999, index: 1})

      assert State.context_label(state) == "1m"

      small =
        context_state(new_state(), [%{role: "user", content: "x"}], %{tokens: 999, index: 1})

      assert State.context_label(small) == "999"
    end

    test "a later snapshot wins — the count grows across turns" do
      one = [%{role: "user", content: String.duplicate("a", 400)}]
      two = one ++ [%{role: "assistant", content: String.duplicate("b", 8_000)}]

      state =
        new_state()
        |> context_state(one, nil)
        |> context_state(two, nil)

      assert State.context_label(state) == "2.1k"
    end
  end

  describe "handle_key/3 — quit" do
    test "Ctrl+Q quits immediately; Ctrl+C needs a second press (issue #28)" do
      assert {_state, :quit} = State.handle_key(new_state(), "q", ["ctrl"])
      # One Ctrl+C only arms the guard — see the exit-guard describe block.
      {armed, nil} = State.handle_key(new_state(), "c", ["ctrl"], 1_000)
      assert armed.exit_guard_at == 1_000
    end

    test "plain c and q type" do
      state = type(new_state(), "cq")
      assert State.input_text(state) == "cq"
    end
  end

  # Issue #28 (ADR 0006 amendment): selection over display rows — anchor,
  # extend, copy on release; content-anchored so it survives scroll and
  # append; cleared by width resize and a count-changing finalize.
  describe "mouse selection" do
    # Two entries => display rows: 0 blank, 1 "alpha line", 2 blank, 3 "beta line".
    defp selected_state do
      new_state()
      |> State.stream_message({:entry, :system, "alpha line"})
      |> State.stream_message({:entry, :system, "beta line"})
    end

    defp drag(state, {x0, y0}, {x1, y1}) do
      {down, _action} = State.select_mouse(state, "down", x0, y0)
      {dragged, _action} = State.select_mouse(down, "drag", x1, y1)
      State.select_mouse(dragged, "up", x1, y1)
    end

    test "down anchors, drag extends, up copies; click-to-clear" do
      state = selected_state()

      {anchored, nil} = State.select_mouse(state, "down", 1, 4)
      assert anchored.selection.anchor == {1, 0}
      # The gesture snapshots the entries' display-row count as its base —
      # the finalize boundary (review P1).
      assert anchored.selection.base_rows == 4
      assert anchored.selection.head == {1, 0}

      {extended, nil} = State.select_mouse(anchored, "drag", 7, 6)
      assert extended.selection.head == {3, 5}

      {released, {:copy, text}} = State.select_mouse(extended, "up", 7, 6)
      assert match?(%{head: _}, released.selection)
      # Last row slices through col 5's cell ("beta l" — the pointed cell
      # is included; review P2a).
      assert text == "alpha line\n\nbeta l"

      # Press+release without extension clears…
      {cleared, nil} = State.select_mouse(anchored, "up", 1, 4)
      assert cleared.selection == nil
      # …and an empty selection copies nothing (the nil clause's contract).
      assert State.selection_text(cleared) == ""
    end

    test "an empty log selects nothing" do
      {state, action} = State.select_mouse(new_state(), "down", 1, 3)
      assert state.selection == nil
      assert action == nil
    end

    test "coordinates clamp into the log rect (status bar and input box)" do
      state = selected_state()

      # Above the log (the status row): clamps to display row 0, col 0.
      {above, nil} = State.select_mouse(state, "down", 0, 0)
      assert above.selection.anchor == {0, 0}

      # Below the log (over the input box): clamps to the last row, and the
      # column clamps to the padded width (one past the last column).
      {below, nil} = State.select_mouse(selected_state(), "down", 999, 23)
      assert below.selection.anchor == {3, 76}
    end

    test "a blank-only selection copies nothing and clears" do
      # An empty entry renders as blank separator + empty line: rows 0-1.
      state = State.stream_message(new_state(), {:entry, :system, ""})

      {anchored, nil} = State.select_mouse(state, "down", 3, 3)
      {released, action} = State.select_mouse(anchored, "up", 3, 4)

      assert action == nil
      assert released.selection == nil
    end

    test "the selection survives the wheel and page keys (content-anchored)" do
      state =
        Enum.reduce(1..50, selected_state(), fn i, acc ->
          State.stream_message(acc, {:entry, :system, "filler #{i}"})
        end)

      {anchored, nil} = State.select_mouse(state, "down", 1, 3)
      {dragged, nil} = State.select_mouse(anchored, "drag", 6, 5)
      {copied, {:copy, text}} = State.select_mouse(dragged, "up", 6, 5)
      assert text != ""

      # Wheel up unfollows; the selection stays anchored to the content.
      wheeled = State.wheel_scroll(copied, :up)
      refute wheeled.follow?
      assert wheeled.selection != nil
      assert State.selection_text(wheeled) == text

      {paged, nil} = State.handle_key(wheeled, "page_up", [])
      assert paged.selection != nil
      assert State.selection_text(paged) == text
    end

    test "coordinates clamp into the log rect in screen space (review P1)" do
      # A tall, scrolled-up log: the viewport shows rows far from either
      # content end, so an off-pane pointer must land on the viewport's
      # edge row — never on invisible rows beyond it.
      state =
        Enum.reduce(1..50, selected_state(), fn i, acc ->
          State.stream_message(acc, {:entry, :system, "filler #{i}"})
        end)

      scrolled = State.wheel_scroll(state, :up)
      refute scrolled.follow?
      top = State.effective_scroll(scrolled, 15)
      assert top > 0

      # Click on the status bar (screen row 0): anchors the viewport's
      # first visible display row, not `top - 2` above the viewport.
      {above, _nil} = State.select_mouse(scrolled, "down", 1, 0)
      assert above.selection.anchor == {top, 0}

      # Drag into the input pane (screen row 23): the viewport's last
      # visible row (13-row idle viewport, issues #28 + #108 + the #129
      # gap: rows top..top + 12).
      {below, _nil} = State.select_mouse(scrolled, "down", 1, 23)
      assert below.selection.anchor == {top + 12, 0}
    end

    test "click jitter below the drag threshold clears instead of copying" do
      # Review contract: a deliberate 3-cell same-row selection MUST copy;
      # a ≤2-cell wobble MUST NOT. The extent is inclusive (distance + 1).
      state = selected_state()

      # Same cell (1-cell extent): a plain click.
      {anchored, _nil} = State.select_mouse(state, "down", 2, 4)
      {same, action} = State.select_mouse(anchored, "up", 2, 4)
      assert action == nil
      assert same.selection == nil

      # Adjacent cell (2-cell extent): still wobble.
      {anchored2, _nil} = State.select_mouse(state, "down", 2, 4)
      {wobbled, action2} = State.select_mouse(anchored2, "up", 3, 4)
      assert action2 == nil
      assert wobbled.selection == nil

      # Two cells away (3-cell extent): a deliberate selection — copies.
      {anchored3, _nil} = State.select_mouse(state, "down", 2, 4)
      {dragged3, {:copy, text}} = State.select_mouse(anchored3, "up", 4, 4)
      assert match?(%{head: _}, dragged3.selection)
      assert text == "alp"
    end

    test "shift-modified events are inert — native selection owns them" do
      # Review P2d: Shift+drag is the terminal's bypass; the app must not
      # select or copy underneath it.
      state = selected_state()

      for kind <- ["down", "drag", "up"] do
        {^state, nil} = State.select_mouse(state, kind, 1, 3, ["shift"])
      end
    end

    test "a gesture that starts shifted can never copy (latched at its down)" do
      # Review P2b (delta): releasing Shift before the button used to leak
      # a clipboard write from the stale anchor of an EARLIER selection.
      # The shifted down dismisses the old selection, so the later plain
      # up has nothing to copy from.
      state = selected_state()

      # An existing selection from a previous gesture…
      {anchored, _nil} = State.select_mouse(state, "down", 1, 3)
      {dragged, _nil} = State.select_mouse(anchored, "drag", 6, 5)
      {kept, {:copy, _text}} = State.select_mouse(dragged, "up", 6, 5)
      assert match?(%{head: _}, kept.selection)

      # …a native-selection gesture starts (shift+down): the old highlight
      # goes away…
      {native, nil} = State.select_mouse(kept, "down", 1, 3, ["shift"])
      assert native.selection == nil

      # …Shift is released, and the plain up at a distant cell still
      # cannot copy from the stale anchor.
      {leaked, action} = State.select_mouse(native, "up", 6, 5)
      assert action == nil
      assert leaked.selection == nil
    end

    test "shift mid-gesture only pauses extension; a plain-start gesture copies" do
      state = selected_state()

      {anchored, _nil} = State.select_mouse(state, "down", 1, 3)
      {paused, _nil} = State.select_mouse(anchored, "drag", 6, 5, ["shift"])
      {resumed, {:copy, _text}} = State.select_mouse(paused, "up", 6, 5)
      assert match?(%{head: _}, resumed.selection)
    end

    test "an over-cap selection reports its size instead of copying" do
      # Review P2d: the OSC 52 payload is bounded — a monster selection
      # drops with a log line at the TUI layer, and its bytes are reported.
      # The real full-log flow: anchor near the bottom, wheel up while the
      # button is held (the selection is content-anchored and survives
      # scrolling), extend, release — this is how a full-log selection is
      # actually made.
      huge = String.duplicate("word ", 20_000)

      state = State.stream_message(new_state(), {:entry, :system, huge})

      {anchored, _nil} = State.select_mouse(state, "down", 1, 3)

      # 400 notches = 1200 rows above the anchor: a genuine full-log span.
      scrolled =
        Enum.reduce(1..400, anchored, fn _i, acc -> State.wheel_scroll(acc, :up) end)

      {dragged, _nil} = State.select_mouse(scrolled, "drag", 1, 3)
      {selected, action} = State.select_mouse(dragged, "up", 1, 3)

      assert {:copy_too_large, bytes} = action

      # The build stopped AT the cap: the reported bytes are the
      # accumulated lower bound, not the full span's size (which never
      # materialises — that was the freeze).
      assert bytes > 64 * 1024
      text = State.selection_text(selected)
      assert byte_size(text) > bytes

      # The highlight stays — the user sees what was too big to copy.
      assert selected.selection != nil
    end

    test "the Esc-cancel contract: a selection into the reply clears despite appended rows" do
      # Review P1 (delta): the reply boundary must come from the gesture's
      # own base, not a finalize-time recount — the cancel contract's
      # system entry lands between the anchor and the idle, shifting the
      # live block 2 rows and drifting any recount.
      opened = new_state(test_mode: {20, 24})

      streaming =
        opened
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "one two three"}, 1_000)

      {ticked, :cont} = State.tick(streaming, 1_100)

      # Select into the live reply (rows 0-1; the base is 0 — no entries).
      {anchored, _nil} = State.select_mouse(ticked, "down", 1, 2)
      {dragged, _nil} = State.select_mouse(anchored, "drag", 10, 4)
      {selected, {:copy, _text}} = State.select_mouse(dragged, "up", 10, 4)
      assert selected.selection.base_rows == 0

      cancelled =
        selected
        |> State.stream_message({:entry, :system, "[cancelled]"})
        |> State.stream_message({:phase, :idle}, 1_200)

      assert cancelled.selection == nil
    end

    test "a selection referencing rows beyond the content copies nothing" do
      # Every current shrink path (width resize, count-changing finalize)
      # clears the selection first, so a stale selection this far out of
      # range cannot arise from an interaction today — but selection_text
      # is total: Phase 4's log trimming will be able to shrink the log
      # under one, and the clamp guard decides that day's answer now —
      # copy nothing, never crash, never wrap around.
      stale = %{selected_state() | selection: %{anchor: {500, 0}, head: {900, 0}}}
      assert State.selection_text(stale) == ""
    end

    test "a width-changing resize clears; a height-only resize keeps" do
      {state, {:copy, _text}} = drag(selected_state(), {1, 3}, {6, 5})

      narrowed = State.resize(state, 40, 24)
      assert narrowed.selection == nil

      {again, {:copy, _text}} = drag(selected_state(), {1, 3}, {6, 5})
      taller = State.resize(again, 80, 40)
      assert taller.selection != nil
    end

    test "a selection reaching into the reply clears at finalize; one above survives" do
      # Review P1: the live in-flight rows can be STALE (tokens arrived
      # after the last tick) and equal in count while differing in
      # content, so row counts cannot decide — the guard is positional.
      # Display rows: 0 blank, 1 "warm", then the reply's rows from 2.
      # 22 cols → content 18: "one two three" AND "one two three four"
      # each fit one padded row (the equal-count premise below).
      warm = new_state(test_mode: {22, 24})

      base = State.stream_message(warm, {:entry, :system, "warm"})

      streaming =
        base
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "one two three"}, 1_000)

      {ticked, :cont} = State.tick(streaming, 1_100)

      dirty = State.stream_message(ticked, {:token, " four"}, 1_200)
      assert dirty.in_flight_dirty

      # Above the reply (row 1): a real drag within "warm" that survives
      # the finalize untouched.
      {anchored, _no_copy} = State.select_mouse(dirty, "down", 1, 4)
      {dragged, _no_copy} = State.select_mouse(anchored, "drag", 4, 4)
      {selected, {:copy, _text}} = State.select_mouse(dragged, "up", 4, 4)

      finalized = State.stream_message(selected, {:phase, :idle}, 1_300)
      assert finalized.selection != nil

      # The P1 shape, pinned: the stale live rows and the final entry rows
      # are EQUAL in count while differing in content ("one two three" →
      # "one two three four" — both fit one padded row).
      reply = Enum.find(finalized.entries, &(&1.kind == :assistant))
      assert length(dirty.in_flight_lines) == length(reply.lines)
      assert reply.text == "one two three four"

      # Reaching into the reply (row 2, the reply's blank separator row)
      # clears even at that equal count.
      {into, _no_copy} = State.select_mouse(dirty, "down", 1, 5)
      {into_drag, _no_copy} = State.select_mouse(into, "drag", 6, 6)
      {into_selected, {:copy, _reply_text}} = State.select_mouse(into_drag, "up", 6, 6)
      assert match?(%{head: _}, into_selected.selection)

      replaced = State.stream_message(into_selected, {:phase, :idle}, 1_400)
      assert replaced.selection == nil
    end
  end

  # Issue #28 (ADR 0006 amendment): one accidental Ctrl+C must not kill a
  # live session. First press arms a 2 s window + prompt; a second press
  # inside quits; expiry resets; any other key disarms.
  describe "exit guard" do
    test "a single Ctrl+C arms the window and does not quit" do
      {armed, action} = State.handle_key(new_state(), "c", ["ctrl"], 1_000)

      assert action == nil
      assert armed.exit_guard_at == 1_000
      assert State.exit_guard_live?(armed, 1_000)
      assert State.exit_guard_delay(armed, 1_000) == 2_000
      # The delay floors at zero once the window has logically expired —
      # the timer fires immediately to clear a stale prompt.
      assert State.exit_guard_delay(armed, 1_000 + 3_000) == 0
    end

    test "a second Ctrl+C inside the window quits through the normal path" do
      {armed, nil} = State.handle_key(new_state(), "c", ["ctrl"], 1_000)
      {cleared, action} = State.handle_key(armed, "c", ["ctrl"], 2_999)

      assert action == :quit
      assert cleared.exit_guard_at == nil
    end

    test "the window boundary is inclusive at 2 s" do
      {armed, nil} = State.handle_key(new_state(), "c", ["ctrl"], 1_000)
      assert {_state, :quit} = State.handle_key(armed, "c", ["ctrl"], 3_000)
    end

    test "an expired window resets: a late press re-arms instead of quitting" do
      {armed, nil} = State.handle_key(new_state(), "c", ["ctrl"], 1_000)
      refute State.exit_guard_live?(armed, 1_000 + 2_001)

      {rearmed, action} = State.handle_key(armed, "c", ["ctrl"], 1_000 + 2_001)

      assert action == nil
      assert rearmed.exit_guard_at == 3_001

      # The fresh window is live and completes a quit of its own.
      {_state, :quit} = State.handle_key(rearmed, "c", ["ctrl"], 3_001 + 1_999)
    end

    test "any other key disarms the guard" do
      {armed, nil} = State.handle_key(new_state(), "c", ["ctrl"], 1_000)

      {typed, nil} = State.handle_key(armed, "x", [], 1_100)
      assert typed.exit_guard_at == nil

      # A follow-up Ctrl+C inside the original window re-arms, not quits.
      {rearmed, action} = State.handle_key(typed, "c", ["ctrl"], 1_200)
      assert action == nil
      assert rearmed.exit_guard_at == 1_200
    end

    test "Esc disarms too — it never becomes an exit key" do
      {armed, nil} = State.handle_key(new_state(), "c", ["ctrl"], 1_000)
      {escaped, nil} = State.handle_key(armed, "esc", [], 1_100)
      assert escaped.exit_guard_at == nil
    end

    test "overlay? is true for an active phase or an armed guard, else false" do
      refute State.overlay?(new_state())
      assert State.overlay?(%{new_state() | phase: :streaming})
      assert State.overlay?(%{new_state() | exit_guard_at: 1_000})
    end
  end

  describe "handle_key/3 — enter semantics" do
    test "Enter submits the draft" do
      {state, action} =
        new_state()
        |> type("hello")
        |> State.handle_key("enter", [])

      assert {:submit, "hello", []} = action
      assert State.input_text(state) == ""
      assert pairs(state) == [{:user, "hello"}]
      assert state.phase == :streaming
      assert state.history == ["hello"]
    end

    test "Ctrl+Enter also submits" do
      state = type(new_state(), "hi")
      {_state, action} = State.handle_key(state, "enter", ["ctrl"])
      assert {:submit, "hi", []} = action
    end

    test "Shift+Enter and Alt+Enter insert newlines" do
      state =
        new_state()
        |> type("one")
        |> press("enter", ["shift"])
        |> type("two")
        # cursor sits at the end, so Alt+Enter appends a trailing newline
        |> press("enter", ["alt"])

      assert State.input_text(state) == "one\ntwo\n"
      assert State.input_line_count(state) == 3
    end

    test "blank and whitespace-only drafts do not submit" do
      {empty, nil} = State.handle_key(new_state(), "enter", [])
      assert empty.entries == []

      {blank, nil} =
        new_state()
        |> type("  ")
        |> State.handle_key("enter", [])

      assert blank.entries == []
      assert blank.phase == :idle
    end

    test "submit is refused while a request is in flight" do
      streaming =
        new_state()
        |> idle_submit("first")
        # put ourselves back into a streaming phase
        |> Map.put(:phase, :streaming)
        |> type("second")

      {state, action} = State.handle_key(streaming, "enter", [])
      assert action == nil
      assert pairs(state) == [{:user, "first"}]
      assert State.input_text(state) == "second"
    end
  end

  describe "handle_key/3 — confirmation mode" do
    defp confirming do
      ref = make_ref()

      {State.stream_message(new_state(), {:confirm, ref, confirm_request(["+ x"])}), ref}
    end

    test "Enter and Ctrl+Enter approve; Esc rejects — both carry no state change" do
      {state, _ref} = confirming()

      assert {^state, {:confirm, :approved}} = State.handle_key(state, "enter", [])
      assert {^state, {:confirm, :approved}} = State.handle_key(state, "enter", ["ctrl"])
      assert {^state, {:confirm, :rejected}} = State.handle_key(state, "esc", [])
    end

    test "arrows move the choice; Down+Enter answers Reject (ADR 0028)" do
      {state, _ref} = confirming()

      {moved, nil} = State.handle_key(state, "down", [])
      assert moved.choice.selected == 1

      assert {^moved, {:confirm, :rejected}} = State.handle_key(moved, "enter", [])

      # Up wraps back to Approve.
      {wrapped, nil} = State.handle_key(moved, "up", [])
      assert wrapped.choice.selected == 0
      assert {^wrapped, {:confirm, :approved}} = State.handle_key(wrapped, "enter", [])
    end

    test "quit keys still quit mid-decision" do
      {state, _ref} = confirming()
      assert {_state, :quit} = State.handle_key(state, "q", ["ctrl"])
      # Ctrl+C mid-decision follows the guard like anywhere else: arm, quit.
      {armed, nil} = State.handle_key(state, "c", ["ctrl"], 1_000)
      assert {_state, :quit} = State.handle_key(armed, "c", ["ctrl"], 1_500)
    end

    test "every other key is swallowed — nothing reaches the textarea" do
      {state, _ref} = confirming()

      for {code, mods} <- [
            {"x", []},
            {"enter", ["shift"]},
            {"enter", ["alt"]},
            {"page_up", []},
            # Space on a single-select approval is a no-op move, not an edit.
            {" ", []}
          ] do
        {^state, nil} = State.handle_key(state, code, mods)
      end

      assert State.input_text(state) == ""
    end

    test "the in-flight draft is preserved under the replacement and restored after" do
      ref = make_ref()
      draft = %{new_state() | input: ExRatatui.textarea_new()}
      ExRatatui.textarea_set_value(draft.input, "keep me")

      armed = State.stream_message(draft, {:confirm, ref, confirm_request(["+ x"])})
      assert armed.choice != nil
      assert State.input_text(armed) == "keep me"

      {answered, {:confirm, :approved}} = State.handle_key(armed, "enter", [])
      decided = State.confirm_decided(answered)

      assert decided.choice == nil
      assert State.input_text(decided) == "keep me"
    end

    test "confirm_decided clears the confirm and the choice; the phase waits for the agent" do
      {state, _ref} = confirming()
      decided = State.confirm_decided(state)

      assert decided.confirm == nil
      assert decided.choice == nil
      assert decided.phase == :confirming

      # After the decision the keys route normally again (no swallowing,
      # no cancel — the gap is one mailbox hop).
      {gap, nil} = State.handle_key(decided, "esc", [])
      assert gap == decided

      {typed, nil} = State.handle_key(decided, "x", [])
      assert State.input_text(typed) == "x"
    end
  end

  describe "handle_key/3 — the model's question (ADR 0028)" do
    defp asking(opts \\ []) do
      State.stream_message(new_state(), {:question, make_ref(), question_msg(opts)})
    end

    defp question_msg(opts \\ []) do
      %{
        question: Keyword.get(opts, :question, "Which database?"),
        options:
          Keyword.get(opts, :options, [
            %{"label" => "Postgres", "description" => "the sturdy default"},
            %{"label" => "SQLite"},
            %{"label" => "MySQL"}
          ]),
        multiple: Keyword.get(opts, :multiple, false)
      }
    end

    test "arming replaces the composer: choice up, phase :asking, ghost reaped" do
      state = asking()

      assert state.choice.kind == :ask
      assert state.choice.question == "Which database?"
      assert state.phase == :asking
      assert Enum.map(state.choice.options, & &1.label) == ["Postgres", "SQLite", "MySQL"]
      # The ghost (#91 interplay, ADR 0028): dismissed and reaped while the
      # choice owns the input surface.
      assert state.suggestion == nil
      assert state.suggest_reap == true
    end

    test "arrows move, Enter answers with the selected label, draft preserved" do
      draft = new_state()
      ExRatatui.textarea_set_value(draft.input, "half-typed")

      armed = State.stream_message(draft, {:question, make_ref(), question_msg()})
      # Question + blank + (Postgres 2: description) + SQLite + MySQL +
      # blank + hint = 8 rows.
      assert State.input_line_count(armed) == 8
      assert State.input_text(armed) == "half-typed"

      {moved_state, nil} = State.handle_key(armed, "down", [])
      assert moved_state.choice.selected == 1

      assert {^moved_state, {:question_answer, {:answered, ["SQLite"]}}} =
               State.handle_key(moved_state, "enter", [])

      decided = State.question_decided(moved_state)
      assert decided.choice == nil
      assert State.input_text(decided) == "half-typed"
    end

    test "multi: space toggles, Enter answers every checked label in order" do
      state = asking(multiple: true)

      {one, nil} = State.handle_key(state, " ", [])
      assert MapSet.to_list(one.choice.checked) == [0]

      {moved, nil} = State.handle_key(one, "down", [])
      {two, nil} = State.handle_key(moved, " ", [])

      assert {^two, {:question_answer, {:answered, ["Postgres", "SQLite"]}}} =
               State.handle_key(two, "enter", [])
    end

    test "Esc dismisses — an explicit answer, never a silent drop" do
      state = asking()

      assert {^state, {:question_answer, :dismissed}} = State.handle_key(state, "esc", [])
    end

    test "every other key is swallowed — mode cycle, palette, typing" do
      state = asking()

      for {code, mods} <- [{"tab", ["shift"]}, {"p", ["ctrl"]}, {"x", []}, {"page_up", []}] do
        {^state, nil} = State.handle_key(state, code, mods)
      end

      assert State.input_text(state) == ""
      assert state.mode == :build
      assert state.palette == nil
    end

    test "any phase message supersedes the ask — the composer restores" do
      superseded = State.stream_message(asking(), {:phase, :streaming})
      assert superseded.choice == nil
    end
  end

  describe "handle_key/3 — mode cycling (ADR 0016)" do
    test "shift+tab yields the cycle action in every chat phase; state unchanged" do
      idle = new_state()
      assert {^idle, {:set_mode, :auto}} = State.handle_key(idle, "tab", ["shift"])

      for phase <- [:streaming, :executing_tool, :checking] do
        state = %{new_state() | phase: phase}
        assert {^state, {:set_mode, :auto}} = State.handle_key(state, "tab", ["shift"])
      end

      unchained = %{new_state() | mode: :unchained}
      assert {^unchained, {:set_mode, :plan}} = State.handle_key(unchained, "tab", ["shift"])
    end

    test "back_tab cycles in the shapes real terminals emit; bare tab never does" do
      # Native BackTab (and the remote parser's CSI Z) arrives as "back_tab",
      # with or without shift reported — the synthetic "tab"+shift shape is
      # covered above.
      for mods <- [[], ["shift"]] do
        state = new_state()
        assert {^state, {:set_mode, :auto}} = State.handle_key(state, "back_tab", mods)
      end

      # Bare tab is an editing key: it forwards to the textarea (which may
      # arm the ghost-reap intent, ADR 0015 §3), never cycles the mode.
      idle = new_state()
      {after_tab, nil} = State.handle_key(idle, "tab", [])
      assert after_tab.mode == :build
    end

    test "shift+tab is swallowed while a confirmation is pending" do
      {state, _ref} = confirming()

      assert {^state, nil} = State.handle_key(state, "tab", ["shift"])
      assert state.mode == :build
    end
  end

  describe "handle_key/3 — history-aware Up/Down" do
    test "Up on the first row enters history; Down on the last row leaves it" do
      base =
        new_state()
        |> idle_submit("one")
        |> idle_submit("two")

      {up_one, nil} = State.handle_key(base, "up", [])
      assert up_one.history_index == 0
      assert State.input_text(up_one) == "two"

      {up_two, nil} = State.handle_key(up_one, "up", [])
      assert up_two.history_index == 1
      assert State.input_text(up_two) == "one"

      {down_one, nil} = State.handle_key(up_two, "down", [])
      assert down_one.history_index == 0
      assert State.input_text(down_one) == "two"

      {down_two, nil} = State.handle_key(down_one, "down", [])
      assert down_two.history_index == nil
      assert State.input_text(down_two) == ""
    end

    test "the pre-navigation draft is restored" do
      base =
        new_state()
        |> idle_submit("kept")
        |> type("dra")

      {browsing, nil} = State.handle_key(base, "up", [])
      assert State.input_text(browsing) == "kept"

      {restored, nil} = State.handle_key(browsing, "down", [])
      assert State.input_text(restored) == "dra"
    end

    test "Up inside a multi-line draft moves the cursor, not history" do
      state =
        new_state()
        |> type("one")
        |> press("enter", ["shift"])
        |> type("two")
        |> press("up", [])

      assert state.history_index == nil
      assert State.input_text(state) == "one\ntwo"
    end

    test "Up with empty history is a no-op" do
      {state, nil} = State.handle_key(new_state(), "up", [])
      assert state.history_index == nil
    end

    test "Down at the last row with live draft is a no-op" do
      {state, nil} = State.handle_key(new_state(), "down", [])
      assert state.history_index == nil
    end

    test "editing while browsing history keeps the edited text as the draft" do
      base = idle_submit(new_state(), "prev")

      {browsing, nil} = State.handle_key(base, "up", [])
      assert State.input_text(browsing) == "prev"

      {edited, nil} = State.handle_key(browsing, "x", [])
      assert edited.history_index == nil
      assert State.input_text(edited) == "prevx"

      # Down no longer discards the edit
      {after_down, nil} = State.handle_key(edited, "down", [])
      assert State.input_text(after_down) == "prevx"
    end

    test "consecutive duplicate submits are not stored twice" do
      state =
        new_state()
        |> idle_submit("same")
        |> idle_submit("same")

      assert state.history == ["same"]
    end

    test "history is capped at 500 entries" do
      seeded = %{new_state() | history: Enum.map(1..500, &"h#{&1}")}
      {state, _action} = submit(seeded, "new")
      assert length(state.history) == 500
      assert List.last(state.history) == "new"
    end

    defp submit(state, text) do
      state
      |> type(text)
      |> State.handle_key("enter", [])
    end
  end

  describe "stream_message/3" do
    test "tokens accumulate in the in-flight entry and count in stats" do
      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "hel"}, 1_000)
        |> State.stream_message({:token, "lo"}, 1_200)

      assert state.in_flight == "hello"
      assert state.entries == []
      assert state.stats.tokens == 2
      assert state.stats.first_token_at == 1_000
      assert state.in_flight_dirty
      # The live lines are only refreshed by the tick.
      assert state.in_flight_lines == nil
    end

    # A stray token at idle belongs to a turn that is over (the late-usage
    # rule): letting it set in_flight would let a later {:phase, :idle}
    # finalize and arm a suggestion for it — a contract-violating producer
    # would re-open the duplicate-arm window (ADR 0015 §3).
    test "a token at idle is ignored: in_flight stays nil, no arm" do
      state = State.stream_message(new_state(), {:token, "x"}, 1_000)

      assert state.in_flight == nil
      assert state.suggest_arm == false
    end

    # The guard keeps the module's own contract rule intact: only a WELL-
    # FORMED late token is ignored; a malformed one still crashes —
    # contract violations are bugs, silent no-ops hide producer errors.
    test "a malformed token at idle still crashes (the contract rule)" do
      assert_raise FunctionClauseError, fn ->
        State.stream_message(new_state(), {:token, :not_binary}, 1_000)
      end
    end

    test "re-announcing :streaming never finalizes the in-flight entry" do
      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "The answer is "}, 1_000)
        |> State.stream_message({:token, "42."}, 1_010)
        |> State.stream_message({:phase, :streaming}, 1_020)
        |> State.stream_message({:token, " (confident)"}, 1_030)
        |> State.stream_message({:phase, :idle}, 2_000)

      assert pairs(state) == [{:assistant, "The answer is 42. (confident)"}]
      assert state.in_flight == nil
      assert state.phase == :idle
    end

    test "leaving :streaming for :executing_tool finalizes the in-flight entry" do
      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "one\ntwo"}, 1_000)
        |> State.stream_message({:phase, :executing_tool}, 1_010)

      assert pairs(state) == [{:assistant, "one\ntwo"}]
      assert state.in_flight == nil
      assert state.phase == :executing_tool

      idle = State.stream_message(state, {:phase, :idle}, 1_020)
      assert idle.phase == :idle
      assert pairs(idle) == [{:assistant, "one\ntwo"}]
    end

    test "tool and system entries append as complete entries" do
      state =
        new_state()
        |> State.stream_message({:entry, :tool, "[tool] ran"})
        |> State.stream_message({:entry, :system, "reconnected"})

      assert pairs(state) == [{:tool, "[tool] ran"}, {:system, "reconnected"}]
    end

    test "tool_call appends a gear row summarizing the path argument" do
      state =
        State.stream_message(
          new_state(),
          {:tool_call, %{id: "t1", name: "read_file", args: %{"path" => "lib/foo.ex"}}}
        )

      [entry] = state.entries
      assert entry.kind == :tool
      assert entry.text == "⚙ read_file lib/foo.ex"
      assert Enum.map(entry.lines, &flatten/1) == ["", "⚙ read_file lib/foo.ex"]
    end

    test "tool_call summarizes execute_command by its command; bare name without either" do
      cmd =
        State.stream_message(
          new_state(),
          {:tool_call, %{id: "t2", name: "execute_command", args: %{"command" => "mix test"}}}
        )

      assert pairs(cmd) == [{:tool, "⚙ execute_command mix test"}]

      bare =
        State.stream_message(new_state(), {:tool_call, %{id: "t3", name: "list_dir", args: %{}}})

      assert pairs(bare) == [{:tool, "⚙ list_dir"}]
    end

    test "tool_result appends the status row with dim, indented, verbatim output" do
      state =
        State.stream_message(
          new_state(),
          {:tool_result,
           %{id: "t1", name: "read_file", ok: true, status: "ok", output: "line one\nline two"}}
        )

      [entry] = state.entries
      assert entry.kind == :tool
      assert entry.text == "⚙ read_file → ok\nline one\nline two"

      assert Enum.map(entry.lines, &flatten/1) == [
               "",
               "⚙ read_file → ok",
               "  line one",
               "  line two"
             ]
    end

    test "tool_result without output is a single row" do
      state =
        State.stream_message(
          new_state(),
          {:tool_result,
           %{id: "t1", name: "write_file", ok: false, status: "rejected", output: nil}}
        )

      [entry] = state.entries
      assert entry.text == "⚙ write_file → rejected"
      assert Enum.map(entry.lines, &flatten/1) == ["", "⚙ write_file → rejected"]
    end

    test "confirm appends the preview entry, arms the decision, flips to :confirming" do
      ref = make_ref()

      state =
        State.stream_message(
          new_state(),
          {:confirm, ref,
           %{
             id: "c1",
             name: "write_file",
             args: %{"path" => "a.ex"},
             lines: ["@@ -1 +1 @@", "- old", "+ new", "$ mix format"]
           }}
        )

      [entry] = state.entries
      assert entry.kind == :tool
      assert entry.text == "@@ -1 +1 @@\n- old\n+ new\n$ mix format"
      assert length(entry.lines) == 5
      assert state.confirm == %{ref: ref, id: "c1", name: "write_file"}
      assert state.phase == :confirming
    end

    test ":confirming is an active phase: it ticks and steps the spinner" do
      state =
        State.stream_message(new_state(), {:confirm, make_ref(), confirm_request(["+ x"])})

      assert State.needs_tick?(state)

      {ticked, :cont} = State.tick(state, 1_000)
      assert ticked.anim_step == 1
    end

    defp confirm_request(lines), do: %{id: "c", name: "write_file", args: %{}, lines: lines}

    test "entry text is kept verbatim, trailing newlines included" do
      state = State.stream_message(new_state(), {:entry, :system, "note\n\n"})
      [entry] = state.entries
      assert entry.text == "note\n\n"
      assert Enum.map(entry.lines, &flatten/1) == ["", "note", "", ""]
    end

    test "entries carry their rendered lines, blank separator first" do
      state = State.stream_message(new_state(), {:entry, :system, "a\nb"})
      [entry] = state.entries

      assert entry.kind == :system
      assert entry.text == "a\nb"
      assert length(entry.lines) == 3
      assert flatten(hd(entry.lines)) == ""
      assert Enum.map(entry.lines, &flatten/1) == ["", "a", "b"]
    end

    test "contract violations crash instead of corrupting state" do
      # Tuples assembled at runtime via List.to_tuple so the compile-time type
      # checker cannot narrow the call into an "impossible input" warning —
      # the payloads are runtime garbage.
      bogus = :bogus
      not_binary = :not_binary
      user = :user
      bad_phase = List.to_tuple([:phase, bogus])
      bad_token = List.to_tuple([:token, not_binary])
      bad_entry = List.to_tuple([:entry, user, "not allowed via messages"])

      assert_raise FunctionClauseError, fn ->
        State.stream_message(new_state(), bad_phase)
      end

      # A malformed token payload crashes only mid-turn — at idle the token
      # is ignored wholesale (the late-usage rule).
      streaming = Map.put(new_state(), :phase, :streaming)

      assert_raise FunctionClauseError, fn ->
        State.stream_message(streaming, bad_token)
      end

      assert_raise FunctionClauseError, fn ->
        State.stream_message(new_state(), bad_entry)
      end
    end
  end

  describe "stream_message/3 — mode messages (ADR 0016)" do
    test "{:mode, mode} echo sets the mode; no entry, no phase change" do
      state = State.stream_message(new_state(), {:mode, :auto})

      assert state.mode == :auto
      assert state.entries == []
      assert state.phase == :idle
    end

    test "tool_preview appends the preview entry without arming the confirm" do
      preview = %{id: 1, name: "edit_file", args: %{}, lines: ["@@ hunk"]}

      state = State.stream_message(new_state(), {:tool_preview, preview})

      [entry] = state.entries
      assert entry.kind == :tool
      assert entry.text == "@@ hunk"
      assert state.confirm == nil
      assert state.phase == :idle

      # The contrast case: {:confirm, ref, same} arms and flips the phase.
      ref = make_ref()
      confirmed = State.stream_message(new_state(), {:confirm, ref, preview})

      assert confirmed.confirm == %{ref: ref, id: 1, name: "edit_file"}
      assert confirmed.phase == :confirming
    end

    test "{:phase, :checking} finalizes the in-flight entry, clears the confirm, ticks" do
      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "partial"}, 1_000)
        |> State.stream_message({:confirm, make_ref(), confirm_request(["+ x"])})
        |> State.stream_message({:phase, :checking}, 1_100)

      # The preview entry stays; the in-flight reply finalized.
      assert pairs(state) == [tool: "+ x", assistant: "partial"]
      assert state.in_flight == nil
      assert state.phase == :checking
      assert state.confirm == nil
      assert State.needs_tick?(state)

      # Esc interrupts the check.
      assert {^state, :cancel} = State.handle_key(state, "esc", [])
    end
  end

  describe "usage reconciliation" do
    test "prompt and completion tokens are reconciled; no phase change" do
      usage = %{prompt_tokens: 120, completion_tokens: 42, total_tokens: 162}

      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:usage, usage}, 2_000)

      assert state.stats.prompt_tokens == 120
      assert state.stats.completion_tokens == 42
      # The estimate is reconciled to the provider's authoritative count.
      assert state.stats.tokens == 42
      assert state.phase == :streaming
    end

    test "a later usage frame wins (per-chunk reporters send running totals)" do
      turn_one =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message(
          {:usage, %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}}
        )
        |> State.stream_message(
          {:usage, %{prompt_tokens: 20, completion_tokens: 8, total_tokens: 28}}
        )

      assert turn_one.stats.prompt_tokens == 20
      assert turn_one.stats.completion_tokens == 8
      assert turn_one.stats.tokens == 8

      idle = State.stream_message(turn_one, {:phase, :idle}, 3_000)
      assert idle.stats.prompt_tokens == 20

      turn_two =
        idle
        |> Map.put(:phase, :streaming)
        |> State.stream_message(
          {:usage, %{prompt_tokens: 30, completion_tokens: 10, total_tokens: 10}}
        )

      assert turn_two.stats.prompt_tokens == 30
    end

    test "a usage frame after the turn finalized is ignored" do
      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "t"}, 1_000)
        |> State.stream_message({:phase, :idle}, 2_000)

      late =
        State.stream_message(
          state,
          {:usage, %{prompt_tokens: 500, completion_tokens: 500, total_tokens: 1_000}},
          2_500
        )

      # Nothing from the finished turn may poison the next one's rate math.
      assert late.stats.tokens == 0
      assert late.stats.prompt_tokens == nil
    end
  end

  describe "context snapshots (ADR 0015 §2 amendment)" do
    test "{:context, _} adopts the snapshot verbatim; a later snapshot wins" do
      one = [%{role: "user", content: "hi"}]
      two = one ++ [%{role: "assistant", content: "hello"}]

      state =
        new_state()
        |> State.stream_message({:context, %{messages: one, anchor: nil}}, 1_000)
        |> State.stream_message(
          {:context, %{messages: two, anchor: %{tokens: 9, index: 2}}},
          1_100
        )

      assert state.context == %{messages: two, anchor: %{tokens: 9, index: 2}}
    end
  end

  describe "rate derivation and freezing" do
    test "the tick never derives a rate — no live tok/s (issue #130)" do
      state =
        Enum.reduce(1..10, Map.put(new_state(), :phase, :streaming), fn i, acc ->
          State.stream_message(acc, {:token, "t#{i}"}, 1_000)
        end)

      {ticked, :cont} = State.tick(state, 2_010)
      assert ticked.stats.rate == nil
      assert State.rate_label(ticked) == nil
    end

    test "finalize freezes the whole-response average and clears the counters" do
      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "abc"}, 1_000)
        |> State.stream_message({:token, "def"}, 1_500)
        |> State.stream_message({:phase, :idle}, 2_000)

      # 2 tokens over the 0.5 s decode window (first → last token, not
      # send → done: the owner's refinement — elapsed-time rates fold TTFT
      # in and drag the number down).
      assert_in_delta state.stats.rate, 4.0, 0.0001
      assert state.stats.tokens == 0
      assert state.stats.first_token_at == nil
      assert state.stats.last_token_at == nil
      assert State.rate_label(state) == "4"
    end

    test "the frozen rate survives a late usage frame; the next submit retires it" do
      usage = %{prompt_tokens: 3, completion_tokens: 2, total_tokens: 5}

      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "a"}, 1_000)
        |> State.stream_message({:token, "b"}, 1_500)
        |> State.stream_message({:usage, usage}, 1_800)
        |> State.stream_message({:phase, :idle}, 2_000)

      assert State.rate_label(state) == "4"

      # A usage frame arriving after the turn ended belongs to nobody.
      late = State.stream_message(state, {:usage, usage}, 2_100)
      assert State.rate_label(late) == "4"

      # The next send clears the retired spans (issue #130: a streaming
      # footer shows the new turn's ttft once a token lands — never a
      # stale tok/s) and stamps the new clock zero.
      resent = idle_submit(late, "next question")
      assert resent.stats.rate == nil
      assert resent.stats.ttft_ms == nil
      assert is_integer(resent.stats.sent_at)
    end

    test "cancel-style finalize with no usage frame still freezes a rate" do
      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "par"}, 1_000)
        |> State.stream_message({:token, "tial"}, 1_200)
        |> State.stream_message({:phase, :idle}, 1_500)

      # 2 partial tokens over the 0.2 s decode window = 10 tok/s.
      assert_in_delta state.stats.rate, 10.0, 0.0001
      assert state.stats.prompt_tokens == nil
      assert pairs(state) == [{:assistant, "partial"}]
    end

    test "no tokens means no rate, never a division by zero" do
      state = State.stream_message(new_state(), {:phase, :idle}, 5_000)
      assert state.stats.rate == nil
      assert State.rate_label(state) == nil
    end

    test "a single token has no decode window, so no rate" do
      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "a"}, 1_000)
        |> State.stream_message({:phase, :idle}, 2_000)

      assert state.stats.rate == nil
      assert State.rate_label(state) == nil
    end
  end

  describe "ttft: send → first token (issue #130)" do
    # The standin stream with a KNOWN first-token delay: Enter at t=0, the
    # first token 1.4 s later, 96 tokens over a 3 s decode window, finalize
    # at 5 s — the issue's own example numbers.
    test "measured from the submit, shown alone while streaming, kept after the turn" do
      base = type(new_state(), "hello")
      {sent, {:submit, "hello", []}} = State.handle_key(base, "enter", [], 0)
      assert sent.stats.sent_at == 0

      # Mid-stream: ttft known from the first token, no tok/s beside it.
      first_token = State.stream_message(sent, {:token, "t0"}, 1_400)
      assert first_token.stats.ttft_ms == 1_400
      assert State.ttft_label(first_token) == "1.4"
      assert State.rate_label(first_token) == nil

      streamed =
        Enum.reduce(1..95, first_token, fn i, acc ->
          State.stream_message(acc, {:token, "t#{i}"}, 1_400 + div(i * 3_000, 95))
        end)

      done = State.stream_message(streamed, {:phase, :idle}, 5_000)

      # After the turn: both spans persist — `ttft 1.4s · 32 tok/s` — the
      # rate is the whole-response average over the decode window alone.
      assert State.ttft_label(done) == "1.4"
      assert State.rate_label(done) == "32"
      assert_in_delta done.stats.rate, 32.0, 0.001
    end

    test "ttft is captured once per turn — a tool interlude cannot reset it" do
      base = type(new_state(), "q")
      {sent, _action} = State.handle_key(base, "enter", [], 0)

      state =
        sent
        |> State.stream_message({:token, "before"}, 1_400)
        # A mid-turn tool episode finalizes the episode counters...
        |> State.stream_message({:phase, :executing_tool}, 1_500)
        |> State.stream_message({:phase, :streaming}, 1_600)
        # ...so this is a NEW episode's first token — the turn's ttft
        # still reads from the send.
        |> State.stream_message({:token, "after"}, 2_000)

      assert state.stats.ttft_ms == 1_400
      assert state.stats.first_token_at == 2_000
    end

    test "a token with no send behind it reads no ttft" do
      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "stray"}, 1_000)

      assert state.stats.ttft_ms == nil
      assert State.ttft_label(state) == nil
    end

    test "a token racing its own submit reads ttft zero, never negative" do
      base = type(new_state(), "q")
      {sent, _action} = State.handle_key(base, "enter", [], 5_000)

      racing = State.stream_message(sent, {:token, "early"}, 4_000)
      assert racing.stats.ttft_ms == 0
      assert State.ttft_label(racing) == "0"
    end
  end

  describe "tick/2" do
    test "halts at idle and changes nothing" do
      state = new_state()
      assert {^state, :halt} = State.tick(state, 9_999)
    end

    test "steps the spinner and refreshes dirty in-flight lines" do
      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "hello"}, 1_000)

      {ticked, :cont} = State.tick(state, 1_125)

      assert ticked.anim_step == 1
      refute ticked.in_flight_dirty
      assert Enum.map(ticked.in_flight_lines, &flatten/1) == ["", "hello"]

      # A clean tick does not re-render.
      {again, :cont} = State.tick(ticked, 1_250)
      assert again.anim_step == 2
      assert again.in_flight_lines == ticked.in_flight_lines
    end

    test "above the 64 KiB cap the last render sticks until finalize" do
      at_cap = String.duplicate("x", 64 * 1024)
      over_cap = at_cap <> "y"

      fitted =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, at_cap}, 1_000)

      {rendered, :cont} = State.tick(fitted, 1_125)
      assert rendered.in_flight_lines != nil

      {over, :cont} =
        rendered
        |> State.stream_message({:token, "y"}, 1_200)
        |> State.tick(1_250)

      assert over.in_flight_lines == rendered.in_flight_lines
      assert over.in_flight_dirty
      assert over.in_flight == over_cap

      # Finalize still renders the full text once — wrapped to the width.
      final = State.stream_message(over, {:phase, :idle}, 1_300)
      [entry] = final.entries
      assert entry.text == over_cap
      # blank separator + 64 KiB + 1 of x's at 76 columns (the padded width)
      # = 864 display rows
      assert length(entry.lines) == 1 + div(64 * 1024, 76) + 1
    end

    test "needs_tick?/1 is true only while active and unscheduled" do
      assert State.needs_tick?(new_state()) == false

      active = %{new_state() | phase: :streaming}
      assert State.needs_tick?(active)
      assert State.needs_tick?(%{new_state() | phase: :confirming})

      assert State.needs_tick?(%{active | tick_ref: make_ref()}) == false
    end

    # Regression (hostile review P1-3): wrapping an unbreakable run used to
    # re-measure the whole remainder per row (quadratic); a CJK reply near
    # the live cap drove one tick to 1.6 s — 13x the 125 ms tick budget.
    # The wrap is single-pass now.
    #
    # The guard is the scaling LAW, not a wall-clock budget (issue #51): a
    # single-run millisecond assert on a loaded runner is a false-red
    # generator — the original 400 ms bound fired at 418 ms on CI while the
    # same tree was green on a plain rerun. Work is measured in reductions,
    # which the BEAM counts deterministically per function call and which
    # therefore does not move with scheduler contention: doubling the input
    # doubles the work for a single pass (measured 1.97-2.01 over 10 runs
    # quiet and under 24 CPU hogs) and quadruples it for the quadratic shape
    # (measured 3.96 on a replica of the pre-fix wrap). The bound below
    # leaves room for constant overhead and still separates 2x from 4x.
    test "a tick wrapping a large unbreakable CJK reply stays linear in its input" do
      phrase = "日本語の長い返事が続きます。"
      small = String.duplicate(phrase, 500)
      large = String.duplicate(phrase, 1_000)

      assert byte_size(large) < 64 * 1024,
             "both inputs must stay under the live render cap or tick stops re-wrapping"

      {small_work, small_ticked} = tick_work(small)
      {large_work, large_ticked} = tick_work(large)

      assert State.log_line_count(small_ticked) > 100
      assert State.log_line_count(large_ticked) > 2 * State.log_line_count(small_ticked) - 10

      ratio = large_work / small_work

      assert ratio < 3.0,
             "tick work grew #{Float.round(ratio, 2)}x for a 2x input — the wrap is " <>
               "quadratic again (#{small_work} -> #{large_work} reductions)"
    end

    # Reductions the calling process spends inside one tick, and the ticked
    # state. Deterministic: no clock, no scheduler, no CPU contention.
    defp tick_work(text) do
      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, text}, 1_000)

      {:reductions, before} = Process.info(self(), :reductions)
      {ticked, :cont} = State.tick(state, 1_100)
      {:reductions, after_} = Process.info(self(), :reductions)

      {after_ - before, ticked}
    end
  end

  describe "scrolling" do
    # Each entry renders one text line plus its blank separator = 2 lines.
    defp full_state(n) do
      Enum.reduce(1..n, new_state(), fn i, acc ->
        State.stream_message(acc, {:entry, :system, "line #{i}"})
      end)
    end

    test "empty log: offsets are zero and page_up keeps following" do
      {state, nil} = State.handle_key(new_state(), "page_up", [])
      assert state.follow?
      assert State.effective_scroll(state, 20) == 0
    end

    test "blank separators count toward the log line total" do
      state = full_state(1)
      assert State.log_line_count(state) == 2
    end

    test "page_up on a viewport-fitting log is a no-op (stays pinned)" do
      # The real idle viewport at 80x24 is 13 rows with the margin (issues
      # #28 + #108; ADR 0015's footer took one row and its #129 gap two
      # more); 6 entries = blank + line each fit inside one viewport.
      base = full_state(6)
      assert State.log_line_count(base) == 12

      {paged, nil} = State.handle_key(base, "page_up", [])
      assert paged.follow?
      assert State.effective_scroll(paged, 13) == 0
    end

    test "submit re-pins the log so the new reply is visible" do
      base = full_state(100)
      {paged, nil} = State.handle_key(base, "page_up", [])
      refute paged.follow?

      state = idle_submit(paged, "next question")
      assert state.follow?
      # 200 lines + the user entry's 2 = 202; bottom is 202 - 20
      assert State.effective_scroll(state, 20) == 182
    end

    # Typing leaves the transcript EXACTLY in place (issue #131, reversing
    # #110): the owner is deliberately reading earlier context while
    # composing a reply — "I only want the chat to automatically scroll to
    # the bottom once I press Enter and not when I type something." A
    # composer edit is not a send; the view keeps its offset to the row.
    test "a draft-editing keystroke leaves the view exactly in place" do
      base = full_state(100)
      {paged, nil} = State.handle_key(base, "page_up", [])
      refute paged.follow?

      {typed, nil} = State.handle_key(paged, "h", [])
      refute typed.follow?
      assert typed.scroll == paged.scroll
      assert State.effective_scroll(typed, 20) == State.effective_scroll(paged, 20)
      assert State.input_text(typed) == "h"
    end

    test "backspace editing an existing draft stays put too" do
      base = full_state(100)
      {drafted, nil} = State.handle_key(base, "a", [])
      {paged, nil} = State.handle_key(drafted, "page_up", [])
      refute paged.follow?

      {edited, nil} = State.handle_key(paged, "backspace", [])
      refute edited.follow?
      assert edited.scroll == paged.scroll
      assert State.input_text(edited) == ""
    end

    test "a paste stays put (a composer edit, not a send)" do
      base = full_state(100)
      {paged, nil} = State.handle_key(base, "page_up", [])
      refute paged.follow?

      pasted = State.paste(paged, "pasted text")
      refute pasted.follow?
      assert pasted.scroll == paged.scroll
      assert State.input_text(pasted) == "pasted text"
    end

    # Enter is the ONE re-pin gesture: a dispatched submit — message or
    # command — snaps the transcript to its tail (issue #131).
    test "submitting a command re-pins the log too" do
      base = full_state(100)
      {paged, nil} = State.handle_key(base, "page_up", [])
      refute paged.follow?

      {helped, nil} =
        paged
        |> type("/help")
        |> State.handle_key("enter", [])

      assert helped.follow?
      assert helped.scroll == 0
    end

    test "a no-op Enter (blank draft) pins nothing" do
      base = full_state(100)
      {paged, nil} = State.handle_key(base, "page_up", [])
      refute paged.follow?

      {noop, nil} = State.handle_key(paged, "enter", [])
      refute noop.follow?
      assert noop.scroll == paged.scroll
    end

    # A reply arriving while the view is parked above the tail must not
    # yank it either (issue #131's verify-and-record clause): the scroll
    # intent is top-anchored, so appends land below the viewport and the
    # visible rows never move.
    test "a reply arriving while scrolled up does not yank the view" do
      base = full_state(100)
      {paged, nil} = State.handle_key(base, "page_up", [])
      refute paged.follow?
      offset = State.effective_scroll(paged, 13)

      arriving =
        paged
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "the reply grows and grows"}, 1_000)

      {ticked, :cont} = State.tick(arriving, 1_100)

      growing = State.stream_message(ticked, {:token, " — more"}, 1_200)

      refute growing.follow?
      assert growing.scroll == paged.scroll
      assert State.effective_scroll(growing, 13) == offset
      assert State.log_line_count(growing) > State.log_line_count(paged)
    end

    # The negative space, recorded (issue #110's decision, kept by #131):
    # cursor-only keys and history navigation are not sends — the view
    # stays where the reader put it.
    test "cursor-only keys and history navigation do NOT re-pin" do
      base = full_state(100)
      {paged, nil} = State.handle_key(base, "page_up", [])
      refute paged.follow?

      {moved, nil} = State.handle_key(paged, "left", [])
      refute moved.follow?

      with_history = %{paged | history: ["old"]}
      {recalled, nil} = State.handle_key(with_history, "up", [])
      refute recalled.follow?
    end

    # The remaining composer edits, each pinned (ADR 0006's #131 amendment
    # enumerates them; hostile review F6): a chip pop, the ghost Tab, and
    # the filter's completion Tab all leave the parked view alone.
    test "a chip pop on an empty draft stays put" do
      base = full_state(100)
      {paged, nil} = State.handle_key(base, "page_up", [])

      chipped = %{paged | attachments: [%{path: "/p/a.png", name: "a.png", kb: 1}]}
      {popped, nil} = State.handle_key(chipped, "backspace", [])
      refute popped.follow?
      assert popped.scroll == paged.scroll
      assert popped.attachments == []
    end

    test "the ghost Tab stays put" do
      base = full_state(100)
      {paged, nil} = State.handle_key(base, "page_up", [])

      ghosted = %{paged | suggestion: "tell me more"}
      {landed, nil} = State.handle_key(ghosted, "tab", [])
      refute landed.follow?
      assert landed.scroll == paged.scroll
      assert State.input_text(landed) == "tell me more"
    end

    test "the filter's completion Tab stays put" do
      base = full_state(100)
      {paged, nil} = State.handle_key(base, "page_up", [])

      {typed, nil} = State.handle_key(paged, "/", [])
      assert typed.palette != nil
      {completed, nil} = State.handle_key(typed, "tab", [])
      refute completed.follow?
      assert completed.scroll == paged.scroll
      assert State.input_text(completed) =~ "/"
    end

    # The modal command palette's Enter is a dispatched submit too (ADR
    # 0006's #131 amendment: Enter is Enter) — it re-pins like the typed
    # and filtered forms.
    test "the modal palette's command Enter re-pins" do
      base = full_state(100)
      {paged, nil} = State.handle_key(base, "page_up", [])
      refute paged.follow?

      {opened, nil} = State.handle_key(paged, "p", ["ctrl"])
      assert opened.palette != nil

      {run, nil} = State.handle_key(opened, "enter", [])
      assert run.follow?
      assert run.scroll == 0
    end

    # The pickers are selectors, not sends (the same amendment): nothing
    # lands in the transcript, so the reader's place keeps. (Opening /model
    # re-pins — a dispatched submit — so the view parks AFTER it opens.)
    test "the model picker's Enter keeps the reader's place" do
      config = %DashFloat.Config{base_url: "http://x", model: "m2", api_key: "k"}

      parked = full_state(100)

      with_catalog =
        parked
        |> Map.put(:provider, {:ok, config})
        |> Map.put(:catalog, %{"http://x" => [%{model: "m1"}, %{model: "m2"}]})

      {opened, nil} = enter_typed(with_catalog, "/model")
      assert opened.palette != nil

      # The wheel is focus-free (ADR 0006): it parks the view even while
      # the modal palette swallows keys.
      wheeled = State.wheel_scroll(opened, :up)
      refute wheeled.follow?

      {picked, _action} = State.handle_key(wheeled, "enter", [])
      refute picked.follow?
      assert picked.scroll == wheeled.scroll
      assert picked.palette == nil
    end

    test "follow pins to the bottom as content grows" do
      state = full_state(50)
      assert State.effective_scroll(state, 20) == 80
      grown = State.stream_message(state, {:entry, :system, "more"})
      assert State.effective_scroll(grown, 20) == 82
    end

    test "page_up unfollows and pages back; page_down re-pins at the bottom" do
      # 200 lines, 13-row viewport (the padded 80x24 layout with ADR 0015's
      # footer and its #129 gap) → bottom 187.
      base = full_state(100)
      {up_one, nil} = State.handle_key(base, "page_up", [])
      refute up_one.follow?
      assert State.effective_scroll(up_one, 15) == 174

      {up_two, nil} = State.handle_key(up_one, "page_up", [])
      assert State.effective_scroll(up_two, 15) == 161

      {down_one, nil} = State.handle_key(up_two, "page_down", [])
      assert State.effective_scroll(down_one, 15) == 174

      {down_two, nil} = State.handle_key(down_one, "page_down", [])
      assert down_two.follow?
      assert State.effective_scroll(down_two, 15) == 185
    end

    test "wheel_scroll: one notch is three lines; up unfollows, down re-pins at the bottom" do
      base = full_state(100)
      assert State.effective_scroll(base, 15) == 185

      wheeled = State.wheel_scroll(base, :up)
      refute wheeled.follow?
      assert State.effective_scroll(wheeled, 15) == 184

      again = State.wheel_scroll(wheeled, :up)
      assert State.effective_scroll(again, 15) == 181

      down = State.wheel_scroll(again, :down)
      refute down.follow?
      assert State.effective_scroll(down, 15) == 184

      pinned = State.wheel_scroll(down, :down)
      assert pinned.follow?
      assert State.effective_scroll(pinned, 15) == 185
    end

    test "wheel up on a viewport-fitting log is a no-op (stays pinned)" do
      base = full_state(6)
      assert State.log_line_count(base) == 12
      assert State.wheel_scroll(base, :up) == base
    end

    test "wheel scrolling stays live while a confirm is pending (focus-free)" do
      base = full_state(100)

      state =
        State.stream_message(
          base,
          {:confirm, make_ref(), %{id: "c", name: "w", args: %{}, lines: ["+ x"]}}
        )

      assert state.phase == :confirming

      # The activity row is up while confirming AND the choice replaces the
      # composer (ADR 0028): the approve widget takes its full 6 rows (the
      # choice's clamp is the area minus chrome, not the draft's third) —
      # 8 bordered rows against the empty draft's 3 — so the viewport is 7
      # rows (12 minus the activity row's minus the box's growth).
      bottom = State.effective_scroll(state, 7)
      wheeled = State.wheel_scroll(state, :up)
      refute wheeled.follow?
      assert State.effective_scroll(wheeled, 7) == bottom - 3
    end

    test "new content does not move an unfollowed view, but clamping still holds" do
      base = full_state(100)
      {paged, nil} = State.handle_key(base, "page_up", [])
      offset = State.effective_scroll(paged, 20)

      grown = State.stream_message(paged, {:entry, :system, "more"})
      assert State.effective_scroll(grown, 20) == offset

      # shrink the viewport: the intent clamps to the new maximum
      assert State.effective_scroll(grown, 10) <= 193
    end

    test "stale scroll intents clamp to content" do
      state = %{full_state(10) | scroll: 999, follow?: false}
      assert State.effective_scroll(state, 20) == 0
    end

    test "log_line_count counts rendered lines of multi-line entries" do
      state =
        new_state()
        |> State.stream_message({:entry, :system, "a\nb"})
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "c\nd"})

      # system entry: blank + a + b; the in-flight text is not rendered until
      # the tick.
      assert State.log_line_count(state) == 3

      {ticked, :cont} = State.tick(%{state | phase: :streaming}, 1_000)
      assert State.log_line_count(ticked) == 6
    end
  end

  describe "agent monitoring" do
    test "claim_agent stores the monitor ref" do
      base = new_state(agent: self())
      state = State.claim_agent(base)
      assert is_reference(state.agent_ref)
      Process.demonitor(state.agent_ref)
    end

    test "Esc cancels while streaming or executing a tool; a no-op otherwise" do
      streaming = %{new_state() | phase: :streaming}
      assert {^streaming, :cancel} = State.handle_key(streaming, "esc", [])

      tool = %{new_state() | phase: :executing_tool}
      assert {^tool, :cancel} = State.handle_key(tool, "esc", [])

      # Idle (and the post-decision confirming gap): no cancel, and the key
      # does not reach the textarea.
      assert {%{phase: :idle} = idle, nil} = State.handle_key(new_state(), "esc", [])
      assert State.input_text(idle) == ""

      gap = %{new_state() | phase: :confirming}
      assert {^gap, nil} = State.handle_key(gap, "esc", [])
    end

    test "a normal agent DOWN finalizes a partial reply, ensures idle, clears the ref" do
      ref = make_ref()

      state =
        new_state()
        |> Map.put(:agent_ref, ref)
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "partial"}, 1_000)

      {after_down, handled} = State.agent_down(state, ref, :normal)
      assert handled == :handled
      assert after_down.phase == :idle
      assert after_down.agent_ref == nil
      assert after_down.in_flight == nil
      assert {:assistant, "partial"} in pairs(after_down)
    end

    test "a :noproc DOWN (monitor attached to an already-dead name) is a success" do
      ref = make_ref()
      state = %{new_state() | agent_ref: ref}

      {after_down, handled} = State.agent_down(state, ref, :noproc)
      assert handled == :handled
      assert after_down.phase == :idle
      assert after_down.entries == []
      assert after_down.agent_ref == nil
    end

    test "an abnormal agent DOWN degrades to idle with an [agent failed] entry" do
      ref = make_ref()

      state =
        new_state()
        |> Map.put(:agent_ref, ref)
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "partial reply"}, 1_000)

      {after_down, handled} = State.agent_down(state, ref, :killed)
      assert handled == :handled
      assert after_down.agent_ref == nil
      assert after_down.phase == :idle

      # the partial reply is kept as an assistant entry, then explained
      assert {:assistant, "partial reply"} in pairs(after_down)
      assert {:system, "[agent failed: :killed]"} in pairs(after_down)
    end

    test "an agent DOWN mid-confirm disarms the modal so input keeps working" do
      ref = make_ref()

      state =
        new_state()
        |> Map.put(:agent_ref, ref)
        |> State.stream_message({:confirm, make_ref(), confirm_request(["+ x"])})

      assert match?(%{ref: _}, state.confirm)

      {after_down, :handled} = State.agent_down(state, ref, :killed)
      assert after_down.confirm == nil
      assert after_down.phase == :idle

      # A phase transition alone (no agent death, no decision) disarms too.
      armed = State.stream_message(new_state(), {:confirm, make_ref(), confirm_request(["+ y"])})
      retired = State.stream_message(armed, {:phase, :idle})
      assert retired.confirm == nil
      assert retired.phase == :idle
    end

    test "the failure entry inspects the reason to a 120-char slice" do
      reason = {:boom, String.duplicate("x", 300)}
      state = %{new_state() | agent_ref: make_ref()}

      {after_down, :handled} = State.agent_down(state, state.agent_ref, reason)

      expected = "[agent failed: #{String.slice(inspect(reason), 0, 120)}]"
      assert {:system, expected} in pairs(after_down)
      assert String.length(expected) == 120 + String.length("[agent failed: ]")
    end

    test "a foreign DOWN ref is ignored" do
      state = %{new_state() | agent_ref: make_ref()}
      {after_down, handled} = State.agent_down(state, make_ref(), :killed)
      assert handled == :ignored
      assert after_down.phase == :idle
      assert after_down.entries == []
    end
  end

  describe "stream_failed/2" do
    test "binary reasons are used verbatim, others are inspected" do
      state = State.stream_failed(new_state(), "[llm: HTTP 502]")
      assert {:system, "[llm: HTTP 502]"} in pairs(state)
      assert state.phase == :idle

      killed = State.stream_failed(new_state(), :killed)
      assert {:system, "[stream failed: :killed]"} in pairs(killed)
    end
  end

  describe "the reasoning block (issue #78)" do
    # The episode's thinking: three deltas over a one-second decode window.
    defp think(state, deltas \\ ["one ", "two ", "three "]) do
      deltas
      |> Enum.with_index()
      |> Enum.reduce(state, fn {text, i}, acc ->
        State.stream_message(acc, {:reasoning, text}, 1_000 + i * 500)
      end)
    end

    defp streaming, do: Map.put(new_state(), :phase, :streaming)

    defp settled(state),
      do: State.stream_message(state, {:phase, :idle}, 3_000)

    # Twenty NEWLINE-SEPARATED rows of thinking (one wrapped row each):
    # enough to overflow the 8-row window with predictable geometry.
    defp long_thinking(state) do
      lines = Enum.map(1..19, fn i -> "line #{i} of the reasoning trail\n" end)
      think(state, lines ++ ["line 20 of the reasoning trail"])
    end

    defp header(state) do
      state.entries
      |> Enum.find(&(&1.kind == :reasoning))
      |> then(fn entry -> Enum.map(entry.lines, &flatten/1) end)
      |> Enum.at(1)
    end

    # The expanded block's index — the app derives focus this way too
    # (expanded <=> focused, issue #78).
    defp expanded_index(state) do
      Enum.find_index(state.entries, &match?(%{kind: :reasoning, meta: %{expanded?: true}}, &1))
    end

    defp reasoning_entry(state, index \\ 0) do
      state.entries
      |> Enum.filter(&(&1.kind == :reasoning))
      |> Enum.at(index)
    end

    test "reasoning accumulates live, counts deltas, stamps its own window" do
      state = think(streaming())

      assert state.reasoning.text == "one two three "
      assert state.reasoning.tokens == 3
      assert state.reasoning.started_at == 1_000
      assert state.reasoning.last_at == 2_000
      assert state.reasoning.dirty

      # Content stats stay answer-only: ttft and tokens never see reasoning.
      assert state.stats.tokens == 0
      assert state.stats.first_token_at == nil
      assert state.in_flight == nil
    end

    test "a reasoning delta at idle is ignored like a late token" do
      state = State.stream_message(new_state(), {:reasoning, "stray"}, 1_000)
      assert state.reasoning == nil
    end

    test "the tick wraps the live block; its tail window auto-follows the stream" do
      state =
        streaming()
        |> long_thinking()
        |> State.tick(3_000)
        |> elem(0)

      rows = State.live_reasoning_rows(state)
      assert length(rows) == 2 + 8

      [blank, header | window] = rows
      assert flatten(blank) == ""
      assert flatten(header) == "◔ Thinking · 20 tokens"
      # The LAST eight rows show — the window pins to the thinking's tail.
      assert Enum.map(window, &flatten/1) ==
               for(i <- 13..20, do: "│ line #{i} of the reasoning trail")

      assert State.log_line_count(state) == 10
    end

    test "finalize collapses to the one-line summary; the full text stays the entry's truth" do
      state =
        streaming()
        |> think()
        |> then(&State.stream_message(&1, {:token, "ans"}, 2_500))
        |> settled()

      assert Enum.map(state.entries, & &1.kind) == [:reasoning, :assistant]

      block = reasoning_entry(state)
      assert block.text == "one two three "
      assert Enum.map(block.lines, &flatten/1) == ["", "◔ Thinking · 3 tokens · 1s"]
      assert block.meta.tokens == 3
      assert block.meta.ms == 1_000
      assert block.meta.expanded? == false

      # The live block is spent.
      assert state.reasoning == nil
      assert State.live_reasoning_rows(state) == nil
      assert State.log_line_count(state) == 4
    end

    test "blank-only thinking renders nothing" do
      state =
        streaming()
        |> think([" ", " "])
        |> settled()

      assert state.entries == []
      assert state.reasoning == nil
    end

    test "Ctrl+R with no reasoning block anywhere is a no-op" do
      state =
        new_state()
        |> State.stream_message({:entry, :system, "plain"})
        |> press("r", ["ctrl"])

      assert pairs(state) == [{:system, "plain"}]
    end

    test "an empty-string delta opens a live block that renders its header only" do
      state = State.stream_message(streaming(), {:reasoning, ""}, 1_000)
      assert State.live_reasoning_rows(state) == nil

      # Once real text lands but before any tick, the live block is its
      # header alone — the tail window waits for the bounded refresh.
      pending = State.stream_message(state, {:reasoning, "words"}, 1_100)
      [blank, header | tail] = State.live_reasoning_rows(pending)
      assert flatten(blank) == ""
      assert flatten(header) == "◔ Thinking · 2 tokens"
      assert tail == []
    end

    test "a second tick with nothing dirty re-wraps nothing" do
      thinking = think(streaming())
      {ticked, :cont} = State.tick(thinking, 2_000)
      lines = ticked.reasoning.lines
      {again, :cont} = State.tick(ticked, 2_125)
      assert again.reasoning.lines == lines
    end

    test "resize re-wraps the live block's window" do
      thinking = long_thinking(streaming())
      {ticked, :cont} = State.tick(thinking, 3_000)
      wide = length(ticked.reasoning.lines)

      narrow = State.resize(ticked, 30, 24)
      assert length(narrow.reasoning.lines) > wide
    end

    test "expanding a block above the viewport reveals it at the window's top" do
      # A long transcript, the thinking block early in it, parked at the tail.
      state =
        streaming()
        |> State.stream_message({:reasoning, "early thinking\nline two"}, 1_000)
        |> State.stream_message({:phase, :idle}, 2_000)
        |> then(fn s ->
          Enum.reduce(1..30, s, fn i, acc ->
            State.stream_message(acc, {:entry, :system, "filler row #{i}"})
          end)
        end)

      # Following the tail, the early block sits above the viewport.
      assert state.follow?
      assert State.effective_scroll(state, 13) > 0

      revealed = press(state, "r", ["ctrl"])
      block_top = Enum.find_index(state.entries, &(&1.kind == :reasoning))

      top =
        state.entries
        |> Enum.take(block_top)
        |> Enum.reduce(0, &(&2 + length(&1.lines)))

      assert State.effective_scroll(revealed, 13) == top
    end

    test "unscoped home/end still reach the composer (nothing expanded)" do
      {homed, nil} = State.handle_key(new_state(), "home", [])
      {ended, nil} = State.handle_key(homed, "end", [])
      assert ended.entries == []
    end

    test "Ctrl+R expands the last block into the hinted 8-row window with a position footer" do
      settled_state =
        streaming()
        |> long_thinking()
        |> settled()

      assert Enum.map(reasoning_entry(settled_state).lines, &flatten/1) == [
               "",
               "◔ Thinking · 20 tokens · 9.5s"
             ]

      expanded_state = press(settled_state, "r", ["ctrl"])
      expanded = reasoning_entry(expanded_state)

      rows = Enum.map(expanded.lines, &flatten/1)
      assert hd(rows) == ""
      assert Enum.at(rows, 1) == "◔ Thinking · 20 tokens · 9.5s · ↑↓ scroll · ctrl+r close"
      assert Enum.at(rows, 2) == "│ line 1 of the reasoning trail"
      assert length(rows) == 2 + 8 + 1
      assert List.last(rows) == "└ 1–8/20"
      assert expanded.meta.expanded?
      assert expanded.meta.view == 0

      assert expanded_index(expanded_state) ==
               Enum.find_index(expanded_state.entries, &(&1.kind == :reasoning))

      # A second Ctrl+R collapses and releases the focus.
      refolded = press(expanded_state, "r", ["ctrl"])
      assert reasoning_entry(refolded).meta.expanded? == false
      assert expanded_index(refolded) == nil
    end

    test "content shorter than the window shows whole with no footer" do
      expanded =
        streaming()
        |> think(["short thought"])
        |> settled()
        |> press("r", ["ctrl"])

      rows = Enum.map(reasoning_entry(expanded).lines, &flatten/1)

      assert rows == [
               "",
               "◔ Thinking · 1 tokens · 0s · ↑↓ scroll · ctrl+r close",
               "│ short thought"
             ]
    end

    test "expanding one block collapses the other — one window at a time" do
      state =
        streaming()
        |> think(["first think "])
        |> State.stream_message({:token, "a"}, 1_500)
        |> State.stream_message({:phase, :executing_tool}, 1_600)
        |> think(["second think "])
        |> State.stream_message({:token, "b"}, 2_500)
        |> settled()

      assert Enum.map(state.entries, & &1.kind) == [
               :reasoning,
               :assistant,
               :reasoning,
               :assistant
             ]

      # Click-expand the FIRST block (row 1 is its header)…
      {anchored, _no_copy} = State.select_mouse(state, "down", 10, 4, [])
      {released, _no_copy2} = State.select_mouse(anchored, "up", 10, 4, [])
      assert reasoning_entry(released, 0).meta.expanded?

      # …then Ctrl+R expands the LAST: the first folds back.
      switched = press(released, "r", ["ctrl"])
      refute reasoning_entry(switched, 0).meta.expanded?
      assert reasoning_entry(switched, 1).meta.expanded?
      assert expanded_index(switched) != nil
    end

    test "focused keys scroll inside the block and clamp at both ends" do
      state =
        streaming()
        |> long_thinking()
        |> settled()
        |> press("r", ["ctrl"])

      down = press(state, "down", [])
      assert reasoning_entry(down).meta.view == 1

      up = press(down, "up", [])
      assert reasoning_entry(up).meta.view == 0

      # Two page-downs clamp at the end (max view 12 over 20 rows).
      paged = press(press(up, "page_down", []), "page_down", [])
      assert reasoning_entry(paged).meta.view == 12

      back = press(paged, "page_up", [])
      assert reasoning_entry(back).meta.view == 4

      ended = press(back, "end", [])
      assert reasoning_entry(ended).meta.view == 12
      ended_rows = Enum.map(reasoning_entry(ended).lines, &flatten/1)
      assert List.last(ended_rows) == "└ 13–20/20"

      # Past the end stays clamped; home returns to the top.
      past = press(ended, "down", [])
      assert reasoning_entry(past).meta.view == 12
      assert reasoning_entry(press(past, "home", [])).meta.view == 0
    end

    test "a wheel notch over the expanded rows scrolls the block, not the log" do
      state =
        streaming()
        |> long_thinking()
        |> settled()
        |> press("r", ["ctrl"])

      # Screen row 3 is the log's first row (margin 2 + status 1); the block
      # header sits at content row 1 → screen row 4. Notch on a content row.
      wheeled = State.wheel_scroll(state, :up, {10, 6})

      # Already at the top: clamped, and the view never unfollowed.
      assert reasoning_entry(wheeled).meta.view == 0
      assert wheeled.follow?

      down = State.wheel_scroll(wheeled, :down, {10, 6})
      assert reasoning_entry(down).meta.view == 3
      assert down.follow?

      # A notch OUTSIDE the block's rows (the status bar) is the transcript's.
      outside = State.wheel_scroll(down, :down, {10, 6 + 100})
      assert reasoning_entry(outside).meta.view == 3
    end

    test "a selection below the expanded block clears; one above survives" do
      # Blocks among filler rows: expand one and select around it.
      base =
        new_state()
        |> State.stream_message({:entry, :system, "filler above"})
        |> then(fn s ->
          Enum.reduce(1..3, s, fn i, acc ->
            acc
            |> Map.put(:phase, :streaming)
            |> State.stream_message({:reasoning, "block #{i} line one\nline two"}, 1_000)
            |> State.stream_message({:phase, :idle}, 1_500)
          end)
        end)
        |> State.stream_message({:entry, :system, "filler below"})

      block_index = Enum.find_index(base.entries, &(&1.kind == :reasoning))

      # Select BELOW the block, then expand it: the insertion shifts the
      # selected rows — the selection clears (the resize precedent).
      {anchored, _no_copy} = State.select_mouse(base, "down", 10, 20, [])
      {dragged, _no_copy} = State.select_mouse(anchored, "drag", 10, 21, [])
      assert dragged.selection != nil

      expanded = press(dragged, "r", ["ctrl"])
      assert expanded.selection == nil

      # A selection entirely ABOVE the block is stable under the insertion.
      {anchored_above, _no_copy} = State.select_mouse(expanded, "down", 10, 4, [])
      {dragged_above, _no_copy} = State.select_mouse(anchored_above, "drag", 10, 5, [])
      assert dragged_above.selection != nil

      refolded = press(dragged_above, "r", ["ctrl"])
      assert refolded.selection != nil
      refute Enum.at(refolded.entries, block_index).meta.expanded?
    end

    test "a selection SPANNING the block's first row clears too (round-2 hole)" do
      base =
        new_state()
        |> State.stream_message({:entry, :system, "row above the block"})
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:reasoning, "span target one\nspan target two"}, 1_000)
        |> State.stream_message({:phase, :idle}, 1_500)
        |> State.stream_message({:entry, :system, "row below the block"})

      # Anchor on the system row ABOVE the block, drag DOWN into it: the
      # selection spans the insertion — it must clear, not survive with
      # shifted content under its highlight.
      rows = Enum.reduce(base.entries, [], &(&2 ++ Enum.map(&1.lines, fn l -> flatten(l) end)))

      block_top = Enum.find_index(rows, &String.starts_with?(&1, "◔"))

      # Screen row = content row + log.y (margin 2 + status 1). Anchor on
      # the system row ABOVE the block's blank separator — a row the OLD
      # from-row predicate would have kept, so this test pins the spanning
      # hole itself.
      anchor_y = 3 + block_top - 2
      into_y = 3 + block_top + 1

      {anchored, _no_copy} = State.select_mouse(base, "down", 10, anchor_y, [])
      spanning = elem(State.select_mouse(anchored, "drag", 10, into_y, []), 0)
      assert spanning.selection != nil

      expanded = press(spanning, "r", ["ctrl"])
      assert expanded.selection == nil
    end

    test "a wheel over a collapsed block scrolls the transcript (position scopes only the expanded window)" do
      # A log long enough to scroll: a notch on the collapsed block's rows
      # unfollows the transcript (the real contract) and never opens the
      # block's inner window.
      filler = {:entry, :system, Enum.map_join(1..40, "\n", &"row #{&1}")}

      state =
        new_state()
        |> State.stream_message(filler)
        |> Map.put(:phase, :streaming)
        |> long_thinking()
        |> State.stream_message({:phase, :idle}, 9_000)

      assert state.follow?
      before = State.effective_scroll(state, 13)

      wheeled = State.wheel_scroll(state, :up, {10, 4})
      assert reasoning_entry(wheeled).meta.view == 0
      refute wheeled.follow?
      assert State.effective_scroll(wheeled, 13) < before
    end

    test "Esc while focused and idle closes the block; Esc while streaming keeps its interrupt" do
      state =
        streaming()
        |> think()
        |> settled()
        |> press("r", ["ctrl"])

      assert expanded_index(state) != nil

      closed = press(state, "esc", [])
      assert expanded_index(closed) == nil
      assert reasoning_entry(closed).meta.expanded? == false

      {streaming_focus, :cancel} =
        state
        |> Map.put(:phase, :streaming)
        |> State.handle_key("esc", [])

      assert expanded_index(streaming_focus) != nil
      assert reasoning_entry(streaming_focus).meta.expanded?
    end

    test "thinking arriving under a parked view never yanks it (the #131 principle)" do
      # A long transcript, parked two notches off the tail.
      long_entry = {:entry, :system, Enum.map_join(1..40, "\n", &"row #{&1}")}
      base = State.stream_message(new_state(), long_entry)

      parked =
        base
        |> State.wheel_scroll(:up)
        |> State.wheel_scroll(:up)

      offset = State.effective_scroll(parked, 13)
      refute parked.follow?

      grew =
        parked
        |> Map.put(:phase, :streaming)
        |> long_thinking()
        |> State.tick(3_000)
        |> elem(0)

      # The window froze: the top-anchored intent ignores rows appended below.
      assert State.effective_scroll(grew, 13) == offset
      refute grew.follow?
    end

    test "replay renders the collapsed block from stored content with no stats" do
      state =
        new_state(
          transcript: [
            %{"role" => "user", "content" => "q"},
            %{
              "role" => "assistant",
              "content" => "a",
              "reasoning_content" => "the stored thinking"
            }
          ]
        )

      block = reasoning_entry(state)
      assert block.text == "the stored thinking"
      assert Enum.map(block.lines, &flatten/1) == ["", "◔ Thinking"]
      # No stats keys at all — the header renders the bare label.
      assert Map.get(block.meta, :tokens) == nil
      assert Map.get(block.meta, :ms) == nil

      # The full content is reachable: expansion wraps the stored text.
      expanded = press(state, "r", ["ctrl"])
      rows = Enum.map(reasoning_entry(expanded).lines, &flatten/1)
      assert rows == ["", "◔ Thinking · ↑↓ scroll · ctrl+r close", "│ the stored thinking"]
    end

    test "resize re-wraps the expanded window and clamps the inner view" do
      state =
        streaming()
        |> long_thinking()
        |> settled()
        |> press("r", ["ctrl"])

      deep = press(press(press(state, "page_down", []), "page_down", []), "end", [])
      assert reasoning_entry(deep).meta.view == 12

      # A narrow frame re-wraps the content longer: the inner intent SURVIVES
      # numerically and re-clamps (the scroll-intent rule, ADR 0006), and the
      # footer reads over the new geometry.
      narrow = State.resize(deep, 30, 24)
      entry = reasoning_entry(narrow)
      total = length(entry.meta.content_lines)
      max_view = total - 8
      assert total > 20
      assert entry.meta.view == 12

      bottom = press(narrow, "end", [])
      assert reasoning_entry(bottom).meta.view == max_view

      bottom_rows = Enum.map(reasoning_entry(bottom).lines, &flatten/1)
      assert List.last(bottom_rows) == "└ #{max_view + 1}–#{total}/#{total}"
    end

    test "/clear spends the live block and the focus" do
      cleared =
        streaming()
        |> long_thinking()
        |> settled()
        |> press("r", ["ctrl"])
        |> type("/clear")
        |> then(&State.handle_key(&1, "enter", []))
        |> elem(0)

      assert cleared.entries == []
      assert expanded_index(cleared) == nil
      assert cleared.reasoning == nil
    end
  end

  describe "resize/3" do
    test "records the new size" do
      state = State.resize(new_state(), 120, 40)
      assert state.size == {120, 40}
    end

    test "degenerate sizes clamp to 1x1" do
      state = State.resize(new_state(), 0, -3)
      assert state.size == {1, 1}
    end

    test "a whitespace run overflowing an empty row drops without a phantom blank" do
      # Regression (review N2): marking an empty row full used to push a
      # blank display row and inflate the log count.
      base = new_state(test_mode: {10, 24})
      text = String.duplicate(" ", 24) <> "x = 1"
      state = State.stream_message(base, {:entry, :system, text})

      [entry] = state.entries

      assert Enum.map(entry.lines, &flatten/1) == ["", "x = 1"]
      assert State.log_line_count(state) == 2
    end

    test "entries re-wrap to the new width without losing text" do
      text = "the quick brown fox jumps over the lazy dog"

      state =
        new_state()
        |> State.stream_message({:entry, :system, text})
        |> State.resize(20, 24)

      [entry] = state.entries
      assert entry.text == text

      # One logical line becomes wrapped display rows, blank separator first;
      # every word survives the wrap (spaces at break points are dropped by
      # design — comparing word sequences, not raw concatenation).
      pieces = Enum.map(entry.lines, &flatten/1)
      assert hd(pieces) == ""

      assert_words_survive(pieces, text)
      tail = tl(pieces)
      assert Enum.all?(tail, &(&1 == "" or String.length(&1) <= 18))
    end

    test "re-wrapping is exact in both directions" do
      text = Enum.map_join(1..15, fn _i -> "word " end)

      state =
        new_state()
        |> State.stream_message({:entry, :system, text})
        |> State.resize(16, 24)

      assert State.log_line_count(state) > 2

      widened = State.resize(state, 80, 24)
      [entry] = widened.entries

      # Back at the original width the display is the logical render again.
      assert State.log_line_count(widened) == 2
      assert Enum.map_join(entry.lines, &flatten/1) == text
    end

    test "a same-size or height-only resize re-wraps nothing" do
      state = State.stream_message(new_state(), {:entry, :system, "some long line here"})

      assert State.resize(state, 80, 24) == state
      assert State.resize(state, 80, 40).entries == state.entries
    end

    test "the in-flight reply re-renders to the new width immediately" do
      text = "one two three four five six seven eight nine ten"

      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, text}, 1_000)
        |> tick_once()

      narrow = State.resize(state, 15, 24)

      refute narrow.in_flight_lines == state.in_flight_lines
      assert State.log_line_count(narrow) > State.log_line_count(state)
      assert_words_survive(Enum.map(narrow.in_flight_lines, &flatten/1), text)
    end

    test "an above-cap in-flight reply clears its live view across a width change" do
      # Above the cap no fresh render is possible until finalize, and the
      # stale one is at the OLD width — rendering it into the narrower pane
      # would truncate at the edge (the #20 symptom). The live view clears
      # instead; the reply reappears when it finalizes.
      over_cap = String.duplicate("x", 64 * 1024) <> "y"

      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, over_cap}, 1_000)
        |> tick_once()

      assert state.in_flight_lines == nil
      assert State.resize(state, 40, 24).in_flight_lines == nil
    end

    test "resize tolerates entries built without logical lines" do
      hand_built = %{kind: :user, text: "hi", lines: Render.entry_lines(:user, "hi")}
      state = %{new_state() | entries: [hand_built]}

      resized = State.resize(state, 40, 24)
      [entry] = resized.entries
      assert length(entry.lines) >= 2
    end

    test "wrap accounting and the windowed view agree after resize (no drift)" do
      # 40 entries, each long enough to wrap several times at width 18.
      full =
        Enum.reduce(1..40, new_state(), fn i, acc ->
          State.stream_message(acc, {:entry, :system, "entry number #{i} with plenty of words"})
        end)

      state = State.resize(full, 18, 24)

      # The view's own log height drives both the offset math and the slice.
      log_height = View.regions(state.size, 1, false).log.height
      total = State.log_line_count(state)
      assert total > log_height

      # Follow: the bottom of the window is the last display row.
      {viewed, _widget} =
        state
        |> View.render(%ExRatatui.Frame{width: 18, height: 24})
        |> Enum.at(1)

      visible = Enum.map(viewed.text, &flatten/1)
      assert length(visible) == log_height
      assert State.effective_scroll(state, log_height) == total - log_height
      assert Enum.all?(visible, &(&1 == "" or String.length(&1) <= 18))

      # Paging up twice moves exactly two viewports up the display list, and
      # the shown rows are the accounting's rows — no gaps, no repeats.
      {paged, nil} = State.handle_key(state, "page_up", [])
      {paged2, nil} = State.handle_key(paged, "page_up", [])

      offset = State.effective_scroll(paged2, log_height)
      all = Enum.flat_map(paged2.entries, & &1.lines)

      {viewed2, _widget2} =
        paged2
        |> View.render(%ExRatatui.Frame{width: 18, height: 24})
        |> Enum.at(1)

      expected =
        all
        |> Enum.drop(offset)
        |> Enum.take(log_height)
        |> Enum.map(&flatten/1)

      assert Enum.map(viewed2.text, &flatten/1) == expected
    end

    test "follow stays pinned to the re-wrapped bottom across resize" do
      state =
        Enum.reduce(1..20, new_state(), fn i, acc ->
          State.stream_message(acc, {:entry, :system, "wrapped words number #{i} keep coming"})
        end)

      narrow = State.resize(state, 12, 24)
      assert narrow.follow?
      assert State.effective_scroll(narrow, 24) == State.log_line_count(narrow) - 24
    end
  end

  describe "paste/2" do
    test "inserts multi-line text at the cursor" do
      state = State.paste(new_state(), "line one\nline two")
      assert State.input_text(state) == "line one\nline two"
    end

    test "CRLF and lone CR are normalized to LF" do
      state = State.paste(new_state(), "a\r\nb\rc\r\n\rd")
      assert State.input_text(state) == "a\nb\nc\n\nd"
    end

    test "pasting while browsing history keeps the edited text as the draft" do
      base = idle_submit(new_state(), "prev")

      {browsing, nil} = State.handle_key(base, "up", [])
      pasted = State.paste(browsing, "pasted")
      assert pasted.history_index == nil
      assert State.input_text(pasted) == "prevpasted"

      {after_down, nil} = State.handle_key(pasted, "down", [])
      assert State.input_text(after_down) == "prevpasted"
    end
  end

  defp flatten(%ExRatatui.Text.Line{spans: spans}), do: Enum.map_join(spans, "", & &1.content)

  # Wrap drops whitespace at break points, so concatenation is width-luck;
  # word sequences are the honest no-loss assertion.
  defp assert_words_survive(pieces, text) do
    joined = Enum.join(pieces, " ")
    assert String.split(joined) == String.split(text)
  end

  describe "the startup phase (ADR 0009)" do
    test "setup_paste feeds wizard text steps and is inert on the selection modal" do
      started = Onboarding.new()
      {name_step, _nil} = Onboarding.handle_key(started, "enter")
      name_state = setup_state(setup: name_step)
      pasted = State.setup_paste(name_state, "PLACEHOLDER-key\r\n")
      assert pasted.setup.draft == "personalPLACEHOLDER-key"

      # The forced-selection modal owns no text input: a paste changes
      # nothing (P1-2 — it can never reach the composer instead).
      modal = setup_state(setup: {:select, ["a", "b"], 0})
      assert State.setup_paste(modal, "anything") == modal
    end

    test "P1-3 regression: Inspect never prints the wizard's key (crash-log leak)" do
      # The reviewer's 4-line crash-report repro: State.setup holds the
      # plaintext key (draft / pending.key); a TUI crash used to dump it
      # into the log. The derivations must redact — Config.ex is the house
      # reference pattern.
      wizard =
        Enum.reduce(
          ["enter", "enter", "enter", "enter", "k", "e", "y", "enter"],
          Onboarding.new(),
          fn key, wizard ->
            {wizard, _action} = Onboarding.handle_key(wizard, key)
            wizard
          end
        )

      assert wizard.pending.key == "key"

      state = setup_state(setup: wizard)
      refute inspect(state) =~ "key: \"key\""
      refute inspect(state) =~ ~s(pending: %{)
      assert inspect(state) =~ "..."

      # The wizard alone redacts too (standalone logs, IEx).
      refute inspect(wizard) =~ ~s(key: "key")
      refute inspect(wizard) =~ ~s(draft: "key")
    end

    defp setup_state(opts \\ []) do
      [test_mode: {80, 24}]
      |> Keyword.merge(opts)
      |> State.new()
    end

    test "the forced-selection modal moves with up/down and commits with Enter" do
      state = setup_state(setup: {:select, ["a", "b"], 0})

      moved_state = state

      {up, nil} = State.handle_key(moved_state, "up", [])
      assert up.setup == {:select, ["a", "b"], 1}

      {moved, nil} = State.handle_key(moved_state, "down", [])
      assert moved.setup == {:select, ["a", "b"], 1}

      {wrapped, nil} = State.handle_key(moved, "down", [])
      assert wrapped.setup == {:select, ["a", "b"], 0}

      {chosen, {:select_profile, "b"}} = State.handle_key(moved, "enter", [])
      assert chosen.setup == {:select, ["a", "b"], 1}
    end

    defp step_wizard(key, wizard) do
      {wizard, _action} = Onboarding.handle_key(wizard, key)
      wizard
    end

    test "the wizard routes through the setup branch: typing and stepping" do
      state = setup_state(setup: Onboarding.new())

      {welcome, nil} = State.handle_key(state, "enter", [])
      assert welcome.setup.step == :profile_name

      {named, nil} = State.handle_key(welcome, "w", [])
      assert named.setup.draft =~ "w"
    end

    test "other keys fall through the setup branch untouched" do
      state = setup_state(setup: {:select, ["a"], 0})
      {same, nil} = State.handle_key(state, "x", [])
      assert same.setup == {:select, ["a"], 0}
    end

    test "provider_resolved clears setup, sets the provider, and emits the agent handoff" do
      state = setup_state(setup: {:select, ["a"], 0})
      config = %DashFloat.Config{base_url: "https://x.example", model: "m", api_key: "k"}

      {resolved, {:agent_provider, {:ok, ^config}}} =
        State.provider_resolved(state, {:ok, config})

      assert resolved.setup == nil
      assert resolved.provider == {:ok, config}
    end

    test "models_arrived feeds a waiting wizard and ignores stale results" do
      start = Onboarding.new()
      keys = ["enter", "enter", "enter", "enter", "k", "enter", "enter"]

      wizard = Enum.reduce(keys, start, &step_wizard/2)

      state = setup_state(setup: wizard)

      fed = State.models_arrived(state, {:ok, [%{model: "m1", context: nil}]})
      assert fed.setup.step == :model_pick

      stale = State.models_arrived(setup_state(), {:ok, [%{model: "late"}]})
      assert stale.setup == nil
    end

    test "setup_write_failed bounces a waiting wizard and is inert elsewhere (issue #39)" do
      at_done =
        Enum.reduce(
          ["enter", "enter", "down", "down", "down", "enter", "down", "down", "enter"],
          Onboarding.new(),
          &step_wizard/2
        )

      assert at_done.step == :done

      state = setup_state(setup: at_done)

      bounced = State.setup_write_failed(state, "settings.json5 already exists")
      assert bounced.setup.step == :loop
      assert bounced.setup.error == "settings.json5 already exists"
      assert bounced.setup.choice == 2

      # Off the wizard (the modal, or no setup at all) the feedback is inert.
      modal = setup_state(setup: {:select, ["a"], 0})
      assert State.setup_write_failed(modal, "late") == modal
    end

    test "catalog_arrived stores the sweep and fills the context denominator (ADR 0009)" do
      base = "https://provider.example/v1"

      config = %DashFloat.Config{
        base_url: base,
        model: "glm-5.3",
        api_key: "k",
        context_tokens: nil
      }

      state = setup_state(provider: {:ok, config})
      # No catalog yet and the model is absent from the seed table: the
      # documented default stands in (issue #111) — the footer always has a
      # denominator on a resolved provider.
      assert State.provider_context_tokens(state) == 131_072

      landed = State.catalog_arrived(state, %{base => [%{model: "glm-5.3", context: 128_000}]})

      # Observed metadata beats the default assumption (issue #111).
      assert State.provider_context_tokens(landed) == 128_000
      assert landed.catalog == %{base => [%{model: "glm-5.3", context: 128_000}]}

      # A configured context always wins over the catalog's metadata.
      configured = setup_state(provider: {:ok, %{config | context_tokens: 64_000}})

      filled =
        State.catalog_arrived(configured, %{base => [%{model: "glm-5.3", context: 128_000}]})

      assert State.provider_context_tokens(filled) == 64_000

      # A catalog entry without usable context falls to the documented
      # default (issue #111) — an unusable observed value assumes nothing.
      bare = setup_state(provider: {:ok, config})

      contextless =
        State.catalog_arrived(bare, %{
          base => [%{model: "glm-5.3", context: nil}]
        })

      assert State.provider_context_tokens(contextless) == 131_072
    end
  end

  describe "ghost text (ADR 0015 §3)" do
    @provider {:ok, %DashFloat.Config{base_url: "http://x", model: "m", api_key: "k"}}

    test "new/1 wires the suggest fetcher and debounce opts; the ghost fields start empty" do
      fetcher = {DashFloat.TUI.Suggest, :request}
      state = new_state(suggest_fetcher: fetcher, suggest_debounce_ms: 25)

      assert state.suggest_fetcher == fetcher
      assert state.suggest_debounce_ms == 25

      fresh = new_state()
      assert fresh.suggest_fetcher == nil
      assert fresh.suggest_debounce_ms == 600
      assert fresh.suggestion == nil
      assert fresh.suggest_epoch == 0
      assert fresh.suggest_arm == false
      assert fresh.suggest_reap == false
    end

    # One completed assistant turn (no usage frame — the rate is not the
    # subject here).
    defp turn_with_reply(state, reply) do
      state
      |> Map.put(:phase, :streaming)
      |> State.stream_message({:token, reply}, 1_000)
      |> State.stream_message({:phase, :idle}, 2_000)
    end

    test "a finalized assistant turn with an empty draft arms the one-shot" do
      base = new_state(provider: @provider)
      state = turn_with_reply(base, "all done")
      assert state.suggest_arm == true
    end

    test "a typed draft never arms" do
      base = new_state(provider: @provider)
      typed = type(base, "question")
      state = turn_with_reply(typed, "answer")

      assert state.suggest_arm == false
    end

    test "suggest: false never arms" do
      off =
        {:ok, %DashFloat.Config{base_url: "http://x", model: "m", api_key: "k", suggest: false}}

      state = turn_with_reply(new_state(provider: off), "answer")

      assert state.suggest_arm == false
    end

    test "a non-assistant last entry never arms" do
      base = new_state(provider: @provider)
      streaming = %{base | phase: :streaming}

      state =
        streaming
        |> State.stream_message({:token, "answer"}, 1_000)
        |> State.stream_message({:phase, :executing_tool}, 1_100)
        |> State.stream_message({:entry, :system, "note"}, 1_500)
        |> State.stream_message({:phase, :idle}, 2_000)

      assert state.suggest_arm == false
    end

    # agent_down(:normal) re-sends {:phase, :idle}: nothing finalizes, so
    # an already-consumed arm intent must not be re-armed into a SECOND
    # side-request for one turn (ADR 0015 §3).
    test "a re-sent idle does not re-arm the consumed intent" do
      base = new_state(provider: @provider)
      armed = turn_with_reply(base, "all done")
      assert armed.suggest_arm == true

      # The runner consumed the one-shot intent (tui.ex suggest_arm/1).
      consumed = %{armed | suggest_arm: false}

      state = State.stream_message(consumed, {:phase, :idle}, 3_000)

      assert state.suggest_arm == false
    end

    test "a tool interlude never arms (mid-turn), even after a reply" do
      base = new_state(provider: @provider)

      state =
        %{base | phase: :streaming}
        |> State.stream_message({:token, "answer"}, 1_000)
        |> State.stream_message({:phase, :executing_tool}, 1_100)

      assert state.suggest_arm == false
    end

    test "Tab materializes the ghost into the draft and dismisses it" do
      ghosted = %{new_state(provider: @provider) | suggestion: "tell me more"}

      {state, nil} = State.handle_key(ghosted, "tab", [])

      assert State.input_text(state) == "tell me more"
      assert state.suggestion == nil
      assert state.suggest_reap == true
    end

    test "Tab with a non-empty draft falls through — the draft is not replaced" do
      typed = type(new_state(provider: @provider), "h")
      ghosted = %{typed | suggestion: "tell me more"}

      {state, nil} = State.handle_key(ghosted, "tab", [])

      refute State.input_text(state) == "tell me more"
    end

    test "typing dismisses the ghost" do
      ghosted = %{new_state(provider: @provider) | suggestion: "tell me more"}
      state = type(ghosted, "x")

      assert state.suggestion == nil
      assert state.suggest_reap == true
    end

    test "a paste dismisses the ghost" do
      ghosted = %{new_state(provider: @provider) | suggestion: "tell me more"}
      state = State.paste(ghosted, "hello")

      assert state.suggestion == nil
      assert state.suggest_reap == true
    end

    test "a submit dismisses the ghost" do
      ghosted = %{new_state(provider: @provider) | suggestion: "tell me more"}
      typed = type(ghosted, "q")

      {state, {:submit, "q", []}} = State.handle_key(typed, "enter", [])

      assert state.suggestion == nil
      assert state.suggest_reap == true
      assert state.phase == :streaming
    end

    test "a new streaming phase dismisses the ghost" do
      ghosted = %{new_state(provider: @provider) | suggestion: "tell me more"}
      state = State.stream_message(ghosted, {:phase, :streaming}, 1_000)

      assert state.suggestion == nil
      assert state.suggest_reap == true
    end

    # Every new phase sets a reap intent (ADR 0015 §3) — a ghost must not
    # survive a tool interlude.
    test "an executing_tool phase dismisses the ghost" do
      ghosted = %{new_state(provider: @provider) | suggestion: "tell me more"}
      state = State.stream_message(ghosted, {:phase, :executing_tool}, 1_000)

      assert state.suggestion == nil
      assert state.suggest_reap == true
    end

    test "history navigation dismisses the ghost" do
      ghosted = %{
        new_state(provider: @provider)
        | suggestion: "tell me more",
          history: ["older"]
      }

      after_up = press(ghosted, "up", [])
      assert after_up.suggestion == nil
      assert after_up.suggest_reap == true

      # Down at the newest restores the draft — still a dismiss.
      after_down = press(after_up, "down", [])
      assert after_down.suggest_reap == true
    end
  end

  # Runs one animation tick (rendering dirty in-flight lines), keeping state.
  defp tick_once(state), do: elem(State.tick(state, 1_100), 0)

  # ADR 0014 §6: the resumed log is derived by replaying the loaded transcript
  # through the exact render path live entries use — the differential tests
  # below build a live state through the contract messages and assert the
  # replayed entries match it.
  describe "transcript replay" do
    # The persisted transcript shape, exactly as Session.load returns it:
    # string-keyed messages, opaque `function.arguments` JSON.
    defp transcript do
      [
        %{"role" => "user", "content" => "fix the bug"},
        %{
          "role" => "assistant",
          "content" => "Reading the file.",
          "tool_calls" => [
            %{
              "id" => "t1",
              "type" => "function",
              "function" => %{"name" => "read_file", "arguments" => ~s({"path": "lib/foo.ex"})}
            },
            %{
              "id" => "t2",
              "type" => "function",
              "function" => %{
                "name" => "execute_command",
                "arguments" => ~s({"command": "mix test"})
              }
            }
          ]
        },
        %{
          "role" => "tool",
          "tool_call_id" => "t1",
          "content" => Jason.encode!(%{ok: true, output: "line one\nline two"})
        },
        %{
          "role" => "tool",
          "tool_call_id" => "t2",
          "content" => Jason.encode!(Tools.cancelled_result())
        },
        %{"role" => "assistant", "content" => "Done."}
      ]
    end

    # The same turn as `transcript/0`, built live through the contract
    # messages: the submit echo, tokens, phase transitions, tool rows.
    defp live_state(size \\ {80, 24}) do
      ok = %{ok: true, output: "line one\nline two"}
      cancelled = Tools.cancelled_result()
      base = new_state(test_mode: size)

      base
      |> idle_submit("fix the bug")
      |> Map.put(:phase, :streaming)
      |> State.stream_message({:token, "Reading the file."}, 1_000)
      |> State.stream_message({:phase, :executing_tool}, 1_100)
      |> State.stream_message(
        {:tool_call, %{id: "t1", name: "read_file", args: %{"path" => "lib/foo.ex"}}}
      )
      |> State.stream_message(
        {:tool_call, %{id: "t2", name: "execute_command", args: %{"command" => "mix test"}}}
      )
      |> State.stream_message({:tool_result, display_msg("t1", "read_file", ok)})
      |> State.stream_message({:tool_result, display_msg("t2", "execute_command", cancelled)})
      |> Map.put(:phase, :streaming)
      |> State.stream_message({:token, "Done."}, 2_000)
      |> State.stream_message({:phase, :idle}, 2_100)
    end

    # The tool_result message the agent derives from a result: status and
    # excerpt come from the same Tools helpers the replay uses (ADR 0014 §6).
    defp display_msg(id, name, result) do
      %{
        id: id,
        name: name,
        ok: result[:ok] == true,
        status: Tools.display_status(result),
        output: Tools.display_excerpt(result)
      }
    end

    test "replayed entries match the live contract kind-for-kind, text-for-text" do
      replayed = new_state(transcript: transcript())

      assert pairs(replayed) == pairs(live_state())
      # Same render pipeline at the same width: logical and wrapped lines too.
      assert replayed.entries == live_state().entries
    end

    test "the stored system message replays as nothing — the prompt is re-derived at boot (ADR 0019)" do
      # A session saved since ADR 0019 always carries the system message
      # first; a resume of one crashed at mount until the skip landed
      # (issue #113's restore dance).
      replayed =
        new_state(
          transcript: [%{"role" => "system", "content" => "You are DashFloat."} | transcript()]
        )

      assert pairs(replayed) == pairs(live_state())
    end

    test "entries wrap at the construction width, exactly like live entries" do
      wide = new_state(transcript: transcript())
      narrow = new_state(test_mode: {20, 24}, transcript: transcript())

      assert State.log_line_count(narrow) > State.log_line_count(wide)
      assert narrow.entries == live_state({20, 24}).entries
    end

    test "assistant rows ride the markdown path" do
      md = "# Title\n\nSome **bold** text."

      state = new_state(transcript: [%{"role" => "assistant", "content" => md}])

      live =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, md}, 1_000)
        |> State.stream_message({:phase, :idle}, 1_100)

      assert state.entries == live.entries
    end

    # ADR 0018 §2's persistence coordination: an image-bearing user turn
    # loads as a parts list, and the replay must render it — the
    # concatenated text parts as the body, one dim 📎 row per image part —
    # never crash the render path (hostile review finding 1: a resumed
    # image session must boot).
    test "an image-bearing user turn replays with its indicator rows" do
      image_turn = %{
        "role" => "user",
        "content" => [
          %{"type" => "text", "text" => "what is this?"},
          %{
            "type" => "image_url",
            "image_url" => %{"url" => "data:image/png;base64,aGVsbG8="}
          }
        ]
      }

      replayed =
        new_state(transcript: [image_turn, %{"role" => "assistant", "content" => "a cat."}])

      assert [
               %{kind: :user, text: "what is this?"} = user,
               %{kind: :assistant, text: "a cat."}
             ] = replayed.entries

      assert Enum.map_join(user.lines, "\n", &flatten/1) =~ "📎 image"
    end

    test "an image-only turn replays with an empty body and its indicator" do
      image_only = %{
        "role" => "user",
        "content" => [
          %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,aGVsbG8="}}
        ]
      }

      replayed = new_state(transcript: [image_only])
      assert [%{kind: :user} = user] = replayed.entries
      assert Enum.map_join(user.lines, "\n", &flatten/1) =~ "📎 image"
    end

    # Issue #107: the resumed log keeps the user/assistant distinction —
    # replay rides Render.entry_lines/2 (the one styler), so the replayed
    # user rows carry the bold :user role and the accent ❯ prefix, while
    # the assistant rows stay plain.
    test "a replayed user turn keeps the bold :user style and the accent prefix" do
      transcript = [
        %{"role" => "user", "content" => "first question"},
        %{"role" => "assistant", "content" => "an answer."}
      ]

      assert [%{kind: :user} = user, %{kind: :assistant} = assistant] =
               new_state(transcript: transcript).entries

      user_style = Theme.style(:user)
      accent_bold = %{Theme.style(:accent) | modifiers: [:bold]}

      [_sep, first | rest] = user.lines

      assert [%ExRatatui.Text.Span{content: "❯ ", style: ^accent_bold}, %{style: ^user_style}] =
               first.spans

      assert Enum.all?(rest, fn line ->
               Enum.all?(line.spans, &(&1.style == user_style))
             end)

      assert Enum.all?(assistant.lines, fn line ->
               Enum.all?(line.spans, &(&1.style == %ExRatatui.Style{}))
             end)
    end

    test "arguments that do not decode render the (invalid arguments) arm" do
      transcript = [
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => "t1",
              "type" => "function",
              "function" => %{"name" => "read_file", "arguments" => "{not json"}
            }
          ]
        }
      ]

      assert pairs(new_state(transcript: transcript)) == [
               {:tool, "⚙ read_file (invalid arguments)"}
             ]
    end

    test "a tool result that does not decode renders an error row, never a crash" do
      transcript = [
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => "t1",
              "type" => "function",
              "function" => %{"name" => "read_file", "arguments" => "{}"}
            }
          ]
        },
        %{"role" => "tool", "tool_call_id" => "t1", "content" => "garbage"}
      ]

      assert pairs(new_state(transcript: transcript)) == [
               {:tool, "⚙ read_file"},
               {:tool, "⚙ read_file → error"}
             ]
    end

    test "a tool message answering an id no batch announced degrades to the literal name" do
      # Belt over the loader's orphan refusal: a hand-built transcript handed
      # straight to new/1 must render a row, never raise on the mount.
      transcript = [
        %{"role" => "user", "content" => "go"},
        %{"role" => "tool", "tool_call_id" => "ghost", "content" => ~s({"ok":true})}
      ]

      assert pairs(new_state(transcript: transcript)) == [
               {:user, "go"},
               {:tool, "⚙ tool → ok"}
             ]
    end

    test "a blocked plan result renders proposed (plan), not error" do
      # The plan-mode proposal's stored result shape (ADR 0016 §4); replay
      # must carry "blocked" through or resume shows a bogus error row.
      transcript = [
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => "t1",
              "type" => "function",
              "function" => %{"name" => "write_file", "arguments" => ~s({"path": "lib/x.ex"})}
            }
          ]
        },
        %{
          "role" => "tool",
          "tool_call_id" => "t1",
          "content" => ~s({"ok":false,"blocked":"plan"})
        }
      ]

      assert pairs(new_state(transcript: transcript)) == [
               {:tool, "⚙ write_file lib/x.ex"},
               {:tool, "⚙ write_file → proposed (plan)"}
             ]
    end

    test "a nil-content assistant with calls produces no empty assistant entry" do
      transcript = [
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => "t1",
              "type" => "function",
              "function" => %{"name" => "list_directory", "arguments" => "{}"}
            }
          ]
        },
        %{"role" => "tool", "tool_call_id" => "t1", "content" => Jason.encode!(%{ok: true})}
      ]

      assert pairs(new_state(transcript: transcript)) == [
               {:tool, "⚙ list_directory"},
               {:tool, "⚙ list_directory → ok"}
             ]
    end

    test "the resumed log opens pinned at the bottom" do
      state = new_state(transcript: transcript())

      assert state.follow?
      assert state.scroll == 0

      height = 5
      bottom = State.effective_scroll(state, height)
      assert bottom == State.log_line_count(state) - height
      assert bottom > 0
    end

    test "the resume note lands last as a system entry" do
      note = "[resuming session pinned to a/m under b/m — continuing]"
      state = new_state(transcript: transcript(), resume_note: note)

      assert pairs(state) == pairs(new_state(transcript: transcript())) ++ [{:system, note}]
    end

    test "an empty transcript behaves exactly as today" do
      assert new_state().entries == []
      assert new_state(transcript: []).entries == []
      assert new_state(transcript: [], resume_note: nil).entries == []
    end
  end

  ## Slash commands and the palette (ADR 0020)

  describe "slash filter palette (ADR 0020)" do
    test "typing a slash prefix derives the popup, selected 0" do
      state = type(new_state(), "/he")

      assert %{mode: :filter, kind: :commands, selected: 0} = state.palette
      assert Enum.map(state.palette.items, & &1.name) == ["help"]
    end

    test "typing narrows the matches and resets the selection" do
      typed = type(new_state(), "/")
      broad = press(typed, "down", [])

      assert length(broad.palette.items) == 9
      assert broad.palette.selected == 1

      narrow = type(broad, "c")
      assert Enum.map(narrow.palette.items, & &1.name) == ["clear", "compact"]
      assert narrow.palette.selected == 0
    end

    test "an edit that keeps the match set keeps the selection" do
      typed = type(new_state(), "/mod")
      state = press(typed, "down", [])

      assert Enum.map(state.palette.items, & &1.name) == ["mode", "model"]

      kept = type(state, "e")
      assert Enum.map(kept.palette.items, & &1.name) == ["mode", "model"]
      assert kept.palette.selected == 1
    end

    test "a non-matching prefix shows nothing" do
      state = type(new_state(), "/zz")
      assert state.palette == nil
    end

    test "a typed space ends the token: the popup dismisses, the draft keeps the args" do
      state = type(new_state(), "/mode ")

      assert state.palette == nil
      assert State.input_text(state) == "/mode "
    end

    test "esc dismisses until the next edit re-derives" do
      typed = type(new_state(), "/he")
      dismissed = press(typed, "esc", [])

      assert dismissed.palette == nil

      redone = press(dismissed, "l", [])
      assert %{mode: :filter} = redone.palette
    end

    test "esc's dismissal survives cursor-only keys; a cursor move keeps an open popup" do
      typed = type(new_state(), "/he")
      dismissed = press(typed, "esc", [])
      moved = press(dismissed, "left", [])

      assert moved.palette == nil
      assert State.input_text(moved) == "/he"

      cursor = press(typed, "left", [])
      assert %{mode: :filter} = cursor.palette
    end

    test "shift+tab and back_tab are swallowed while the filter popup is open" do
      typed = type(new_state(), "/he")

      assert {swallowed, nil} = State.handle_key(typed, "tab", ["shift"])
      assert swallowed == typed

      assert {back, nil} = State.handle_key(typed, "back_tab", [])
      assert back == typed
    end

    # Tab completes to the SELECTED match (issue #105; ADR 0020's
    # 2026-10-31 amendment): "/name " — trailing space closes the popup and
    # leaves room for args; the cursor lands at the end, editable.
    test "tab completes the draft to the highlighted match with a trailing space" do
      typed = type(new_state(), "/mod")

      assert Enum.map(typed.palette.items, & &1.name) == ["mode", "model"]

      {completed, nil} = State.handle_key(typed, "tab", [])

      assert State.input_text(completed) == "/mode "
      assert completed.palette == nil
    end

    test "tab honors the arrow-key selection, not just the head of the list" do
      state =
        new_state()
        |> type("/mod")
        |> press("down", [])

      assert state.palette.selected == 1

      {completed, nil} = State.handle_key(state, "tab", [])

      assert State.input_text(completed) == "/model "
      assert completed.palette == nil
    end

    test "a completion from a history-recalled draft leaves history" do
      recalled = press(%{new_state() | history: ["/mode"]}, "up", [])

      assert recalled.history_index == 0
      assert %{mode: :filter} = recalled.palette

      {completed, nil} = State.handle_key(recalled, "tab", [])

      assert completed.history_index == nil
      assert State.input_text(completed) == "/mode "
    end

    test "up/down move the popup selection and never touch history" do
      moved =
        new_state()
        |> idle_submit("past prompt")
        |> type("/m")
        |> press("down", [])
        |> press("down", [])

      assert moved.palette.selected == 1
      assert moved.history_index == nil

      back = press(moved, "up", [])

      assert back.palette.selected == 0
      assert State.input_text(back) == "/m"
    end

    test "enter executes the SELECTED match, not the typed text" do
      base = cataloged()
      typed = type(base, "/mo")
      state = press(typed, "down", [])

      assert Enum.map(state.palette.items, & &1.name) == ["mode", "model"]

      {picked, nil} = State.handle_key(state, "enter", [])

      assert %{mode: :modal, kind: :models, selected: 1} = picked.palette
      assert picked.history == ["/mo"]
    end

    test "the popup is idle-only: typing while streaming derives nothing" do
      state = type(%{new_state() | phase: :streaming}, "/he")
      assert state.palette == nil
    end

    test "a paste derives the popup too" do
      state = State.paste(new_state(), "/he")
      assert %{mode: :filter, kind: :commands} = state.palette
    end

    test "history navigation re-derives the popup for a command-shaped entry" do
      state = press(%{new_state() | history: ["/help"], draft: "x"}, "up", [])

      assert %{mode: :filter, kind: :commands} = state.palette
      assert State.input_text(state) == "/help"
    end

    test "a tab-materialized slash-shaped ghost derives the popup like typed text" do
      state = press(%{new_state() | suggestion: "/clear"}, "tab", [])

      assert State.input_text(state) == "/clear"
      assert %{mode: :filter} = state.palette
    end
  end

  describe "slash commands (ADR 0020)" do
    defp cataloged do
      config = %DashFloat.Config{
        base_url: "http://x",
        model: "m2",
        api_key: "k",
        nickname: "Nick",
        context_tokens: 1_000
      }

      state = new_state(provider: {:ok, config})

      catalog = %{
        "http://x" => [
          %{model: "m1", context: 128_000},
          %{model: "m2", context: nil},
          %{model: "m3", context: 200_000}
        ]
      }

      State.catalog_arrived(state, catalog)
    end

    # Types the draft, then Enter — the full submit/command path.
    defp enter_typed(state, text) do
      state
      |> type(text)
      |> State.handle_key("enter", [])
    end

    test "/clear via the popup's Enter resets the log but keeps the input history" do
      state =
        new_state()
        |> State.stream_message({:entry, :system, "old"})
        |> type("/clear")

      {cleared, nil} = State.handle_key(state, "enter", [])

      assert cleared.entries == []
      assert cleared.history == ["/clear"]
      assert State.input_text(cleared) == ""
      assert cleared.phase == :idle
      assert cleared.palette == nil
    end

    test "/clear via the submit path (args typed, popup dismissed) behaves the same" do
      state =
        new_state()
        |> State.stream_message({:entry, :system, "old"})
        |> Map.put(:history, ["kept"])
        |> type("/clear ")

      assert state.palette == nil

      {cleared, nil} = State.handle_key(state, "enter", [])

      assert cleared.entries == []
      assert cleared.history == ["kept", "/clear "]
      assert cleared.phase == :idle
    end

    test "/help lists the registry and the key hints" do
      {helped, nil} = enter_typed(new_state(), "/help")

      assert [{:system, text}] = pairs(helped)

      for name <- ~w(clear help mode model profile quit title) do
        assert text =~ "/#{name} — "
      end

      assert text =~ "Enter send · Shift+Enter newline"
      assert text =~ "Ctrl+P commands"
      assert text =~ "Shift+Tab mode"
    end

    test "/quit returns :quit" do
      assert {state, :quit} = enter_typed(new_state(), "/quit")
      assert state.palette == nil
    end

    test "bare /mode names the current mode" do
      planning = Map.put(new_state(), :mode, :plan)
      {printed, nil} = enter_typed(planning, "/mode ")

      assert printed.mode == :plan
      assert pairs(printed) == [{:system, "[mode: Plan — /mode <plan|build|auto|unchained>]"}]
    end

    test "/mode <name> returns {:set_mode, _} with no local mode change" do
      {state, action} = enter_typed(new_state(), "/mode plan")

      assert action == {:set_mode, :plan}
      assert state.mode == :build
      assert state.history == ["/mode plan"]
      assert State.input_text(state) == ""
    end

    test "an unknown mode warns with the four names" do
      {state, nil} = enter_typed(new_state(), "/mode bogus")

      assert pairs(state) == [{:system, "unknown mode: bogus (plan, build, auto, unchained)"}]
      assert state.mode == :build
    end

    test "/title carries its args to the agent" do
      assert {state, {:set_title, "fix the login"}} =
               enter_typed(new_state(), "/title fix the login")

      assert State.input_text(state) == ""
    end

    test "a bare /title opens the dialog pre-filled with the current title" do
      titled = Map.put(new_state(), :title, "Fix the login")
      {state, nil} = enter_typed(titled, "/title ")

      assert state.title_dialog == %{draft: "Fix the login", error: nil}
    end

    test "/compact returns the action; trailing text is ignored" do
      assert {_state, :compact} = enter_typed(new_state(), "/compact")
      assert {_state, :compact} = enter_typed(new_state(), "/compact now")
    end

    test "/model opens the picker preselected on the current model" do
      base = cataloged()
      {opened, nil} = enter_typed(base, "/model")

      assert %{mode: :modal, kind: :models, selected: 1} = opened.palette
      assert Enum.map(opened.palette.items, & &1.model) == ["m1", "m2", "m3"]
    end

    test "the picker's Enter swaps the provider for the highlighted entry" do
      base = cataloged()
      {opened, nil} = enter_typed(base, "/model")
      assert %{mode: :modal, kind: :models, selected: 1} = opened.palette

      moved = press(opened, "down", [])
      assert moved.palette.selected == 2

      {picked, {:switch_model, {:ok, config}}} = State.handle_key(moved, "enter", [])

      assert config.model == "m3"
      assert config.nickname == nil
      # m3 is catalog-only (no settings menu entry): no explicit window —
      # the observed/seeded/default chain takes over, never the outgoing
      # model's 1_000.
      assert config.context_tokens == nil
      assert config.base_url == "http://x"
      assert picked.provider == {:ok, config}
      assert picked.palette == nil
    end

    # Issue #111 (hostile review F2): a settings-menu entry's explicit
    # context survives the switch to its own id — the window re-resolves
    # for the PICKED model, and the user's number is never silently
    # displaced by observed/seed/default.
    test "the picker's Enter re-resolves the window from the picked id's menu entry" do
      menu = [
        %{nickname: "Seer", model: "m9", context: 262_144, images: false},
        %{nickname: "Plain", model: "m2", context: nil, images: false}
      ]

      base =
        new_state(
          provider:
            {:ok,
             %DashFloat.Config{
               base_url: "http://x",
               model: "m2",
               api_key: "k",
               context_tokens: 1_000,
               model_menu: menu
             }}
        )

      with_catalog =
        State.catalog_arrived(base, %{
          "http://x" => [%{model: "m2", context: nil}, %{model: "m9", context: 128_000}]
        })

      {opened, nil} = enter_typed(with_catalog, "/model")
      moved = press(opened, "down", [])
      {_picked, {:switch_model, {:ok, switched}}} = State.handle_key(moved, "enter", [])

      assert switched.model == "m9"
      # The menu entry's 262_144 — NOT the outgoing 1_000, NOT the
      # catalog's observed 128_000 (which loses to an explicit entry).
      assert switched.context_tokens == 262_144
    end

    # ADR 0018 §1 (hostile review finding 2): the images flag never carries
    # over from the outgoing model — the picked id re-resolves against the
    # settings-side menu, and a catalog-only id is not capable. Both
    # directions: capable → plain, plain → marked.
    test "the picker's Enter re-resolves the images flag from the model menu" do
      menu = [
        %{nickname: "Seer", model: "m9", context: nil, images: true},
        %{nickname: "Plain", model: "m2", context: nil, images: false}
      ]

      base =
        new_state(
          provider:
            {:ok,
             %DashFloat.Config{
               base_url: "http://x",
               model: "m2",
               api_key: "k",
               images: false,
               model_menu: menu
             }}
        )

      base_catalog = %{
        "http://x" => [%{model: "m2", context: nil}, %{model: "m9", context: 128_000}]
      }

      base_with_catalog = State.catalog_arrived(base, base_catalog)

      # plain (selected 0) → marked m9: capable
      {opened, nil} = enter_typed(base_with_catalog, "/model")
      moved = press(opened, "down", [])
      {_picked, {:switch_model, {:ok, capable}}} = State.handle_key(moved, "enter", [])

      assert capable.model == "m9"
      assert capable.images == true

      # marked boot model → plain m2: not capable
      booted_capable =
        new_state(
          provider:
            {:ok,
             %DashFloat.Config{
               base_url: "http://x",
               model: "m9",
               api_key: "k",
               images: true,
               model_menu: menu
             }}
        )

      booted_with_catalog = State.catalog_arrived(booted_capable, base_catalog)

      {reopened, nil} = enter_typed(booted_with_catalog, "/model")
      # preselected on m9 (index 1); up to m2
      up = press(reopened, "up", [])
      {_p2, {:switch_model, {:ok, plain}}} = State.handle_key(up, "enter", [])

      assert plain.model == "m2"
      assert plain.images == false
    end

    test "/model with an empty catalog warns" do
      provider = {:ok, %DashFloat.Config{base_url: "http://x", model: "m", api_key: "k"}}
      {state, nil} = enter_typed(new_state(provider: provider), "/model")

      assert pairs(state) == [{:system, "[model catalog is empty — nothing to pick]"}]
      assert state.palette == nil
    end

    test "/model with no provider names the missing provider, not the catalog" do
      {state, nil} = enter_typed(new_state(), "/model")

      assert pairs(state) == [
               {:system, "[no provider resolved — /model needs a working profile]"}
             ]
    end

    test "/profile returns :list_profiles" do
      assert {_state, :list_profiles} = enter_typed(new_state(), "/profile")
      assert _state.palette == nil
    end

    test "a runtime profile switch keeps the composer draft (ADR 0020)" do
      typed = type(new_state(), "hello draft")

      {switched, {:agent_provider, _classification}} =
        State.provider_resolved(typed, {:ok, %DashFloat.Config{}})

      assert State.input_text(switched) == "hello draft"
      assert switched.setup == nil
    end

    test "profiles_arrived opens the picker" do
      state = State.profiles_arrived(new_state(), ["personal", "work"])

      assert %{mode: :modal, kind: :profiles, items: ["personal", "work"], selected: 0} =
               state.palette
    end

    test "profiles_arrived with nothing to list warns" do
      state = State.profiles_arrived(new_state(), [])
      assert pairs(state) == [{:system, "[no profiles configured]"}]
    end

    test "the profiles picker's Enter rides the existing select_profile action" do
      listed = State.profiles_arrived(new_state(), ["personal", "work"])
      state = press(listed, "down", [])

      {picked, {:select_profile, "work"}} = State.handle_key(state, "enter", [])

      assert picked.palette == nil
    end

    test "an unknown bare command warns instead of submitting" do
      {state, nil} = enter_typed(new_state(), "/nope")

      assert pairs(state) == [{:system, "unknown command: /nope — try /help"}]
      assert state.phase == :idle
      assert state.history == ["/nope"]
      assert State.input_text(state) == ""
    end

    test "slash text with an argument is an ordinary message — the escape hatch" do
      {state, {:submit, "/etc/hosts is weird", []}} =
        enter_typed(new_state(), "/etc/hosts is weird")

      assert [{:user, "/etc/hosts is weird"}] = pairs(state)
      assert state.phase == :streaming
    end

    test "commands are idle-gated: a /clear submit mid-stream is a no-op" do
      typed = type(%{new_state() | phase: :streaming}, "/clear")
      assert typed.palette == nil

      {kept, nil} = State.handle_key(typed, "enter", [])

      assert kept.phase == :streaming
      assert kept.entries == []
      assert kept.history == []
    end
  end

  describe "the modal palette (ADR 0020)" do
    test "ctrl+p opens the command palette from idle" do
      state = press(new_state(), "p", ["ctrl"])

      assert %{mode: :modal, kind: :commands, selected: 0} = state.palette

      assert Enum.map(state.palette.items, & &1.name) ==
               ~w(clear compact help mode model profile quit resume title)
    end

    test "ctrl+p is idle-gated like submit" do
      state = press(%{new_state() | phase: :streaming}, "p", ["ctrl"])
      assert state.palette == nil
    end

    test "ctrl+p toggles a modal or filter palette closed" do
      opened = press(new_state(), "p", ["ctrl"])
      modal = press(opened, "p", ["ctrl"])

      assert modal.palette == nil

      typed = type(new_state(), "/he")
      filter = press(typed, "p", ["ctrl"])

      assert filter.palette == nil
    end

    test "the modal swallows everything but up/down/enter/esc — the mode cycle included" do
      state =
        new_state()
        |> press("p", ["ctrl"])
        |> press("x", [])
        |> press("page_up", [])
        |> press("back_tab", [])

      assert State.input_text(state) == ""
      assert state.mode == :build
      assert %{mode: :modal} = state.palette
    end

    test "up/down move and enter executes the highlighted entry" do
      state =
        new_state()
        |> press("p", ["ctrl"])
        |> press("down", [])
        |> press("up", [])
        |> press("down", [])

      assert state.palette.selected == 1

      # Selected 1 is now /compact (alphabetical under /clear): enter runs it —
      # the action rides to the TUI, no entry, palette closed.
      {ran, :compact} = State.handle_key(state, "enter", [])

      assert ran.palette == nil
      assert pairs(ran) == []
    end

    test "esc closes the modal" do
      opened = press(new_state(), "p", ["ctrl"])
      state = press(opened, "esc", [])

      assert state.palette == nil
    end

    test "ctrl+q still quits while a modal is open" do
      state = press(new_state(), "p", ["ctrl"])
      assert {^state, :quit} = State.handle_key(state, "q", ["ctrl"])
    end

    test "the double Ctrl+C quit works while a modal is open" do
      opened = press(new_state(), "p", ["ctrl"])

      {armed, nil} = State.handle_key(opened, "c", ["ctrl"], 1_000)
      assert armed.exit_guard_at == 1_000

      {quitting, :quit} = State.handle_key(armed, "c", ["ctrl"], 1_500)
      assert quitting.exit_guard_at == nil
    end

    test "a palette-executed /clear dismisses the ghost too" do
      opened =
        new_state()
        |> Map.put(:suggestion, "next thing")
        |> press("p", ["ctrl"])

      {cleared, nil} = State.handle_key(opened, "enter", [])

      assert cleared.entries == []
      assert cleared.suggestion == nil
    end

    test "a pending confirm outranks the palette (ADR 0016 §3)" do
      {state, _ref} = confirming()
      {swallowed, nil} = State.handle_key(state, "p", ["ctrl"])

      assert swallowed.palette == nil
      assert swallowed.confirm != nil
    end
  end

  ## Image attachments (ADR 0018 §5/§6)

  describe "image attachments (ADR 0018 §5)" do
    @capable {:ok,
              %DashFloat.Config{
                base_url: "http://x",
                model: "m",
                api_key: "k",
                images: true
              }}

    @incapable {:ok,
                %DashFloat.Config{
                  base_url: "http://x",
                  model: "m",
                  api_key: "k",
                  nickname: "Sol"
                }}

    defp images_dir do
      dir =
        Path.join(
          "/tmp/opencode",
          "dashfloat-tui-state-images-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      dir
    end

    defp write_image(dir, name) do
      path = Path.join(dir, name)
      File.write!(path, "12345678")
      path
    end

    # A successful attach to reuse in the flow tests: the prompt was opened,
    # the path typed, and Enter landed the metadata.
    defp attached(path) do
      fresh = new_state(provider: @capable)

      fresh
      |> press("o", ["ctrl"])
      |> type(path)
      |> State.handle_key("enter", [])
      |> elem(0)
    end

    defp logical_text(entry), do: Enum.map_join(entry.logical, "\n", &flatten_entry_line/1)

    defp flatten_entry_line(line), do: Enum.map_join(line.spans, "", & &1.content)

    test "provider_images? reads the resolved provider's flag" do
      capable = new_state(provider: @capable)
      incapable = new_state(provider: @incapable)
      unresolved = new_state(provider: {:error, "no provider"})

      assert State.provider_images?(capable)
      refute State.provider_images?(incapable)
      refute State.provider_images?(new_state())
      refute State.provider_images?(unresolved)
    end

    # The drag-and-drop shape (issue #112; ADR 0018's 2026-10-31
    # amendment): a bracketed paste whose whole content is a path to an
    # existing image file becomes a pending chip — never literal path text.
    test "a pasted image path attaches instead of typing" do
      dir = images_dir()
      path = write_image(dir, "dropped.png")

      fresh = new_state(provider: @capable)
      state = State.paste(fresh, path <> "\r\n")

      assert state.attachments == [%{path: path, name: "dropped.png", kb: 1}]
      assert State.input_text(state) == ""
      assert state.entries == []
    end

    test "two drops number per queue order; a pop renumbers" do
      dir = images_dir()
      one = write_image(dir, "one.png")
      two = write_image(dir, "two.png")

      fresh = new_state(provider: @capable)

      state =
        fresh
        |> State.paste(one)
        |> then(&State.paste(&1, two))

      assert Enum.map(state.attachments, & &1.path) == [one, two]

      {popped, nil} = State.handle_key(state, "backspace", [])
      assert Enum.map(popped.attachments, & &1.path) == [one]
      assert State.input_text(popped) == ""
    end

    test "backspace with draft text edits the draft, not the chips" do
      dir = images_dir()
      path = write_image(dir, "dropped.png")

      fresh = new_state(provider: @capable)

      state =
        fresh
        |> State.paste(path)
        |> then(&type(&1, "hi"))

      {edited, nil} = State.handle_key(state, "backspace", [])
      assert edited.attachments == [%{path: path, name: "dropped.png", kb: 1}]
      assert State.input_text(edited) == "h"
    end

    test "a non-image paste stays ordinary text — even a path" do
      dir = images_dir()
      missing = Path.join(dir, "nope.png")
      text = State.paste(new_state(), missing)

      assert text.attachments == []
      assert State.input_text(text) == missing

      prose = State.paste(new_state(), "hello world")
      assert prose.attachments == []
      assert State.input_text(prose) == "hello world"

      multi = State.paste(new_state(), "#{write_image(dir, "a.png")} and more")
      assert multi.attachments == []
      assert State.input_text(multi) == "#{Path.join(dir, "a.png")} and more"
    end

    test "a drop on a non-capable model refuses visibly; nothing typed" do
      dir = images_dir()
      path = write_image(dir, "dropped.png")

      fresh = new_state(provider: @incapable)
      state = State.paste(fresh, path)

      assert state.attachments == []
      assert State.input_text(state) == ""
      assert [{:system, entry}] = pairs(state)
      assert entry =~ "[images: model Sol does not accept images"
    end

    test "an empty paste stays ordinary (nothing to drop)" do
      fresh = new_state(provider: @capable)
      state = State.paste(fresh, "")
      assert state.attachments == []
      assert State.input_text(state) == ""
    end

    test "an over-cap dropped image refuses visibly through the shared check" do
      dir = images_dir()
      path = write_image(dir, "huge.png")
      File.write!(path, :binary.copy("x", 10 * 1024 * 1024 + 1))

      fresh = new_state(provider: @capable)
      state = State.paste(fresh, path)

      assert state.attachments == []
      assert State.input_text(state) == ""
      assert [{:system, entry}] = pairs(state)
      assert entry =~ "exceeds the 10 MiB image cap"
    end

    test "a drop works mid-stream too — the queue only rides a submit" do
      dir = images_dir()
      path = write_image(dir, "dropped.png")

      state = State.paste(%{new_state(provider: @capable) | phase: :streaming}, path)

      assert Enum.map(state.attachments, & &1.path) == [path]
      assert State.input_text(state) == ""
    end

    test "ctrl+o opens the prompt while idle; a second ctrl+o closes it" do
      fresh = new_state(provider: @capable)
      {opened, nil} = State.handle_key(fresh, "o", ["ctrl"])
      assert opened.attach == %{draft: ""}

      # printable keys feed the open prompt's draft
      typed = type(opened, "/tmp/opencode/a")
      assert typed.attach == %{draft: "/tmp/opencode/a"}

      {closed, nil} = State.handle_key(typed, "o", ["ctrl"])
      assert closed.attach == nil
    end

    test "ctrl+o is inert while streaming, under a palette, and under a pending confirm" do
      # streaming: the key falls through to the (unaffected) composer, the
      # prompt never opens
      {streaming, nil} = State.handle_key(%{new_state() | phase: :streaming}, "o", ["ctrl"])
      assert streaming.attach == nil

      paletted = press(new_state(), "p", ["ctrl"])
      {kept, nil} = State.handle_key(paletted, "o", ["ctrl"])
      assert kept.attach == nil
      assert kept.palette != nil

      {confirming_state, _ref} = confirming()
      {swallowed, nil} = State.handle_key(confirming_state, "o", ["ctrl"])
      assert swallowed.attach == nil
      assert swallowed.confirm != nil
    end

    test "typing and backspace edit the draft grapheme-wise" do
      opened = press(new_state(), "o", ["ctrl"])
      state = type(opened, "café.png")
      assert state.attach.draft == "café.png"

      edited = press(state, "backspace", [])
      assert edited.attach.draft == "café.pn"

      # backspacing past the start is a no-op
      emptied =
        Enum.reduce(1..9, edited, fn _n, acc -> press(acc, "backspace", []) end)

      assert emptied.attach.draft == ""
    end

    test "Enter on an empty draft is a no-op — no refusal, prompt stays open" do
      opened = press(new_state(), "o", ["ctrl"])
      entered = press(opened, "enter", [])

      assert entered.attach != nil
      assert entered.attach.draft == ""
      assert entered.attachments == []
      assert entered.entries == []
    end

    # The no-op is provider-independent (hostile review finding 6): an
    # empty draft never reaches the capability gate, capable or not.
    test "Enter on an empty draft is a no-op under an incapable provider too" do
      incapable =
        new_state(
          provider:
            {:ok,
             %DashFloat.Config{base_url: "http://x", model: "m", api_key: "k", images: false}}
        )

      opened = press(incapable, "o", ["ctrl"])
      entered = press(opened, "enter", [])

      assert entered.attach.draft == ""
      assert entered.entries == []
    end

    # A chord is not a printable key (ADR 0018 §5; hostile review finding
    # 3): Ctrl+P must open nothing and type nothing while the prompt owns
    # the input — the "p" stays out of the draft.
    test "control chords are swallowed — they neither act nor type" do
      opened = press(new_state(), "o", ["ctrl"])
      typed = press(opened, "p", ["ctrl"])

      assert typed.attach.draft == ""
      assert typed.palette == nil

      ctrl_u = press(typed, "u", ["ctrl"])
      assert ctrl_u.attach.draft == ""

      alt_a = press(ctrl_u, "a", ["alt"])
      assert alt_a.attach.draft == ""
    end

    # crossterm reports an uppercase char as SHIFT-modified (delta review):
    # shift-only must type — capital letters in paths are mainline input.
    test "a shifted printable types its uppercase character" do
      opened = press(new_state(), "o", ["ctrl"])

      typed = press(opened, "P", ["shift"])
      assert typed.attach.draft == "P"

      more = press(typed, "I", ["shift"])
      assert more.attach.draft == "PI"
    end

    test "a paste feeds the prompt's draft, newlines stripped, composer untouched" do
      opened = press(new_state(), "o", ["ctrl"])
      pasted = State.attach_paste(opened, "/tmp/opencode/cat.png\r\n")

      assert pasted.attach.draft == "/tmp/opencode/cat.png"
      assert State.input_text(pasted) == ""
    end

    test "overlay? is true with the prompt open, allocating the one activity row" do
      opened = press(new_state(), "o", ["ctrl"])
      assert State.overlay?(opened)

      regions = View.regions({80, 24}, State.input_line_count(opened), State.overlay?(opened))
      assert regions.activity.height == 1
    end

    test "tab completes the last segment to the longest common prefix, then the extension" do
      dir = images_dir()
      write_image(dir, "alpha.png")
      write_image(dir, "alphabet.jpg")
      write_image(dir, "beta.gif")

      state =
        new_state()
        |> press("o", ["ctrl"])
        |> type(dir <> "/alp")
        |> press("tab", [])

      # alpha.png / alphabet.jpg share only "alpha" — no trailing slash
      assert state.attach.draft == dir <> "/alpha"

      # the further dot completes the extension: alpha. → alpha.png
      completed =
        state
        |> type(".")
        |> press("tab", [])

      assert completed.attach.draft == dir <> "/alpha.png"

      # a fully-completed name re-tabs as a no-op
      re_tapped = press(completed, "tab", [])
      assert re_tapped.attach.draft == dir <> "/alpha.png"
    end

    test "tab completes a directory with a trailing slash; no match is a no-op" do
      dir = images_dir()
      delta = Path.join(dir, "delta")
      File.mkdir!(delta)

      state =
        new_state()
        |> press("o", ["ctrl"])
        |> type(dir <> "/del")
        |> press("tab", [])

      assert state.attach.draft == dir <> "/delta/"

      # no matches at all — the draft is untouched
      stale =
        new_state()
        |> press("o", ["ctrl"])
        |> type(dir <> "/zz")
        |> press("tab", [])

      assert stale.attach.draft == dir <> "/zz"
    end

    test "dotfile entries complete only after the typed segment starts with a dot" do
      dir = images_dir()
      write_image(dir, ".hidden.png")
      write_image(dir, "readme.txt")

      # segment "": the dotfile is invisible, the plain file completes
      plain =
        new_state()
        |> press("o", ["ctrl"])
        |> type(dir <> "/")
        |> press("tab", [])

      assert plain.attach.draft == dir <> "/readme.txt"

      # segment ".": the dotfile surfaces
      dotted =
        new_state()
        |> press("o", ["ctrl"])
        |> type(dir <> "/.")
        |> press("tab", [])

      assert dotted.attach.draft == dir <> "/.hidden.png"
    end

    test "enter on a valid path attaches the metadata and closes the prompt" do
      dir = images_dir()
      alpha = write_image(dir, "alpha.png")
      alphabet = write_image(dir, "alphabet.jpg")

      first = attached(alpha)

      # success logs nothing — the chip is the only trace
      assert first.attach == nil
      assert first.attachments == [%{path: alpha, name: "alpha.png", kb: 1}]
      assert pairs(first) == []

      # a second attach accumulates
      second =
        first
        |> press("o", ["ctrl"])
        |> type(alphabet)
        |> State.handle_key("enter", [])
        |> elem(0)

      assert Enum.map(second.attachments, & &1.name) == ["alpha.png", "alphabet.jpg"]
    end

    test "enter under an incapable provider refuses naming the model and keeps the draft" do
      fresh = new_state(provider: @incapable)
      opened = press(fresh, "o", ["ctrl"])
      typed = type(opened, "/tmp/opencode/cat.png")

      {refused, nil} = State.handle_key(typed, "enter", [])

      assert refused.attach == %{draft: "/tmp/opencode/cat.png"}
      assert refused.attachments == []

      assert pairs(refused) == [
               {:system, "[images: model Sol does not accept images — attach refused]"}
             ]
    end

    test "the capability refusal names the bare model id without a nickname" do
      provider = {:ok, %DashFloat.Config{base_url: "http://x", model: "glm", api_key: "k"}}
      fresh = new_state(provider: provider)
      opened = press(fresh, "o", ["ctrl"])
      typed = type(opened, "/tmp/opencode/cat.png")

      {refused, nil} = State.handle_key(typed, "enter", [])

      assert pairs(refused) == [
               {:system, "[images: model glm does not accept images — attach refused]"}
             ]
    end

    test "enter on a bad path refuses naming the path and keeps the draft" do
      dir = images_dir()
      notes = Path.join(dir, "notes.txt")
      File.write!(notes, "x")

      refusals = [
        {Path.join(dir, "nope.png"), Path.join(dir, "nope.png") <> ": no such file or directory"},
        {Path.join(dir, "notes.txt"),
         Path.join(dir, "notes.txt") <>
           ": not an image extension (one of .png .jpg .jpeg .gif .webp)"}
      ]

      for {draft, reason} <- refusals do
        fresh = new_state(provider: @capable)
        opened = press(fresh, "o", ["ctrl"])
        typed = type(opened, draft)
        {refused, nil} = State.handle_key(typed, "enter", [])

        # the prompt stays open with the draft intact — fix the path, retry
        assert refused.attach == %{draft: draft}
        assert refused.attachments == []
        assert pairs(refused) == [{:system, "[images: " <> reason <> "]"}]
      end
    end

    test "esc closes the prompt keeping pending attachments; ctrl+d clears them" do
      alpha = write_image(images_dir(), "alpha.png")
      attached_state = attached(alpha)

      reopened = press(attached_state, "o", ["ctrl"])
      closed = press(reopened, "esc", [])
      assert closed.attach == nil
      assert length(closed.attachments) == 1

      # ctrl+d clears all — and closes the prompt it was open with
      again = press(closed, "o", ["ctrl"])
      cleared = press(again, "d", ["ctrl"])
      assert cleared.attach == nil
      assert cleared.attachments == []
    end

    test "submit with text and an attachment sends the paths and renders the indicators" do
      alpha = write_image(images_dir(), "alpha.png")
      attached_state = attached(alpha)
      typed = type(attached_state, "what is this?")

      {state, {:submit, "what is this?", [^alpha]}} = State.handle_key(typed, "enter", [])

      # the attachment survives until the agent's streaming echo (ADR 0018 §6)
      assert state.phase == :streaming
      assert length(state.attachments) == 1

      # entry text verbatim (ADR 0006); the rendered lines gain the dim
      # indicator under the prompt text (ADR 0018 §5)
      [entry] = for(%{kind: :user} = e <- state.entries, do: e)
      assert entry.text == "what is this?"
      assert logical_text(entry) == "\n❯ what is this?\n📎 alpha.png (1 KB)"
      assert hd(List.last(entry.logical).spans).style == Theme.style(:dim)
    end

    test "submit with a blank draft but pending attachments is the image-only turn" do
      alpha = write_image(images_dir(), "alpha.png")
      attached_state = attached(alpha)

      {state, {:submit, "", [^alpha]}} = State.handle_key(attached_state, "enter", [])

      [entry] = for(%{kind: :user} = e <- state.entries, do: e)
      assert entry.text == ""
      assert logical_text(entry) == "\n❯ \n📎 alpha.png (1 KB)"
    end

    test "a command submit leaves pending attachments untouched" do
      alpha = write_image(images_dir(), "alpha.png")
      attached_state = attached(alpha)
      typed = type(attached_state, "/help")

      {state, nil} = State.handle_key(typed, "enter", [])

      assert state.phase == :idle
      assert length(state.attachments) == 1
    end

    test "the streaming echo clears pending attachments; a refusal flow does not" do
      pending = %{new_state() | attachments: [%{path: "/p/a.png", name: "a.png", kb: 1}]}

      cleared = State.stream_message(pending, {:phase, :streaming}, 1_000)
      assert cleared.attachments == []

      # repeated tool-loop episodes clear an already-empty list — a no-op
      assert State.stream_message(cleared, {:phase, :streaming}, 1_000).attachments == []

      # the submit-time refusal never echoes streaming: the set survives
      refused =
        pending
        |> State.stream_message(
          {:entry, :system, "[images: /p/a.png: no such file or directory]"},
          1_000
        )
        |> State.stream_message({:phase, :idle}, 1_000)

      assert length(refused.attachments) == 1
    end
  end

  ## The /title dialog (issue #106; ADR 0023's 2026-10-31 amendment)

  describe "the /title dialog" do
    # The dialog as bare /title opens it: idle, pre-filled, no error.
    defp dialog_open(opts \\ []) do
      opts
      |> new_state()
      |> enter_typed("/title ")
      |> elem(0)
    end

    test "bare /title with no current title opens with an empty draft" do
      assert dialog_open().title_dialog == %{draft: "", error: nil}
    end

    test "a paste with no dialog open is a no-op (the TUI clause guards the open state)" do
      closed = new_state(title: "Kept")

      pasted = State.title_paste(closed, "pasted title\n")

      assert pasted.title_dialog == nil
      assert pasted.title == "Kept"
    end

    test "bare /title via the filter palette's Enter opens the same dialog" do
      # No trailing space: Enter executes the SELECTED match, which lands on
      # run_command(state, "title", "") — the dialog clause, not the inline.
      {state, nil} = enter_typed(new_state(title: "Via Palette"), "/title")

      assert state.title_dialog == %{draft: "Via Palette", error: nil}
    end

    test "typing appends, a shifted printable uppercases, backspace slices the last grapheme" do
      state =
        dialog_open()
        |> press("f", [])
        |> press("i", [])
        |> press("x", [])
        |> press("I", ["shift"])
        |> press("t", [])
        |> press("backspace", [])

      assert state.title_dialog.draft == "fixI"

      # backspacing past the start is a no-op
      emptied =
        Enum.reduce(1..9, state, fn _n, acc -> press(acc, "backspace", []) end)

      assert emptied.title_dialog.draft == ""
    end

    test "a paste appends newline-stripped; the composer stays untouched" do
      state = State.title_paste(dialog_open(), "fix it\r\n")

      assert state.title_dialog.draft == "fix it"
      assert State.input_text(state) == ""
    end

    test "enter returns {:set_title, draft} and keeps the dialog open, error reset" do
      state = %{dialog_open() | title_dialog: %{draft: "fix it", error: "stale refusal"}}

      {submitted, {:set_title, "fix it"}} = State.handle_key(state, "enter", [])

      # The dialog stays open: the agent's {:title, _} closes it or
      # {:title_refused, _} errors it.
      assert submitted.title_dialog == %{draft: "fix it", error: nil}
    end

    test "enter accepts the ctrl modifier; esc closes" do
      state = dialog_open()
      {sent, {:set_title, ""}} = State.handle_key(state, "enter", ["ctrl"])
      assert sent.title_dialog != nil

      {closed, nil} = State.handle_key(state, "esc", [])
      assert closed.title_dialog == nil
    end

    test "{:title, t} sets the title and closes an open dialog" do
      opened = dialog_open(title: "Old")
      titled = State.stream_message(opened, {:title, "New"}, 1_000)

      assert titled.title == "New"
      assert titled.title_dialog == nil
    end

    test "{:title_refused, r} errors the open dialog, keeping the draft" do
      reason = ~s("x" is already taken by session 0192aa10-b002-7c00-8000-00000000000c)
      typed = press(dialog_open(title: "Old"), "x", [])

      refused = State.stream_message(typed, {:title_refused, reason}, 1_000)

      assert refused.title_dialog == %{draft: "Oldx", error: reason}
    end

    test "{:title_refused, r} with no dialog open is a no-op" do
      state = State.stream_message(new_state(), {:title_refused, "may not be empty"}, 1_000)

      assert state.title_dialog == nil
      assert state.entries == []
    end

    test "the open dialog swallows up/down/tab/page keys — no history, no mode cycle, no palette" do
      state =
        dialog_open()
        |> Map.put(:history, ["/old"])
        |> Map.put(:suggestion, "ghost")
        |> press("up", [])
        |> press("down", [])
        |> press("tab", [])
        |> press("page_up", [])
        |> press("back_tab", [])
        |> press("p", ["ctrl"])
        |> press("u", ["ctrl"])

      assert state.title_dialog.draft == ""
      assert state.history == ["/old"]
      assert state.mode == :build
      assert state.palette == nil
      assert state.suggestion == "ghost"
    end

    test "the global quits still work while the dialog is open" do
      state = dialog_open()
      assert {^state, :quit} = State.handle_key(state, "q", ["ctrl"])

      {armed, nil} = State.handle_key(state, "c", ["ctrl"], 1_000)
      assert armed.exit_guard_at == 1_000
    end

    test "the inline form is unchanged: /title <name> returns {:set_title, name}" do
      {state, {:set_title, "fix the login"}} = enter_typed(new_state(), "/title fix the login")

      assert state.title_dialog == nil
      assert State.input_text(state) == ""
    end
  end

  # The /resume picker (issue #128): the modal over saved sessions, and the
  # adoption that lands when Enter picks one.
  describe "the /resume picker (issue #128)" do
    defp summary(id, overrides \\ []) do
      Map.merge(
        %{
          id: id,
          title: nil,
          created_at: "2026-10-31T00:00:00Z",
          pin: %{profile: nil, model: nil, base_url: nil},
          preview: "the first question"
        },
        Map.new(overrides)
      )
    end

    defp session_body(messages, overrides \\ []) do
      Map.merge(
        %{
          version: 1,
          id: "01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5c",
          created_at: "2026-10-30T09:00:00Z",
          pin: %{profile: nil, model: nil, base_url: nil},
          messages: messages,
          context: nil,
          compactions: []
        },
        Map.new(overrides)
      )
    end

    test "/resume returns :list_sessions" do
      {state, :list_sessions} = enter_typed(new_state(), "/resume")
      assert state.palette == nil
    end

    test "sessions_arrived over an empty store warns, never opens" do
      state = State.sessions_arrived(new_state(), [], 1_000)

      assert pairs(state) == [{:system, "[no saved sessions — nothing to resume]"}]
      assert state.palette == nil
    end

    test "sessions_arrived opens the picker: one labelled row per session" do
      now = DateTime.to_unix(~U[2026-10-31T00:00:00Z])

      rows = [
        summary("01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5c",
          title: "Titled Session",
          created_at: "2026-10-30T23:59:30Z",
          pin: %{profile: "personal", model: "glm-5.3", base_url: nil}
        ),
        summary("01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5d",
          preview: "what is elixir?",
          created_at: "2026-10-30T20:00:00Z",
          pin: %{
            profile: nil,
            model: "glm-5.3-flash",
            base_url: "https://api.z.ai/api/coding/paas/v4"
          }
        )
      ]

      state = State.sessions_arrived(new_state(), rows, now)

      assert %{mode: :modal, kind: :sessions, selected: 0} = state.palette
      [first, second] = state.palette.items
      # Title wins over preview; relative time; provider · model — the
      # profile name, else the base_url's preset label (ADR 0015 §2).
      assert first.id == "01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5c"
      assert first.label == "Titled Session · now · personal · glm-5.3"
      assert second.id == "01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5d"
      assert second.label == "what is elixir? · 4h · zai · glm-5.3-flash"
    end

    test "row labels: long previews cap with an ellipsis, control bytes drop, times bucket" do
      now = DateTime.to_unix(~U[1970-01-02T02:00:00Z])

      long =
        summary("01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5c",
          preview: String.duplicate("a", 20) <> "\n" <> String.duplicate("b", 25) <> "\e[31m",
          created_at: "1970-01-01T00:00:00Z",
          pin: %{profile: nil, model: nil, base_url: "https://custom.example/v1"}
        )

      state = State.sessions_arrived(new_state(), [long], now)
      [row] = state.palette.items

      # The cap is 40 display columns WITH the ellipsis (#144, the #139
      # class): 39 content columns + `…`, never 41 cells at the popup's edge.
      assert row.label ==
               String.duplicate("a", 20) <>
                 " " <> String.duplicate("b", 18) <> "… · 1d · custom.example · —"

      [capped | _rest] = String.split(row.label, " · ")
      assert Wrap.width(capped) <= 40
    end

    # #144 (the #139 class): every Han grapheme is two display cells — a
    # 40-grapheme CJK preview is 80 columns, and the grapheme-count cap
    # shipped it whole, pushing the row's metadata past the picker popup's
    # edge (the popup's List clips, never wraps). The honest cap keeps the
    # whole row inside the popup at every terminal width.
    test "row labels: a wide-glyph preview caps at 40 columns, not 40 graphemes" do
      now = DateTime.to_unix(~U[2026-10-31T00:00:00Z])

      cjk =
        summary("01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5c",
          preview: String.duplicate("汉", 40),
          created_at: "2026-10-30T23:59:30Z",
          pin: %{profile: "personal", model: "glm-5.3", base_url: nil}
        )

      state = State.sessions_arrived(new_state(), [cjk], now)
      [row] = state.palette.items

      [capped | _rest] = String.split(row.label, " · ")

      # 19 Han pairs (38) + `…` — 39 columns, the next glyph would overflow.
      assert capped == String.duplicate("汉", 19) <> "…"
      assert Wrap.width(capped) <= 40
    end

    test "row labels: minutes bucket, the plain-date fallback past a week, raw unparseable stamps" do
      now = DateTime.to_unix(~U[2026-10-31T12:00:00Z])

      rows = [
        summary("01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5c", created_at: "2026-10-31T11:30:00Z"),
        summary("01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5d", created_at: "2026-10-20T00:00:00Z"),
        summary("01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5e", created_at: "not a stamp")
      ]

      state = State.sessions_arrived(new_state(), rows, now)

      assert Enum.map(state.palette.items, & &1.label) == [
               "the first question · 30m · — · —",
               "the first question · 2026-10-20 · — · —",
               "the first question · not a stamp · — · —"
             ]
    end

    test "Enter returns the picked row's id and closes the palette" do
      rows = [
        summary("01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5c"),
        summary("01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5d")
      ]

      opened = State.sessions_arrived(new_state(), rows, 1_000)
      moved = press(opened, "down", [])

      {picked, {:resume_session, "01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5d"}} =
        State.handle_key(moved, "enter", [])

      assert picked.palette == nil
    end

    test "Esc cancels back to the current session untouched" do
      rows = [summary("01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5c")]
      opened = State.sessions_arrived(new_state(), rows, 1_000)

      {cancelled, nil} = State.handle_key(opened, "esc", [])

      assert cancelled.palette == nil
      assert cancelled.entries == opened.entries
      assert cancelled.session_id == opened.session_id
    end

    test "session_adopted replays the transcript (stored system message skipped), resets the live surfaces, keeps the draft" do
      # The current session has one exchange, a hot stats block, a context
      # snapshot, a pending attachment, and a panned-away log.
      live =
        new_state()
        |> idle_submit("the outgoing question")
        |> Map.merge(%{
          # A "hot" stats block over the zero shape (the #130 fields ride
          # @zero_stats; a bare literal would drop them).
          stats: %{
            new_state().stats
            | tokens: 9,
              first_token_at: 1,
              rate: 3.0,
              prompt_tokens: 5,
              completion_tokens: 4
          },
          context: %{messages: [%{role: "user", content: "x"}], anchor: nil},
          attachments: [%{path: "shot.png", name: "shot.png", kb: 1}],
          scroll: 4,
          follow?: false,
          suggestion: "a ghost"
        })

      streamed =
        live
        |> State.stream_message({:phase, :streaming}, 1_000)
        |> State.stream_message({:token, "the outgoing answer"}, 1_001)
        |> State.stream_message({:phase, :idle}, 1_002)

      typed = type(streamed, "an unsent draft")

      adopted =
        State.session_adopted(
          typed,
          session_body(
            [
              %{"role" => "system", "content" => "the stored prompt (ADR 0019)"},
              %{"role" => "user", "content" => "the adopted question"},
              %{"role" => "assistant", "content" => "the adopted answer"}
            ],
            %{title: "Adopted", id: "01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5f"}
          ),
          "[resuming session pinned to model other under active model m — continuing; the session keeps its pin]"
        )

      # The log is the replayed transcript: the STORED system message
      # renders as nothing (ADR 0019 — the #116 crash shape), the two
      # adopted turns replace the outgoing exchange, and the note rides
      # last exactly as a resumed boot's.
      assert pairs(adopted) == [
               {:user, "the adopted question"},
               {:assistant, "the adopted answer"},
               {:system,
                "[resuming session pinned to model other under active model m — continuing; the session keeps its pin]"}
             ]

      assert adopted.session_id == "01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5f"
      assert adopted.title == "Adopted"
      assert adopted.stats.tokens == 0 and adopted.stats.rate == nil
      assert adopted.context == nil
      assert adopted.attachments == []
      assert adopted.scroll == 0 and adopted.follow? == true
      assert adopted.suggestion == nil and adopted.suggest_reap == true
      # The draft survives the switch — composer state, not session state.
      assert State.input_text(adopted) == "an unsent draft"
    end

    test "session_refused lands one system entry and keeps the session" do
      state = idle_submit(new_state(), "still here")

      refused = State.session_refused(state, "no session gone under /tmp/x")

      refused_pairs = pairs(refused)

      assert List.last(refused_pairs) ==
               {:system, "[resume failed: no session gone under /tmp/x]"}

      assert Enum.take(refused_pairs, 1) == [{:user, "still here"}]
      assert refused.session_id == state.session_id
    end
  end
end
