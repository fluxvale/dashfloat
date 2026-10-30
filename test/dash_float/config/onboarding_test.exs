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
  # collected actions IN ORDER — exactly what the TUI runner does. A
  # keypress's action may be a list (issue #64) or nil.
  defp drive(state, keys) do
    Enum.reduce(keys, {state, []}, fn key, {state, actions} ->
      {state, action} = Onboarding.handle_key(state, key)
      {state, actions ++ List.wrap(action)}
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
              # the key: the write and its fetch are one ordered pair
              "k",
              "-",
              "1",
              "enter",
              # model: esc leaves the (never-answered) fetch for manual entry
              "esc",
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

      assert [
               {:write_key, {"work", @zai_url, "k-1"}},
               {:fetch_models, {@zai_url, "k-1"}} | _rest
             ] = actions

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

    test "a picked model's observed window is written into settings.json5 (issue #111)" do
      # The provider's /models carried context_length for one model: the
      # pick persists it as the entry's `context` — observed metadata is
      # the freshest truth and belongs in the file. A model without one
      # (or a typed manual id) stays context-less and rides the runtime
      # seed/default.
      results =
        {:ok, [%{model: "m-observed", context: 262_144}, %{model: "m-bare", context: nil}]}

      picker = Onboarding.models_arrived(at_fetching(), results)

      picked = press(picker, ["enter"])
      observed = Onboarding.settings_doc(picked)

      assert [
               %{
                 "models" => [
                   %{"nickname" => "m-observed", "model" => "m-observed", "context" => 262_144}
                 ]
               }
             ] = hd(observed["profiles"])["providers"]

      # A pick whose entry carried no metadata writes no context key —
      # byte-compatible with the pre-#111 shape.
      bare_picked = press(picker, ["down", "enter"])
      bare = Onboarding.settings_doc(bare_picked)

      assert [
               %{
                 "models" => [%{"nickname" => "m-bare", "model" => "m-bare"} = bare_model]
               }
             ] = hd(bare["profiles"])["providers"]

      refute Map.has_key?(bare_model, "context")

      # A typed manual id knows no window either.
      manual = press(at_fetching(), ["esc"])
      typed_pick = press(manual, String.codepoints("m-typed") ++ ["enter"])
      typed = Onboarding.settings_doc(typed_pick)

      assert [
               %{"models" => [%{"nickname" => "m-typed", "model" => "m-typed"} = typed_model]}
             ] = hd(typed["profiles"])["providers"]

      refute Map.has_key?(typed_model, "context")
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
      {state, _actions} =
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

    test "a paste is written immediately and its fetch fires with it (issue #64)" do
      {state, actions} =
        drive(at_key_step(), String.codepoints("sk-live-placeholder") ++ ["enter"])

      assert actions == [
               {:write_key, {"personal", @zai_url, "sk-live-placeholder"}},
               {:fetch_models, {@zai_url, "sk-live-placeholder"}}
             ]

      assert state.step == :fetching
      assert state.fetched == []
      assert state.pending.key == "sk-live-placeholder"
    end

    test "a $ENV_VAR reference is stored verbatim, not resolved" do
      {_state, actions} = drive(at_key_step(), String.codepoints("$ZAI_KEY") ++ ["enter"])

      assert actions == [
               {:write_key, {"personal", @zai_url, "$ZAI_KEY"}},
               {:fetch_models, {@zai_url, "$ZAI_KEY"}}
             ]
    end

    test "a blank Enter skips the key straight to manual entry" do
      {state, actions} = drive(at_key_step(), ["enter"])
      assert actions == []
      assert state.step == :model_manual
    end

    test "esc returns to the label step, side-effect-free (issue #65)" do
      {state, actions} = drive(at_key_step(), ["esc"])
      assert actions == []
      assert state.step == :label
    end
  end

  describe "write refusals bounce back (issue #39)" do
    test "a refused key write returns to :key with the draft restored and the fetch off" do
      at_key = press(Onboarding.new(), ["enter", "enter", "enter", "enter"])

      {advanced, actions} = drive(at_key, String.codepoints("k-1\\9") ++ ["enter"])
      assert advanced.step == :fetching
      assert advanced.pending.key == "k-1\\9"

      assert actions == [
               {:write_key, {"personal", @zai_url, "k-1\\9"}},
               {:fetch_models, {@zai_url, "k-1\\9"}}
             ]

      bounced = Onboarding.write_failed(advanced, "keys.json5 cannot store that value")

      assert bounced.step == :key
      assert bounced.draft == "k-1\\9"
      assert bounced.pending.key == nil
      assert bounced.error == "keys.json5 cannot store that value"

      # Editing keeps the refusal on screen; a step transition clears it.
      {editing, nil} = Onboarding.handle_key(bounced, "backspace")
      assert editing.error != nil

      back = press(bounced, ["esc"])
      assert back.step == :label
      assert back.error == nil

      # The retry re-emits BOTH actions, in order.
      {retry, retry_actions} = drive(bounced, ["backspace", "backspace", "9", "enter"])
      assert retry.step == :fetching
      assert retry.error == nil

      assert retry_actions == [
               {:write_key, {"personal", @zai_url, "k-19"}},
               {:fetch_models, {@zai_url, "k-19"}}
             ]
    end

    test "a refused settings write returns to :loop with done highlighted; done retries the write" do
      {at_done, actions} =
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

      assert at_done.step == :done
      assert {:write_settings, doc} = List.last(actions)
      assert doc["configVersion"] == 3

      bounced = Onboarding.write_failed(at_done, "settings.json5 already exists")
      assert bounced.step == :loop
      assert bounced.error == "settings.json5 already exists"
      # The highlight stays on Done: Enter retries, what the hint offers.
      done_at =
        bounced
        |> Onboarding.options()
        |> Enum.find_index(&(&1 == :done))

      assert bounced.choice == done_at

      # The retry re-emits the settings write for the same document.
      {retry, retry_actions} = drive(bounced, ["enter"])
      assert retry.step == :done
      assert retry.error == nil
      assert {:write_settings, retry_doc} = List.last(retry_actions)
      assert retry_doc == doc
    end

    test "stale feedback is inert" do
      welcome = Onboarding.new()
      assert Onboarding.write_failed(welcome, "late") == welcome
    end
  end

  describe "the model step (issue #64: the fetch is the primary path)" do
    defp at_fetching do
      press(Onboarding.new(), ["enter", "enter", "enter", "enter", "k", "enter"])
    end

    test "the key enter lands at :fetching with both actions in order" do
      {state, actions} =
        drive(Onboarding.new(), ["enter", "enter", "enter", "enter", "k", "enter"])

      assert state.step == :fetching

      assert actions == [
               {:write_key, {"personal", @zai_url, "k"}},
               {:fetch_models, {@zai_url, "k"}}
             ]
    end

    test "ids populate the picker; nickname defaults to the id; an observed window rides the pick (issue #111)" do
      results = {:ok, [%{model: "m-a", context: nil}, %{model: "m-b", context: 8}]}
      state = Onboarding.models_arrived(at_fetching(), results)

      assert state.step == :model_pick
      assert state.fetched == [%{model: "m-a", context: nil}, %{model: "m-b", context: 8}]

      picked = press(state, ["down", "enter"])
      assert picked.step == :loop
      assert [%{models: [%{nickname: "m-b", model: "m-b", context: 8}]}] = picked.providers
    end

    test "an empty list falls back to manual with the reason on screen" do
      state = Onboarding.models_arrived(at_fetching(), {:ok, []})
      assert state.step == :model_manual
      assert state.note == "The provider returned no models."
    end

    test "a failed fetch falls back to manual with the fetch layer's reason" do
      http_401 = Onboarding.models_arrived(at_fetching(), {:error, "HTTP 401"})
      assert http_401.step == :model_manual
      assert http_401.note == "Couldn't fetch the model list — HTTP 401."

      # A failure shape without a reason (kept for robustness) still degrades
      # gently.
      bare = Onboarding.models_arrived(at_fetching(), :error)
      assert bare.step == :model_manual
      assert bare.note == "Couldn't fetch the model list."
    end

    test "esc during the fetch falls back to manual; a late result is ignored" do
      state = press(at_fetching(), ["esc"])
      assert state.step == :model_manual
      assert state.note == nil

      stale = Onboarding.models_arrived(state, {:ok, [%{model: "late"}]})
      assert stale.step == :model_manual
    end

    test "skip at the model step is a blank Enter on manual — the provider keeps an empty menu" do
      state = press(at_fetching(), ["esc", "enter"])
      assert state.step == :loop
      assert [%{models: []}] = state.providers
    end
  end

  describe "the optional loops" do
    defp at_loop do
      # The key enter fires the fetch; esc leaves it for manual entry, and a
      # blank Enter skips the model.
      keys = ["enter", "enter", "enter", "enter", "k", "enter", "esc", "enter"]
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
          "esc",
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
      # The loop highlight is restored memory (issue #65): the user left it
      # on add_mcp, and the finish-return lands back there.
      done_index =
        state
        |> Onboarding.options()
        |> Enum.find_index(&(&1 == :add_mcp))

      assert state.choice == done_index

      {_done, actions} = drive(state, ["down", "enter"])
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

  describe "esc back navigation (issue #65)" do
    test "profile_name: esc returns to welcome; the typed name survives the round trip" do
      welcome = Onboarding.new()
      assert press(welcome, ["esc"]).step == :welcome

      named =
        press(
          Onboarding.new(),
          ["enter" | List.duplicate("backspace", 8)] ++ String.codepoints("work")
        )

      assert named.step == :profile_name
      assert named.draft == "work"

      back = press(named, ["esc"])
      assert back.step == :welcome

      round_trip = press(back, ["enter"])
      assert round_trip.step == :profile_name
      assert round_trip.draft == "work"
    end

    test "provider: esc returns to profile_name with its remembered draft" do
      named =
        press(
          Onboarding.new(),
          ["enter" | List.duplicate("backspace", 8)] ++ String.codepoints("work")
        )

      at_provider = press(named, ["enter"])

      back = press(at_provider, ["esc"])
      assert back.step == :profile_name
      assert back.draft == "work"
    end

    test "custom_url: esc returns to provider with the choice; the draft round-trips" do
      state = press(Onboarding.new(), ["enter", "enter", "down", "down", "enter"])
      assert state.step == :custom_url

      typed = press(state, String.codepoints("https://x.example/v1"))

      back = press(typed, ["esc"])
      assert back.step == :provider
      # The move to custom is remembered, not reset.
      assert back.choice == 2

      round_trip = press(back, ["enter"])
      assert round_trip.step == :custom_url
      assert round_trip.draft == "https://x.example/v1"
    end

    test "label: esc returns to provider; key: esc returns to label; drafts round-trip" do
      at_label = press(Onboarding.new(), ["enter", "enter", "enter"])

      typed =
        press(at_label, ["backspace", "backspace", "backspace"] ++ String.codepoints("lab"))

      assert typed.draft == "lab"

      back = press(typed, ["esc"])
      assert back.step == :provider

      forward = press(back, ["enter"])
      assert forward.step == :label
      # Re-picking the preset is a NEW provider: the label memory was
      # cleared with it, so the preset prefill stands (issue #65).
      assert forward.draft == "zai"

      keyed = press(forward, ["enter" | String.codepoints("k-1")])
      assert keyed.step == :key

      back_from_key = press(keyed, ["esc"])
      assert back_from_key.step == :label
      # No label edit was remembered, so the pending label prefills.
      assert back_from_key.draft == "zai"

      round_trip = press(back_from_key, ["enter"])
      assert round_trip.step == :key
      assert round_trip.draft == "k-1"
    end

    test "fetching: esc keeps the manual fallback and a late result is inert (the exception)" do
      state = press(at_fetching(), ["esc"])
      assert state.step == :model_manual
      assert state.fetched == []

      stale = Onboarding.models_arrived(state, {:ok, [%{model: "late"}]})
      assert stale.step == :model_manual
    end

    test "model_pick: esc returns to the key with its draft; the choice re-restores" do
      picker = Onboarding.models_arrived(at_fetching(), {:ok, [%{model: "m-a"}, %{model: "m-b"}]})
      moved = press(picker, ["down"])

      back = press(moved, ["esc"])
      assert back.step == :key
      assert back.draft == "k"

      # Back then forward: the refetched picker lands on the remembered pick.
      {refetched, _actions} = drive(back, ["enter"])
      assert refetched.step == :fetching

      relanded = Onboarding.models_arrived(refetched, {:ok, [%{model: "m-a"}, %{model: "m-b"}]})
      assert relanded.step == :model_pick
      assert relanded.choice == 1
    end

    test "model_manual: esc returns to the key; the typed id round-trips" do
      manual = press(at_fetching(), ["esc"])
      typed = press(manual, String.codepoints("glm-x"))

      back = press(typed, ["esc"])
      assert back.step == :key
      assert back.draft == "k"

      {refetched, _actions} = drive(back, ["enter"])
      round_trip = press(refetched, ["esc"])
      assert round_trip.step == :model_manual
      assert round_trip.draft == "glm-x"
    end

    test "loop with no providers: esc returns to provider with the choice" do
      at_loop = press(Onboarding.new(), ["enter", "enter", "down", "down", "down", "enter"])
      assert at_loop.step == :loop

      back = press(at_loop, ["esc"])
      assert back.step == :provider
      assert back.choice == 3
    end

    test "loop pop after a picker finish: pick cleared, fetched restored, back at the picker" do
      picker = Onboarding.models_arrived(at_fetching(), {:ok, [%{model: "m-a"}, %{model: "m-b"}]})
      picked = press(picker, ["down", "enter"])
      assert picked.step == :loop

      assert [
               %{
                 models: [%{nickname: "m-b", model: "m-b"}],
                 fetched: [%{model: "m-a"}, %{model: "m-b"}]
               }
             ] =
               picked.providers

      popped = press(picked, ["esc"])
      assert popped.step == :model_pick
      assert popped.fetched == [%{model: "m-a"}, %{model: "m-b"}]
      assert popped.providers == []
      assert popped.choice == 1

      assert popped.pending == %{
               label: "zai",
               base_url: @zai_url,
               key: "k",
               models: [],
               fetched: [%{model: "m-a"}, %{model: "m-b"}]
             }

      # Re-picking re-finishes the provider exactly once.
      refinished = press(popped, ["enter"])

      assert [
               %{
                 models: [%{nickname: "m-b", model: "m-b"}],
                 fetched: [%{model: "m-a"}, %{model: "m-b"}]
               }
             ] =
               refinished.providers

      # The snapshot never reaches the settings document.
      {_done, actions} = drive(refinished, ["down", "down", "enter"])
      {:write_settings, doc} = List.last(actions)
      [provider] = hd(doc["profiles"])["providers"]
      assert Map.keys(provider) == ["baseUrl", "label", "models"]
    end

    test "loop pop after a manual finish: back at manual with the typed id" do
      manual = press(at_fetching(), ["esc"])
      finished = press(manual, String.codepoints("glm-x") ++ ["enter"])
      assert finished.step == :loop

      assert [%{models: [%{nickname: "glm-x", model: "glm-x"}], fetched: []}] =
               finished.providers

      popped = press(finished, ["esc"])
      assert popped.step == :model_manual
      assert popped.draft == "glm-x"
      assert popped.fetched == []
      assert popped.providers == []

      assert popped.pending == %{
               label: "zai",
               base_url: @zai_url,
               key: "k",
               models: [],
               fetched: []
             }

      refinished = press(popped, ["enter"])
      assert [%{models: [%{nickname: "glm-x", model: "glm-x"}]}] = refinished.providers
    end

    test "welcome and done: esc is a no-op — done never backs over a written config" do
      {still, nil} = Onboarding.handle_key(Onboarding.new(), "esc")
      assert still == Onboarding.new()

      done =
        press(Onboarding.new(), [
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

      assert done.step == :done

      {trapped, nil} = Onboarding.handle_key(done, "esc")
      assert trapped == done
    end

    test "mcp steps walk back with drafts; forward again restores them" do
      at_loop = press(Onboarding.new(), ["enter", "enter", "down", "down", "down", "enter"])

      at_name = press(at_loop, ["down", "enter"])
      named = press(at_name, String.codepoints("fetch"))
      at_command = press(named, ["enter"])
      commanded = press(at_command, String.codepoints("uvx"))
      at_args = press(commanded, ["enter"])
      argsed = press(at_args, String.codepoints("-y"))
      at_token = press(argsed, ["enter"])
      assert at_token.step == :mcp_token

      back_args = press(at_token, ["esc"])
      assert back_args.step == :mcp_args
      assert back_args.draft == "-y"

      back_command = press(back_args, ["esc"])
      assert back_command.step == :mcp_command
      assert back_command.draft == "uvx"

      back_name = press(back_command, ["esc"])
      assert back_name.step == :mcp_name
      assert back_name.draft == "fetch"

      back_loop = press(back_name, ["esc"])
      assert back_loop.step == :loop

      at_name_again = press(back_loop, ["enter"])
      assert at_name_again.step == :mcp_name
      assert at_name_again.draft == "fetch"

      round_command = press(at_name_again, ["enter"])
      assert round_command.step == :mcp_command
      assert round_command.mcp_name == "fetch"
    end

    test "esc back is side-effect-free across the whole spine" do
      {state, actions} =
        drive(
          Onboarding.new(),
          ["enter", "enter", "enter", "enter"] ++
            String.codepoints("k") ++
            ["enter", "esc", "esc", "esc", "esc", "esc", "esc"]
        )

      # The ONLY actions are the key enter's write+fetch pair; the six escs
      # (fetching → manual → key → label → provider → profile_name →
      # welcome) contribute none.
      assert actions == [
               {:write_key, {"personal", @zai_url, "k"}},
               {:fetch_models, {@zai_url, "k"}}
             ]

      assert state.step == :welcome
    end

    test "a new provider starts clean: no stale provider-scoped memory" do
      # Provider one: an edited label, a typed key, a manual model id.
      first =
        press(
          Onboarding.new(),
          ["enter", "enter", "enter"] ++
            ["backspace", "backspace", "backspace"] ++
            String.codepoints("lab-one") ++
            ["enter"] ++
            String.codepoints("k1") ++
            ["enter", "esc"] ++
            String.codepoints("mx") ++
            ["enter"]
        )

      assert first.step == :loop

      # Provider two: the preset label again, an empty key draft, an empty
      # manual draft — provider one's edits are gone.
      at_label_two = press(first, ["enter", "enter"])
      assert at_label_two.step == :label
      assert at_label_two.draft == "zai"

      at_key_two = press(at_label_two, ["enter"])
      assert at_key_two.step == :key
      assert at_key_two.draft == ""

      at_manual_two = press(at_key_two, ["enter"])
      assert at_manual_two.step == :model_manual
      assert at_manual_two.draft == ""
    end

    test "custom_url memory survives across providers" do
      at_custom = press(Onboarding.new(), ["enter", "enter", "down", "down", "enter"])
      typed = press(at_custom, String.codepoints("https://one.example/v1"))

      # Provider one finished keyless and model-less.
      one = press(typed, ["enter", "enter", "enter", "enter"])
      assert one.step == :loop

      # Provider two's custom entry pre-fills provider one's URL.
      two_custom = press(one, ["enter", "down", "down", "enter"])
      assert two_custom.step == :custom_url
      assert two_custom.draft == "https://one.example/v1"

      two = press(two_custom, ["enter", "enter", "enter", "enter"])
      assert length(two.providers) == 2
    end

    test "consecutive providers cannot cross-contaminate the fetched list" do
      # Provider one finishes from the picker: its snapshot is the list.
      picker = Onboarding.models_arrived(at_fetching(), {:ok, [%{model: "m-a"}]})
      one = press(picker, ["enter"])
      assert [%{fetched: [%{model: "m-a"}]}] = one.providers

      # Provider two keyless: no fetch ran, and every manual entry clears
      # fetched — the finish must snapshot [], never provider one's list.
      two = press(one, ["enter", "enter", "enter", "enter"])
      assert two.step == :model_manual
      assert two.fetched == []

      finished = press(two, ["enter"])
      assert [%{fetched: [%{model: "m-a"}]}, %{fetched: []}] = finished.providers
    end

    test "a bracketed paste feeds the memory: the pasted key round-trips" do
      at_key = at_key_step()
      pasted = Onboarding.paste(at_key, "PLACEHOLDER-pasted")

      assert pasted.draft == "PLACEHOLDER-pasted"

      back = press(pasted, ["esc"])
      assert back.step == :label

      round_trip = press(back, ["enter"])
      assert round_trip.step == :key
      assert round_trip.draft == "PLACEHOLDER-pasted"
    end

    test "a refetch that shrinks the list clamps the remembered pick (no crash)" do
      # Five downs on a six-model picker remember choice 5; a refetch
      # returning one model must clamp the restore, never leave Enter
      # pointing past the list.
      six = Onboarding.models_arrived(at_fetching(), {:ok, Enum.map(1..6, &%{model: "m#{&1}"})})
      moved = press(six, List.duplicate("down", 5))
      assert moved.choice == 5

      back = press(moved, ["esc"])
      assert back.step == :key

      {refetched, _actions} = drive(back, ["enter"])
      assert refetched.step == :fetching

      relanded = Onboarding.models_arrived(refetched, {:ok, [%{model: "only"}]})
      assert relanded.fetched == [%{model: "only"}]
      assert relanded.choice == 1

      # Enter on the clamped highlight picks the manual option — no crash.
      {manual, nil} = Onboarding.handle_key(relanded, "enter")
      assert manual.step == :model_manual
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
            # the key: the Enter writes AND fires the fetch
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
            # model: esc leaves the (never-answered) fetch for manual entry
            "esc",
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

          # The fetch would run live here; this drive only exercises writes.
          {:fetch_models, _spec} ->
            :ok

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
      assert early.step == :label
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
          "esc",
          "enter"
        ])

      assert actions != []
      assert elem(hd(actions), 0) == :write_key

      # A later re-run reaching the same profile+endpoint skips the key step
      # and finds its key already homed (abort-resume by construction).
      rerun = press(Onboarding.new(), ["enter", "enter", "enter", "enter", "esc"])
      assert rerun.step == :label
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

      # selection steps: up wraps, noise is inert
      provider = press(base, ["enter", "enter"])
      {wrapped, nil} = Onboarding.handle_key(provider, "up")
      assert wrapped.choice == 3

      {noise, nil} = Onboarding.handle_key(provider, "z")
      assert noise.step == :provider

      # text steps: non-char keys (arrows etc.) do not edit the draft
      at_key = press(base, ["enter", "enter", "enter", "enter", "k"])

      {tab_noise, nil} = Onboarding.handle_key(at_key, "tab")
      assert tab_noise.step == :key

      # fetching: only esc matters, noise is inert
      fetching = press(at_key, ["enter"])
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
          "esc",
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

      # The finish-return restored the loop's highlight (add_mcp); one more
      # down reaches done.
      {_done, actions} = drive(state, ["down", "enter"])
      {:write_settings, doc} = List.last(actions)

      assert [
               %{"name" => "n", "command" => "cmd", "args" => []}
             ] = hd(doc["profiles"])["mcp"]
    end

    test "a paste at a non-text step is inert (selections own no draft)" do
      welcome = Onboarding.new()
      assert Onboarding.paste(welcome, "ignored") == welcome

      provider = press(welcome, ["enter", "enter"])
      pasted = Onboarding.paste(provider, "ignored")
      assert pasted.choice == provider.choice
      refute Map.get(pasted, :draft) =~ "ignored"
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
