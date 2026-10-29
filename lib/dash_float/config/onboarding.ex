defmodule DashFloat.Config.Onboarding do
  @moduledoc """
  The first-run onboarding wizard's pure state machine
  ([ADR 0009](../../docs/decisions/0009-config-v3-persona-profiles.md)).

  Modeled on Octofriend's first-time setup: welcome → name your first profile
  (becomes `defaultProfile`) → add a provider (Z.AI / Synthetic presets or a
  custom OpenAI-compatible URL) → the key (paste, a `$ENV_VAR` reference, or
  skip — a paste is written straight into `keys.json5` at 0600, immediately,
  merging into any existing file) → pick a model (the key is written, then
  the `/models` fetch runs automatically; the fetched list is the picker —
  Enter selects; manual entry is the explicit fallback — esc while fetching
  or the picker's last option; failures fall back to manual with the reason
  on screen; nickname defaults to the model id) → optional loops (more
  providers, MCP servers; every step skippable) → done: `settings.json5`
  written and the app starts under the new profile. Esc at any other step
  walks BACK to the previous one, side-effect-free, the step's remembered
  draft/choice restored (issue #65; ADR 0009's back-navigation amendment):
  `:welcome` and `:done` are no-ops, `:fetching`'s esc stays the manual
  fallback, and esc at `:loop` pops the last finished provider.

  This module is pure: it never touches the filesystem or the network.
  `handle_key/2` returns `{state, action}` where the RUNNER executes the
  side-effecting actions — `action` is a single action or an ordered LIST of
  actions, executed in order. Actions: `{:write_key, {profile, base_url,
  value}}` (atomic 0600 merge into keys.json5), `{:fetch_models, {base_url,
  raw_key}}` (the standing catalog fetch), `{:write_settings, map}` (atomic
  0600 write), `:finish` (hand the freshly-written config to the app),
  `:quit` (abort — nothing further is written). `models_arrived/2` feeds the
  fetch result back. Key inputs render masked; this module never echoes a
  value.
  """

  alias DashFloat.Config.Catalog
  alias DashFloat.Config.Presets

  @env_ref ~r/\A\$[A-Z_][A-Z0-9_]*\z/

  @type step ::
          :welcome
          | :profile_name
          | :provider
          | :custom_url
          | :label
          | :key
          | :fetching
          | :model_pick
          | :model_manual
          | :loop
          | :mcp_name
          | :mcp_command
          | :mcp_args
          | :mcp_token
          | :done

  @type provider_draft :: %{
          label: String.t(),
          base_url: String.t(),
          key: String.t() | nil,
          models: [%{nickname: String.t(), model: String.t()}],
          # The fetch snapshot at finish (issue #65): what the loop's esc-pop
          # restores. Never written out — settings_doc/1 maps explicit fields.
          fetched: [String.t()]
        }

  @type t :: %__MODULE__{
          step: step(),
          draft: String.t(),
          pending: provider_draft() | nil,
          choice: non_neg_integer(),
          fetched: [String.t()],
          profile_name: String.t(),
          providers: [provider_draft()],
          mcp: [%{name: String.t(), command: String.t(), args: [String.t()], token: nil | :ref}],
          memory: %{optional(step()) => %{draft: String.t(), choice: non_neg_integer()}},
          note: String.t() | nil
        }

  # Inspected standalone (logs, IEx): the draft, the pending provider, and
  # the back-nav memory can hold the plaintext key — ADR 0005's never-echo
  # rule, belt to DashFloat.TUI.State's own :setup exclusion (P1-3, hostile
  # review).
  @derive {Inspect, except: [:draft, :pending, :memory]}
  defstruct step: :welcome,
            draft: "",
            pending: nil,
            choice: 0,
            fetched: [],
            profile_name: "personal",
            providers: [],
            mcp: [],
            mcp_name: nil,
            mcp_command: nil,
            mcp_args: [],
            # Per-step draft/choice snapshots (issue #65): what esc-back
            # restores — a back-then-forward round trip is lossless.
            memory: %{},
            # A refused write's message, shown at the step that issued the
            # write (issue #39): paths and remedies only, never values.
            error: nil,
            # The manual-fallback screen's gentle note (issue #64): the
            # fetch failure's short class phrase — informational, never an
            # error, and never response-body content.
            note: nil

  @doc "The initial wizard state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  A bracketed paste into the wizard's current text step (P1-2, hostile
  review): appended to the draft with CR/CRLF/newlines normalized out — a
  key pasted with a trailing newline is the common terminal shape.
  Selection steps ignore it (no text input there).
  """
  @spec paste(t(), String.t()) :: t()
  def paste(%__MODULE__{step: step, draft: draft} = state, content)
      when is_binary(content) and
             step in [
               :profile_name,
               :custom_url,
               :label,
               :key,
               :model_manual,
               :mcp_name,
               :mcp_command,
               :mcp_args,
               :mcp_token
             ] do
    # A paste is an edit: it feeds the back-nav memory like typing (issue #65).
    remember(%{state | draft: draft <> normalize(content)})
  end

  def paste(%__MODULE__{} = state, _content), do: state

  defp normalize(content) do
    content
    |> String.replace("\r\n", "")
    |> String.replace("\r", "")
    |> String.replace("\n", "")
  end

  @doc """
  One keypress: `{state, action}`. `code` is an `ExRatatui` key code; the
  global Ctrl+C/Ctrl+Q quits live in the TUI router, not here. Line steps
  type (single chars), backspace, Enter to accept; Esc steps BACK to the
  previous step — side-effect-free, the destination's remembered draft and
  choice restored — except at `:fetching`, where Esc is the manual fallback,
  and at `:welcome`/`:done`, where it is a no-op. Selection steps move with
  up/down and pick with Enter.
  """
  @spec handle_key(t(), String.t()) :: {t(), term()}
  def handle_key(%__MODULE__{step: step} = state, code), do: step_key(state, step, code)

  ## Welcome

  defp step_key(state, :welcome, "enter"),
    do: {step(state, :profile_name, state.profile_name), nil}

  defp step_key(state, :welcome, _code), do: {state, nil}

  ## Profile name (becomes defaultProfile; blank keeps the prefill)

  # Esc back (issue #65): the welcome screen's ctrl+q stays the taught,
  # deliberate abort — esc here is navigation, not a quit.
  defp step_key(state, :profile_name, "esc"), do: {step(state, :welcome, ""), nil}

  defp step_key(state, :profile_name, "enter") do
    name = nonblank(state.draft) || state.profile_name
    {%{step(state, :provider, "") | profile_name: name}, nil}
  end

  defp step_key(state, :profile_name, code), do: {edit(state, code), nil}

  ## Provider choice (presets + custom + skip)

  defp step_key(state, :provider, "esc"), do: {step(state, :profile_name, ""), nil}
  defp step_key(state, :provider, "up"), do: {move(state, -1), nil}
  defp step_key(state, :provider, "down"), do: {move(state, 1), nil}

  defp step_key(state, :provider, "enter") do
    case option(state) do
      {:preset, preset} ->
        pending = %{
          label: preset.label,
          base_url: preset.base_url,
          key: nil,
          models: [],
          fetched: []
        }

        {enter_provider(state, pending, preset.label), nil}

      :custom ->
        {step(state, :custom_url, ""), nil}

      :skip ->
        {step(state, :loop, ""), nil}
    end
  end

  defp step_key(state, :provider, _code), do: {state, nil}

  ## Custom base URL

  defp step_key(state, :custom_url, "enter") do
    case nonblank(state.draft) do
      nil ->
        {state, nil}

      url ->
        pending = %{label: host(url), base_url: url, key: nil, models: [], fetched: []}
        {enter_provider(state, pending, host(url)), nil}
    end
  end

  defp step_key(state, :custom_url, "esc"), do: {step(state, :provider, ""), nil}
  defp step_key(state, :custom_url, code), do: {edit(state, code), nil}

  ## Provider label (optional; blank keeps the suggested/host default)

  defp step_key(state, :label, "esc"), do: {step(state, :provider, ""), nil}

  defp step_key(state, :label, "enter") do
    label = nonblank(state.draft) || state.pending.label
    {%{step(state, :key, "") | pending: %{state.pending | label: label}}, nil}
  end

  defp step_key(state, :label, code), do: {edit(state, code), nil}

  ## The key: paste, `$ENV_VAR`, or skip. A non-empty value is written to
  ## keys.json5 IMMEDIATELY (ADR 0009: abort-resume for free) — and its
  ## fetch fires with it (issue #64): the fetched list is the primary model
  ## path, so the write and the fetch travel as one ordered action pair.

  defp step_key(state, :key, "enter") do
    pending = state.pending
    profile = state.profile_name

    case nonblank(state.draft) do
      nil ->
        {to_manual(state), nil}

      value ->
        actions = [
          {:write_key, {profile, pending.base_url, value}},
          {:fetch_models, {pending.base_url, value}}
        ]

        {%{step(state, :fetching, "") | pending: %{pending | key: value}, fetched: []}, actions}
    end
  end

  # Esc walks back to the label (issue #65 — it no longer skips; a blank
  # Enter above still skips forward). The pending label prefills — the
  # value a blank Enter would keep, what the write-failed bounce shows too.
  # Re-accepting re-executes nothing here; at the key it re-executes the
  # write, an idempotent merge into keys.json5.
  defp step_key(state, :key, "esc"), do: {step(state, :label, state.pending.label), nil}
  defp step_key(state, :key, code), do: {edit(state, code), nil}

  # Waiting on the fetch: Esc is the manual fallback, not back navigation
  # (issue #65's documented exception — a fetch result landing after this
  # esc is ignored), and entering manual always clears `fetched`.
  defp step_key(state, :fetching, "esc"), do: {to_manual(state), nil}
  defp step_key(state, :fetching, _code), do: {state, nil}

  # The picker over fetched ids (nickname defaults to the id), manual entry
  # as the last option.
  defp step_key(state, :model_pick, "esc"), do: {step(state, :key, ""), nil}
  defp step_key(state, :model_pick, "up"), do: {move(state, -1), nil}
  defp step_key(state, :model_pick, "down"), do: {move(state, 1), nil}

  defp step_key(state, :model_pick, "enter") do
    case option(state) do
      {:model, id} ->
        {finish_provider(add_model(state, id)), nil}

      :manual ->
        {to_manual(state), nil}
    end
  end

  defp step_key(state, :model_pick, _code), do: {state, nil}

  defp step_key(state, :model_manual, "esc"), do: {step(state, :key, ""), nil}

  defp step_key(state, :model_manual, "enter") do
    case nonblank(state.draft) do
      nil -> {finish_provider(state), nil}
      id -> {finish_provider(add_model(state, id)), nil}
    end
  end

  defp step_key(state, :model_manual, code), do: {edit(state, code), nil}

  ## The optional loops: another provider, an MCP server, or done

  # Esc back (issue #65): with a finished provider, undo the finish — the
  # provider returns as pending with its pick cleared (that is what is being
  # undone) and its fetch snapshot restored, landing at the step it finished
  # from: the picker when the snapshot is non-empty, manual otherwise. With
  # no providers, back to the provider choice.

  defp step_key(%__MODULE__{providers: []} = state, :loop, "esc"),
    do: {step(state, :provider, ""), nil}

  defp step_key(%__MODULE__{providers: providers} = state, :loop, "esc") do
    last = List.last(providers)
    fetched = last.fetched

    {%{
       step(state, if(fetched == [], do: :model_manual, else: :model_pick), "")
       | pending: %{last | models: []},
         fetched: fetched,
         providers: :lists.sublist(providers, length(providers) - 1)
     }, nil}
  end

  defp step_key(state, :loop, "up"), do: {move(state, -1), nil}
  defp step_key(state, :loop, "down"), do: {move(state, 1), nil}

  defp step_key(state, :loop, "enter") do
    case option(state) do
      :add_provider -> {%{step(state, :provider, "") | pending: nil, choice: 0}, nil}
      :add_mcp -> {step(state, :mcp_name, ""), nil}
      :done -> {%{step(state, :done, "") | pending: nil}, {:write_settings, settings_doc(state)}}
    end
  end

  defp step_key(state, :loop, _code), do: {state, nil}

  ## MCP server sub-flow (name → command → args → optional token env var)

  defp step_key(state, :mcp_name, "esc"), do: {step(state, :loop, ""), nil}

  defp step_key(state, :mcp_name, "enter") do
    case nonblank(state.draft) do
      nil -> {step(state, :loop, ""), nil}
      name -> {%{step(state, :mcp_command, "") | mcp_name: name}, nil}
    end
  end

  defp step_key(state, :mcp_name, code), do: {edit(state, code), nil}

  defp step_key(state, :mcp_command, "esc"), do: {step(state, :mcp_name, ""), nil}

  defp step_key(state, :mcp_command, "enter") do
    case nonblank(state.draft) do
      nil -> {abandon_mcp(state), nil}
      command -> {%{step(state, :mcp_args, "") | mcp_command: command}, nil}
    end
  end

  defp step_key(state, :mcp_command, code), do: {edit(state, code), nil}

  defp step_key(state, :mcp_args, "esc"), do: {step(state, :mcp_command, ""), nil}

  defp step_key(state, :mcp_args, "enter") do
    args =
      state.draft
      |> String.trim()
      |> String.split()

    {%{step(state, :mcp_token, "") | mcp_args: args}, nil}
  end

  defp step_key(state, :mcp_args, code), do: {edit(state, code), nil}

  defp step_key(state, :mcp_token, "esc"), do: {step(state, :mcp_args, ""), nil}

  defp step_key(state, :mcp_token, "enter") do
    entry = %{
      name: state.mcp_name,
      command: state.mcp_command,
      args: state.mcp_args,
      token: valid_token_ref(state.draft)
    }

    state = %{state | mcp: state.mcp ++ [entry]}
    {step(state, :loop, ""), nil}
  end

  defp step_key(state, :mcp_token, code), do: {edit(state, code), nil}

  ## Done — any key hands the fresh config to the app

  defp step_key(state, :done, "enter"), do: {state, :finish}
  defp step_key(state, :done, _code), do: {state, nil}

  @doc """
  Feeds the `/models` fetch result back into the picker: ids populate the
  picker, an empty list or any failure falls back to manual entry with a
  gentle `note` on screen (ADR 0009: the fetch is failure-soft, never an
  error screen). The reason is a class phrase from the fetch layer — an HTTP
  status or an error class — never response-body content. Stale results (the
  wizard moved on) are inert.
  """
  @spec models_arrived(t(), {:ok, [Catalog.entry()]} | {:error, String.t()} | :error | term()) ::
          t()
  def models_arrived(%__MODULE__{step: :fetching} = state, {:ok, entries})
      when is_list(entries) do
    ids = Enum.map(entries, & &1.model)

    if ids == [] do
      manual_with_note(state, "The provider returned no models.")
    else
      # The picker's highlight is step/3's restore job: choice 0 on a first
      # arrival, the remembered position on a back-then-forward return —
      # clamped to the list that just arrived, which a refetch may have
      # SHRUNK under a remembered position (issue #65).
      landed = step(state, :model_pick, "")
      %{landed | fetched: ids, choice: min(landed.choice, length(ids))}
    end
  end

  def models_arrived(%__MODULE__{step: :fetching} = state, {:error, reason})
      when is_binary(reason),
      do: manual_with_note(state, "Couldn't fetch the model list — " <> reason <> ".")

  def models_arrived(%__MODULE__{step: :fetching} = state, _failure),
    do: manual_with_note(state, "Couldn't fetch the model list.")

  def models_arrived(%__MODULE__{} = state, _result), do: state

  @doc """
  A wizard write refused (issue #39): the TUI runner feeds the config layer's
  error message back, and the wizard bounces to the step that issued the
  write — the key step re-takes its draft (masked on screen) so the value can
  be edited and retried, and `pending.key` resets: the fetch must not fire
  for a key that is not on disk. The settings write lands back at `:loop`,
  so `:done` and its handoff are reachable only by a write that actually
  succeeded. Stale feedback (the wizard moved on) is inert.
  """
  @spec write_failed(t(), String.t()) :: t()
  def write_failed(
        %__MODULE__{step: :fetching, pending: %{key: value} = pending} = state,
        message
      )
      when is_binary(value) do
    # The restored draft feeds the memory too (issue #65): a bounce without
    # an edit still round-trips through esc-back losslessly.
    remember(%{step(state, :key, value) | pending: %{pending | key: nil}, error: message})
  end

  def write_failed(%__MODULE__{step: :done} = state, message) do
    # The highlight stays on Done, the option that refused: Enter retries
    # the write, exactly what the hint offers.
    bounced = step(state, :loop, "")
    %{bounced | error: message, choice: done_index(bounced)}
  end

  def write_failed(%__MODULE__{} = state, _message), do: state

  defp done_index(state) do
    state
    |> options()
    |> Enum.find_index(&(&1 == :done))
    |> Kernel.||(0)
  end

  @doc """
  The wizard's final settings document (ADR 0009 shape): one profile — the
  named one, `defaultProfile` by construction — with its providers and MCP
  entries. Labels are written explicitly: they are what the user confirmed.
  """
  @spec settings_doc(t()) :: map()
  def settings_doc(%__MODULE__{} = state) do
    %{
      "configVersion" => 3,
      "defaultProfile" => state.profile_name,
      "profiles" => [
        %{
          "name" => state.profile_name,
          "providers" =>
            Enum.map(state.providers, fn provider ->
              %{
                "label" => provider.label,
                "baseUrl" => provider.base_url,
                "models" =>
                  Enum.map(provider.models, fn model ->
                    %{"nickname" => model.nickname, "model" => model.model}
                  end)
              }
            end),
          "mcp" =>
            Enum.map(state.mcp, fn entry ->
              doc = mcp_doc(entry)

              if entry.token, do: Map.put(doc, "token", entry.token), else: doc
            end)
        }
      ]
    }
  end

  ## Option lists (selection steps)

  @doc "The current selection step's options, in display order."
  @spec options(t()) :: [term()]
  def options(%__MODULE__{step: :provider} = _state),
    do: Enum.map(Presets.all(), &{:preset, &1}) ++ [:custom, :skip]

  def options(%__MODULE__{step: :model_pick, fetched: fetched}),
    do: Enum.map(fetched, &{:model, &1}) ++ [:manual]

  def options(%__MODULE__{step: :loop}), do: [:add_provider, :add_mcp, :done]
  def options(%__MODULE__{}), do: []

  ## Internals

  # A new provider's pending (the provider-enter preset arm and the
  # custom_url-enter arm, issue #65): the provider-scoped memory drops with
  # it, so a stale label/key/model edit never leaks into the next provider —
  # the profile/provider/custom-url memory survives across providers.
  @provider_scoped [:label, :key, :model_pick, :model_manual]

  defp fresh_provider(state, pending),
    do: %{state | pending: pending, memory: Map.drop(state.memory, @provider_scoped)}

  # Entering a new provider's label: the pending built above, provider-scoped
  # memory dropped, the suggested label as the prefill.
  defp enter_provider(state, pending, label) do
    state
    |> fresh_provider(pending)
    |> step(:label, label)
  end

  # A token reference the loader cannot resolve back ($lowercase etc.) is
  # stored as NO token rather than a value the loader would drop the whole
  # entry for (P3-3, hostile review — the strict $[A-Z_][A-Z0-9_]* shape is
  # the loader's contract; the wizard must not write against it).
  defp valid_token_ref(draft) do
    case nonblank(draft) do
      nil ->
        nil

      var ->
        var = if(String.starts_with?(var, "$"), do: var, else: "$" <> var)
        if(Regex.match?(@env_ref, var), do: var, else: nil)
    end
  end

  defp mcp_doc(entry),
    do: %{"name" => entry.name, "command" => entry.command, "args" => entry.args}

  defp option(state) do
    opts = options(state)
    Enum.at(opts, state.choice)
  end

  defp move(state, delta) do
    count = length(options(state))

    if count == 0 do
      state
    else
      remember(%{state | choice: rem(state.choice + delta + count, count)})
    end
  end

  # Every transition clears the step's messages: the error belongs to the
  # step that produced it (issue #39), the note to the manual-fallback land
  # it came from (issue #64). A remembered draft/choice for the destination
  # (issue #65's memory) overrides the passed-in prefill — the prefill is
  # the default, not an override — so back-then-forward is lossless.
  defp step(state, step, draft) do
    remembered = Map.get(state.memory, step, %{draft: draft, choice: 0})

    %{
      state
      | step: step,
        draft: remembered.draft,
        choice: remembered.choice,
        error: nil,
        note: nil
    }
  end

  # One edit or move (issue #65): the snapshot a later esc-back restores.
  defp remember(%__MODULE__{step: step, draft: draft, choice: choice} = state),
    do: %{state | memory: Map.put(state.memory, step, %{draft: draft, choice: choice})}

  defp edit(state, code) do
    cond do
      code == "backspace" ->
        remember(%{state | draft: String.slice(state.draft, 0..-2//1)})

      single_char?(code) and String.valid?(code) ->
        remember(%{state | draft: state.draft <> code})

      true ->
        state
    end
  end

  defp single_char?(code), do: String.length(code) == 1

  defp nonblank(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp host(url) do
    case URI.parse(url) do
      %URI{host: nil} -> url
      %URI{host: host} -> host
    end
  end

  # Entering :model_manual — from any arm — always clears `fetched`
  # (issue #65's uniform rule): a stale picker list must never survive into
  # manual entry.
  defp to_manual(state), do: %{step(state, :model_manual, "") | fetched: []}

  defp manual_with_note(state, note), do: %{to_manual(state) | note: note}

  defp add_model(state, id), do: %{state | pending: add_model_to(state.pending, id)}

  defp add_model_to(pending, id),
    do: %{pending | models: pending.models ++ [%{nickname: id, model: id}]}

  defp finish_provider(state) do
    # The finish snapshots the fetch state onto the provider (issue #65):
    # the loop's esc-pop restores it and reads it as "finished from the
    # picker" (non-empty) vs manual/keyless (empty).
    pending = %{state.pending | fetched: state.fetched}

    %{step(%{state | providers: state.providers ++ [pending]}, :loop, "") | pending: nil}
  end

  defp abandon_mcp(state), do: step(state, :loop, "")
end
