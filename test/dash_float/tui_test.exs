defmodule DashFloat.TUITest do
  @moduledoc """
  App-level tests under `test_mode`: supervised lifecycle, teardown paths
  (including crashes), the agent seam (fake agents are this test process or
  plain spawned processes — the TUI only ever sends
  `{:prompt, ui, text, paths}` / `{:confirm_decision, ref, decision}` / `{:cancel}` /
  `{:set_mode, ui, mode}` / `{:set_title, ui, title}` / `{:set_provider, _}`
  and receives the frozen stream contract, ADR 0007),
  and the responsiveness proof. Not async: they measure timing, share
  telemetry handlers, and drive one supervised TUI per test.
  """

  use ExUnit.Case, async: false

  alias DashFloat.Config
  alias DashFloat.Config.JSON5
  alias DashFloat.Config.Onboarding
  alias DashFloat.Session
  alias DashFloat.SSEServer
  alias DashFloat.TUI
  alias DashFloat.TUI.Palette
  alias DashFloat.TUI.State
  alias DashFloat.TUI.Suggest
  alias DashFloat.TUI.Theme
  alias DashFloat.TUI.View
  alias ExRatatui.Runtime

  # A struct no clause names — the handle_event/2 catch-all's payload.
  defmodule UnknownEvent do
    defstruct []
  end

  @opts [test_mode: {80, 24}, name: nil]

  defp start_tui(opts \\ []) do
    # The default fake agent is the test process: the TUI's sends land in
    # this mailbox and each test answers with contract messages.
    opts =
      @opts
      |> Keyword.merge(opts)
      |> Keyword.put_new(:agent, self())

    # A real supervisor, mirroring the Application wiring (restart: :temporary).
    {:ok, sup} =
      Supervisor.start_link(
        [%{id: TUI, start: {TUI, :start_link, [opts]}, type: :worker, restart: :temporary}],
        strategy: :one_for_one
      )

    # Unlink: the supervisor must outlive the test process so on_exit can
    # stop it (and the TUI) deterministically.
    Process.unlink(sup)
    on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)

    [{TUI, pid, :worker, _modules}] = Supervisor.which_children(sup)
    {:ok, pid}
  end

  defp provider do
    {:ok, %Config{base_url: "http://localhost:1", model: "test-model", api_key: "test-key-123"}}
  end

  defp press(pid, code, modifiers \\ []) do
    Runtime.inject_event(pid, %ExRatatui.Event.Key{
      code: code,
      modifiers: modifiers,
      kind: "press"
    })
  end

  defp type(pid, text) do
    text
    |> String.codepoints()
    |> Enum.each(&press(pid, &1))
  end

  defp submit(pid, text) do
    type(pid, text)
    press(pid, "enter")
  end

  # The runtime's own state carries our user_state; no test backdoor needed.
  defp get_state(pid) do
    runtime_state = :sys.get_state(pid)
    Map.get(runtime_state, :user_state)
  end

  defp cursor(pid), do: ExRatatui.textarea_cursor(get_state(pid).input)

  defp eventually(pid, fun, tries \\ 200) do
    state = get_state(pid)

    if fun.(state) do
      state
    else
      true = tries > 0
      Process.sleep(15)
      eventually(pid, fun, tries - 1)
    end
  end

  test "the standing catalog refresh starts at mount and lands in state (ADR 0009)" do
    # An injected fetcher (tests never touch the network); the sweep
    # delivers {:catalog, map} and the state stores it.
    provider =
      {:ok,
       %Config{
         base_url: "https://active.example/v1",
         model: "m1",
         api_key: "PLACEHOLDER-k",
         providers: [
           %{label: "a", base_url: "https://active.example/v1", api_key: "PLACEHOLDER-k"}
         ]
       }}

    {:ok, pid} =
      start_tui(
        provider: provider,
        catalog_fetcher: fn "https://active.example/v1", "PLACEHOLDER-k" ->
          {:ok, [%{model: "m1", context: 128_000}]}
        end
      )

    state = eventually(pid, fn s -> s.catalog != %{} end)

    assert state.catalog == %{
             "https://active.example/v1" => [%{model: "m1", context: 128_000}]
           }

    # The context denominator fills in from the catalog (config carried none).
    assert State.provider_context_tokens(state) == 128_000
  end

  test "the setup phase completes: a selection resolves through the resolver and hands off (ADR 0009)" do
    # The classification's :select arm boots the TUI in setup mode; the
    # modal's Enter runs the Application-style resolver, updates the
    # provider, and notifies the agent (here: the test process).
    resolver = fn
      "work" -> {:ok, %Config{base_url: "https://resolved.example/v1", model: "m1", api_key: "k"}}
    end

    {:ok, pid} =
      start_tui(
        provider: {:error, "no profile selected — choose one to start"},
        setup: {:select, ["work"], 0},
        resolve: resolver,
        config_dir: "/tmp/opencode/does-not-matter"
      )

    press(pid, "enter")

    assert_receive {:set_provider, {:ok, config}}, 1_000
    assert config.base_url == "https://resolved.example/v1"

    state = eventually(pid, fn s -> s.setup == nil end)
    assert state.provider == {:ok, config}
  end

  test "the onboarding wizard runs end to end through the app (ADR 0009)" do
    # A loopback /models server stands in for the provider: the wizard's
    # fetch goes through the REAL Catalog.fetch path, offline.
    script = [http_ok(models_body(["glm-loopback", "other-one"])), :close]

    {:ok, server} = SSEServer.start_link(script)
    on_exit(fn -> DashFloat.TestTeardown.stop(server) end)
    base = SSEServer.base_url(server)

    dir =
      Path.join(System.tmp_dir!(), "dashfloat-tui-wizard-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    resolver = fn _nil_or_name ->
      DashFloat.Config.load(dir, %{}, [])
    end

    {:ok, pid} =
      start_tui(
        provider: {:error, "no profile configured — finish first-run setup"},
        setup: Onboarding.new(),
        config_dir: dir,
        resolve: resolver
      )

    # welcome → profile name (accept the prefill) → provider: custom →
    # its URL (the loopback) → label (accept) → key paste.
    press(pid, "enter")
    press(pid, "enter")
    press(pid, "down")
    press(pid, "down")
    press(pid, "enter")

    for ch <- String.codepoints(base), do: press(pid, ch)
    press(pid, "enter")
    press(pid, "enter")
    for ch <- String.codepoints("PLACEHOLDER-wizard-key"), do: press(pid, ch)

    # The key Enter writes AND fires the /models fetch (issue #64).
    press(pid, "enter")

    # The key landed IMMEDIATELY (ADR 0009: per-step writes, 0600).
    keys_path = Path.join(dir, "keys.json5")
    eventually(pid, fn _s -> File.exists?(keys_path) end)
    assert match?({:ok, %File.Stat{}}, File.stat(keys_path))

    # The fetch lands on the picker; pick the second id.
    picker =
      eventually(pid, fn s ->
        s.setup != nil and s.setup.step == :model_pick
      end)

    assert picker.setup.fetched == [
             %{model: "glm-loopback", context: nil},
             %{model: "other-one", context: nil}
           ]

    press(pid, "down")
    press(pid, "enter")

    # Loop: done — settings.json5 is written, the wizard hands off, the
    # agent (the test process) gets the resolved provider.
    press(pid, "down")
    press(pid, "down")
    press(pid, "enter")

    # The done screen hands off (ADR 0009: any Enter finishes).
    press(pid, "enter")

    assert_receive {:set_provider, {:ok, config}}, 2_000
    assert config.base_url == base
    assert config.api_key == "PLACEHOLDER-wizard-key"
    assert config.model == "other-one"

    state = eventually(pid, fn s -> s.setup == nil end)
    assert state.provider == {:ok, config}

    # Both files on disk at 0600; the entered key is the effective one.
    settings_path = Path.join(dir, "settings.json5")
    assert File.exists?(settings_path)

    assert {:ok, %File.Stat{mode: keys_mode}} = File.stat(keys_path)
    assert Bitwise.band(keys_mode, 0o777) == 0o600

    assert {:ok, %File.Stat{mode: settings_mode}} = File.stat(settings_path)
    assert Bitwise.band(settings_mode, 0o777) == 0o600
  end

  test "a failed /models fetch falls back to manual entry with the reason on screen (issue #64)" do
    # The loopback answers HTTP 500: the key Enter's automatic fetch must
    # land the wizard on manual entry — the fetch layer's short reason on
    # screen, never an error screen — and manual entry completes the wizard.
    script = [{:send, "HTTP/1.1 500 Internal Server Error\r\ncontent-length: 0\r\n\r\n"}, :close]

    {:ok, server} = SSEServer.start_link(script)
    on_exit(fn -> DashFloat.TestTeardown.stop(server) end)
    base = SSEServer.base_url(server)

    dir = wizard_dir("dashfloat-tui-fetch-fail")
    resolver = fn _nil_or_name -> DashFloat.Config.load(dir, %{}, []) end

    {:ok, pid} =
      start_tui(
        provider: {:error, "no profile configured"},
        setup: Onboarding.new(),
        config_dir: dir,
        resolve: resolver
      )

    # welcome → profile name (accept the prefill) → provider: custom → its
    # URL (the loopback) → label (accept) → key — this Enter writes AND
    # fetches (issue #64).
    press(pid, "enter")
    press(pid, "enter")
    press(pid, "down")
    press(pid, "down")
    press(pid, "enter")

    for ch <- String.codepoints(base), do: press(pid, ch)
    press(pid, "enter")
    press(pid, "enter")
    for ch <- String.codepoints("PLACEHOLDER-fallback-key"), do: press(pid, ch)
    press(pid, "enter")

    manual =
      eventually(pid, fn s ->
        s.setup != nil and s.setup.step == :model_manual and s.setup.note != nil
      end)

    assert manual.setup.note == "Couldn't fetch the model list — HTTP 500."

    screen = screen_text(manual)
    assert screen =~ "Couldn't fetch the model list"
    assert screen =~ "HTTP 500"

    # Manual entry completes the provider; done writes the config.
    for ch <- String.codepoints("manual-model"), do: press(pid, ch)
    press(pid, "enter")
    press(pid, "down")
    press(pid, "down")
    press(pid, "enter")

    # The done screen hands off (ADR 0009: any Enter finishes).
    press(pid, "enter")

    assert_receive {:set_provider, {:ok, config}}, 2_000
    assert config.base_url == base
    assert config.api_key == "PLACEHOLDER-fallback-key"
    assert config.model == "manual-model"

    state = eventually(pid, fn s -> s.setup == nil end)
    assert state.provider == {:ok, config}

    dir
    |> Path.join("settings.json5")
    |> File.exists?()
    |> assert()
  end

  ## ESC back navigation through the live wizard (issue #65, ADR 0009)

  defp esc_tui(dir) do
    resolver = fn _nil_or_name -> DashFloat.Config.load(dir, %{}, []) end

    start_tui(
      provider: {:error, "no profile configured"},
      setup: Onboarding.new(),
      config_dir: dir,
      resolve: resolver
    )
  end

  test "esc at welcome is a no-op (issue #65)" do
    {:ok, pid} = esc_tui(wizard_dir("dashfloat-tui-esc-welcome"))

    press(pid, "esc")
    state = eventually(pid, fn s -> s.setup == Onboarding.new() end)
    assert state.setup.step == :welcome
  end

  test "esc at profile_name returns to welcome; the typed name round-trips (issue #65)" do
    {:ok, pid} = esc_tui(wizard_dir("dashfloat-tui-esc-name"))

    press(pid, "enter")
    eventually(pid, fn s -> s.setup.step == :profile_name end)

    for ch <- List.duplicate("backspace", 8) ++ String.codepoints("work"), do: press(pid, ch)
    press(pid, "esc")

    eventually(pid, fn s -> s.setup.step == :welcome end)

    press(pid, "enter")

    round_trip =
      eventually(pid, fn s ->
        s.setup.step == :profile_name and s.setup.draft == "work"
      end)

    assert round_trip.setup.draft == "work"
  end

  test "esc at provider returns to profile_name (issue #65)" do
    {:ok, pid} = esc_tui(wizard_dir("dashfloat-tui-esc-provider"))

    press(pid, "enter")
    press(pid, "enter")
    eventually(pid, fn s -> s.setup.step == :provider end)

    press(pid, "esc")

    back = eventually(pid, fn s -> s.setup.step == :profile_name end)
    assert back.setup.step == :profile_name
  end

  test "esc at custom_url returns to provider and the draft round-trips (issue #65)" do
    {:ok, pid} = esc_tui(wizard_dir("dashfloat-tui-esc-custom"))

    press(pid, "enter")
    press(pid, "enter")
    press(pid, "down")
    press(pid, "down")
    press(pid, "enter")
    eventually(pid, fn s -> s.setup.step == :custom_url end)

    for ch <- String.codepoints("https://esc.example/v1"), do: press(pid, ch)
    press(pid, "esc")

    back = eventually(pid, fn s -> s.setup.step == :provider end)
    assert back.setup.choice == 2

    # Forward again on the restored highlight: the draft comes back.
    press(pid, "enter")

    round_trip =
      eventually(pid, fn s ->
        s.setup.step == :custom_url and s.setup.draft == "https://esc.example/v1"
      end)

    assert round_trip.setup.draft == "https://esc.example/v1"
  end

  test "esc at label returns to provider (issue #65)" do
    {:ok, pid} = esc_tui(wizard_dir("dashfloat-tui-esc-label"))

    press(pid, "enter")
    press(pid, "enter")
    press(pid, "enter")
    eventually(pid, fn s -> s.setup.step == :label end)

    press(pid, "esc")

    back = eventually(pid, fn s -> s.setup.step == :provider end)
    assert back.setup.step == :provider
  end

  test "esc at key returns to label with the pending label on screen (issue #65)" do
    {:ok, pid} = esc_tui(wizard_dir("dashfloat-tui-esc-key"))

    press(pid, "enter")
    press(pid, "enter")
    press(pid, "enter")
    press(pid, "enter")
    eventually(pid, fn s -> s.setup.step == :key end)

    for ch <- String.codepoints("k"), do: press(pid, ch)
    press(pid, "esc")

    back =
      eventually(pid, fn s ->
        s.setup.step == :label and s.setup.draft == "zai"
      end)

    assert back.setup.step == :label
    assert screen_text(back) =~ "esc back"
  end

  test "esc while fetching falls back to manual entry — the exception (issue #65)" do
    # The server accepts the request and never answers: the wizard sits at
    # :fetching until esc takes the manual fallback.
    script = [{:wait_close, 5_000}]
    {:ok, server} = SSEServer.start_link(script)
    on_exit(fn -> DashFloat.TestTeardown.stop(server) end)
    base = SSEServer.base_url(server)

    {:ok, pid} = esc_tui(wizard_dir("dashfloat-tui-esc-fetching"))

    press(pid, "enter")
    press(pid, "enter")
    press(pid, "down")
    press(pid, "down")
    press(pid, "enter")
    for ch <- String.codepoints(base), do: press(pid, ch)
    press(pid, "enter")
    press(pid, "enter")
    for ch <- String.codepoints("PLACEHOLDER-esc-fetch"), do: press(pid, ch)
    press(pid, "enter")

    eventually(pid, fn s -> s.setup.step == :fetching end)
    press(pid, "esc")

    manual = eventually(pid, fn s -> s.setup.step == :model_manual end)
    assert manual.setup.step == :model_manual
  end

  test "esc at the picker returns to key with the key draft intact (issue #65)" do
    script = [http_ok(models_body(["glm-loopback"])), :close]
    {:ok, server} = SSEServer.start_link(script)
    on_exit(fn -> DashFloat.TestTeardown.stop(server) end)
    base = SSEServer.base_url(server)

    {:ok, pid} = esc_tui(wizard_dir("dashfloat-tui-esc-pick"))

    press(pid, "enter")
    press(pid, "enter")
    press(pid, "down")
    press(pid, "down")
    press(pid, "enter")
    for ch <- String.codepoints(base), do: press(pid, ch)
    press(pid, "enter")
    press(pid, "enter")
    for ch <- String.codepoints("PLACEHOLDER-esc-pick"), do: press(pid, ch)
    press(pid, "enter")

    eventually(pid, fn s -> s.setup.step == :model_pick end)
    press(pid, "esc")

    back =
      eventually(pid, fn s ->
        s.setup.step == :key and s.setup.draft == "PLACEHOLDER-esc-pick"
      end)

    assert back.setup.step == :key
  end

  test "esc at manual entry returns to key with the key draft intact (issue #65)" do
    script = [{:send, "HTTP/1.1 500 Internal Server Error\r\ncontent-length: 0\r\n\r\n"}, :close]
    {:ok, server} = SSEServer.start_link(script)
    on_exit(fn -> DashFloat.TestTeardown.stop(server) end)
    base = SSEServer.base_url(server)

    {:ok, pid} = esc_tui(wizard_dir("dashfloat-tui-esc-manual"))

    press(pid, "enter")
    press(pid, "enter")
    press(pid, "down")
    press(pid, "down")
    press(pid, "enter")
    for ch <- String.codepoints(base), do: press(pid, ch)
    press(pid, "enter")
    press(pid, "enter")
    for ch <- String.codepoints("PLACEHOLDER-esc-manual"), do: press(pid, ch)
    press(pid, "enter")

    eventually(pid, fn s -> s.setup.step == :model_manual end)
    for ch <- String.codepoints("m"), do: press(pid, ch)
    press(pid, "esc")

    back =
      eventually(pid, fn s ->
        s.setup.step == :key and s.setup.draft == "PLACEHOLDER-esc-manual"
      end)

    assert back.setup.step == :key
  end

  test "esc at the loop pops the provider finished from the picker (issue #65)" do
    script = [http_ok(models_body(["glm-loopback", "other-one"])), :close]
    {:ok, server} = SSEServer.start_link(script)
    on_exit(fn -> DashFloat.TestTeardown.stop(server) end)
    base = SSEServer.base_url(server)

    {:ok, pid} = esc_tui(wizard_dir("dashfloat-tui-esc-loop-pick"))

    press(pid, "enter")
    press(pid, "enter")
    press(pid, "down")
    press(pid, "down")
    press(pid, "enter")
    for ch <- String.codepoints(base), do: press(pid, ch)
    press(pid, "enter")
    press(pid, "enter")
    for ch <- String.codepoints("PLACEHOLDER-esc-loop"), do: press(pid, ch)
    press(pid, "enter")

    eventually(pid, fn s -> s.setup.step == :model_pick end)
    press(pid, "down")
    press(pid, "enter")
    eventually(pid, fn s -> s.setup.step == :loop end)

    press(pid, "esc")

    popped =
      eventually(pid, fn s ->
        s.setup.step == :model_pick and s.setup.providers == [] and
          s.setup.fetched == [
            %{model: "glm-loopback", context: nil},
            %{model: "other-one", context: nil}
          ]
      end)

    assert popped.setup.pending.models == []
    # The highlight is restored memory: back on the model that was picked.
    assert popped.setup.choice == 1

    # Re-picking re-finishes the provider exactly once.
    press(pid, "enter")

    refinished =
      eventually(pid, fn s ->
        s.setup.step == :loop and length(s.setup.providers) == 1
      end)

    assert [%{models: [%{nickname: "other-one", model: "other-one"}]}] =
             refinished.setup.providers
  end

  test "esc at the loop pops a manual-finish provider back to manual (issue #65)" do
    script = [{:send, "HTTP/1.1 500 Internal Server Error\r\ncontent-length: 0\r\n\r\n"}, :close]
    {:ok, server} = SSEServer.start_link(script)
    on_exit(fn -> DashFloat.TestTeardown.stop(server) end)
    base = SSEServer.base_url(server)

    {:ok, pid} = esc_tui(wizard_dir("dashfloat-tui-esc-loop-manual"))

    press(pid, "enter")
    press(pid, "enter")
    press(pid, "down")
    press(pid, "down")
    press(pid, "enter")
    for ch <- String.codepoints(base), do: press(pid, ch)
    press(pid, "enter")
    press(pid, "enter")
    for ch <- String.codepoints("PLACEHOLDER-esc-loop2"), do: press(pid, ch)
    press(pid, "enter")

    eventually(pid, fn s -> s.setup.step == :model_manual end)
    for ch <- String.codepoints("manual-model"), do: press(pid, ch)
    press(pid, "enter")
    eventually(pid, fn s -> s.setup.step == :loop end)

    press(pid, "esc")

    popped =
      eventually(pid, fn s ->
        s.setup.step == :model_manual and s.setup.draft == "manual-model" and
          s.setup.providers == []
      end)

    assert popped.setup.pending.models == []
    assert popped.setup.fetched == []

    press(pid, "enter")

    refinished =
      eventually(pid, fn s ->
        s.setup.step == :loop and length(s.setup.providers) == 1
      end)

    assert [%{models: [%{nickname: "manual-model", model: "manual-model"}]}] =
             refinished.setup.providers
  end

  test "esc at a provider-less loop returns to provider (issue #65)" do
    {:ok, pid} = esc_tui(wizard_dir("dashfloat-tui-esc-loop-empty"))

    press(pid, "enter")
    press(pid, "enter")
    press(pid, "down")
    press(pid, "down")
    press(pid, "down")
    press(pid, "enter")
    eventually(pid, fn s -> s.setup.step == :loop end)

    press(pid, "esc")

    back = eventually(pid, fn s -> s.setup.step == :provider end)
    assert back.setup.step == :provider
  end

  test "esc walks back through the mcp steps with drafts (issue #65)" do
    {:ok, pid} = esc_tui(wizard_dir("dashfloat-tui-esc-mcp"))

    press(pid, "enter")
    press(pid, "enter")
    press(pid, "down")
    press(pid, "down")
    press(pid, "down")
    press(pid, "enter")
    press(pid, "down")
    press(pid, "enter")
    eventually(pid, fn s -> s.setup.step == :mcp_name end)

    for ch <- String.codepoints("fetch"), do: press(pid, ch)
    press(pid, "enter")
    eventually(pid, fn s -> s.setup.step == :mcp_command end)

    for ch <- String.codepoints("uvx"), do: press(pid, ch)
    press(pid, "enter")
    eventually(pid, fn s -> s.setup.step == :mcp_args end)

    for ch <- String.codepoints("-y"), do: press(pid, ch)
    press(pid, "enter")
    eventually(pid, fn s -> s.setup.step == :mcp_token end)

    press(pid, "esc")

    eventually(pid, fn s ->
      s.setup.step == :mcp_args and s.setup.draft == "-y"
    end)

    press(pid, "esc")
    eventually(pid, fn s -> s.setup.step == :mcp_command and s.setup.draft == "uvx" end)

    press(pid, "esc")
    eventually(pid, fn s -> s.setup.step == :mcp_name and s.setup.draft == "fetch" end)

    press(pid, "esc")
    back_loop = eventually(pid, fn s -> s.setup.step == :loop end)
    assert back_loop.setup.step == :loop
  end

  test "esc at done is a no-op — the written config stands (issue #65)" do
    dir = wizard_dir("dashfloat-tui-esc-done")
    {:ok, pid} = esc_tui(dir)

    press(pid, "enter")
    press(pid, "enter")
    press(pid, "down")
    press(pid, "down")
    press(pid, "down")
    press(pid, "enter")
    press(pid, "down")
    press(pid, "down")
    press(pid, "enter")
    eventually(pid, fn s -> s.setup.step == :done end)

    settings_path = Path.join(dir, "settings.json5")
    assert File.exists?(settings_path)

    press(pid, "esc")

    trapped = eventually(pid, fn s -> s.setup.step == :done end)
    assert trapped.setup.step == :done
    assert File.exists?(settings_path)
  end

  test "a failing settings write at wizard-done surfaces the refusal and gates :done (issue #39)" do
    dir = wizard_dir("dashfloat-tui-swf")
    keys_file = Path.join(dir, "keys.json5")
    File.write!(keys_file, "{}")
    File.chmod!(keys_file, 0o600)
    # Block the settings WRITE itself (the unique staging name made a
    # planted .tmp inert): the directory is read-but-not-writable, so the
    # pre-write checks pass and Posture's touch of the staging file fails.
    on_exit(fn -> File.chmod!(dir, 0o700) end)
    File.chmod!(dir, 0o500)

    {:ok, pid} =
      start_tui(
        provider: {:error, "no profile configured"},
        setup: Onboarding.new(),
        config_dir: dir
      )

    # Straight to the loop with no provider and no key, then done.
    press(pid, "enter")
    press(pid, "enter")
    press(pid, "down")
    press(pid, "down")
    press(pid, "down")
    press(pid, "enter")
    press(pid, "down")
    press(pid, "down")
    press(pid, "enter")

    # The refusal bounced the wizard off :done — the error and remedy are on
    # screen, the done screen's copy never rendered, no file appeared.
    bounced =
      eventually(pid, fn s ->
        s.setup != nil and s.setup.step == :loop and s.setup.error != nil
      end)

    assert bounced.setup.error =~ "cannot write"
    assert screen_text(bounced) =~ "cannot write"
    refute screen_text(bounced) =~ "All set"

    settings_path = Path.join(dir, "settings.json5")
    refute File.exists?(settings_path)
  end

  test "P2-1 regression: a non-empty zero-profile settings.json5 refuses on the wizard surface, never lies (issue #39)" do
    # The exact shape whose :onboard classification boots the wizard. The
    # refusal (mv-aside remedy) must be ON SCREEN, :done must never render,
    # and the remedy must work in place: re-pick done after moving the file.
    dir = wizard_dir("dashfloat-tui-p21")
    settings_file = Path.join(dir, "settings.json5")
    File.write!(settings_file, "{configVersion: 3, profiles: []}")

    resolver = fn _name -> DashFloat.Config.load(dir, %{}, []) end

    {:ok, pid} =
      start_tui(
        provider: {:error, "no profile configured"},
        setup: Onboarding.new(),
        config_dir: dir,
        resolve: resolver
      )

    # Skip everything straight to done: welcome → name → provider skip → done.
    press(pid, "enter")
    press(pid, "enter")
    press(pid, "down")
    press(pid, "down")
    press(pid, "down")
    press(pid, "enter")
    press(pid, "down")
    press(pid, "down")
    press(pid, "enter")

    bounced =
      eventually(pid, fn s ->
        s.setup != nil and s.setup.step == :loop and s.setup.error != nil
      end)

    # The mv-aside remedy, on the wizard surface, file byte-unchanged.
    assert bounced.setup.error =~ "already exists and is not empty"
    assert bounced.setup.error =~ "settings.json5.old"

    screen = screen_text(bounced)
    assert screen =~ "not empty"
    assert screen =~ "retries the write"
    # The highlight stays on Done — Enter retries the write.
    assert screen =~ "❯ Done"
    refute screen =~ "All set"
    assert File.read!(settings_file) == "{configVersion: 3, profiles: []}"

    # No handoff reached the agent: finish is unreachable off a refused write.
    refute_receive {:set_provider, _classification}, 50

    # The remedy works in place: move the file aside, re-pick done — the
    # retry writes, the wizard reaches :done for real, and the handoff runs.
    File.rename!(settings_file, settings_file <> ".old")
    press(pid, "enter")

    eventually(pid, fn s -> s.setup != nil and s.setup.step == :done end)
    press(pid, "enter")

    assert_receive {:set_provider, _classification}, 2_000
  end

  test "P1-2 regression: a bracketed paste at the key step feeds the wizard, never the composer" do
    # Reviewer repro: paste at W3 routed to the hidden chat composer — the
    # key never reached keys.json5, and the first post-setup Enter SUBMITTED
    # it to the provider as a prompt.
    dir = wizard_dir("dashfloat-tui-paste")
    resolver = fn _name -> DashFloat.Config.load(dir, %{}, []) end

    {:ok, pid} =
      start_tui(
        provider: {:error, "no profile configured"},
        setup: Onboarding.new(),
        config_dir: dir,
        resolve: resolver
      )

    # To the key step: welcome → name (prefill) → zai preset → label.
    press(pid, "enter")
    press(pid, "enter")
    press(pid, "enter")
    press(pid, "enter")

    # THE PASTE (bracketed, with the trailing newline terminals add).
    Runtime.inject_event(pid, %ExRatatui.Event.Paste{
      content: "PLACEHOLDER-pasted-key\r\n"
    })

    state =
      eventually(pid, fn s ->
        s.setup != nil and s.setup.step == :key and s.setup.draft != ""
      end)

    # The wizard holds the key; the composer holds NOTHING.
    assert state.setup.draft == "PLACEHOLDER-pasted-key"
    assert State.input_text(state) == ""

    # Enter writes it — immediately, 0600 (ADR 0009 per-step writes).
    press(pid, "enter")

    keys_file = Path.join(dir, "keys.json5")

    eventually(pid, fn _s -> File.exists?(keys_file) end)

    zai = "https://api.z.ai/api/coding/paas/v4"

    assert {:ok, %{"personal" => %{^zai => "PLACEHOLDER-pasted-key"}}} =
             JSON5.read_map(keys_file)
  end

  test "P1-2 class guard: setup exits CLEAR the composer; Enter never submits mid-setup" do
    # Whatever a routing bug of the day drops into the composer during
    # setup, it can never become chat prompt text: (1) Enter while setup is
    # active belongs to the wizard; (2) leaving setup clears the draft.
    resolver = fn _name -> {:error, "resolved-error-arm"} end

    {:ok, pid} =
      start_tui(
        provider: {:error, "no profile selected — choose one to start"},
        setup: {:select, ["work"], 0},
        resolve: resolver
      )

    # Poison the composer directly (the routing-bug-of-the-day stand-in):
    # ExRatatui.textarea_set_value on the live input.
    state = get_state(pid)
    ExRatatui.textarea_set_value(state.input, "PLACEHOLDER-poison-key")

    # Enter while setup is active: the modal consumes it (select_profile),
    # never a submit.
    press(pid, "enter")

    assert_receive {:set_provider, {:error, "resolved-error-arm"}}, 1_000

    cleared = eventually(pid, fn s -> s.setup == nil end)
    assert State.input_text(cleared) == ""
    assert system_entries(cleared) == []
  end

  test "P2-3 regression: an :onboard classification resolves to a displayed error, never a crash" do
    # Reviewer repro path: the wizard's settings write fails → setup clears
    # → the resolver reloads a zero-profile directory → :onboard reached
    # the agent raw and crashed it on the first prompt (CaseClauseError).
    dir = wizard_dir("dashfloat-tui-onboard")
    # A directory that stays profile-less: the reload yields :onboard.
    resolver = fn _name -> DashFloat.Config.load(dir, %{}, []) end

    {:ok, pid} =
      start_tui(
        provider: {:error, "no profile configured"},
        setup: {:select, ["ghost"], 0},
        resolve: resolver,
        agent: self()
      )

    press(pid, "enter")

    assert_receive {:set_provider, {:error, handoff}}, 1_000
    assert handoff =~ "first-run setup is incomplete"
    refute match?(:onboard, handoff)
    refute match?({:select, _names}, handoff)
  end

  test "P2-3 arm: a {:select, names} reload hands the agent a readable error naming the profiles" do
    resolver = fn _name -> {:select, ["work", "personal"]} end

    {:ok, pid} =
      start_tui(
        provider: {:error, "no profile selected — choose one to start"},
        setup: {:select, ["work"], 0},
        resolve: resolver
      )

    press(pid, "enter")

    assert_receive {:set_provider, {:error, handoff}}, 1_000
    assert handoff =~ "no profile selected — choose one of: work, personal"
  end

  test "a selection with no resolver clears setup without crashing" do
    {:ok, pid} =
      start_tui(
        provider: {:error, "no profile selected — choose one to start"},
        setup: {:select, ["work"], 0}
      )

    press(pid, "enter")

    state = eventually(pid, fn s -> s.setup == nil end)
    assert state.provider == {:error, "no provider configured"}
  end

  test "a raising resolver degrades to the classification error arm" do
    resolver = fn _name -> raise "boom" end

    {:ok, pid} =
      start_tui(
        provider: {:error, "no profile selected — choose one to start"},
        setup: {:select, ["work"], 0},
        resolve: resolver
      )

    press(pid, "enter")

    state =
      eventually(pid, fn s ->
        s.provider == {:error, "config could not be loaded"}
      end)

    assert state.provider == {:error, "config could not be loaded"}
    assert state.setup == nil
  end

  test "a wizard $ENV_VAR key resolves from the environment for the fetch" do
    # The wizard stores the reference verbatim; the fetch resolves it.
    var = "DASHFLOAT_WIZARD_TEST_KEY"
    previous = System.get_env(var)
    System.put_env(var, "PLACEHOLDER-resolved-key")

    on_exit(fn ->
      if previous, do: System.put_env(var, previous), else: System.delete_env(var)
    end)

    script = [http_ok(models_body(["glm-env"])), :close]

    {:ok, server} = SSEServer.start_link(script)
    on_exit(fn -> DashFloat.TestTeardown.stop(server) end)
    base = SSEServer.base_url(server)

    dir = Path.join(System.tmp_dir!(), "dashfloat-tui-ref-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, pid} =
      start_tui(
        provider: {:error, "no profile configured"},
        setup: Onboarding.new(),
        config_dir: dir
      )

    press(pid, "enter")
    press(pid, "enter")
    press(pid, "down")
    press(pid, "down")
    press(pid, "enter")
    for ch <- String.codepoints(base), do: press(pid, ch)
    press(pid, "enter")
    press(pid, "enter")
    for ch <- String.codepoints("$" <> var), do: press(pid, ch)

    # The key Enter writes the reference AND fires the fetch; the reference
    # is resolved from the environment for the fetch only.
    press(pid, "enter")

    picker =
      eventually(pid, fn s ->
        s.setup != nil and s.setup.step == :model_pick
      end)

    assert picker.setup.fetched == [%{model: "glm-env", context: nil}]

    keys_file = Path.join(dir, "keys.json5")
    assert {:ok, keys} = JSON5.read_map(keys_file)
    assert keys["personal"][base] == "$" <> var
  end

  test "a refused key write surfaces at the key step; the damaged file is never clobbered (issue #39)" do
    dir = wizard_dir("dashfloat-tui-wizard")
    # Hand damage: an unparseable keys.json5 must be refused, never clobbered.
    keys_file = Path.join(dir, "keys.json5")
    File.write!(keys_file, "{ broken")

    {:ok, pid} =
      start_tui(
        provider: {:error, "no provider configured"},
        setup: Onboarding.new(),
        config_dir: dir
      )

    press(pid, "enter")
    press(pid, "enter")
    press(pid, "enter")
    press(pid, "enter")
    for ch <- String.codepoints("k"), do: press(pid, ch)
    press(pid, "enter")

    # The write refused: the wizard is back at :key with the refusal on
    # screen and the draft restored for editing; the damaged file is intact.
    refused =
      eventually(pid, fn s ->
        s.setup != nil and s.setup.step == :key and s.setup.error != nil
      end)

    assert refused.setup.error =~ "invalid JSON5"
    assert refused.setup.draft == "k"
    assert screen_text(refused) =~ "retries the write"
    assert File.read!(keys_file) == "{ broken"

    # A config dir in this state still loads to an error arm, never a crash.
    assert {:error, _load_error} = DashFloat.Config.load(dir, %{"DASHFLOAT_API_KEY" => "k"}, [])
  end

  test "P3-3 regression: an unquotable key surfaces its refusal; the hint matches file state (issue #39)" do
    # A backslash (or both quote kinds) cannot be stored in the JSON5
    # dialect: write_keys_entry refuses, keys.json5 stays absent, and the
    # wizard shows the refusal AT the key step — the draft restored (masked),
    # the hint no longer promising a write that did not happen.
    dir = wizard_dir("dashfloat-tui-p33")

    {:ok, pid} =
      start_tui(
        provider: {:error, "no provider configured"},
        setup: Onboarding.new(),
        config_dir: dir
      )

    # To the key step (zai preset, suggested label), then a backslash key.
    press(pid, "enter")
    press(pid, "enter")
    press(pid, "enter")
    press(pid, "enter")
    for ch <- String.codepoints("k-1\\9"), do: press(pid, ch)
    press(pid, "enter")

    refused =
      eventually(pid, fn s ->
        s.setup != nil and s.setup.step == :key and s.setup.error != nil
      end)

    assert refused.setup.error =~ "backslash or both quote kinds"
    assert refused.setup.error =~ "$ENV_VAR"

    # File state matches the screen: nothing was written, and the on-screen
    # hint is the retry wording — not the write promise.
    keys_file = Path.join(dir, "keys.json5")
    refute File.exists?(keys_file)

    screen = screen_text(refused)
    assert screen =~ "retries the write"
    refute screen =~ "immediately"
    refute screen =~ "k-1"

    # Fix in place: backspace out the backslash, re-accept — the retry writes
    # and its fetch fires (issue #64). No loopback stands in here, so the
    # wizard leaves :fetching for whichever arm the live endpoint yields.
    press(pid, "backspace")
    press(pid, "backspace")
    press(pid, "9")
    press(pid, "enter")

    eventually(
      pid,
      fn s -> s.setup != nil and s.setup.step != :fetching end,
      600
    )

    zai = "https://api.z.ai/api/coding/paas/v4"
    assert {:ok, %{"personal" => %{^zai => "k-19"}}} = JSON5.read_map(keys_file)
  end

  test "a pre-existing unquotable keys value refuses naming it; the hint matches the remedy (issue #42)" do
    # A hand-edited keys.json5 holding a backslashed value on ANOTHER
    # endpoint: the wizard's own entry is clean, so the refusal must blame
    # the stored value — and the bounce hint must not claim that fixing the
    # typed key fixes the write (the error/remedy contradiction).
    dir = wizard_dir("dashfloat-tui-p42")
    keys_file = Path.join(dir, "keys.json5")
    File.write!(keys_file, "{personal: {'https://other/v1': 'a\\b'}}")

    {:ok, pid} =
      start_tui(
        provider: {:error, "no provider configured"},
        setup: Onboarding.new(),
        config_dir: dir
      )

    # To the key step (zai preset, suggested label), then a CLEAN key.
    press(pid, "enter")
    press(pid, "enter")
    press(pid, "enter")
    press(pid, "enter")
    for ch <- String.codepoints("clean-key"), do: press(pid, ch)
    press(pid, "enter")

    refused =
      eventually(pid, fn s ->
        s.setup != nil and s.setup.step == :key and s.setup.error != nil
      end)

    assert refused.setup.error =~ "already holds a name or value"
    assert refused.setup.error =~ "by hand"
    assert refused.setup.error =~ "backslash or both quote kinds"
    # The typed key is masked and unblamed; the hint is the generic retry
    # wording, not "fix or empty the value" (the draft is not the culprit).
    screen = screen_text(refused)
    assert screen =~ "retries the write"
    refute screen =~ "fix or empty"
    refute screen =~ "clean-key"
    assert File.read!(keys_file) == "{personal: {'https://other/v1': 'a\\b'}}"

    # Apply the remedy by hand, retry the same key — the write lands and its
    # fetch fires (issue #64). The wizard leaves :fetching for whichever arm
    # the live endpoint yields; the assertions below are about the file.
    File.write!(keys_file, "{personal: {'https://other/v1': 'ab'}}")
    press(pid, "enter")

    eventually(
      pid,
      fn s -> s.setup != nil and s.setup.step != :fetching end,
      600
    )

    zai = "https://api.z.ai/api/coding/paas/v4"

    assert {:ok, %{"personal" => merged}} = JSON5.read_map(keys_file)
    assert merged["https://other/v1"] == "ab"
    assert merged[zai] == "clean-key"
  end

  defp wizard_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp http_ok(body) do
    length =
      body
      |> byte_size()
      |> Integer.to_string()

    {:send,
     "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: " <>
       length <> "\r\n\r\n" <> body}
  end

  defp models_body(ids) do
    ids
    |> Enum.map(&%{"id" => &1})
    |> then(&%{data: &1})
    |> Jason.encode!()
  end

  defp system_entries(state), do: for(%{kind: :system, text: text} <- state.entries, do: text)

  defp entry?(state, kind, text),
    do: Enum.any?(state.entries, &(&1.kind == kind and &1.text == text))

  test "supervised start renders, typed input accumulates, and an agent stream lands" do
    {:ok, pid} = start_tui(provider: provider())
    assert Runtime.snapshot(pid).render_count >= 1

    type(pid, "hello tui")
    typed = get_state(pid)
    assert State.input_text(typed) == "hello tui"

    press(pid, "enter")

    # Submit is a plain send to the agent with our pid as the reply address.
    assert_receive {:prompt, ui_pid, "hello tui", []}, 1_000
    assert ui_pid == pid

    # Mid-stream: the reply grows in flight (one token per message) and is
    # not finalized until the idle phase.
    send(ui_pid, {:token, "Hello"})
    streaming = eventually(pid, fn s -> s.in_flight == "Hello" end)
    assert streaming.phase == :streaming
    assert entry?(streaming, :user, "hello tui")

    send(ui_pid, {:token, " from the agent"})
    grown = eventually(pid, fn s -> s.in_flight == "Hello from the agent" end)
    assert grown.phase == :streaming

    send(ui_pid, {:phase, :idle})
    state = eventually(pid, fn s -> s.phase == :idle and s.in_flight == nil end)

    assert entry?(state, :assistant, "Hello from the agent")
    assert state.history == ["hello tui"]
    assert system_entries(state) == []

    # The footer under the composer names provider and model (ADR 0015 §2's
    # amendment: no settings entry matches, so the host degrades in); the
    # status bar keeps phase truth.
    assert State.provider_label(state) == "localhost - test-model"
    assert footer_text(state) =~ "test-model"
    refute status_text(state) =~ "test-model"
    assert status_text(state) =~ "Idle"
  end

  test "the footer under the composer carries cwd, model, and the live rate during a stream" do
    {:ok, pid} = start_tui(provider: provider())
    submit(pid, "stream for the footer")

    assert_receive {:prompt, ui_pid, "stream for the footer", []}, 1_000
    send(ui_pid, {:token, "x"})
    Process.sleep(20)
    send(ui_pid, {:token, "x"})

    # The tick recomputes the rate while streaming; give it a few frames.
    Process.sleep(300)

    state = get_state(pid)
    assert state.stats.rate != nil

    # (a) Render-output seam: the footer line carries cwd, model, and rate.
    text = footer_text(state)
    assert text =~ State.cwd_label(state)
    assert text =~ "test-model"
    assert text =~ "tok/s"

    # (b) Drawn-buffer probe: the footer reaches the screen.
    term = ExRatatui.init_test_terminal(80, 24)
    widgets = View.render(state, %ExRatatui.Frame{width: 80, height: 24})
    assert :ok = ExRatatui.draw(term, widgets)
    buffer = ExRatatui.get_buffer_content(term)
    assert buffer =~ "test-model"
    assert buffer =~ "tok/s"

    send(ui_pid, {:phase, :idle})
    eventually(pid, fn s -> s.phase == :idle and s.in_flight == nil end)
  end

  test "the footer's context span populates from an agent snapshot and reaches the screen" do
    provider =
      {:ok,
       %Config{
         base_url: "http://localhost:1",
         model: "test-model",
         api_key: "test-key-123",
         context_tokens: 128_000
       }}

    {:ok, pid} = start_tui(provider: provider)
    submit(pid, "stream for the footer")

    assert_receive {:prompt, ui_pid, "stream for the footer", []}, 1_000

    # Pre-snapshot: the span is hidden — no ratio anywhere in the footer.
    blank = get_state(pid)
    refute footer_text(blank) =~ "128k"

    send(
      ui_pid,
      {:context,
       %{
         messages: [%{role: "user", content: "stream for the footer"}],
         anchor: %{tokens: 4_100, index: 1}
       }}
    )

    send(ui_pid, {:token, "x"})

    state =
      eventually(pid, fn s -> s.context != nil and s.in_flight != nil end)

    # (a) Render-output seam: the span carries tokens-used and percent.
    assert footer_text(state) =~ "4.1k/128k · 3.2%"

    # (b) Drawn-buffer probe: the span reaches the screen.
    term = ExRatatui.init_test_terminal(80, 24)
    widgets = View.render(state, %ExRatatui.Frame{width: 80, height: 24})
    assert :ok = ExRatatui.draw(term, widgets)
    buffer = ExRatatui.get_buffer_content(term)
    assert buffer =~ "4.1k/128k"

    send(ui_pid, {:phase, :idle})
    eventually(pid, fn s -> s.phase == :idle and s.in_flight == nil end)
  end

  test "Esc during streaming sends {:cancel} to the agent and the agent's ack lands" do
    {:ok, pid} = start_tui()
    submit(pid, "cancel me")

    assert_receive {:prompt, ui_pid, "cancel me", []}, 1_000
    send(ui_pid, {:token, "partial"})
    eventually(pid, fn s -> s.in_flight == "partial" end)

    press(pid, "esc")
    assert_receive {:cancel}, 1_000

    # The agent's half of the cancel contract: explanation + idle.
    send(ui_pid, {:entry, :system, "[cancelled]"})
    send(ui_pid, {:phase, :idle})

    state =
      eventually(pid, fn s ->
        s.phase == :idle and "[cancelled]" in system_entries(s)
      end)

    assert entry?(state, :assistant, "partial")

    # Input is usable again.
    submit(pid, "again")
    assert_receive {:prompt, ^ui_pid, "again", []}, 1_000
  end

  # Shift+Tab rides the agent seam (ADR 0016 §7): send, then the echo applies.
  test "shift+tab sends the mode to the agent; the echo applies it" do
    {:ok, pid} = start_tui()

    press(pid, "tab", ["shift"])

    assert_receive {:set_mode, ^pid, :auto}, 1_000
    # No optimistic apply: the chrome waits for the agent's single voice.
    assert get_state(pid).mode == :build

    send(pid, {:mode, :auto})
    state = eventually(pid, &(&1.mode == :auto))
    assert state.mode == :auto
  end

  ## The command surface's deliveries (ADR 0020). /title, /mode, and
  ## /profile are proven against the default fake agent (this test process)
  ## and the picker state; /model is proven END TO END with a real agent and
  ## the loopback server — the switch must reach the NEXT request.

  test "/title delivers the rename seam: the typed title, then the dialog's submit" do
    {:ok, pid} = start_tui()

    submit(pid, "/title fix the login")
    assert_receive {:set_title, ^pid, "fix the login"}, 1_000

    # Bare /title opens the dialog; Enter submits its draft through the same
    # seam — the agent owns validation either way.
    submit(pid, "/title")
    eventually(pid, fn s -> s.title_dialog != nil end)
    press(pid, "enter")
    assert_receive {:set_title, ^pid, ""}, 1_000
  end

  test "/compact delivers to the agent as {:compact, pid}" do
    {:ok, pid} = start_tui()

    submit(pid, "/compact")
    assert_receive {:compact, ^pid}, 1_000
  end

  test "/mode plan reaches the agent through shift+tab's seam" do
    {:ok, pid} = start_tui()

    submit(pid, "/mode plan")

    assert_receive {:set_mode, ^pid, :plan}, 1_000
  end

  test "/profile opens the profiles picker over settings.json5's names; esc closes it" do
    dir = wizard_dir("dashfloat-tui-profiles")
    settings = Path.join(dir, "settings.json5")
    File.write!(settings, "{profiles: [{name: 'work'}, {name: 'personal'}]}")

    {:ok, pid} = start_tui(config_dir: dir)

    submit(pid, "/profile")

    opened =
      eventually(pid, fn s ->
        match?(%{mode: :modal, kind: :profiles}, s.palette)
      end)

    assert opened.palette.items == ["work", "personal"]
    assert opened.palette.selected == 0

    press(pid, "down")

    moved = eventually(pid, fn s -> s.palette && s.palette.selected == 1 end)
    assert moved.palette.items == ["work", "personal"]

    press(pid, "esc")
    eventually(pid, fn s -> s.palette == nil end)
  end

  ## The /title dialog (issue #106) driven through the app: the default fake
  ## agent (this test process) answers with the title pushes.

  describe "the /title dialog" do
    defp open_dialog(pid) do
      submit(pid, "/title")
      eventually(pid, fn s -> s.title_dialog != nil end)
    end

    test "bare /title opens the dialog pre-filled from the mount title" do
      {:ok, pid} = start_tui(title: "Booted Title")

      state = open_dialog(pid)

      assert state.title_dialog == %{draft: "Booted Title", error: nil}
    end

    test "enter sends the draft; the agent's {:title, _} closes the dialog and updates" do
      {:ok, pid} = start_tui(title: "Old")

      open_dialog(pid)
      type(pid, "Name")
      press(pid, "enter")

      assert_receive {:set_title, ^pid, "OldName"}, 1_000

      # The dialog is still open, error cleared, until the agent's reply.
      assert get_state(pid).title_dialog == %{draft: "OldName", error: nil}

      send(pid, {:title, "OldName"})
      state = eventually(pid, fn s -> s.title_dialog == nil end)
      assert state.title == "OldName"
    end

    test "the agent's {:title_refused, _} errors the open dialog, draft kept" do
      {:ok, pid} = start_tui()
      open_dialog(pid)
      type(pid, "Taken")
      press(pid, "enter")

      assert_receive {:set_title, ^pid, "Taken"}, 1_000

      reason = ~s("Taken" is already taken by session 0192aa10-b002-7c00-8000-00000000000c)
      send(pid, {:title_refused, reason})

      state = eventually(pid, fn s -> s.title_dialog.error != nil end)
      assert state.title_dialog == %{draft: "Taken", error: reason}
    end

    test "esc closes the dialog and nothing is sent" do
      {:ok, pid} = start_tui()

      open_dialog(pid)
      press(pid, "esc")

      eventually(pid, fn s -> s.title_dialog == nil end)
      refute_received {:set_title, _, _}
    end

    test "a paste feeds the open dialog's draft, not the composer" do
      {:ok, pid} = start_tui()
      open_dialog(pid)

      inject(pid, %ExRatatui.Event.Paste{content: "pasted name\r\n"})

      state = eventually(pid, fn s -> s.title_dialog == %{draft: "pasted name", error: nil} end)
      assert State.input_text(state) == ""
    end

    test "the agent's pushes reach the state with no dialog open" do
      {:ok, pid} = start_tui()

      send(pid, {:title, "Inline Title"})
      assert eventually(pid, &(&1.title == "Inline Title")).title_dialog == nil

      send(pid, {:title_refused, "may not be empty"})
      state = eventually(pid, &(&1.title == "Inline Title"))
      assert state.title_dialog == nil
      assert state.entries == []
    end
  end

  # A final-only episode: one content frame, then DONE — the agent returns to
  # idle after it (agent_test's final_episode shape, mirrored locally).
  defp final_episode(text) do
    frame = ~s(data: {"choices":[{"index":0,"delta":{"content":#{Jason.encode!(text)}}}]}\n\n)

    [
      {:send,
       ["HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n", frame]},
      {:send, "data: [DONE]\n\n"},
      :close
    ]
  end

  # THE load-bearing e2e (ADR 0020): /model's switch provably takes effect on
  # the NEXT request. A real agent (supervised like agent_test wires one)
  # streams two final-only episodes off the per-connection loopback; the
  # catalog lands by message (no HTTP for the picker), so the server sees
  # exactly the two chat POSTs — the second body's model is the assertion.
  test "/model switches the model for the next request, end to end at the request seam" do
    {:ok, server} =
      SSEServer.start_link(:per_connection, [
        final_episode("first reply"),
        final_episode("second reply")
      ])

    on_exit(fn -> DashFloat.TestTeardown.stop(server) end)
    base = SSEServer.base_url(server)

    provider =
      {:ok, %Config{base_url: base, model: "model-a", api_key: "test-key-123", auto_title: false}}

    # A REAL agent, per-test supervised like the app does (agent_test's shape).
    {:ok, sup} = Task.Supervisor.start_link()

    {:ok, agent} =
      DashFloat.Agent.start_link(
        provider: provider,
        cwd: wizard_dir("dashfloat-tui-model-switch"),
        exec_timeout: 500,
        supervisor: sup,
        name: nil
      )

    on_exit(fn ->
      DashFloat.TestTeardown.stop(agent)
      if Process.alive?(sup), do: Process.exit(sup, :kill)
    end)

    {:ok, pid} = start_tui(agent: agent, provider: provider)

    # Turn 1: model-a is on the wire.
    submit(pid, "hello")
    assert_receive {:sse_request, "POST", _, _, first_body}, 2_000
    assert Jason.decode!(first_body)["model"] == "model-a"

    # The final-only episode returns the agent — and the UI — to idle.
    eventually(pid, fn s -> s.phase == :idle end)

    # The standing catalog sweep's result arrives by message (tests never
    # touch the network for it), so connections stay the two chat POSTs.
    catalog = %{base => [%{model: "model-a", context: nil}, %{model: "model-b", context: nil}]}
    send(pid, {:catalog, catalog})
    eventually(pid, fn s -> s.catalog != %{} end)

    # The picker opens preselected on the active model; down + enter picks model-b.
    submit(pid, "/model")

    opened =
      eventually(pid, fn s ->
        match?(%{mode: :modal, kind: :models}, s.palette)
      end)

    assert opened.palette.selected == 0

    press(pid, "down")
    press(pid, "enter")

    eventually(pid, fn s ->
      match?({:ok, %Config{model: "model-b"}}, s.provider)
    end)

    # THE load-bearing assertion: the switch took effect on the next request.
    submit(pid, "again")
    assert_receive {:sse_request, "POST", _, _, second_body}, 2_000
    assert Jason.decode!(second_body)["model"] == "model-b"
  end

  test "quit keys stop the supervised app with reason :normal" do
    {:ok, pid} = start_tui()
    attach_disconnect_listener()

    ref = Process.monitor(pid)
    press(pid, "q", ["ctrl"])

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert_receive {:transport_disconnect, :normal}, 1_000
  end

  # Issue #28: a single accidental Ctrl+C must not exit. One press shows the
  # transient prompt (activity row up while idle); a second press inside the
  # 2 s window exits through the normal teardown.
  test "one Ctrl+C shows the prompt and does not exit; the prompt self-clears" do
    {:ok, pid} = start_tui()
    attach_disconnect_listener()

    press(pid, "c", ["ctrl"])

    armed = eventually(pid, fn s -> s.exit_guard_at != nil end)
    assert armed.exit_guard_ref != nil
    assert Process.alive?(pid)
    assert activity_text(armed) == "Press Ctrl+C again to exit"

    # The expiry is one frame, not a loop: the prompt clears at ~2 s and the
    # app goes quiet again — no idle-render regression (ADR 0006).
    cleared = eventually(pid, fn s -> s.exit_guard_at == nil end, 400)
    assert cleared.exit_guard_ref == nil

    {cleared_activity, _rect} =
      cleared
      |> View.render(%ExRatatui.Frame{width: 80, height: 24})
      |> Enum.at(2)

    assert cleared_activity.text == []

    settled = Runtime.snapshot(pid).render_count
    Process.sleep(300)
    assert Runtime.snapshot(pid).render_count == settled
    assert Process.alive?(pid)
  end

  test "two Ctrl+C presses inside the window quit through the normal teardown" do
    {:ok, pid} = start_tui()
    attach_disconnect_listener()

    ref = Process.monitor(pid)
    press(pid, "c", ["ctrl"])
    armed = eventually(pid, fn s -> s.exit_guard_at != nil end)
    press(pid, "c", ["ctrl"])

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert_receive {:transport_disconnect, :normal}, 1_000
    assert armed.phase == :idle
  end

  # The guard's one-shot timer must never clear a live window: a message
  # from a cancelled or superseded timer is dropped without a frame.
  test "stale exit-guard messages are dropped without a frame" do
    idle = State.new(test_mode: {80, 24})
    assert {:noreply, ^idle, %{render?: false}} = TUI.handle_info(:dashfloat_exit_guard, idle)

    # A guard message while the tracked timer has not fired yet is stale —
    # it belongs to an earlier, superseded window.
    ref = Process.send_after(self(), :never, 10_000)
    armed = %{idle | exit_guard_at: 1, exit_guard_ref: ref}

    assert {:noreply, ^armed, %{render?: false}} = TUI.handle_info(:dashfloat_exit_guard, armed)
    Process.cancel_timer(ref)

    # A fired timer's message clears the prompt and renders (the prompt
    # disappearing IS the frame).
    fired_ref = Process.send_after(self(), :dashfloat_exit_guard, 1)
    fired = %{idle | exit_guard_at: 1_000, exit_guard_ref: fired_ref}
    Process.sleep(20)

    assert {:noreply, cleared} = TUI.handle_info(:dashfloat_exit_guard, fired)
    assert cleared.exit_guard_at == nil and cleared.exit_guard_ref == nil
  end

  # The disarm path: a keystroke between arming and expiry cancels the
  # pending timer outright — no orphan frame later.
  test "a disarming key press cancels the pending expiry timer" do
    {:ok, pid} = start_tui()

    press(pid, "c", ["ctrl"])
    armed = eventually(pid, fn s -> s.exit_guard_at != nil end)
    assert armed.exit_guard_ref != nil

    press(pid, "x")
    disarmed = eventually(pid, fn s -> s.exit_guard_at == nil end)

    assert disarmed.exit_guard_ref == nil
    assert State.input_text(disarmed) == "x"

    # Disarmed means no expiry frame either: the quiet window stays quiet.
    settled = Runtime.snapshot(pid).render_count
    Process.sleep(300)
    assert Runtime.snapshot(pid).render_count == settled
  end

  # Incidental events (the wheel here, stream messages equally) must not
  # disturb a pending expiry: the timer stays live and still fires on time.
  test "incidental events leave a pending expiry timer alone" do
    {:ok, pid} = start_tui()

    press(pid, "c", ["ctrl"])
    armed = eventually(pid, fn s -> s.exit_guard_at != nil end)
    armed_ref = armed.exit_guard_ref

    scroll(pid, "scroll_up")
    wheeled = get_state(pid)

    assert wheeled.exit_guard_at != nil
    assert wheeled.exit_guard_ref == armed_ref
    assert State.exit_guard_live?(wheeled, System.monotonic_time(:millisecond))

    # The original timer still owns the expiry: the prompt clears without
    # a second press.
    cleared = eventually(pid, fn s -> s.exit_guard_at == nil end, 400)
    assert cleared.exit_guard_ref == nil
  end

  # The fired-but-undrained race: an event is processed after the timer
  # fired but before its message drained. The timer is replaced (exactly
  # one per window) and the orphaned message is dropped by the staleness
  # check instead of clearing the fresh window.
  test "a fired-but-undrained guard timer is replaced, orphan dropped" do
    base = State.new(test_mode: {80, 24})

    fired_ref = Process.send_after(self(), :dashfloat_exit_guard, 1)
    Process.sleep(20)

    # A fresh arming (1 s left on its window) whose tracked timer already
    # fired but has not drained.
    armed = %{
      base
      | phase: :streaming,
        exit_guard_at: System.monotonic_time(:millisecond) - 1_000,
        exit_guard_ref: fired_ref
    }

    # A stream message schedules while the fired timer's message is queued.
    assert {:noreply, rescheduled} = TUI.handle_info({:token, "t"}, armed)
    assert rescheduled.exit_guard_ref != nil
    assert rescheduled.exit_guard_ref != fired_ref

    # The orphaned message is stale against the new timer: no frame, and
    # the fresh window survives it.
    assert {:noreply, kept, %{render?: false}} =
             TUI.handle_info(:dashfloat_exit_guard, rescheduled)

    assert kept.exit_guard_at != nil
    assert kept.exit_guard_ref == rescheduled.exit_guard_ref

    Process.cancel_timer(kept.exit_guard_ref)
  end

  @tag :capture_log
  test "a crashing message tears the app down through the terminal-restore path" do
    {:ok, pid} = start_tui()
    attach_disconnect_listener()

    ref = Process.monitor(pid)

    # {:phase, :bogus} violates the stream contract; State.stream_message/2 has
    # no clause for it, so the callback raises like any real bug would.
    bogus = :bogus
    send(pid, {:phase, bogus})

    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 1_000
    assert reason != :normal

    # The disconnect telemetry fires from ExRatatui.Server.terminate/2 — the
    # same path that restores the terminal and reattaches the BEAM reader.
    assert_receive {:transport_disconnect, _crash_reason}, 1_000
  end

  test "history is reachable through real key events" do
    {:ok, pid} = start_tui()

    submit(pid, "first")
    assert_receive {:prompt, ui_pid, "first", []}, 1_000
    send(ui_pid, {:phase, :idle})
    eventually(pid, &(&1.phase == :idle))

    submit(pid, "second")
    assert_receive {:prompt, ^ui_pid, "second", []}, 1_000
    send(ui_pid, {:phase, :idle})
    eventually(pid, &(&1.phase == :idle))

    press(pid, "up")
    latest = get_state(pid)
    assert State.input_text(latest) == "second"
    press(pid, "up")
    oldest = get_state(pid)
    assert State.input_text(oldest) == "first"
    press(pid, "down")
    press(pid, "down")
    restored = get_state(pid)
    assert State.input_text(restored) == ""
  end

  @tag :capture_log
  test "a dead agent degrades to idle with an explanation instead of bricking input" do
    agent =
      spawn(fn ->
        receive do
          {:prompt, ui, _text, _paths} -> send(ui, {:token, "slow"})
        end

        # Park until the test kills this process.
        :timer.sleep(:infinity)
      end)

    {:ok, pid} = start_tui(agent: agent)
    submit(pid, "hello")

    eventually(pid, fn s -> s.in_flight == "slow" end)
    Process.exit(agent, :kill)

    state =
      eventually(pid, fn s ->
        entries = system_entries(s)
        s.phase == :idle and Enum.any?(entries, &String.contains?(&1, "agent failed"))
      end)

    assert state.agent_ref == nil
    assert entry?(state, :user, "hello")
    assert entry?(state, :assistant, "slow")

    # Input is usable again: typing works and a fresh submit still flips to
    # :streaming optimistically (the dead agent just never answers).
    type(pid, "again")
    typed = get_state(pid)
    assert State.input_text(typed) == "again"

    press(pid, "enter")
    eventually(pid, &(&1.phase == :streaming))
  end

  test "a normally-exiting agent logs no failure (idle finalize only)" do
    agent =
      spawn(fn ->
        receive do
          {:prompt, ui, _text, _paths} ->
            send(ui, {:token, "done"})
            send(ui, {:phase, :idle})
        end
      end)

    {:ok, pid} = start_tui(agent: agent)
    submit(pid, "quick")

    # The agent answers then exits :normal; the DOWN must not read as failure.
    state =
      eventually(pid, fn s ->
        s.phase == :idle and s.agent_ref == nil and
          Enum.any?(s.entries, &(&1.kind == :assistant))
      end)

    assert entry?(state, :assistant, "done")
    assert system_entries(state) == []
  end

  @tag :capture_log
  test "the UI stays responsive while a stream lands at cadence into a large log" do
    {:ok, pid} = start_tui()

    # Preload a log far beyond the viewport (400 entries = 800 rendered lines
    # including their blank separators).
    Enum.each(1..400, fn i -> send(pid, {:entry, :system, "warm #{i}"}) end)
    eventually(pid, &(State.log_line_count(&1) == 800))

    # Burst coalescing with a big log: hundreds of messages, few frames.
    burst = Enum.map(1..300, &"b#{&1} ")
    burst_text = IO.iodata_to_binary(burst)
    # Tokens ride a live turn per the stream contract — a stray token at
    # idle is ignored (ADR 0015 §3's once-per-turn arm).
    send(pid, {:phase, :streaming})
    before = Runtime.snapshot(pid).render_count
    Enum.each(burst, &send(pid, {:token, &1}))
    eventually(pid, &(&1.in_flight == burst_text))
    assert Runtime.snapshot(pid).render_count - before < 50

    # Cadence phase: tokens every 2ms while the user keeps typing.
    cadence_count = 200

    cadence =
      spawn(fn ->
        Enum.each(1..cadence_count, fn _i ->
          send(pid, {:token, "c"})
          Process.sleep(2)
        end)
      end)

    timings_ms =
      Enum.map(1..5, fn _i ->
        {micros, :ok} = :timer.tc(fn -> press(pid, "z") end)
        div(micros, 1000)
      end)

    max_ms = Enum.max(timings_ms)

    # Two asserts catch two different serialisation modes, and each is
    # credited only for what it alone catches.
    #
    # (1) Whole-stream serialisation, clock-free: all five synchronous
    # round-trips have RETURNED while the stream is still mid-flight. A UI
    # that queued input behind the entire stream would service the presses
    # only after draining every token, so the buffer would already be
    # complete. This compares LENGTHS, not durations. It is not literally
    # contention-immune — the cadence producer is wall-clock paced (200 ×
    # 2 ms sleeps, so it finishes at >= 400 ms under any load) while the
    # round-trips are load-sensitive, so a run that stretched them past the
    # producer's whole window without exceeding the per-call backstop below
    # could false-red here. That window is narrow (all five uniformly 8-20x
    # degraded and still under 100 ms each, measured worst case 28 ms under
    # 24 CPU hogs) and it fails red, never green.
    mid_flight = get_state(pid)

    assert String.length(mid_flight.in_flight || "") < String.length(burst_text) + cadence_count,
           "every cadence token had landed before the presses returned — input was " <>
             "serialised behind the stream"

    # (2) Per-keystroke backlog, load-bearing for this mode: input that waits
    # behind a QUEUE of pending tokens (not the whole stream) leaves the
    # buffer incomplete, so (1) passes and only this catches it. 100 ms is
    # 3.5x the worst round-trip measured on this host under 24 CPU hogs
    # (28 ms). The fragile assert this replaces was #51's 400 ms tick budget
    # at 1.05x headroom.
    assert max_ms < 100, "input round-tripped in #{max_ms}ms, over the backstop"

    ref = Process.monitor(cadence)
    assert_receive {:DOWN, ^ref, :process, ^cadence, :normal}, 2_000

    # Exact count: every burst and cadence token landed, and every keystroke
    # was kept — a single dropped message fails this.
    expected = burst_text <> String.duplicate("c", cadence_count)

    state =
      eventually(pid, &(String.length(&1.in_flight || "") >= String.length(expected)))

    assert state.in_flight == expected
    assert State.input_text(state) == "zzzzz"
  end

  # Issue #20: a resize re-wraps the log to the new width live — no restart,
  # no restart of the turn, and nothing lost at the pane edge.
  test "a resize re-wraps the log live and follow stays pinned" do
    {:ok, pid} = start_tui()
    long = "the quick brown fox jumps over the lazy dog again and again"

    send(pid, {:entry, :system, long})
    state = eventually(pid, &(State.log_line_count(&1) == 2))
    assert State.log_line_count(state) == 2

    inject(pid, %ExRatatui.Event.Resize{width: 20, height: 24})
    narrowed = eventually(pid, &(State.log_line_count(&1) > 2))

    assert narrowed.size == {20, 24}
    assert narrowed.follow?
    # Content still fits the viewport at this size, so follow pins at 0; make
    # it overflow and confirm the pin moves with the wrapped bottom.
    Enum.each(1..20, fn i -> send(pid, {:entry, :system, "#{i} #{long}"}) end)

    full = eventually(pid, &(State.log_line_count(&1) > 24))
    assert State.effective_scroll(full, 20) == State.log_line_count(full) - 20

    # Full text survives the re-wrap, every row fits the new padded width.
    [entry] = narrowed.entries

    rows = Enum.map(entry.lines, &Enum.map_join(&1.spans, "", fn s -> s.content end))

    joined = Enum.join(rows, " ")
    assert String.split(joined) == String.split(long)
    assert Enum.all?(rows, &(&1 == "" or String.length(&1) <= 18))

    # And the drawn frame really carries the wrapped rows, not a truncation.
    term = ExRatatui.init_test_terminal(20, 24)
    widgets = View.render(narrowed, %ExRatatui.Frame{width: 20, height: 24})
    assert :ok = ExRatatui.draw(term, widgets)
    buffer = ExRatatui.get_buffer_content(term)

    for word <- ~w(jumps over lazy dog again) do
      assert buffer =~ word
    end
  end

  test "paste, resize, key releases, unknown events, and stray messages are handled" do
    {:ok, pid} = start_tui()

    inject(pid, %ExRatatui.Event.Paste{content: "pasted text"})
    pasted = get_state(pid)
    assert State.input_text(pasted) == "pasted text"

    inject(pid, %ExRatatui.Event.Resize{width: 100, height: 30})
    assert get_state(pid).size == {100, 30}

    # Key releases are ignored (kitty protocol).
    inject(pid, %ExRatatui.Event.Key{code: "x", modifiers: [], kind: "release"})
    released = get_state(pid)
    assert State.input_text(released) == "pasted text"

    # Events and messages we do not use are dropped, not crashes.
    inject(pid, %ExRatatui.Event.FocusGained{})
    inject(pid, %ExRatatui.Event.Mouse{kind: "down"})
    send(pid, :stray_message)
    after_stray = get_state(pid)
    assert State.input_text(after_stray) == "pasted text"

    # The event catch-all: a struct the app never names schedules (never
    # crashes) and renders nothing.
    inject(pid, %UnknownEvent{})
    after_unknown = get_state(pid)
    assert State.input_text(after_unknown) == "pasted text"
  end

  # Focus events gate the composer's cursor artifact (ADR 0015 §1): an
  # unfocused pane shows no cursor at all.
  test "focus events toggle the composer cursor" do
    {:ok, pid} = start_tui()

    inject(pid, %ExRatatui.Event.FocusLost{})
    lost = get_state(pid)
    refute lost.focused?

    {widget, _rect} =
      lost
      |> View.render(%ExRatatui.Frame{width: 80, height: 24})
      |> Enum.at(3)

    assert widget.cursor_style == %ExRatatui.Style{}

    inject(pid, %ExRatatui.Event.FocusGained{})
    gained = eventually(pid, & &1.focused?)

    {gained_widget, _rect} =
      gained
      |> View.render(%ExRatatui.Frame{width: 80, height: 24})
      |> Enum.at(3)

    assert gained_widget.cursor_style == Theme.style(:cursor)
  end

  # ADR 0006 paste hardening: CRLF/lone-CR normalize to LF, insertion at the
  # cursor, and wrap stays visual (the draft keeps one logical line).
  test "a multi-line bracketed paste with CRLF normalizes to LF at the cursor" do
    {:ok, pid} = start_tui()

    type(pid, "ab")
    press(pid, "left")

    inject(pid, %ExRatatui.Event.Paste{content: "line one\r\nline two\r\rline three"})
    state = get_state(pid)

    assert State.input_text(state) == "aline one\nline two\n\nline threeb"
    assert State.input_line_count(state) == 4
  end

  # Input-box wrap re-check (issue #20): the textarea wraps the draft itself
  # (Rust-side, per frame at the area width), so a resize re-wraps it with no
  # help from us; the box height stays bound to LOGICAL lines by ADR 0002 —
  # wrapped overflow scrolls inside the box rather than growing it.
  test "a long draft renders and stays whole through a narrow resize" do
    {:ok, pid} = start_tui()
    long = "https://example.com/" <> String.duplicate("segment-", 40)

    inject(pid, %ExRatatui.Event.Paste{content: long})
    pasted = get_state(pid)
    assert State.input_text(pasted) == long
    assert State.input_line_count(pasted) == 1

    inject(pid, %ExRatatui.Event.Resize{width: 30, height: 12})
    state = eventually(pid, &(&1.size == {30, 12}))

    # One logical line still: the box keeps its idle height, wrap is visual.
    assert State.input_line_count(state) == 1
    assert State.input_text(state) == long

    widgets = View.render(state, %ExRatatui.Frame{width: 30, height: 12})
    {input_widget, input_rect} = Enum.at(widgets, 3)
    assert input_widget.wrap_mode == :word_or_glyph
    assert input_rect.height == View.input_height(1, 12)

    # The narrow frame draws whole without raising; the cursor row stays
    # visible (the textarea scrolls its own wrapped overflow).
    term = ExRatatui.init_test_terminal(30, 12)
    assert :ok = ExRatatui.draw(term, widgets)
    assert ExRatatui.get_buffer_content(term) =~ "❯"
  end

  test "a very long unbroken paste stays one logical line and does not grow the box" do
    {:ok, pid} = start_tui()
    long = "https://example.com/" <> String.duplicate("segment-", 200)

    inject(pid, %ExRatatui.Event.Paste{content: long})
    state = get_state(pid)

    # Wrap is visual: one logical line, so the input box keeps its idle height.
    assert State.input_text(state) == long
    assert State.input_line_count(state) == 1

    widgets = View.render(state, %ExRatatui.Frame{width: 80, height: 24})
    {widget, rect} = Enum.at(widgets, 3)

    assert widget.wrap_mode == :word_or_glyph
    assert rect.height == View.input_height(1, 24)
  end

  test "cursor movement within a pasted multi-line draft is row-aware" do
    {:ok, pid} = start_tui()

    submit(pid, "seed")
    assert_receive {:prompt, ui_pid, "seed", []}, 1_000
    send(ui_pid, {:phase, :idle})
    eventually(pid, &(&1.phase == :idle))

    inject(pid, %ExRatatui.Event.Paste{content: "row one\nrow two\nrow three"})

    # The cursor lands at the end of the pasted draft (last row).
    assert cursor(pid) == {2, 9}

    # Not on a boundary row: Up/Down move between rows.
    press(pid, "up")
    assert cursor(pid) == {1, 7}
    row_state = get_state(pid)
    assert State.input_text(row_state) == "row one\nrow two\nrow three"
    assert row_state.history_index == nil

    # Left/right move within the row.
    press(pid, "left")
    assert cursor(pid) == {1, 6}
    press(pid, "right")
    assert cursor(pid) == {1, 7}

    # Vertical moves clamp to the target row's length, not a sticky column.
    press(pid, "down")
    assert cursor(pid) == {2, 7}
    press(pid, "up")
    press(pid, "up")
    assert cursor(pid) == {0, 7}

    # On the first row, Up navigates history instead of moving the cursor.
    press(pid, "up")
    state = get_state(pid)
    assert State.input_text(state) == "seed"
    assert state.history_index == 0
  end

  # The animation-discipline proof (ADR 0006): idle => no timers => no renders.
  test "an idle app renders nothing on a timer" do
    {:ok, pid} = start_tui()
    # Let mount's first frame land, then observe a quiet window.
    Process.sleep(50)
    before = Runtime.snapshot(pid).render_count

    Process.sleep(300)

    assert Runtime.snapshot(pid).render_count == before
    assert get_state(pid).tick_ref == nil
  end

  # The composer cursor's blink (ADR 0015 §1): while a turn is live it
  # toggles on the existing activity tick; at idle it is static reversed —
  # a further sampling window never sees the off half, and the idle render
  # discipline (no frames on a timer) still holds.
  test "the blink toggles over ticks while a turn is live and stops at idle" do
    {:ok, pid} = start_tui()
    submit(pid, "blink")
    assert_receive {:prompt, ui_pid, "blink", []}, 1_000

    send(ui_pid, {:token, "x"})
    eventually(pid, fn s -> s.phase == :streaming and s.tick_ref != nil end)

    # Sample across >= 1.1 s of streaming (one full blink period at the
    # 125 ms tick): both halves of the blink must appear.
    streaming_seen = sample_cursor_styles(pid, 1_100)
    assert :reversed in streaming_seen, "blink never showed the on half"
    assert :empty in streaming_seen, "blink never showed the off half"

    # Idle: static reversed — sampling never sees the artifact toggle.
    send(ui_pid, {:phase, :idle})
    eventually(pid, fn s -> s.phase == :idle and s.tick_ref == nil end)
    idle_seen = sample_cursor_styles(pid, 600)
    assert MapSet.to_list(idle_seen) == [:reversed]

    # The idle render discipline still holds (ADR 0006).
    settled = Runtime.snapshot(pid).render_count
    Process.sleep(300)
    assert Runtime.snapshot(pid).render_count == settled
  end

  # The placeholder rule (#91, owner-set): "ask anything" only until the
  # session's first exchange; mid-session an empty composer shows nothing.
  test "the hint disappears with the session's first exchange" do
    {:ok, pid} = start_tui()
    assert screen_text(get_state(pid)) =~ "ask anything"

    submit(pid, "first prompt")
    assert_receive {:prompt, ui_pid, "first prompt", []}, 1_000

    # The turn finalizes (the in-flight tokens land as the assistant
    # entry); the draft is empty again — no placeholder now.
    send(ui_pid, {:token, "an answer"})
    send(ui_pid, {:phase, :idle})
    eventually(pid, fn s -> s.phase == :idle and s.entries != [] end)

    text = screen_text(get_state(pid))
    refute text =~ "ask anything"
    refute text =~ "Enter send"
  end

  # Samples the input widget's cursor_style over `window_ms` of wall clock
  # (a pure View.render in this process — no frames drawn), returning the
  # observed shapes: :reversed (the cursor artifact) or :empty (absent).
  defp sample_cursor_styles(pid, window_ms) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    do_sample_cursor(pid, deadline, MapSet.new())
  end

  defp do_sample_cursor(pid, deadline, acc) do
    state = get_state(pid)

    {widget, _rect} =
      state
      |> View.render(%ExRatatui.Frame{width: 80, height: 24})
      |> Enum.at(3)

    acc = MapSet.put(acc, cursor_kind(widget.cursor_style))

    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(30)
      do_sample_cursor(pid, deadline, acc)
    else
      acc
    end
  end

  defp cursor_kind(%ExRatatui.Style{modifiers: [:reversed]}), do: :reversed
  defp cursor_kind(%ExRatatui.Style{}), do: :empty

  # ADR 0006 extension along ADR 0007: a confirm phase is active (it ticks),
  # and the tick must die again the moment the agent ends the turn.
  test "the tick dies again after a confirm phase resolves to idle" do
    {:ok, pid} = start_tui()

    send(pid, {:confirm, make_ref(), confirm_request(["+ x"])})
    eventually(pid, fn s -> s.phase == :confirming and s.tick_ref != nil end)

    send(pid, {:phase, :idle})
    state = eventually(pid, fn s -> s.phase == :idle and s.tick_ref == nil end)
    assert state.confirm == nil

    before = Runtime.snapshot(pid).render_count
    Process.sleep(300)
    assert Runtime.snapshot(pid).render_count == before
  end

  test "a stale tick is dropped: no double-step, no orphan timer, no frame" do
    # A tick with no timer pending (its timer was cancelled after firing, or the
    # message is a leftover) must not step the spinner, arm anything, or draw.
    idle = State.new(test_mode: {80, 24})
    assert {:noreply, ^idle, %{render?: false}} = TUI.handle_info(:dashfloat_tick, idle)

    # A tick whose tracked timer has not fired yet is stale too, and the live
    # timer is left alone.
    ref = Process.send_after(self(), :never, 10_000)
    active = %{idle | phase: :streaming, tick_ref: ref}

    assert {:noreply, ^active, %{render?: false}} = TUI.handle_info(:dashfloat_tick, active)
    assert is_integer(Process.read_timer(ref))

    Process.cancel_timer(ref)
  end

  test "a tick that finds idle halts and clears the timer (last-resort net)" do
    # schedule/1 cancels on any idle transition, so this state should be
    # unreachable; if it ever happens, the tick must still die here — and draw
    # nothing, since idle renders on no timer (ADR 0006).
    idle = State.new(test_mode: {80, 24})
    ref = Process.send_after(self(), :never, 10_000)
    # A fired timer: read_timer returns false, so the tick is not stale.
    Process.cancel_timer(ref)
    Process.sleep(5)

    leaked = %{idle | tick_ref: ref}
    assert {:noreply, cleared, %{render?: false}} = TUI.handle_info(:dashfloat_tick, leaked)
    assert cleared.tick_ref == nil
    assert cleared.phase == :idle
  end

  test "a stray tick while idle halts without rescheduling" do
    {:ok, pid} = start_tui()
    Process.sleep(50)

    send(pid, :dashfloat_tick)

    state = get_state(pid)
    assert state.phase == :idle
    assert state.tick_ref == nil
    assert state.anim_step == 0

    # The timer is not re-armed, so no further frames arrive.
    Process.sleep(50)
    settled = Runtime.snapshot(pid).render_count
    Process.sleep(300)
    assert Runtime.snapshot(pid).render_count == settled
  end

  test "a stale tick draining at idle draws no frame (render-suppressed)" do
    # The race this pins: a tick timer fires just as the terminal idle
    # message queues behind a backlog; cancel_timer cannot stop the already-
    # queued tick, so it drains at idle. Its callback has no state change —
    # and must draw no frame either (ADR 0006: idle renders nothing on a
    # timer). The render counter is the metric of record.
    {:ok, pid} = start_tui()
    :ok = Runtime.enable_trace(pid, limit: 200)
    Process.sleep(50)
    before_count = Runtime.snapshot(pid).render_count

    send(pid, :dashfloat_tick)

    # Wait until the server has processed the tick (it appears in the trace)…
    await_trace(pid, fn events ->
      Enum.any?(events, &tick_message?/1)
    end)

    # …then confirm the processed tick drew nothing. An unsuppressed return
    # would render immediately here: the mailbox is empty at idle.
    traced = Runtime.trace_events(pid)
    assert Enum.any?(traced, &tick_message?/1)
    assert Runtime.snapshot(pid).render_count == before_count
  end

  defp tick_message?(%{kind: :message, details: %{source: :info, payload: :dashfloat_tick}}),
    do: true

  defp tick_message?(_other), do: false

  defp await_trace(pid, predicate, tries \\ 100) do
    traced = Runtime.trace_events(pid)

    if predicate.(traced) or tries == 0 do
      :ok
    else
      Process.sleep(10)
      await_trace(pid, predicate, tries - 1)
    end
  end

  test "renders increase while a turn is live and freeze again after :idle" do
    {:ok, pid} = start_tui()

    submit(pid, "animate")
    assert_receive {:prompt, ui_pid, "animate", []}, 1_000

    # While active there is always a tick pending and the frame counter climbs.
    eventually(pid, fn s -> s.phase == :streaming and s.tick_ref != nil end)
    during = Runtime.snapshot(pid).render_count
    Process.sleep(250)
    assert Runtime.snapshot(pid).render_count > during

    # The tick stepped the spinner while the turn was open.
    stepped = eventually(pid, fn s -> s.anim_step > 0 end)
    assert stepped.anim_step > 0

    send(ui_pid, {:phase, :idle})
    state = eventually(pid, fn s -> s.phase == :idle and s.tick_ref == nil end)
    assert state.tick_ref == nil

    # ...and the timer is gone: another quiet window changes nothing.
    frozen = Runtime.snapshot(pid).render_count
    Process.sleep(300)
    assert Runtime.snapshot(pid).render_count == frozen
  end

  # The idle cursor blink (issue #104; ADR 0006's 2026-10-31 amendment —
  # sanctioned exception #5, the first REPEATING idle timer). The default
  # suite stays hermetic: without an injected cadence the timer never arms
  # (the suggest-arm pattern), so every flat-render assertion above holds.
  # These tests opt IN through `blink_ms:` and watch the real wiring.
  describe "the idle cursor blink (issue #104)" do
    test "the timer arms at mount with an injected cadence and toggles the phase" do
      {:ok, pid} = start_tui(blink_ms: 20, provider: provider())

      # The phase flips on the timer: blink_on reaches false, then true…
      eventually(pid, fn s -> s.blink_on == false end, 300)
      toggled_back = eventually(pid, fn s -> s.blink_on == true end, 300)

      # …exactly one timer stays pending the whole time, and each toggle
      # drew a frame (the honest bounded cost — 2 renders/s at 500 ms).
      assert toggled_back.blink_ref != nil
      assert toggled_back.phase == :idle
      assert Runtime.snapshot(pid).render_count > 1
    end

    test "leaving idle cancels the blink and resets the phase visible" do
      {:ok, pid} = start_tui(blink_ms: 20, provider: provider())
      eventually(pid, fn s -> s.blink_on == false end, 300)

      submit(pid, "stream now")
      assert_receive {:prompt, ui_pid, "stream now", []}, 1_000

      active =
        eventually(pid, fn s ->
          s.phase == :streaming and s.tick_ref != nil and s.blink_ref == nil
        end)

      assert active.blink_on == true

      send(ui_pid, {:phase, :idle})
      back = eventually(pid, fn s -> s.phase == :idle and s.blink_ref != nil end)
      assert back.blink_on == true
    end

    test "a stale blink message is dropped without a frame" do
      idle = State.new(test_mode: {80, 24})
      assert {:noreply, ^idle, %{render?: false}} = TUI.handle_info(:dashfloat_blink, idle)

      # A blink whose tracked timer has not fired yet is stale — it belongs
      # to a superseded arm; the live timer is left alone.
      ref = Process.send_after(self(), :never, 10_000)
      pending = %{idle | blink_ref: ref}

      assert {:noreply, ^pending, %{render?: false}} = TUI.handle_info(:dashfloat_blink, pending)
      assert is_integer(Process.read_timer(ref))
      Process.cancel_timer(ref)
    end

    test "a fired blink toggles through the choke point and re-arms" do
      armed = State.new(test_mode: {80, 24}, blink_ms: 20)
      fired_ref = Process.send_after(self(), :dashfloat_blink, 1)
      Process.sleep(5)

      assert {:noreply, toggled} =
               TUI.handle_info(:dashfloat_blink, %{armed | blink_ref: fired_ref})

      assert toggled.blink_on == false
      # The choke point re-armed exactly one fresh timer.
      assert toggled.blink_ref != nil and toggled.blink_ref != fired_ref
      Process.cancel_timer(toggled.blink_ref)

      # The hermetic default (no injected cadence) never re-arms: the
      # toggle is reset visible with no timer pending.
      plain = State.new(test_mode: {80, 24})
      stale_ref = Process.send_after(self(), :dashfloat_blink, 1)
      Process.sleep(5)

      assert {:noreply, reset} =
               TUI.handle_info(:dashfloat_blink, %{plain | blink_ref: stale_ref})

      assert reset.blink_on == true
      assert reset.blink_ref == nil
    end

    test "the default suite never arms: renders stay flat at idle" do
      {:ok, pid} = start_tui(provider: provider())
      Process.sleep(50)

      assert get_state(pid).blink_ref == nil

      settled = Runtime.snapshot(pid).render_count
      Process.sleep(300)
      assert Runtime.snapshot(pid).render_count == settled
    end
  end

  test "the render counter is the metric of record: it ticks during activity only" do
    {:ok, pid} = start_tui()

    idle_before = Runtime.snapshot(pid).render_count
    submit(pid, "rate")
    assert_receive {:prompt, ui_pid, "rate", []}, 1_000
    eventually(pid, fn s -> s.phase == :streaming end)

    # Sample across a quiet gap: the activity tick alone drives renders.
    start_count = Runtime.snapshot(pid).render_count
    Process.sleep(400)
    active_delta = Runtime.snapshot(pid).render_count - start_count
    assert active_delta >= 2, "expected tick-driven renders, saw #{active_delta}"

    send(ui_pid, {:phase, :idle})
    eventually(pid, fn s -> s.phase == :idle and s.tick_ref == nil end)
    idle_after = Runtime.snapshot(pid).render_count
    Process.sleep(300)
    assert Runtime.snapshot(pid).render_count == idle_after
    assert idle_after > idle_before
  end

  test "a usage frame reconciles token counts before the terminal idle phase" do
    {:ok, pid} = start_tui()
    :ok = Runtime.enable_trace(pid, limit: 500)

    submit(pid, "count me")
    assert_receive {:prompt, ui_pid, "count me", []}, 1_000

    send(ui_pid, {:token, "Hello"})
    send(ui_pid, {:usage, %{prompt_tokens: 120, completion_tokens: 42, total_tokens: 162}})

    send(
      ui_pid,
      {:context,
       %{
         messages: [%{role: "user", content: "count me"}, %{role: "assistant", content: "Hello"}],
         anchor: %{tokens: 162, index: 2}
       }}
    )

    send(ui_pid, {:phase, :idle})

    state = eventually(pid, fn s -> s.phase == :idle and s.in_flight == nil end)

    assert state.stats.prompt_tokens == 120
    assert state.stats.completion_tokens == 42
    assert entry?(state, :assistant, "Hello")

    # Ordering proof: the usage message is handled before the idle phase.
    traced = Runtime.trace_events(pid)
    payloads = for(%{kind: :message, details: %{payload: payload}} <- traced, do: payload)

    usage_at = Enum.find_index(payloads, &match?({:usage, _usage}, &1))
    idle_at = Enum.find_index(payloads, &(&1 == {:phase, :idle}))
    assert usage_at != nil and idle_at != nil
    assert usage_at < idle_at

    # The snapshot landed (stage-2 span truth) and the bar no longer carries ctx.
    assert state.context.anchor == %{tokens: 162, index: 2}
    refute status_text(state) =~ "ctx"
  end

  test "tool rows land in the log and the executing_tool phase names itself" do
    {:ok, pid} = start_tui()

    send(pid, {:tool_call, %{id: "t1", name: "read_file", args: %{"path" => "lib/foo.ex"}}})

    state = eventually(pid, fn s -> s.entries != [] end)

    assert [%{kind: :tool, text: "⚙ read_file lib/foo.ex", lines: lines}] = state.entries
    assert flatten_lines(lines) == ["", "⚙ read_file lib/foo.ex"]

    send(
      pid,
      {:tool_result, %{id: "t1", name: "read_file", ok: true, status: "ok", output: "one\ntwo"}}
    )

    eventually(pid, fn s -> length(s.entries) == 2 end)

    send(pid, {:phase, :executing_tool})
    tool_phase = eventually(pid, fn s -> s.phase == :executing_tool end)
    assert status_text(tool_phase) =~ "Running tool"

    send(pid, {:phase, :idle})
    eventually(pid, &(&1.phase == :idle))
  end

  test "the full confirm round trip: preview, decision, and swallowed keys" do
    {:ok, pid} = start_tui()
    submit(pid, "edit that file")
    assert_receive {:prompt, ui_pid, "edit that file", []}, 1_000

    ref = make_ref()

    send(
      ui_pid,
      {:confirm, ref,
       %{
         id: "call_1",
         name: "write_file",
         args: %{"path" => "lib/foo.ex"},
         lines: ["@@ -1,2 +1,3 @@", "- old line", "+ new line", "$ mix format lib/foo.ex"]
       }}
    )

    state = eventually(pid, fn s -> s.phase == :confirming end)
    assert state.confirm == %{ref: ref, id: "call_1", name: "write_file"}

    # The preview landed as a tool entry (blank separator + 4 preview rows).
    [preview] = for(%{kind: :tool} = entry <- state.entries, do: entry)
    assert preview.text == "@@ -1,2 +1,3 @@\n- old line\n+ new line\n$ mix format lib/foo.ex"

    assert flatten_lines(preview.lines) == [
             "",
             "@@ -1,2 +1,3 @@",
             "- old line",
             "+ new line",
             "$ mix format lib/foo.ex"
           ]

    # The activity line prompts the decision instead of offering interrupt.
    assert activity_text(state) =~ "Approve this change?"
    assert activity_text(state) =~ "⏎ approve · esc reject"

    # Everything but Enter/Esc is swallowed — keys and pastes alike, the
    # draft stays untouched.
    press(pid, "x")
    press(pid, "enter", ["shift"])
    inject(pid, %ExRatatui.Event.Paste{content: "pasted mid-decision"})
    swallowed = get_state(pid)
    assert State.input_text(swallowed) == ""

    # Enter approves: the decision carries the confirm ref to the agent.
    press(pid, "enter")
    assert_receive {:confirm_decision, ^ref, :approved}, 1_000

    decided = eventually(pid, fn s -> s.confirm == nil end)
    assert decided.phase == :confirming

    # The agent resumes — a tool result rows in, then the turn ends.
    send(
      ui_pid,
      {:tool_result,
       %{id: "call_1", name: "write_file", ok: true, status: "ok", output: "wrote 3 lines"}}
    )

    send(ui_pid, {:phase, :idle})
    approved = eventually(pid, fn s -> s.phase == :idle end)
    assert entry?(approved, :tool, "⚙ write_file → ok\nwrote 3 lines")

    # Second round: Esc rejects.
    ref2 = make_ref()
    send(ui_pid, {:confirm, ref2, confirm_request(["+ again"])})
    eventually(pid, fn s -> s.confirm != nil end)

    press(pid, "esc")
    assert_receive {:confirm_decision, ^ref2, :rejected}, 1_000

    send(
      ui_pid,
      {:tool_result,
       %{id: "call_2", name: "write_file", ok: false, status: "cancelled", output: nil}}
    )

    send(ui_pid, {:phase, :idle})
    rejected = eventually(pid, fn s -> s.phase == :idle end)
    assert entry?(rejected, :tool, "⚙ write_file → cancelled")
    assert State.input_text(rejected) == ""
  end

  # Issue #21 (ADR 0006 amendment): the wheel always addresses the log view —
  # never the input draft. Routing is focus-free: the pane under the cursor,
  # the draft's contents, and a pending confirm are all irrelevant to it.
  defp scroll(pid, kind) do
    inject(pid, %ExRatatui.Event.Mouse{kind: kind, button: "", x: 10, y: 5})
  end

  # A tall log: one submitted question plus a 100-entry system reply. Returns
  # once idle, with the bottom offset under the real rendered viewport (the
  # margin took two rows off the log height — issue #28).
  defp viewport(state) do
    View.regions(state.size, State.input_line_count(state), false).log.height
  end

  defp active_viewport(state) do
    View.regions(state.size, State.input_line_count(state), true).log.height
  end

  defp tall_log(pid) do
    submit(pid, "first question")
    assert_receive {:prompt, ui_pid, "first question", []}, 1_000

    for i <- 1..100, do: send(ui_pid, {:entry, :system, "line #{i}"})
    send(ui_pid, {:phase, :idle})

    state = eventually(pid, fn s -> s.phase == :idle and State.log_line_count(s) >= 202 end)
    {state, State.effective_scroll(state, viewport(state))}
  end

  test "the wheel scrolls the log view, not the input draft" do
    {:ok, pid} = start_tui(provider: provider())
    {_state, bottom} = tall_log(pid)
    type(pid, "fresh draft")

    scroll(pid, "scroll_up")

    wheeled = get_state(pid)
    refute wheeled.follow?
    assert State.effective_scroll(wheeled, viewport(wheeled)) == bottom - 3
    # The wheel never touches the draft — the live bug walked history here.
    assert State.input_text(wheeled) == "fresh draft"
    assert wheeled.history_index == nil
  end

  test "wheel-down re-pins at the bottom; genuine Up still walks history" do
    {:ok, pid} = start_tui(provider: provider())
    {_state, bottom} = tall_log(pid)

    scroll(pid, "scroll_up")
    scroll(pid, "scroll_up")
    two_notches = get_state(pid)
    assert State.effective_scroll(two_notches, viewport(two_notches)) == bottom - 6

    scroll(pid, "scroll_down")
    one_down = get_state(pid)
    assert State.effective_scroll(one_down, viewport(one_down)) == bottom - 3

    for _notch <- 1..4, do: scroll(pid, "scroll_down")
    pinned = get_state(pid)
    assert pinned.follow?
    assert State.effective_scroll(pinned, viewport(pinned)) == bottom

    # Keyboard truth is unchanged: Up is still history navigation at the
    # draft's first row (ADR 0002).
    press(pid, "up")
    walked = get_state(pid)
    assert walked.history_index == 0
    assert State.input_text(walked) == "first question"
  end

  test "the wheel still scrolls while a confirm is pending" do
    {:ok, pid} = start_tui(provider: provider())
    {_state, _bottom} = tall_log(pid)

    send(pid, {:confirm, make_ref(), confirm_request(["+ x"])})

    confirming =
      eventually(pid, fn s ->
        s.phase == :confirming and
          State.effective_scroll(s, active_viewport(s)) > 0
      end)

    # The preview appended rows and the activity row is up (confirming is an
    # active phase): the pinned bottom under the real active viewport.
    confirm_bottom = State.effective_scroll(confirming, active_viewport(confirming))

    scroll(pid, "scroll_up")
    state = get_state(pid)
    assert state.phase == :confirming
    refute state.follow?
    assert State.effective_scroll(state, active_viewport(state)) == confirm_bottom - 3
  end

  test "inert mouse events change nothing and render nothing" do
    {:ok, pid} = start_tui()
    before_count = Runtime.snapshot(pid).render_count

    for event <- [
          %ExRatatui.Event.Mouse{kind: "moved", button: "", x: 1, y: 1},
          %ExRatatui.Event.Mouse{kind: "moved", button: "", x: 7, y: 9},
          %ExRatatui.Event.Mouse{kind: "down", button: "right", x: 1, y: 1},
          %ExRatatui.Event.Mouse{kind: "up", button: "middle", x: 2, y: 2},
          %ExRatatui.Event.Mouse{kind: "drag", button: "right", x: 3, y: 3},
          %ExRatatui.Event.Mouse{kind: "scroll_left", button: "", x: 1, y: 1}
        ] do
      inject(pid, event)
    end

    assert Runtime.snapshot(pid).render_count == before_count
    untouched = get_state(pid)
    assert State.input_text(untouched) == ""
    assert untouched.selection == nil
  end

  # Issue #28: click-drag over the log anchors a display-row selection,
  # extends with the drag, and copies on release. Test mode never writes
  # the OSC 52 sequence (live?-gated); the selection state is the observable.
  test "a left drag over the log selects display rows and copies on release" do
    {:ok, pid} = start_tui()

    for i <- 1..8, do: send(pid, {:entry, :system, "selectable line #{i}"})
    eventually(pid, &(State.log_line_count(&1) == 16))

    # A drag with no press before it (a missed or dropped down event) is a
    # no-op, never a crash.
    inject(pid, %ExRatatui.Event.Mouse{kind: "drag", button: "left", x: 5, y: 5})
    bare = get_state(pid)
    assert bare.selection == nil

    # down at log row 1 ("selectable line 1"), drag to row 3, release.
    # (16 lines in the 15-row idle viewport: follow pins the bottom, so the
    # view sits at scroll 1 — screen row 3 is display row 1.)
    inject(pid, %ExRatatui.Event.Mouse{kind: "down", button: "left", x: 4, y: 3})
    drag = eventually(pid, &(&1.selection != nil))
    assert drag.selection.anchor == {1, 2}

    inject(pid, %ExRatatui.Event.Mouse{kind: "drag", button: "left", x: 6, y: 5})
    extended = get_state(pid)
    assert extended.selection.head == {3, 4}

    inject(pid, %ExRatatui.Event.Mouse{kind: "up", button: "left", x: 6, y: 5})
    released = get_state(pid)

    # The highlight stays after the copy (terminal convention)…
    assert released.selection != nil

    # …and the copy payload is the selected column ranges, newline-joined:
    # row 1 from col 2 through its end, the blank separator, row 3 through
    # col 4's cell ("selec" — the pointed cell is included).
    assert State.selection_text(released) == "lectable line 1\n\nselec"

    # Click-to-clear: a press+release without extension clears it.
    inject(pid, %ExRatatui.Event.Mouse{kind: "down", button: "left", x: 4, y: 3})
    inject(pid, %ExRatatui.Event.Mouse{kind: "up", button: "left", x: 4, y: 3})
    cleared = get_state(pid)
    assert cleared.selection == nil
  end

  # The live-only OSC 52 write (ADR 0006 amendment, issue #28): test mode
  # never writes; a live state writes exactly one bounded sequence on
  # release.
  test "copy on release writes the OSC 52 sequence on live runs only" do
    # Test mode: the full down/drag/up flow through TUI.handle_event, with
    # nothing reaching standard output.
    {:ok, pid} = start_tui()
    send(pid, {:entry, :system, "copy me please"})
    eventually(pid, &(State.log_line_count(&1) == 2))
    test_state = get_state(pid)
    assert test_state.live? == false

    assert ExUnit.CaptureIO.capture_io(fn ->
             threaded =
               Enum.reduce(
                 [
                   %ExRatatui.Event.Mouse{kind: "down", button: "left", x: 1, y: 4},
                   %ExRatatui.Event.Mouse{kind: "drag", button: "left", x: 13, y: 4},
                   %ExRatatui.Event.Mouse{kind: "up", button: "left", x: 13, y: 4}
                 ],
                 test_state,
                 fn event, acc ->
                   assert {:noreply, next} = TUI.handle_event(event, acc)
                   next
                 end
               )

             # A real drag completed (a copy action fired in test mode) —
             # the empty capture then genuinely proves the live? gate held.
             assert threaded.selection != nil
             assert State.selection_text(threaded) != ""
           end) == ""

    # A live state (no test_mode): the up event writes the exact sequence.
    live_base = State.new([])
    live = State.stream_message(live_base, {:entry, :system, "copy me please"})
    assert live.live? == true

    dragging =
      Enum.reduce(
        [
          %ExRatatui.Event.Mouse{kind: "down", button: "left", x: 1, y: 4},
          %ExRatatui.Event.Mouse{kind: "drag", button: "left", x: 13, y: 4}
        ],
        live,
        fn event, acc ->
          {acc, _action} = State.select_mouse(acc, event.kind, event.x, event.y)
          acc
        end
      )

    up = %ExRatatui.Event.Mouse{kind: "up", button: "left", x: 13, y: 4}

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:noreply, _state} = TUI.handle_event(up, dragging)
      end)

    # Columns [0, 12) of "copy me please" — through the pointed cell.
    expected = "\e]52;c;" <> Base.encode64("copy me plea") <> "\a"
    assert output == expected
  end

  # Review P2d: Shift+drag is the terminal's native-selection bypass — the
  # app neither selects nor writes underneath it.
  test "shift-modified left events never select" do
    {:ok, pid} = start_tui()
    send(pid, {:entry, :system, "native selection bypass"})
    eventually(pid, &(State.log_line_count(&1) == 2))

    for event <- [
          %ExRatatui.Event.Mouse{kind: "down", button: "left", x: 1, y: 3, modifiers: ["shift"]},
          %ExRatatui.Event.Mouse{kind: "drag", button: "left", x: 10, y: 3, modifiers: ["shift"]},
          %ExRatatui.Event.Mouse{kind: "up", button: "left", x: 10, y: 3, modifiers: ["shift"]}
        ] do
      inject(pid, event)
    end

    untouched = get_state(pid)
    assert untouched.selection == nil
  end

  # Review P2d: an over-cap selection keeps its highlight, writes nothing,
  # and logs why.
  test "an over-cap selection drops the copy with a log line" do
    huge = String.duplicate("word ", 20_000)
    live_base = State.new([])
    live = State.stream_message(live_base, {:entry, :system, huge})

    {anchored, _nil} = State.select_mouse(live, "down", 1, 3)

    # 400 notches = 1200 rows above the anchor: a genuine full-log span.
    scrolled =
      Enum.reduce(1..400, anchored, fn _i, acc -> State.wheel_scroll(acc, :up) end)

    {dragged, _nil} = State.select_mouse(scrolled, "drag", 1, 3)

    up = %ExRatatui.Event.Mouse{kind: "up", button: "left", x: 1, y: 3}

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        output =
          ExUnit.CaptureIO.capture_io(fn ->
            assert {:noreply, kept} = TUI.handle_event(up, dragged)
            assert kept.selection != nil
          end)

        assert output == ""
      end)

    assert logs =~ "clipboard cap"
  end

  # The lynchpin of the wheel fix: without capture, terminals emulate the
  # wheel as arrow keys and input history eats it (issue #21). The flag is
  # the TUI start_link default, so it holds for every starter — pinned via
  # the transport-connect telemetry span (the test backend itself ignores
  # the flag, so the span metadata is the observable).
  test "the TUI starts with mouse capture enabled" do
    handler_id = {:mouse_capture_test, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      # Span start event; its metadata is the connect meta (exact name —
      # :telemetry.attach does not prefix-match).
      [:ex_ratatui, :transport, :connect, :start],
      fn _event, _measurements, meta, _config ->
        # Runs inside the starting Server; send to the captured test pid.
        send(test_pid, {:connect_meta, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, _pid} = start_tui()
    assert_receive {:connect_meta, meta}, 1_000
    assert meta[:mouse_capture] == true
  end

  # Focus reporting gates the composer's cursor (ADR 0015 §1) — the same
  # connect-span pattern as mouse capture above.
  test "the TUI starts with focus reporting enabled" do
    handler_id = {:focus_events_test, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:ex_ratatui, :transport, :connect, :start],
      fn _event, _measurements, meta, _config ->
        send(test_pid, {:connect_meta, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, _pid} = start_tui()
    assert_receive {:connect_meta, meta}, 1_000
    assert meta[:focus_events] == true
  end

  test "child_spec/1 is temporary and a worker" do
    spec = TUI.child_spec([])
    assert spec.type == :worker
    assert spec.restart == :temporary
  end

  test "exit_code/1 maps only an explicit quit to success" do
    assert TUI.exit_code(:normal) == 0
    assert TUI.exit_code(:shutdown) == 1
    assert TUI.exit_code({:error, :boom}) == 1
  end

  test "the TUI and agent are absent from the application supervision tree in test env" do
    children = Supervisor.which_children(DashFloat.Supervisor)
    child_ids = Enum.map(children, &elem(&1, 0))
    # the task supervisor is up; the TUI and agent are gated out of :test
    assert DashFloat.TaskSupervisor in child_ids
    refute TUI in child_ids
    refute DashFloat.Agent in child_ids
  end

  defp confirm_request(lines), do: %{id: "c", name: "write_file", args: %{}, lines: lines}

  defp inject(pid, event) do
    GenServer.call(pid, {:ex_ratatui_runtime_inject_event, event})
  end

  defp status_text(state) do
    {widget, _rect} =
      state
      |> View.render(%ExRatatui.Frame{width: 80, height: 24})
      |> List.first()

    [line] = widget.text
    Enum.map_join(line.spans, "", & &1.content)
  end

  defp footer_text(state) do
    {widget, _rect} =
      state
      |> View.render(%ExRatatui.Frame{width: 80, height: 24})
      |> Enum.at(4)

    [line] = widget.text
    Enum.map_join(line.spans, "", & &1.content)
  end

  defp activity_text(state) do
    {widget, _rect} =
      state
      |> View.render(%ExRatatui.Frame{width: 80, height: 24})
      |> Enum.at(2)

    [line] = widget.text
    Enum.map_join(line.spans, "", & &1.content)
  end

  # The full drawn frame as text (issue #39: the on-screen evidence for
  # wizard-surface assertions).
  defp screen_text(state) do
    term = ExRatatui.init_test_terminal(80, 24)
    widgets = View.render(state, %ExRatatui.Frame{width: 80, height: 24})
    assert :ok = ExRatatui.draw(term, widgets)
    ExRatatui.get_buffer_content(term)
  end

  defp flatten_lines(lines),
    do: Enum.map(lines, &Enum.map_join(&1.spans, "", fn span -> span.content end))

  defp attach_disconnect_listener do
    handler_id = {:disconnect_test, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:ex_ratatui, :transport, :disconnect],
      fn _event, _measurements, %{reason: reason}, _config ->
        # Runs inside the TUI process; send to the captured test pid.
        send(test_pid, {:transport_disconnect, reason})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  ## Ghost-text suggestion (issue #70; ADR 0015 §3) — the Done-when proofs,
  ## at the loopback seam. The agent is the fake (the test process); the
  ## suggest side-request is the ONLY traffic the server sees, riding the
  ## real HTTP path via `suggest_fetcher: {DashFloat.TUI.Suggest, :request}`.

  defp suggest_provider(base, overrides) do
    {:ok,
     struct!(
       Config,
       Keyword.merge([base_url: base, model: "active-m", api_key: "k"], overrides)
     )}
  end

  # A completion whose content carries surrounding quotes — normalize strips them.
  defp ghost_completion do
    Jason.encode!(%{choices: [%{message: %{content: "\"tell me more\""}}]})
  end

  # The loopback server replays one script per connection; the suggest
  # side-request is the only traffic it ever sees.
  defp start_suggest_tui(provider_overrides, debounce_ms, scripts) do
    {:ok, server} = SSEServer.start_link(:per_connection, scripts)
    on_exit(fn -> DashFloat.TestTeardown.stop(server) end)

    start_tui(
      provider: suggest_provider(SSEServer.base_url(server), provider_overrides),
      suggest_fetcher: {DashFloat.TUI.Suggest, :request},
      suggest_debounce_ms: debounce_ms
    )
  end

  # One fake-agent turn: submit, answer, finalize. The idle finalize is what
  # arms the one-shot ghost.
  defp complete_turn(pid) do
    submit(pid, "hi")
    assert_receive {:prompt, ui, "hi", []}, 1_000
    send(ui, {:token, "hello there"})
    send(ui, {:phase, :idle})
    eventually(pid, &(&1.entries != [] and &1.phase == :idle))
    ui
  end

  describe "ghost-text suggestion (issue #70, ADR 0015 §3)" do
    test "the side-request hits the loopback seam and the ghost lands as the placeholder" do
      {:ok, pid} = start_suggest_tui([], 25, [[http_ok(ghost_completion()), :close]])

      complete_turn(pid)

      # The seam: a custom provider falls back to the ACTIVE model (the
      # preset→cheap-id mapping is proven at the body seam in suggest_test —
      # together they prove the default cheap model reaches the wire).
      assert_receive {:sse_request, "POST", "/chat/completions", headers, body}, 1_000
      payload = Jason.decode!(body)
      assert payload["model"] == "active-m"
      assert payload["max_tokens"] == 48

      assert [
               %{"role" => "system", "content" => instruction},
               %{"role" => "user", "content" => tail}
             ] = payload["messages"]

      assert tail =~ "hello there"
      assert instruction =~ "next message"
      assert headers["authorization"] == "Bearer k"

      state = eventually(pid, &(&1.suggestion == "tell me more"))
      assert State.input_text(state) == ""
      # The drawn buffer shows the ghost while the draft is empty.
      assert screen_text(state) =~ "tell me more"
    end

    test "settings.suggest pins the exact model id on the wire" do
      {:ok, pid} =
        start_suggest_tui([suggest: "cheap-override-m"], 25, [
          [http_ok(ghost_completion()), :close]
        ])

      complete_turn(pid)

      assert_receive {:sse_request, "POST", "/chat/completions", _headers, body}, 1_000
      assert Jason.decode!(body)["model"] == "cheap-override-m"
    end

    # The preset DEFAULT cheap model was never proven at this seam: the
    # provider config is the genuine preset shape (trailing slash, flagship
    # active model, suggest unset) and only the transport redirects to the
    # loopback — the real model-resolution chain (F1's normalization
    # included) decides the wire model.
    test "the preset default cheap model reaches the wire and the ghost lands" do
      provider =
        {:ok,
         struct!(Config,
           base_url: "https://api.z.ai/api/coding/paas/v4/",
           model: "glm-5.3",
           api_key: "k"
         )}

      {:ok, server} =
        SSEServer.start_link(:per_connection, [[http_ok(ghost_completion()), :close]])

      on_exit(fn -> DashFloat.TestTeardown.stop(server) end)
      base = SSEServer.base_url(server)

      {:ok, pid} =
        start_tui(
          provider: provider,
          suggest_fetcher: fn config, tail ->
            # The model resolves on the REAL preset base_url; only the
            # transport redirects to the loopback.
            model = Suggest.model(config)
            Suggest.request(%{config | base_url: base, suggest: model}, tail)
          end,
          suggest_debounce_ms: 25
        )

      complete_turn(pid)

      assert_receive {:sse_request, "POST", "/chat/completions", _headers, body}, 1_000
      assert Jason.decode!(body)["model"] == "glm-5.3-flash"

      state = eventually(pid, &(&1.suggestion == "tell me more"))
      assert screen_text(state) =~ "tell me more"
    end

    # agent_down(:normal) re-sends {:phase, :idle}: the turn was already
    # finalized and the one-shot consumed — a second side-request for one
    # turn would be a budget bug (ADR 0015 §3).
    test "a re-sent idle never fires a second side-request for the same turn" do
      {:ok, pid} = start_suggest_tui([], 20, [[http_ok(ghost_completion()), :close]])

      complete_turn(pid)
      assert_receive {:sse_request, "POST", "/chat/completions", _, _}, 1_000

      send(pid, {:phase, :idle})
      Process.sleep(300)

      refute_receive {:sse_request, _, _, _, _}
    end

    test "suggest: false never builds a side-request at all" do
      {:ok, pid} =
        start_suggest_tui([suggest: false], 20, [[http_ok(ghost_completion()), :close]])

      complete_turn(pid)
      # Wait well past a generous debounce window.
      Process.sleep(200)

      refute_receive {:sse_request, _, _, _, _}
      assert get_state(pid).suggestion == nil
    end

    test "the debounce delays the side-request, then it fires" do
      {:ok, pid} =
        start_suggest_tui([], 150, [[http_ok(ghost_completion()), :close]])

      complete_turn(pid)

      # Inside the window: nothing on the wire yet (75 + 40 < 150).
      Process.sleep(75)
      refute_receive {:sse_request, _, _, _, _}, 40

      assert_receive {:sse_request, "POST", "/chat/completions", _, _}, 1_000
    end

    test "typing kills the in-flight side-request; the straggler never lands" do
      {:ok, pid} =
        start_suggest_tui([], 20, [[{:sleep, 600}, http_ok(ghost_completion()), :close]])

      complete_turn(pid)
      %{suggest_task: task} = eventually(pid, &(&1.suggest_task != nil))

      type(pid, "x")

      # The late response would have landed by now.
      Process.sleep(800)
      state = get_state(pid)
      assert state.suggestion == nil
      assert State.input_text(state) == "x"
      refute Process.alive?(task)
      # The app never crashes — the composer still works.
      assert Process.alive?(pid)
      assert state.phase == :idle
    end

    test "Tab materializes the ghost; the draft edits and sends through the unchanged submit" do
      {:ok, pid} = start_suggest_tui([], 25, [[http_ok(ghost_completion()), :close]])

      complete_turn(pid)
      eventually(pid, &(&1.suggestion == "tell me more"))
      # The ghost displaced the hint in the placeholder slot.
      refute screen_text(get_state(pid)) =~ "ask anything"

      press(pid, "tab")
      state = eventually(pid, &(State.input_text(&1) == "tell me more"))
      assert state.suggestion == nil

      # It is EDITABLE text: type "!" onto it, then Enter sends it.
      type(pid, "!")

      assert pid
             |> get_state()
             |> State.input_text() == "tell me more!"

      press(pid, "enter")
      assert_receive {:prompt, _ui, "tell me more!", []}, 1_000
    end

    test "typing over a landed ghost dismisses it; the late response is dropped (epoch stale)" do
      {:ok, pid} =
        start_suggest_tui([], 20, [[{:sleep, 400}, http_ok(ghost_completion()), :close]])

      complete_turn(pid)
      eventually(pid, &(&1.suggest_task != nil))
      type(pid, "h")

      Process.sleep(700)
      state = get_state(pid)
      assert state.suggestion == nil
      assert State.input_text(state) == "h"
      # The ghost is gone from the drawn buffer too.
      refute screen_text(state) =~ "tell me more"
    end

    test "a failed side-request fails open: no suggestion, no crash, composer usable" do
      {:ok, pid} = start_suggest_tui([], 20, [[:close]])

      complete_turn(pid)
      assert_receive {:sse_request, "POST", "/chat/completions", _, _}, 1_000

      Process.sleep(150)
      state = get_state(pid)
      assert state.suggestion == nil
      assert Process.alive?(pid)

      type(pid, "still here")

      assert pid
             |> get_state()
             |> State.input_text() == "still here"
    end

    test "a 2xx with a non-OpenAI body fails open too" do
      {:ok, pid} = start_suggest_tui([], 20, [[http_ok("{}"), :close]])

      complete_turn(pid)
      assert_receive {:sse_request, "POST", "/chat/completions", _, _}, 1_000

      Process.sleep(150)
      state = get_state(pid)
      assert state.suggestion == nil
      assert Process.alive?(pid)

      type(pid, "usable")

      assert pid
             |> get_state()
             |> State.input_text() == "usable"
    end

    test "the debounce is stale without an armed timer; the opt-out clears it at dispatch" do
      off =
        {:ok, %Config{base_url: "http://127.0.0.1:1", model: "m", api_key: "k", suggest: false}}

      state =
        State.new(provider: off, suggest_fetcher: {DashFloat.TUI.Suggest, :request})

      # No timer of ours pending: the message is stale and inert.
      assert {:noreply, ^state, %{render?: false}} =
               TUI.handle_info(:dashfloat_suggest, state)

      # A fired-but-unprocessed timer is live; the opt-out just clears the ref.
      fired = Process.send_after(self(), :ignore, 1)
      Process.sleep(5)
      armed = %{state | suggest_ref: fired}

      assert {:noreply, dispatched, %{render?: false}} =
               TUI.handle_info(:dashfloat_suggest, armed)

      assert dispatched.suggest_ref == nil
    end

    # A dead task supervisor EXITS the start call — the dispatch catches it
    # and fails open (ADR 0015 §3): the armed timer clears, no task is
    # tracked, and the UI process never crashes. In :test the application
    # supervisor owns ONLY the task supervisor (the TUI and agent are gated
    # out), so stopping the application takes exactly that name down.
    test "a dispatch with the task supervisor down fails open, no crash" do
      Application.stop(:dash_float)
      on_exit(fn -> {:ok, _apps} = Application.ensure_all_started(:dash_float) end)

      state =
        State.new(
          provider: {:ok, %Config{base_url: "http://127.0.0.1:1", model: "m", api_key: "k"}},
          suggest_fetcher: {DashFloat.TUI.Suggest, :request}
        )

      fired = Process.send_after(self(), :ignore, 1)
      Process.sleep(5)

      assert {:noreply, dispatched, %{render?: false}} =
               TUI.handle_info(:dashfloat_suggest, %{state | suggest_ref: fired})

      assert dispatched.suggest_ref == nil
      assert dispatched.suggest_task == nil
      assert dispatched.suggestion == nil
    end

    test "a provider error at dispatch clears the armed timer" do
      state =
        State.new(
          provider: {:error, "no provider"},
          suggest_fetcher: {DashFloat.TUI.Suggest, :request}
        )

      fired = Process.send_after(self(), :ignore, 1)
      Process.sleep(5)

      assert {:noreply, dispatched, %{render?: false}} =
               TUI.handle_info(:dashfloat_suggest, %{state | suggest_ref: fired})

      assert dispatched.suggest_ref == nil
    end

    # A stale-epoch result must not untrack a NEWER live request: the state
    # is untouched, render-suppressed (ADR 0015 §3's straggler rule).
    test "a stale-epoch straggler leaves a live request tracked and the state untouched" do
      task = spawn(fn -> Process.sleep(1_000) end)
      state = %{State.new(provider: provider()) | suggest_task: task, suggest_epoch: 2}

      assert {:noreply, ^state, %{render?: false}} =
               TUI.handle_info({:suggestion, 1, "stale"}, state)
    end

    # The transport seam's accept predicate trusts nothing: "" is a truthy
    # binary, so a blank ghost would land and blank the composer's
    # placeholder.
    test "an empty-string ghost is refused: no suggestion, render-suppressed" do
      state = %{State.new(provider: provider()) | suggest_epoch: 5}

      assert {:noreply, ^state, %{render?: false}} =
               TUI.handle_info({:suggestion, 5, ""}, state)
    end

    # Whitespace-only is the same refusal: it is truthy, so a " " ghost
    # would blank the composer's placeholder entirely (the F5 class, at the
    # transport seam).
    test "a whitespace-only ghost is refused like the empty string" do
      state = %{State.new(provider: provider()) | suggest_epoch: 5}

      assert {:noreply, ^state, %{render?: false}} =
               TUI.handle_info({:suggestion, 5, "   "}, state)
    end

    # Invisible-but-non-whitespace ghosts (soft hyphen, word joiner, a bare
    # combining mark) pass a plain trim test — the module's own normalize
    # is the visible-remainder gate.
    test "an invisible-character ghost is refused: it would blank the placeholder unseen" do
      for ghost <- ["\u00AD", "\u2060", "\u0301"] do
        state = %{State.new(provider: provider()) | suggest_epoch: 5}

        assert {:noreply, ^state, %{render?: false}} =
                 TUI.handle_info({:suggestion, 5, ghost}, state)
      end
    end
  end

  ## Image attachments (ADR 0018 §5/§6) — the prompt driven through the app.

  describe "image attachments" do
    defp images_dir do
      dir =
        Path.join("/tmp/opencode", "dashfloat-tui-attach-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      dir
    end

    defp capable_provider do
      {:ok,
       %Config{
         base_url: "http://localhost:1",
         model: "test-model",
         api_key: "test-key-123",
         images: true
       }}
    end

    defp composer_title(state) do
      {widget, _rect} =
        state
        |> View.render(%ExRatatui.Frame{width: 80, height: 24})
        |> Enum.at(3)

      widget.block.title.content
    end

    defp type_into_prompt(pid, text) do
      for ch <- String.codepoints(text), do: press(pid, ch)
    end

    test "ctrl+o opens the prompt and the activity row renders it while idle" do
      {:ok, pid} = start_tui(provider: provider())

      press(pid, "o", ["ctrl"])

      state = eventually(pid, fn s -> s.attach != nil end)
      assert state.attach == %{draft: ""}
      # the transient row is allocated at idle and carries the prompt
      assert activity_text(state) =~ "Attach image: "

      # a second ctrl+o closes it
      press(pid, "o", ["ctrl"])
      eventually(pid, fn s -> s.attach == nil end)
    end

    test "a paste feeds the open prompt's draft, not the composer" do
      {:ok, pid} = start_tui(provider: provider())
      press(pid, "o", ["ctrl"])
      eventually(pid, fn s -> s.attach != nil end)

      inject(pid, %ExRatatui.Event.Paste{content: "/tmp/opencode/cat.png\r\n"})

      state = eventually(pid, fn s -> s.attach == %{draft: "/tmp/opencode/cat.png"} end)
      assert State.input_text(state) == ""
    end

    test "enter attaches a checked path; the submit seam carries it; streaming clears" do
      dir = images_dir()
      path = Path.join(dir, "alpha.png")
      File.write!(path, "12345678")

      {:ok, pid} = start_tui(provider: capable_provider())

      # open, type the path, attach
      press(pid, "o", ["ctrl"])
      eventually(pid, fn s -> s.attach != nil end)
      type_into_prompt(pid, path)
      press(pid, "enter")

      attached = eventually(pid, fn s -> s.attachments != [] end)
      assert attached.attachments == [%{path: path, name: "alpha.png", kb: 1}]
      assert attached.attach == nil
      # the chips ride the composer title (issue #112's numbering)
      assert composer_title(attached) == "❯ [Image #1]"

      # the turn submits with the attachment's path on the seam
      submit(pid, "what is this?")

      assert_receive {:prompt, ui_pid, "what is this?", [^path]}, 1_000

      # the :user entry's text stays verbatim; the dim indicator rides the
      # rendered lines (ADR 0006 / ADR 0018 §5)
      submitted =
        eventually(
          pid,
          fn s -> match?(%{kind: :user, text: "what is this?"}, List.last(s.entries)) end
        )

      entry = List.last(submitted.entries)
      assert entry.text == "what is this?"
      assert "📎 alpha.png (1 KB)" in flatten_lines(entry.lines)

      # the agent's streaming echo clears the pending set (ADR 0018 §6)
      send(ui_pid, {:phase, :streaming})
      cleared = eventually(pid, fn s -> s.attachments == [] end)
      refute composer_title(cleared) =~ "[Image"

      send(ui_pid, {:phase, :idle})
    end

    test "an attach refusal lands in the log and keeps the prompt open" do
      # a capable provider: the refusal below is the path check's, not the
      # capability gate's
      {:ok, pid} = start_tui(provider: capable_provider())

      press(pid, "o", ["ctrl"])
      eventually(pid, fn s -> s.attach != nil end)
      type_into_prompt(pid, "/tmp/opencode/nope.png")
      press(pid, "enter")

      state =
        eventually(pid, fn s ->
          Enum.any?(s.entries, &(&1.kind == :system and &1.text =~ "nope.png"))
        end)

      # the refusal names the path and the prompt stays open, draft intact
      assert state.attach == %{draft: "/tmp/opencode/nope.png"}
      assert state.attachments == []
      assert state.phase == :idle
    end

    # The drag-and-drop shape (issue #112; ADR 0018's 2026-10-31
    # amendment): a bracketed paste of an existing image path attaches as a
    # numbered chip — the path never types into the draft.
    test "a bracketed-pasted image path becomes a numbered chip, not text" do
      dir = images_dir()
      path = Path.join(dir, "dropped.png")
      File.write!(path, "12345678")

      {:ok, pid} = start_tui(provider: capable_provider())

      inject(pid, %ExRatatui.Event.Paste{content: path <> "\r\n"})

      state = eventually(pid, fn s -> s.attachments != [] end)
      assert state.attachments == [%{path: path, name: "dropped.png", kb: 1}]
      assert State.input_text(state) == ""
      assert composer_title(state) == "❯ [Image #1]"

      # a second drop numbers on; Backspace on the empty draft pops the
      # newest chip and renumbers
      other = Path.join(dir, "second.jpg")
      File.write!(other, "12345678")
      inject(pid, %ExRatatui.Event.Paste{content: other})

      two = eventually(pid, fn s -> length(s.attachments) == 2 end)
      assert composer_title(two) == "❯ [Image #1] [Image #2]"

      press(pid, "backspace")
      popped = eventually(pid, fn s -> length(s.attachments) == 1 end)
      assert Enum.map(popped.attachments, & &1.path) == [path]
      assert composer_title(popped) == "❯ [Image #1]"

      # the submit seam carries the queue; the streaming echo clears it
      submit(pid, "what is this?")
      assert_receive {:prompt, ui_pid, "what is this?", [^path]}, 1_000

      send(ui_pid, {:phase, :streaming})
      eventually(pid, fn s -> s.attachments == [] end)
      send(ui_pid, {:phase, :idle})
    end

    test "a dropped image path on a non-capable model refuses visibly" do
      dir = images_dir()
      path = Path.join(dir, "dropped.png")
      File.write!(path, "12345678")

      {:ok, pid} = start_tui(provider: provider())

      inject(pid, %ExRatatui.Event.Paste{content: path})

      state =
        eventually(pid, fn s ->
          Enum.any?(s.entries, &(&1.kind == :system and &1.text =~ "[images:"))
        end)

      assert state.attachments == []
      assert State.input_text(state) == ""

      last = List.last(state.entries)
      assert last.text =~ "model test-model does not accept images"
    end
  end

  # The Herdr integration (ADR 0024): the reporter hooks are driven through
  # the real TUI event loop — mount's first report, the phase transitions
  # through the stream contract, the blocked prompts, the session-id
  # landing, and release on quit. The injected runner is the test seam.
  describe "herdr reporting (ADR 0024)" do
    defp herdr_ctx do
      test = self()

      %DashFloat.Herdr{
        pane: "wA:p1",
        socket: "/tmp/opencode/herdr-tui.sock",
        runner: fn request -> send(test, {:herdr, request}) end
      }
    end

    defp herdr_state(%{params: params}), do: params.state

    defp herdr_message(%{params: params}), do: params[:message]

    test "mount holds the pane with the idle state" do
      {:ok, pid} = start_tui(provider: provider(), herdr: herdr_ctx())

      assert_receive {:herdr, %{method: "pane.report_agent", params: params}}, 1_000
      seq = params.seq

      assert params == %{
               pane_id: "wA:p1",
               source: "dashfloat",
               agent: "dashfloat",
               state: "idle",
               seq: seq
             }

      assert seq > 0
      assert get_state(pid).herdr.seq == seq
    end

    test "outside Herdr nothing reports and nothing breaks" do
      {:ok, pid} = start_tui(provider: provider())

      submit(pid, "hello")
      assert_receive {:prompt, _ui, "hello", []}, 1_000
      refute_receive {:herdr, _request}, 50
      assert get_state(pid).herdr == nil
    end

    test "a turn reports working, then idle" do
      {:ok, pid} = start_tui(provider: provider(), herdr: herdr_ctx())
      assert_receive {:herdr, request}, 1_000
      assert herdr_state(request) == "idle"

      submit(pid, "hello")
      assert_receive {:prompt, ui, "hello", []}, 1_000
      assert_receive {:herdr, request}, 1_000
      assert herdr_state(request) == "working"

      send(ui, {:phase, :idle})
      assert_receive {:herdr, request}, 1_000
      assert herdr_state(request) == "idle"
    end

    test "a confirm prompt reports blocked naming the decision" do
      {:ok, pid} = start_tui(provider: provider(), herdr: herdr_ctx())
      assert_receive {:herdr, _request}, 1_000

      send(pid, {:confirm, make_ref(), %{id: "c1", name: "bash", args: %{}, lines: ["$ x"]}})
      assert_receive {:herdr, request}, 1_000
      assert herdr_state(request) == "blocked"
      assert herdr_message(request) == "approve bash"
    end

    test "the exit prompt reports blocked; its expiry returns to idle" do
      {:ok, pid} = start_tui(provider: provider(), herdr: herdr_ctx())
      assert_receive {:herdr, _request}, 1_000

      press(pid, "c", ["ctrl"])
      assert_receive {:herdr, request}, 1_000
      assert herdr_state(request) == "blocked"
      assert herdr_message(request) == "exit? press Ctrl+C again"

      # The guard's one-shot timer expiry (2 s) is the non-schedule return
      # path that also carries the hook.
      assert_receive {:herdr, request}, 3_000
      assert herdr_state(request) == "idle"
    end

    test "the setup questions report blocked until the provider resolves" do
      {:ok, pid} =
        start_tui(
          setup: {:select, ["work", "home"], 0},
          resolve: fn "work" -> provider() end,
          herdr: herdr_ctx()
        )

      assert_receive {:herdr, request}, 1_000
      assert herdr_state(request) == "blocked"
      assert herdr_message(request) == "first-run setup: choose a provider"

      press(pid, "enter")
      assert_receive {:herdr, request}, 1_000
      assert herdr_state(request) == "idle"
    end

    test "the agent's session-id landing attaches the resume command" do
      {:ok, pid} = start_tui(provider: provider(), herdr: herdr_ctx())
      assert_receive {:herdr, _request}, 1_000

      id = "01923f8e-6b1e-7abc-8def-123456789abc"
      send(pid, {:session_id, id})

      assert_receive {:herdr, %{method: "pane.report_agent_session", params: params}}, 1_000
      assert params.agent_session_id == id
      assert params.resume_argv == ["dashfloat", "--resume", id, "--model", "test-model"]
      assert get_state(pid).session_id == id
    end

    test "a resumed boot reports the resume command from mount" do
      id = "01923f8e-6b1e-7abc-8def-123456789abc"
      {:ok, pid} = start_tui(provider: provider(), herdr: herdr_ctx(), session_id: id)

      assert_receive {:herdr, %{method: "pane.report_agent_session", params: params}}, 1_000
      assert params.resume_argv == ["dashfloat", "--resume", id, "--model", "test-model"]
      assert get_state(pid).session_id == id
    end

    test "quit releases the pane on teardown" do
      {:ok, pid} = start_tui(provider: provider(), herdr: herdr_ctx())
      assert_receive {:herdr, _request}, 1_000
      ref = Process.monitor(pid)

      press(pid, "q", ["ctrl"])

      assert_receive {:herdr, %{method: "pane.release_agent", params: params}}, 2_000
      assert params.pane_id == "wA:p1"
      assert params.source == "dashfloat"
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "a /model switch re-reports the resume command under the new model" do
      provider =
        {:ok,
         %Config{
           base_url: "https://active.example/v1",
           model: "m1",
           api_key: "k",
           providers: [%{label: "a", base_url: "https://active.example/v1", api_key: "k"}]
         }}

      {:ok, pid} =
        start_tui(
          provider: provider,
          catalog_fetcher: fn "https://active.example/v1", "k" ->
            {:ok, [%{model: "m2", context: 128_000}]}
          end,
          herdr: herdr_ctx(),
          session_id: "01923f8e-6b1e-7abc-8def-123456789abc"
        )

      assert_receive {:herdr, %{method: "pane.report_agent_session", params: params}}, 1_000
      assert List.last(params.resume_argv) == "m1"
      eventually(pid, fn s -> s.catalog != %{} end)

      submit(pid, "/model")
      press(pid, "enter")

      assert_receive {:herdr, %{method: "pane.report_agent_session", params: params}}, 1_000
      assert List.last(params.resume_argv) == "m2"
    end
  end

  # The /resume picker (issue #128) end to end through the real event loop,
  # and the exit print (issue #127) at the teardown every deliberate quit
  # The /resume picker (issue #128) end to end through the real event loop,
  # and the exit print (issue #127) at the teardown every deliberate quit
  # funnels through. The default fake agent is this test process: the
  # adoption send lands in this mailbox.
  describe "the /resume picker and the exit print (#127/#128)" do
    @resume_id "01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5c"
    @older_id "01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5d"

    defp sessions_dir do
      dir = wizard_dir("dashfloat-tui-resume")

      save_session(dir, @resume_id, "2026-10-30T23:00:00Z", "Pick Me", [
        %{"role" => "user", "content" => "the resume question"}
      ])

      save_session(dir, @older_id, "2026-10-29T23:00:00Z", nil, [
        %{"role" => "user", "content" => "the older question"}
      ])

      dir
    end

    defp save_session(dir, id, created_at, title, messages) do
      :ok =
        Session.save(dir, %{
          version: 1,
          id: id,
          created_at: created_at,
          title: title,
          pin: %{profile: "personal", model: "test-model", base_url: "http://localhost:1"},
          messages: messages
        })
    end

    defp picker_herdr do
      test = self()

      %DashFloat.Herdr{
        pane: "wA:p1",
        socket: "/tmp/opencode/herdr-tui.sock",
        runner: fn request -> send(test, {:herdr, request}) end
      }
    end

    test "/resume lists the store most-recent first and Enter adopts the picked session" do
      dir = sessions_dir()

      {:ok, pid} =
        start_tui(
          provider: provider(),
          sessions_dir: dir,
          herdr: picker_herdr()
        )

      assert_receive {:herdr, _request}, 1_000

      submit(pid, "/resume")
      opened = eventually(pid, fn s -> match?(%Palette{kind: :sessions}, s.palette) end)

      [first, second] = opened.palette.items
      assert first.id == @resume_id
      assert String.starts_with?(first.label, "Pick Me ·")
      assert second.id == @older_id
      assert String.starts_with?(second.label, "the older question ·")

      press(pid, "enter")

      {ui, session} =
        receive do
          {:adopt_session, ui, session} -> {ui, session}
        after
          1_000 -> flunk("the agent never received the adoption")
        end

      assert ui == pid
      assert session.id == @resume_id
      assert session.title == "Pick Me"

      # The log is the adopted transcript's replay; the identity follows.
      adopted = eventually(pid, fn s -> s.session_id == @resume_id end)
      assert entry?(adopted, :user, "the resume question")
      assert adopted.palette == nil

      # The Herdr reporter re-reports the switched session's id (the
      # signature carries it, ADR 0024 §5).
      assert_receive {:herdr, %{method: "pane.report_agent_session", params: params}}, 1_000
      assert params.agent_session_id == @resume_id
    end

    test "a session deleted between listing and Enter refuses loudly, untouched" do
      dir = sessions_dir()
      {:ok, pid} = start_tui(provider: provider(), sessions_dir: dir)

      submit(pid, "/resume")
      eventually(pid, fn s -> match?(%Palette{kind: :sessions}, s.palette) end)

      victim = Path.join(dir, @resume_id <> ".json")
      File.rm!(victim)
      press(pid, "enter")

      refused =
        eventually(
          pid,
          fn s ->
            Enum.any?(s.entries, &match?(%{kind: :system, text: "[resume failed: " <> _tail}, &1))
          end
        )

      assert refused.session_id == nil
      refute_receive {:adopt_session, _ui, _session}, 100
    end

    test "no sessions dir warns locally and never opens the picker" do
      {:ok, pid} = start_tui(provider: provider())

      submit(pid, "/resume")

      warned =
        eventually(
          pid,
          fn s ->
            Enum.any?(
              s.entries,
              &match?(%{kind: :system, text: "[no saved sessions" <> _tail}, &1)
            )
          end
        )

      assert warned.palette == nil
    end

    test "Esc over the open picker cancels back untouched" do
      dir = sessions_dir()
      {:ok, pid} = start_tui(provider: provider(), sessions_dir: dir, session_id: @older_id)

      submit(pid, "/resume")
      eventually(pid, fn s -> match?(%Palette{kind: :sessions}, s.palette) end)
      press(pid, "esc")

      cancelled = eventually(pid, fn s -> s.palette == nil end)
      assert cancelled.session_id == @older_id
      assert cancelled.entries == []
      refute_receive {:adopt_session, _ui, _session}, 100
    end

    test "exit_message: the title form when titled, the id form otherwise, nothing unpersisted" do
      dir = sessions_dir()

      # Titled and persisted — the quoted title command.
      titled =
        State.new(
          test_mode: {80, 24},
          sessions_dir: dir,
          session_id: @resume_id,
          title: "Pick Me"
        )

      assert TUI.exit_message(titled) ==
               "resume this session with:\ndashfloat --resume \"Pick Me\"\n"

      # Untitled — the bare id (a UUID needs no quoting).
      untitled = State.new(test_mode: {80, 24}, sessions_dir: dir, session_id: @older_id)

      assert TUI.exit_message(untitled) ==
               "resume this session with:\ndashfloat --resume #{@older_id}\n"

      # A title carrying shell specials escapes them.
      spiky =
        State.new(
          test_mode: {80, 24},
          sessions_dir: dir,
          session_id: @resume_id,
          title: ~s(he said "hi" & `that`)
        )

      # Backtick escapes too — all four POSIX double-quote specials
      # (\" \\ \$ \`) must be prefixed for a verbatim paste.
      assert TUI.exit_message(spiky) ==
               "resume this session with:\ndashfloat --resume \"he said \\\"hi\\\" & \\`that\\`\"\n"

      # Nothing persisted: no session id, or an id whose file is gone —
      # the command that would refuse at the next boot prints nothing.
      fresh = State.new(test_mode: {80, 24}, sessions_dir: dir)
      assert TUI.exit_message(fresh) == nil

      gone =
        State.new(
          test_mode: {80, 24},
          sessions_dir: dir,
          session_id: "01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5e"
        )

      assert TUI.exit_message(gone) == nil
      no_dir = State.new(test_mode: {80, 24}, session_id: @resume_id)
      assert TUI.exit_message(no_dir) == nil
    end

    test "terminate prints the command on the clean quit, after the release, never on a crash" do
      dir = sessions_dir()

      # The release runs inline through the runner seam inside terminate —
      # a marker write orders it against the print inside one capture.
      herdr = %DashFloat.Herdr{
        pane: "wA:p1",
        socket: "/tmp/opencode/x.sock",
        runner: fn request -> IO.write("RELEASED:#{request.method}") end
      }

      state =
        State.new(
          test_mode: {80, 24},
          sessions_dir: dir,
          session_id: @resume_id,
          title: "Pick Me",
          herdr: herdr
        )

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert TUI.terminate(:normal, state) == :ok
        end)

      # The release lands first (ADR 0024 §6's ordering), the print after —
      # the two surfaces never fight.
      assert {release_at, _release_end} = :binary.match(output, "RELEASED:pane.release_agent")
      assert {print_at, _print_end} = :binary.match(output, "dashfloat --resume \"Pick Me\"")
      assert release_at < print_at

      # A crash (or supervisor shutdown) never prints — the release still
      # fires (ADR 0024 §6 releases on every terminate), the print is the
      # clean exit's alone.
      quiet =
        ExUnit.CaptureIO.capture_io(fn ->
          assert TUI.terminate({:shutdown, :killed}, state) == :ok
        end)

      assert quiet =~ "RELEASED:pane.release_agent"
      refute quiet =~ "dashfloat --resume"
    end

    test "every quit path prints the command on its clean teardown" do
      dir = sessions_dir()

      quits = [
        ctrl_q: fn pid -> press(pid, "q", ["ctrl"]) end,
        double_ctrl_c: fn pid ->
          press(pid, "c", ["ctrl"])
          press(pid, "c", ["ctrl"])
        end,
        slash_quit: fn pid -> submit(pid, "/quit") end,
        # Ctrl+P's palette runs the same run_command("quit") clause; quit
        # sits at registry index 6 (clear compact help mode model profile
        # QUIT resume title) — six downs land the highlight on it.
        palette_quit: fn pid ->
          press(pid, "p", ["ctrl"])
          Enum.each(1..6, fn _step -> press(pid, "down", []) end)
          press(pid, "enter")
        end
      ]

      for {name, quit} <- quits do
        output =
          ExUnit.CaptureIO.capture_io(fn ->
            {:ok, pid} =
              start_tui(provider: provider(), sessions_dir: dir, session_id: @resume_id)

            ref = Process.monitor(pid)
            quit.(pid)
            assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
          end)

        assert output =~ "dashfloat --resume",
               "#{name} never printed the resume command: #{inspect(output)}"
      end
    end
  end
end
