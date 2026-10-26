defmodule DashFloat.Config.OnboardingTest do
  @moduledoc false
  # ADR 0009: the first-run wizard's pure state machine, the presets it
  # offers, and the end-to-end drive a fresh HOME through the same writers
  # the TUI runner uses. Placeholders only — never a real key.
  use ExUnit.Case, async: true

  alias DashFloat.Config
  alias DashFloat.Config.Catalog
  alias DashFloat.Config.Onboarding
  alias DashFloat.Config.Presets

  @zai_url "https://api.z.ai/api/coding/paas/v4"
  @tmp_root "/tmp/opencode"

  defp tmp_dir do
    dir = Path.join(@tmp_root, "dashfloat-onboarding-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o777)
  end

  # Drives the machine one key at a time, returning the final state and the
  # collected actions IN ORDER — exactly what the TUI runner does.
  defp drive(state, keys) do
    Enum.reduce(keys, {state, []}, fn key, {state, actions} ->
      {state, action} = Onboarding.handle_key(state, key)
      {state, if(action, do: actions ++ [action], else: actions)}
    end)
  end

  defp press(state, keys) do
    {state, _actions} = drive(state, keys)
    state
  end

  describe "presets (first-class, verified — ADR 0009)" do
    test "Z.AI Coding Plan and Synthetic with their exact base URLs, plus friendly labels" do
      assert [
               %{id: :zai, name: "Z.AI Coding Plan", label: "zai", base_url: @zai_url},
               %{
                 id: :synthetic,
                 name: "Synthetic",
                 label: "synthetic",
                 base_url: "https://api.synthetic.new/openai/v1"
               }
             ] = Presets.all()
    end
  end

  describe "the happy path" do
    test "welcome → name → preset provider → key → manual model → done, with the write actions" do
      {state, actions} =
        drive(
          Onboarding.new(),
          ["enter" | List.duplicate("backspace", 8)] ++
            String.codepoints("work") ++
            [
              "enter",
              # provider: the Z.AI preset (choice 0); label: accept 'zai'
              "enter",
              "enter",
              # the key
              "k",
              "-",
              "1",
              "enter",
              # model: manual entry
              "down",
              "enter",
              "g",
              "l",
              "m",
              "enter",
              # loop: done
              "down",
              "down",
              "enter"
            ]
        )

      assert state.step == :done
      assert state.profile_name == "work"
      assert {:write_key, {"work", @zai_url, "k-1"}} in actions
      assert {:write_settings, doc} = List.last(actions)
      assert doc["configVersion"] == 3
      assert doc["defaultProfile"] == "work"

      assert [%{"label" => "zai", "baseUrl" => @zai_url, "models" => [model]}] =
               hd(doc["profiles"])["providers"]

      assert hd(doc["profiles"])["name"] == "work"

      assert model == %{"nickname" => "glm", "model" => "glm"}
      assert hd(doc["profiles"])["mcp"] == []

      # One more Enter hands off to the app.
      {^state, :finish} = Onboarding.handle_key(state, "enter")
    end

    test "the profile name defaults to the prefill on a blank Enter" do
      state = press(Onboarding.new(), ["enter", "enter"])
      assert state.step == :provider
      assert state.profile_name == "personal"
    end

    test "backspace edits the draft" do
      state =
        press(
          Onboarding.new(),
          ["enter" | List.duplicate("backspace", 8)] ++ ["a", "b", "backspace", "c"]
        )

      assert state.draft == "ac"
    end
  end

  describe "provider choice" do
    test "custom URL: esc goes back; blank does not advance; the label defaults to the host" do
      state = press(Onboarding.new(), ["enter", "enter", "down", "down", "enter"])
      assert state.step == :custom_url

      back = press(state, ["esc"])
      assert back.step == :provider

      stuck = press(state, ["enter"])
      assert stuck.step == :custom_url

      custom =
        press(state, String.codepoints("https://custom.example/v1") ++ ["enter"])

      assert custom.step == :label
      assert custom.draft == "custom.example"
      assert custom.pending.base_url == "https://custom.example/v1"
    end

    test "skip lands in the loop menu with a provider-less profile" do
      {state, actions} =
        drive(Onboarding.new(), ["enter", "enter", "down", "down", "down", "enter"])

      assert state.step == :loop
      assert state.providers == []

      {_state, more} = drive(state, ["down", "down", "enter"])
      {:write_settings, doc} = List.last(more)
      assert hd(doc["profiles"])["providers"] == []
    end
  end

  describe "the key step" do
    defp at_key_step do
      press(Onboarding.new(), ["enter", "enter", "enter", "enter"])
    end

    test "a paste is written immediately (ADR 0009: abort-resume)" do
      {state, actions} =
        drive(at_key_step(), String.codepoints("sk-live-placeholder") ++ ["enter"])

      assert [{:write_key, {"personal", @zai_url, "sk-live-placeholder"}}] = actions
      assert state.step == :model_choice
      assert state.pending.key == "sk-live-placeholder"
    end

    test "a $ENV_VAR reference is stored verbatim, not resolved" do
      {_state, actions} = drive(at_key_step(), String.codepoints("$ZAI_KEY") ++ ["enter"])

      assert [{:write_key, {"personal", @zai_url, "$ZAI_KEY"}}] = actions
    end

    test "esc skips the key" do
      {state, actions} = drive(at_key_step(), ["esc"])
      assert actions == []
      # No key → no fetch offer in the model step.
      assert Onboarding.options(state) == [:manual, :skip]
    end
  end

  describe "the model step (ADR 0009: fetch, failure-soft)" do
    defp at_model_choice do
      press(Onboarding.new(), ["enter", "enter", "enter", "enter", "k", "enter"])
    end

    test "with a key the fetch is offered first" do
      state = at_model_choice()
      assert Onboarding.options(state) == [:fetch, :manual, :skip]
    end

    test "fetch emits the action and waits; ids populate the picker; nickname defaults to id" do
      {fetched, actions} = drive(at_model_choice(), ["enter"])
      assert fetched.step == :fetching
      assert [{:fetch_models, {@zai_url, "k"}}] = actions

      results = {:ok, [%{model: "m-a", context: nil}, %{model: "m-b", context: 8}]}
      state = Onboarding.models_arrived(fetched, results)

      assert state.step == :model_pick
      assert state.fetched == ["m-a", "m-b"]

      picked = press(state, ["down", "enter"])
      assert picked.step == :loop
      assert [%{models: [%{nickname: "m-b", model: "m-b"}]}] = picked.providers
    end

    test "a failed or empty fetch falls back to manual entry, never an error screen" do
      waiting = press(at_model_choice(), ["enter"])

      for result <- [:error, {:ok, []}] do
        assert Onboarding.models_arrived(waiting, result).step == :model_manual
      end
    end

    test "esc during the fetch falls back to manual; a late result is ignored" do
      state = press(at_model_choice(), ["enter", "esc"])
      assert state.step == :model_manual

      stale = Onboarding.models_arrived(state, {:ok, [%{model: "late"}]})
      assert stale.step == :model_manual
    end

    test "skip leaves the provider with an empty menu" do
      state = press(at_model_choice(), ["down", "down", "enter"])
      assert state.step == :loop
      assert [%{models: []}] = state.providers
    end
  end

  describe "the optional loops" do
    defp at_loop do
      keys = ["enter", "enter", "enter", "enter", "k", "enter", "down", "down", "enter"]
      press(Onboarding.new(), keys)
    end

    test "another provider under the same profile" do
      state =
        press(at_loop(), [
          "enter",
          "down",
          "enter",
          "enter",
          "s",
          "enter",
          "down",
          "down",
          "enter"
        ])

      assert state.step == :loop
      assert length(state.providers) == 2

      {_done, actions} = drive(state, ["down", "down", "enter"])
      {:write_settings, doc} = List.last(actions)
      assert length(hd(doc["profiles"])["providers"]) == 2
    end

    test "an MCP server: name → command → args → token env var (stored as $REF)" do
      state =
        press(at_loop(), [
          "down",
          "enter",
          "f",
          "e",
          "t",
          "c",
          "h",
          "enter",
          "u",
          "v",
          "x",
          "enter",
          "m",
          "c",
          "p",
          "-",
          "s",
          "e",
          "r",
          "v",
          "e",
          "r",
          " ",
          "f",
          "e",
          "t",
          "c",
          "h",
          "enter",
          "F",
          "E",
          "T",
          "C",
          "H",
          "_",
          "T",
          "O",
          "K",
          "E",
          "N",
          "enter"
        ])

      assert state.step == :loop

      {_done, actions} = drive(state, ["down", "down", "enter"])
      {:write_settings, doc} = List.last(actions)

      assert [
               %{
                 "name" => "fetch",
                 "command" => "uvx",
                 "args" => ["mcp-server", "fetch"],
                 "token" => "$FETCH_TOKEN"
               }
             ] = hd(doc["profiles"])["mcp"]
    end

    test "MCP sub-steps skip and cancel" do
      blank_name = press(at_loop(), ["down", "enter", "enter"])
      assert blank_name.step == :loop

      named = press(at_loop(), ["down", "enter", "n", "enter"])
      cancelled = press(named, ["enter"])
      assert cancelled.step == :loop
    end
  end

  describe "end to end on a fresh HOME (the Done-when drive)" do
    test "files written 0600, the entered key resolves as the effective credential" do
      dir = tmp_dir()

      # The runner: execute the wizard's actions exactly as the TUI does.
      # (Names clear the prefill first — the draft is an editor, typing
      # appends.)
      keys =
        ["enter" | List.duplicate("backspace", 8)] ++
          String.codepoints("personal") ++
          [
            "enter",
            # provider: the Z.AI preset (choice 0)
            "enter",
            # label: accept the suggested 'zai'
            "enter",
            # the key
            "k",
            "-",
            "p",
            "e",
            "r",
            "s",
            "o",
            "n",
            "a",
            "l",
            "enter",
            # model: type it manually
            "down",
            "enter",
            "g",
            "l",
            "m",
            "-",
            "5",
            "enter",
            # loop: done
            "down",
            "down",
            "enter"
          ]

      {state, actions} = drive(Onboarding.new(), keys)

      assert state.step == :done

      for action <- actions do
        case action do
          {:write_key, {profile, base_url, value}} ->
            :ok = Config.write_keys_entry(dir, profile, base_url, value)

          {:write_settings, doc} ->
            :ok = Config.write_settings(dir, doc)
        end
      end

      settings = Path.join(dir, "settings.json5")
      keys_file = Path.join(dir, "keys.json5")
      assert mode(settings) == 0o600
      assert mode(keys_file) == 0o600

      assert {:ok,
              %Config{
                profile: "personal",
                base_url: @zai_url,
                model: "glm-5",
                nickname: "glm-5",
                api_key: "k-personal"
              }} = Config.load(dir, %{}, [])
    end

    test "an aborted run before the key step writes nothing; after it, keys.json5 alone survives" do
      dir = tmp_dir()

      early = press(Onboarding.new(), ["enter", "enter", "enter", "enter", "esc"])
      assert early.step == :model_choice
      settings = Path.join(dir, "settings.json5")
      keys = Path.join(dir, "keys.json5")
      refute File.exists?(settings)
      refute File.exists?(keys)

      {_late, actions} =
        drive(Onboarding.new(), [
          "enter",
          "enter",
          "enter",
          "enter",
          "k",
          "enter",
          "down",
          "down",
          "enter"
        ])

      assert actions != []
      assert elem(hd(actions), 0) == :write_key

      # A later re-run reaching the same profile+endpoint skips the key step
      # and finds its key already homed (abort-resume by construction).
      rerun = press(Onboarding.new(), ["enter", "enter", "enter", "enter", "esc"])
      assert rerun.step == :model_choice
    end

    test "skip-everything writes a valid minimal config — onboarding never loops" do
      dir = tmp_dir()

      {_state, actions} =
        drive(Onboarding.new(), [
          "enter",
          "enter",
          "down",
          "down",
          "down",
          "enter",
          "down",
          "down",
          "enter"
        ])

      {:write_settings, doc} = List.last(actions)
      :ok = Config.write_settings(dir, doc)

      # A profile EXISTS (the wizard's contract), so the next load is a
      # field error — never :onboard again.
      assert {:error, "missing provider config: base_url, model, api_key"} =
               Config.load(dir, %{}, [])

      refute match?(:onboard, Config.load(dir, %{}, []))
    end
  end

  describe "navigation noise and edge arms" do
    test "irrelevant keys at each step are no-ops (never crashes, never advances)" do
      base = Onboarding.new()

      # welcome swallows everything but Enter
      {welcome, nil} = Onboarding.handle_key(base, "x")
      assert welcome.step == :welcome

      named = press(base, ["enter", "enter", "enter", "enter", "k", "enter"])

      # selection steps: up wraps, noise is inert
      provider = press(base, ["enter", "enter"])
      {wrapped, nil} = Onboarding.handle_key(provider, "up")
      assert wrapped.choice == 3

      {noise, nil} = Onboarding.handle_key(provider, "z")
      assert noise.step == :provider

      # text steps: non-char keys (arrows etc.) do not edit the draft
      model_choice = press(base, ["enter", "enter", "enter", "enter", "k", "enter"])

      {up_noise, nil} = Onboarding.handle_key(model_choice, "up")
      assert up_noise.step == :model_choice

      {key_noise, nil} = Onboarding.handle_key(model_choice, "tab")
      assert key_noise.step == :model_choice

      # fetching: only esc matters
      fetching = press(model_choice, ["enter"])
      {fetch_noise, nil} = Onboarding.handle_key(fetching, "down")
      assert fetch_noise.step == :fetching

      # model_pick: up wraps, noise inert, manual is the last option
      picker = Onboarding.models_arrived(fetching, {:ok, [%{model: "a"}, %{model: "b"}]})
      {pick_up, nil} = Onboarding.handle_key(picker, "up")
      assert pick_up.choice == 2

      {pick_noise, nil} = Onboarding.handle_key(picker, "q")
      assert pick_noise.step == :model_pick

      manual = press(picker, ["down", "down", "enter"])
      assert manual.step == :model_manual

      # model_manual: blank Enter skips the model
      {skipped, nil} = Onboarding.handle_key(manual, "enter")
      assert skipped.step == :loop

      # loop: up wraps, noise inert
      {loop_up, nil} = Onboarding.handle_key(skipped, "up")
      assert loop_up.step == :loop

      {loop_noise, nil} = Onboarding.handle_key(skipped, "x")
      assert loop_noise.step == :loop

      # done: only Enter finishes, noise is inert
      finished = press(skipped, ["down", "down", "enter"])
      assert finished.step == :done

      {done_noise, nil} = Onboarding.handle_key(finished, "x")
      assert done_noise.step == :done

      # text steps ignore non-character keys (arrows, tab)
      typing = press(Onboarding.new(), ["enter"])
      {arrow, nil} = Onboarding.handle_key(typing, "left")
      assert arrow.draft == "personal"

      {tabbed, nil} = Onboarding.handle_key(typing, "tab")
      assert tabbed.draft == "personal"
    end

    test "a label can be edited; a host-less custom URL becomes its own label" do
      state = press(Onboarding.new(), ["enter", "enter", "down", "down", "enter"])

      custom =
        press(state, String.codepoints("just-a-word") ++ ["enter", "enter"])

      assert custom.pending.label == "just-a-word"

      edited =
        press(
          state,
          String.codepoints("https://x.example/v1") ++ ["enter" | ["b", "a", "d", "enter"]]
        )

      assert edited.pending.label == "x.examplebad"
    end

    test "an MCP entry without a token stores no token key" do
      at_loop =
        press(Onboarding.new(), [
          "enter",
          "enter",
          "enter",
          "enter",
          "k",
          "enter",
          "down",
          "down",
          "enter"
        ])

      state =
        press(at_loop, [
          "down",
          "enter",
          "n",
          "enter",
          "c",
          "m",
          "d",
          "enter",
          "enter",
          "enter"
        ])

      {_done, actions} = drive(state, ["down", "down", "enter"])
      {:write_settings, doc} = List.last(actions)
      [mcp_entry] = hd(doc["profiles"])["mcp"]
      assert mcp_entry == %{"name" => "n", "command" => "cmd", "args" => []}
    end

    test "options on non-selection steps is the empty list" do
      assert Onboarding.options(Onboarding.new()) == []
      assert Onboarding.options(%Onboarding{step: :profile_name}) == []
    end
  end

  describe "catalog interplay" do
    test "the wizard's fetch action feeds Catalog.fetch and the picker merges (same contract)" do
      # The merge rules are the catalog's (ADR 0009): explicit entries win,
      # catalog ids append with nickname = id.
      menu = [%{nickname: "Mine", model: "glm-5.3", context: nil}]
      fetched = [%{model: "glm-5.3", context: 128_000}, %{model: "new-one", context: nil}]

      assert Catalog.merge(menu, fetched) == [
               %{nickname: "Mine", model: "glm-5.3", context: 128_000},
               %{nickname: "new-one", model: "new-one", context: nil}
             ]
    end
  end
end
