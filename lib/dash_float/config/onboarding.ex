defmodule DashFloat.Config.Onboarding do
  @moduledoc """
  The first-run onboarding wizard's pure state machine
  ([ADR 0009](../../docs/decisions/0009-config-v3-persona-profiles.md)).

  Modeled on Octofriend's first-time setup: welcome → name your first profile
  (becomes `defaultProfile`) → add a provider (Z.AI / Synthetic presets or a
  custom OpenAI-compatible URL) → the key (paste, a `$ENV_VAR` reference, or
  skip — a paste is written straight into `keys.json5` at 0600, immediately,
  merging into any existing file) → pick a model (live `/models` fetch with
  manual fallback; nickname defaults to the model id) → optional loops (more
  providers, MCP servers; every step skippable) → done: `settings.json5`
  written and the app starts under the new profile.

  This module is pure: it never touches the filesystem or the network.
  `handle_key/2` returns `{state, action}` where the RUNNER executes the
  side-effecting actions — `{:write_key, {profile, base_url, value}}`
  (atomic 0600 merge into keys.json5), `{:fetch_models, {base_url, raw_key}}`
  (the standing catalog fetch), `{:write_settings, map}` (atomic 0600 write),
  `:finish` (hand the freshly-written config to the app), `:quit` (abort —
  nothing further is written). `models_arrived/2` feeds the fetch result
  back. Key inputs render masked; this module never echoes a value.
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
          | :model_choice
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
          models: [%{nickname: String.t(), model: String.t()}]
        }

  @type t :: %__MODULE__{
          step: step(),
          draft: String.t(),
          pending: provider_draft() | nil,
          choice: non_neg_integer(),
          fetched: [String.t()],
          profile_name: String.t(),
          providers: [provider_draft()],
          mcp: [%{name: String.t(), command: String.t(), args: [String.t()], token: nil | :ref}]
        }

  # Inspected standalone (logs, IEx): the draft and the pending provider can
  # hold the plaintext key — ADR 0005's never-echo rule, belt to
  # DashFloat.TUI.State's own :setup exclusion (P1-3, hostile review).
  @derive {Inspect, except: [:draft, :pending]}
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
            # A refused write's message, shown at the step that issued the
            # write (issue #39): paths and remedies only, never values.
            error: nil

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
    %{state | draft: draft <> normalize(content)}
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
  type (single chars), backspace, Enter to accept, Esc to skip where a skip
  is sensible; selection steps move with up/down and pick with Enter.
  """
  @spec handle_key(t(), String.t()) :: {t(), term()}
  def handle_key(%__MODULE__{step: step} = state, code), do: step_key(state, step, code)

  ## Welcome

  defp step_key(state, :welcome, "enter"),
    do: {step(state, :profile_name, state.profile_name), nil}

  defp step_key(state, :welcome, _code), do: {state, nil}

  ## Profile name (becomes defaultProfile; blank keeps the prefill)

  defp step_key(state, :profile_name, "enter") do
    name = nonblank(state.draft) || state.profile_name
    {%{step(state, :provider, "") | profile_name: name, choice: 0}, nil}
  end

  defp step_key(state, :profile_name, code), do: {edit(state, code), nil}

  ## Provider choice (presets + custom + skip)

  defp step_key(state, :provider, "up"), do: {move(state, -1), nil}
  defp step_key(state, :provider, "down"), do: {move(state, 1), nil}

  defp step_key(state, :provider, "enter") do
    case option(state) do
      {:preset, preset} ->
        pending = %{label: preset.label, base_url: preset.base_url, key: nil, models: []}
        {%{step(state, :label, preset.label) | pending: pending}, nil}

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
        {%{
           step(state, :label, host(url))
           | pending: %{label: host(url), base_url: url, key: nil, models: []}
         }, nil}
    end
  end

  defp step_key(state, :custom_url, "esc"), do: {step(state, :provider, ""), nil}
  defp step_key(state, :custom_url, code), do: {edit(state, code), nil}

  ## Provider label (optional; blank keeps the suggested/host default)

  defp step_key(state, :label, "enter") do
    label = nonblank(state.draft) || state.pending.label
    {%{step(state, :key, "") | pending: %{state.pending | label: label}}, nil}
  end

  defp step_key(state, :label, code), do: {edit(state, code), nil}

  ## The key: paste, `$ENV_VAR`, or skip. A non-empty value is written to
  ## keys.json5 IMMEDIATELY (ADR 0009: abort-resume for free).

  defp step_key(state, :key, "enter") do
    pending = state.pending
    profile = state.profile_name

    case nonblank(state.draft) do
      nil ->
        {model_choice(%{state | pending: pending}), nil}

      value ->
        action = {:write_key, {profile, pending.base_url, value}}
        {model_choice(%{state | pending: %{pending | key: value}}), action}
    end
  end

  defp step_key(state, :key, "esc"), do: {model_choice(state), nil}
  defp step_key(state, :key, code), do: {edit(state, code), nil}

  ## Model: live fetch (only with a key), manual entry, or skip

  defp step_key(state, :model_choice, "up"), do: {move(state, -1), nil}
  defp step_key(state, :model_choice, "down"), do: {move(state, 1), nil}

  defp step_key(state, :model_choice, "enter") do
    case option(state) do
      :fetch ->
        {%{step(state, :fetching, "") | fetched: []},
         {:fetch_models, {state.pending.base_url, state.pending.key}}}

      :manual ->
        {step(state, :model_manual, ""), nil}

      :skip ->
        {finish_provider(state), nil}
    end
  end

  defp step_key(state, :model_choice, _code), do: {state, nil}

  # Waiting on the fetch: Esc falls back to manual entry (the fetch result,
  # when it lands, is ignored — a fresh choice would only re-enter here).
  defp step_key(state, :fetching, "esc"), do: {step(state, :model_manual, ""), nil}
  defp step_key(state, :fetching, _code), do: {state, nil}

  # The picker over fetched ids (nickname defaults to the id), manual entry
  # as the last option.
  defp step_key(state, :model_pick, "up"), do: {move(state, -1), nil}
  defp step_key(state, :model_pick, "down"), do: {move(state, 1), nil}

  defp step_key(state, :model_pick, "enter") do
    case option(state) do
      {:model, id} ->
        {finish_provider(add_model(state, id)), nil}

      :manual ->
        {step(state, :model_manual, ""), nil}
    end
  end

  defp step_key(state, :model_pick, _code), do: {state, nil}

  defp step_key(state, :model_manual, "enter") do
    case nonblank(state.draft) do
      nil -> {finish_provider(state), nil}
      id -> {finish_provider(add_model(state, id)), nil}
    end
  end

  defp step_key(state, :model_manual, code), do: {edit(state, code), nil}

  ## The optional loops: another provider, an MCP server, or done

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

  defp step_key(state, :mcp_name, "enter") do
    case nonblank(state.draft) do
      nil -> {step(state, :loop, ""), nil}
      name -> {%{step(state, :mcp_command, "") | mcp_name: name}, nil}
    end
  end

  defp step_key(state, :mcp_name, code), do: {edit(state, code), nil}

  defp step_key(state, :mcp_command, "enter") do
    case nonblank(state.draft) do
      nil -> {abandon_mcp(state), nil}
      command -> {%{step(state, :mcp_args, "") | mcp_command: command}, nil}
    end
  end

  defp step_key(state, :mcp_command, code), do: {edit(state, code), nil}

  defp step_key(state, :mcp_args, "enter") do
    args =
      state.draft
      |> String.trim()
      |> String.split()

    {%{step(state, :mcp_token, "") | mcp_args: args}, nil}
  end

  defp step_key(state, :mcp_args, code), do: {edit(state, code), nil}

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
  picker, an empty list or any failure falls back to manual entry (ADR 0009:
  the fetch is failure-soft, never an error screen).
  """
  @spec models_arrived(t(), {:ok, [Catalog.entry()]} | :error) :: t()
  def models_arrived(%__MODULE__{step: :fetching} = state, {:ok, entries})
      when is_list(entries) do
    ids = Enum.map(entries, & &1.model)

    if ids == [] do
      step(state, :model_manual, "")
    else
      %{step(state, :model_pick, "") | fetched: ids, choice: 0}
    end
  end

  def models_arrived(%__MODULE__{step: :fetching} = state, _failure),
    do: step(state, :model_manual, "")

  def models_arrived(%__MODULE__{} = state, _result), do: state

  @doc """
  A wizard write refused (issue #39): the TUI runner feeds the config layer's
  error message back, and the wizard bounces to the step that issued the
  write — the key step re-takes its draft (masked on screen) so the value can
  be edited and retried, and `pending.key` resets: the fetch offer must not
  appear for a key that is not on disk. The settings write lands back at
  `:loop`, so `:done` and its handoff are reachable only by a write that
  actually succeeded. Stale feedback (the wizard moved on) is inert.
  """
  @spec write_failed(t(), String.t()) :: t()
  def write_failed(
        %__MODULE__{step: :model_choice, pending: %{key: value} = pending} = state,
        message
      )
      when is_binary(value),
      do: %{step(state, :key, value) | pending: %{pending | key: nil}, error: message}

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

  def options(%__MODULE__{step: :model_choice, pending: pending}) do
    if pending && pending.key, do: [:fetch, :manual, :skip], else: [:manual, :skip]
  end

  def options(%__MODULE__{step: :model_pick, fetched: fetched}),
    do: Enum.map(fetched, &{:model, &1}) ++ [:manual]

  def options(%__MODULE__{step: :loop}), do: [:add_provider, :add_mcp, :done]
  def options(%__MODULE__{}), do: []

  ## Internals

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
    if count == 0, do: state, else: %{state | choice: rem(state.choice + delta + count, count)}
  end

  # Every transition clears the step's error: the message belongs to the step
  # that produced it (issue #39).
  defp step(state, step, draft),
    do: %{state | step: step, draft: draft, choice: 0, error: nil}

  defp edit(state, code) do
    cond do
      code == "backspace" ->
        %{state | draft: String.slice(state.draft, 0..-2//1)}

      single_char?(code) and String.valid?(code) ->
        %{state | draft: state.draft <> code}

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

  defp model_choice(state) do
    step(state, :model_choice, "")
  end

  defp add_model(state, id), do: %{state | pending: add_model_to(state.pending, id)}

  defp add_model_to(pending, id),
    do: %{pending | models: pending.models ++ [%{nickname: id, model: id}]}

  defp finish_provider(state) do
    %{step(%{state | providers: state.providers ++ [state.pending]}, :loop, "") | pending: nil}
  end

  defp abandon_mcp(state), do: step(state, :loop, "")
end
