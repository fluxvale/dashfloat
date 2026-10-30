defmodule DashFloat.TUI.State do
  @moduledoc """
  Pure UI state and every state transition for `DashFloat.TUI`.

  All logic here is deterministic: no processes, no terminal, no timers (the
  one side-effecting exception is `claim_agent/1`, called from the TUI process
  at mount so the monitor lives there). The input draft lives in the
  textarea's Rust-side state, reached through its synchronous in-memory API.
  Transitions return `{state, action}` where `action` is `:quit`,
  `{:submit, prompt, paths}`, `{:confirm, decision}`, `:cancel`, `{:set_mode, mode}`,
  the command actions (`{:set_title, title}`, `{:switch_model, _}`,
  `:list_profiles`, `:compact` — ADR 0020), `nil`, or one of the setup actions; the TUI
  interprets actions. The one clock is injectable (`now` arguments,
  defaulting to the monotonic clock) so the animation tick and rate math stay
  pure. See ADRs 0002, 0006, and 0007.
  """

  alias DashFloat.Accounting
  alias DashFloat.Config
  alias DashFloat.Config.Onboarding
  alias DashFloat.Config.Presets
  alias DashFloat.Images
  alias DashFloat.Mode
  alias DashFloat.Tools
  alias DashFloat.TUI.Commands
  alias DashFloat.TUI.Palette
  alias DashFloat.TUI.Render
  alias DashFloat.TUI.Selection
  alias DashFloat.TUI.Theme
  alias DashFloat.TUI.View
  alias DashFloat.TUI.Wrap
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span

  @type phase :: :idle | :streaming | :executing_tool | :checking | :confirming
  @type entry_kind :: :user | :assistant | :tool | :system

  @type entry :: %{
          kind: entry_kind(),
          text: String.t(),
          logical: [ExRatatui.Text.Line.t()],
          lines: [ExRatatui.Text.Line.t()]
        }
  @type confirm :: %{ref: term(), id: term(), name: String.t()}

  @typedoc "One pending attachment's display metadata — never the bytes (ADR 0018 §6)."
  @type attachment :: %{path: String.t(), name: String.t(), kb: pos_integer()}

  @typedoc "The open attach prompt's editable path draft (ADR 0018 §5)."
  @type attach_prompt :: %{draft: String.t()}

  @typedoc """
  The bare /title dialog (ADR 0023's 2026-10-31 amendment): the editable
  draft and the last rename refusal, nil closed.
  """
  @type title_dialog :: %{draft: String.t(), error: String.t() | nil}

  @typedoc """
  One keypress's outcome. The chat actions are ADR 0002/0006/0007; the mode
  cycle's `{:set_mode, _}` is ADR 0016; the setup actions (ADR 0009) carry
  the wizard's side-effecting steps to the TUI runner: a profile picked in
  the forced-selection modal, the wizard's finish handoff, an immediate
  keys.json5 write, the `/models` fetch, and the final settings.json5
  write. The wizard may return an ordered LIST of actions (issue #64: the
  accepted key writes, then its fetch fires), executed in order by the
  runner.
  """
  @type action ::
          :quit
          | {:submit, String.t(), [String.t()]}
          | {:confirm, :approved | :rejected}
          | :cancel
          | {:set_mode, Mode.mode()}
          | {:set_title, String.t()}
          | {:switch_model, DashFloat.Config.classification()}
          | :list_profiles
          | :compact
          | nil
          | {:select_profile, String.t()}
          | :setup_finish
          | {:write_key, {String.t(), String.t(), String.t()}}
          | {:fetch_models, {String.t(), String.t()}}
          | {:write_settings, map()}
          | [action()]

  @type stats :: %{
          tokens: non_neg_integer(),
          first_token_at: integer() | nil,
          rate: float() | nil,
          prompt_tokens: non_neg_integer() | nil,
          completion_tokens: non_neg_integer() | nil
        }

  @max_history 500
  @default_size {80, 24}
  # Live re-renders of the in-flight reply stop above this; finalize still
  # parses once at the end (ADR 0006).
  @in_flight_cap 64 * 1024
  # The double Ctrl+C exit window (issue #28; ADR 0006 amendment).
  @exit_window_ms 2_000
  # /help's key hints (ADR 0020) — the composer's static hints plus the
  # palette and mode keys.
  @key_hints "Enter send · Shift+Enter newline · Esc interrupt · Ctrl+Q quit · Ctrl+P commands · Ctrl+O attach · Shift+Tab mode"

  @enforce_keys [:input]

  # A crash report prints this state (P1-3, hostile review): the startup
  # phase can hold the wizard's plaintext key (draft / pending.key), and
  # ADR 0005's never-echo rule must hold in the log exactly as it holds on
  # the masked screen. `setup` is excluded wholesale; the provider config
  # carries its own derivation.
  @derive {Inspect, except: [:setup]}
  defstruct [
    :input,
    :provider,
    :cwd,
    :agent,
    :confirm,
    # The startup phase (ADR 0009): the forced-selection modal or the
    # onboarding wizard, rendered instead of the chat UI until it clears.
    :setup,
    :config_dir,
    :resolve,
    :catalog_fetcher,
    # The interaction mode (ADR 0016): defaulted here, no mount opt — the
    # agent's {:mode, _} echo is the single writer after boot.
    mode: :build,
    phase: :idle,
    entries: [],
    in_flight: nil,
    in_flight_lines: nil,
    in_flight_dirty: false,
    anim_step: 0,
    tick_ref: nil,
    # The idle cursor blink (issue #104; ADR 0006's 2026-10-31 amendment):
    # `blink_on` is the display phase (true = cursor cell drawn), `blink_ref`
    # the pending timer (owned by the TUI process), `blink_ms` the injectable
    # cadence — nil means "live runs blink at the TUI's default; the
    # hermetic suite never arms one" (the suggest-arm pattern).
    blink_on: true,
    blink_ref: nil,
    blink_ms: nil,
    exit_guard_at: nil,
    exit_guard_ref: nil,
    stats: %{
      tokens: 0,
      first_token_at: nil,
      rate: nil,
      prompt_tokens: nil,
      completion_tokens: nil
    },
    # The stage-2 context snapshot (ADR 0015 §2 amendment): the agent's
    # {messages, anchor} pair, pushed at every transcript mutation and each
    # usage frame — what the footer's Accounting.usage/3 read computes from.
    # nil until the first push (the span is hidden, the rate-span pattern).
    context: nil,
    scroll: 0,
    follow?: true,
    # Terminal-pane focus (ADR 0015 §1): gates the composer's cursor
    # artifact. Terminals without focus reporting send nothing, so the
    # default keeps the status quo ante.
    focused?: true,
    history: [],
    history_index: nil,
    draft: "",
    size: @default_size,
    live?: false,
    agent_ref: nil,
    selection: nil,
    # The standing catalog refresh's landing state (ADR 0009): per-provider
    # fetched entries, keyed by baseUrl. In-memory per session only.
    catalog: %{},
    # Ghost text (ADR 0015 §3): the landed suggestion, the debounce timer
    # and in-flight task, the straggler epoch, the one-shot arm/reap
    # intents, and the injected fetcher + debounce delay (the
    # catalog_fetcher pattern).
    suggestion: nil,
    suggest_ref: nil,
    suggest_task: nil,
    suggest_epoch: 0,
    suggest_arm: false,
    suggest_reap: false,
    suggest_fetcher: nil,
    suggest_debounce_ms: 600,
    # The command palette (ADR 0020): nil closed; :filter is the composer's
    # derived slash autocomplete, :modal is Ctrl+P or a picker.
    palette: nil,
    # Image attachments (ADR 0018 §5): `attachments` is the pending set —
    # display metadata only, never bytes (the agent reads at submit); `attach`
    # is the open attach prompt's path draft, nil closed.
    attachments: [],
    attach: nil,
    # The session title (ADR 0023): the boot/resume mount value, kept current
    # by the agent's {:title, _} push (issue #106); pre-fills the dialog.
    title: nil,
    # The bare /title dialog (issue #106), nil closed.
    title_dialog: nil,
    # The Herdr integration (ADR 0024): nil outside Herdr — every hook is a
    # no-op then. `session_id` is the resume identity the reporter reports;
    # set at mount for a resumed boot, or on the agent's `{:session_id, _}`
    # when a fresh session's id is minted at first save.
    herdr: nil,
    session_id: nil
  ]

  @type t :: %__MODULE__{
          input: reference(),
          provider: {:ok, DashFloat.Config.t()} | {:error, String.t()} | nil,
          cwd: String.t(),
          agent: pid() | atom(),
          mode: Mode.mode(),
          phase: phase(),
          entries: [entry()],
          in_flight: String.t() | nil,
          in_flight_lines: [ExRatatui.Text.Line.t()] | nil,
          in_flight_dirty: boolean(),
          anim_step: non_neg_integer(),
          tick_ref: reference() | nil,
          blink_on: boolean(),
          blink_ref: reference() | nil,
          blink_ms: non_neg_integer() | nil,
          stats: stats(),
          context: %{messages: [map()], anchor: Accounting.anchor()} | nil,
          scroll: non_neg_integer(),
          follow?: boolean(),
          focused?: boolean(),
          history: [String.t()],
          history_index: non_neg_integer() | nil,
          draft: String.t(),
          size: {pos_integer(), pos_integer()},
          live?: boolean(),
          agent_ref: reference() | nil,
          confirm: confirm() | nil,
          exit_guard_at: integer() | nil,
          exit_guard_ref: reference() | nil,
          selection: Selection.t() | nil,
          setup: setup() | nil,
          config_dir: String.t() | nil,
          resolve: (String.t() | nil -> DashFloat.Config.classification()) | nil,
          catalog: %{optional(String.t()) => [DashFloat.Config.Catalog.entry()]},
          catalog_fetcher:
            (String.t(), String.t() | nil -> {:ok, [DashFloat.Config.Catalog.entry()]} | :error)
            | nil,
          suggestion: String.t() | nil,
          suggest_ref: reference() | nil,
          suggest_task: pid() | nil,
          suggest_epoch: non_neg_integer(),
          suggest_arm: boolean(),
          suggest_reap: boolean(),
          suggest_fetcher:
            (DashFloat.Config.t(), String.t() -> {:ok, String.t()} | :error)
            | {module(), atom()}
            | nil,
          suggest_debounce_ms: non_neg_integer(),
          palette: Palette.t() | nil,
          attachments: [attachment()],
          attach: attach_prompt() | nil,
          title: String.t() | nil,
          title_dialog: title_dialog() | nil,
          herdr: DashFloat.Herdr.t() | nil,
          session_id: String.t() | nil
        }

  @typedoc """
  The startup phase (ADR 0009): `{:select, names, index}` is the
  forced-selection modal; `%Onboarding{}` is the wizard.
  """
  @type setup :: {:select, [String.t()], non_neg_integer()} | DashFloat.Config.Onboarding.t()

  @typedoc """
  One message of the stream contract (see `stream_message/2` and ADR 0002 /
  0006 / 0007). The agent is the single voice; the tool messages are ADR 0007,
  the mode messages ADR 0016, the title messages ADR 0023's 2026-10-31
  amendment.
  """
  @type stream_msg ::
          {:token, String.t()}
          | {:usage,
             %{
               prompt_tokens: non_neg_integer(),
               completion_tokens: non_neg_integer(),
               total_tokens: non_neg_integer()
             }}
          | {:context, %{messages: [map()], anchor: Accounting.anchor()}}
          | {:phase, :streaming}
          | {:phase, :executing_tool | :checking | :idle}
          | {:tool_call, tool_call_msg()}
          | {:tool_result, tool_result_msg()}
          | {:confirm, term(), confirm_msg()}
          | {:entry, :tool | :system, String.t()}
          | {:mode, Mode.mode()}
          | {:tool_preview, confirm_msg()}
          | {:title, String.t()}
          | {:title_refused, String.t()}

  @typep tool_call_msg :: %{id: term(), name: String.t(), args: map()}

  @typep tool_result_msg :: %{
           id: term(),
           name: String.t(),
           ok: boolean(),
           status: String.t(),
           output: String.t() | nil
         }

  @typep confirm_msg :: %{id: term(), name: String.t(), args: map(), lines: [String.t()]}

  ## Construction

  @doc """
  Builds the initial state from the App's mount opts. Under `test_mode: {w, h}`
  the size comes from the opts; live, it is read from the terminal (falling
  back to 80x24 without a TTY) and kept fresh by later Resize events. The
  provider is loaded once by the Application and handed in as `:provider`
  (ADR 0005); the agent the UI talks to as `:agent` (pid or name, default
  `DashFloat.Agent` — ADR 0007). The `cwd` label is computed here, once —
  status truth, not I/O per frame (ADR 0006).

  The resume opts (ADR 0014 §6) derive the resumed log: `:transcript` is the
  decoded string-keyed message list `DashFloat.Session.load` returns, replayed
  through the exact render path live entries use; `:resume_note` appends last
  as a `:system` entry when non-nil. Replay is pure and stats stay zeroed.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    state = %__MODULE__{
      input: ExRatatui.textarea_new(),
      provider: Keyword.get(opts, :provider),
      agent: Keyword.get(opts, :agent, DashFloat.Agent),
      confirm: nil,
      cwd: cwd_label(),
      size: initial_size(opts),
      live?: is_nil(Keyword.get(opts, :test_mode)),
      setup: Keyword.get(opts, :setup),
      config_dir: Keyword.get(opts, :config_dir),
      resolve: Keyword.get(opts, :resolve),
      catalog_fetcher: Keyword.get(opts, :catalog_fetcher),
      # The ghost-text side-request's seams (ADR 0015 §3): the injected
      # fetcher gates the runner's arm (the default suite stays hermetic)
      # and the debounce delay is injectable for the timing tests.
      suggest_fetcher: Keyword.get(opts, :suggest_fetcher),
      suggest_debounce_ms: Keyword.get(opts, :suggest_debounce_ms, 600),
      # The idle blink's injectable cadence (issue #104): present only when
      # a test opts in — its presence is what un-hermetically-gates the
      # timer arm (the suggest_fetcher pattern); live runs use the default.
      blink_ms: Keyword.get(opts, :blink_ms),
      # The session title (ADR 0023): the boot --title or the resumed file's
      # title — the dialog's prefill (issue #106).
      title: Keyword.get(opts, :title),
      # The Herdr reporter's seams (ADR 0024): the detected context (nil
      # outside Herdr — inert) and the resumed boot's session id.
      herdr: Keyword.get(opts, :herdr),
      session_id: Keyword.get(opts, :session_id)
    }

    replay(state, Keyword.get(opts, :transcript, []), Keyword.get(opts, :resume_note))
  end

  ## Transcript replay (ADR 0014 §6)

  # The resumed log is derived, never read from disk: each loaded message
  # rides the exact render path live entries use and lands through put_entry,
  # so `logical` is freshly built and `lines` wrap at the current width.
  # Pure — Render/Markdown/Wrap only, like live appends.
  defp replay(state, transcript, note) do
    {replayed, _names} = Enum.reduce(transcript, {state, %{}}, &replay_message/2)
    resume_note(replayed, note)
  end

  defp resume_note(state, nil), do: state
  defp resume_note(state, note) when is_binary(note), do: append_entry(state, :system, note)

  # An image-bearing user turn (ADR 0018 §2) replays through the same
  # shape the live submit renders: the concatenated text parts as the
  # body, then one dim 📎 row per image part — the loaded part carries a
  # data URL, not the display metadata, so the row counts, not names.
  # The transcript's system message (ADR 0019) is not chat-log content: the
  # prompt is re-derived at every boot, so replay skips the role instead of
  # rendering it. Without this clause a resume of any system-bearing session
  # crashes at mount (found by the Herdr restore dance, issue #113).
  defp replay_message(%{"role" => "system"}, acc), do: acc

  defp replay_message(%{"role" => "user", "content" => parts}, {state, names})
       when is_list(parts) do
    text =
      Enum.map_join(parts, fn
        %{"type" => "text", "text" => t} -> t
        %{"type" => "image_url"} -> ""
        _other -> ""
      end)

    indicator_rows = for _url <- image_parts(parts), do: replay_image_line()
    lines = Render.entry_lines(:user, text) ++ indicator_rows

    {put_entry(state, :user, text, lines), names}
  end

  defp replay_message(%{"role" => "user", "content" => text}, {state, names})
       when is_binary(text) do
    {append_entry(state, :user, text), names}
  end

  # The prose lands first (markdown path), then one gear row per announced
  # call — a nil/empty content makes no assistant entry. Each call id
  # registers its name for the tool rows that follow it.
  defp replay_message(%{"role" => "assistant"} = message, {state, names}) do
    content = message["content"]

    state =
      if is_binary(content) and content != "" do
        append_entry(state, :assistant, content)
      else
        state
      end

    Enum.reduce(message["tool_calls"] || [], {state, names}, fn call, {st, nm} ->
      function = call["function"]
      name = function["name"]
      {text, lines} = Render.tool_call(name, decoded_args(function["arguments"]))
      {put_entry(st, :tool, text, lines), Map.put(nm, call["id"], name)}
    end)
  end

  # The call name comes from the announcing batch; an id no batch announced
  # (hand damage the loader's refusals exist to catch) degrades the row to
  # the literal name "tool" — a malformed transcript must never kill the
  # mount (ADR 0014 §6). Status and display excerpt re-derive through the
  # same Tools helpers the live display messages use — one derivation, two
  # callers.
  defp replay_message(
         %{"role" => "tool", "tool_call_id" => id, "content" => content},
         {state, names}
       ) do
    {name, names} = Map.pop(names, id, "tool")
    result = replay_result(content)

    {text, lines} =
      Render.tool_result(name, Tools.display_status(result), Tools.display_excerpt(result))

    {put_entry(state, :tool, text, lines), names}
  end

  # `function.arguments` is opaque at load; replay decodes it for the summary
  # only. Anything but a JSON object renders the "(invalid arguments)" arm.
  defp decoded_args(args) do
    case Jason.decode(args) do
      {:ok, %{} = args} -> args
      _other -> nil
    end
  end

  # The image parts of a loaded user turn (ADR 0018 §2): the exact
  # image_url shapes the session validation admits.
  defp image_parts(parts) do
    Enum.filter(parts, fn
      %{"type" => "image_url", "image_url" => %{"url" => url}} when is_binary(url) -> true
      _other -> false
    end)
  end

  # The replay's indicator row: the loaded part carries a data URL, not the
  # live display metadata, so the row counts, not names.
  defp replay_image_line,
    do: Line.new([Span.new("📎 image", style: Theme.style(:dim))])

  # The stored result is the JSON the agent gave the model. A payload that
  # does not decode to a JSON object displays as an error row with no output —
  # never a crash. Its keys are our own closed result shape, so the known
  # fields are picked back to atoms for the Tools helpers' matchers (no
  # dynamic atoms — ADR 0014 §3).
  defp replay_result(content) do
    case Jason.decode(content) do
      {:ok, %{} = result} ->
        %{
          ok: result["ok"],
          rejected: result["rejected"],
          cancelled: result["cancelled"],
          blocked: result["blocked"],
          error: result["error"],
          output: result["output"],
          content: result["content"]
        }

      _other ->
        %{}
    end
  end

  @doc """
  The status footer's model label as `"<provider> - <model>"` — the provider
  ladder and the dropped profile suffix are ADR 0015 §2's amendment (issue
  #109): the base_url's preset label ([`DashFloat.Config.Presets.label/1`]),
  else the active provider's settings label, else the URL host; the model
  part is the nickname, else the id. nil only when nothing resolves — the
  footer's "—" arm.
  """
  @spec provider_label(t()) :: String.t() | nil
  def provider_label(%__MODULE__{provider: {:ok, provider}}), do: label(provider)
  def provider_label(%__MODULE__{}), do: nil

  defp label(%DashFloat.Config{nickname: nickname, model: model} = config) do
    with model when is_binary(model) <- nickname || model,
         provider when is_binary(provider) <- provider_name(config) do
      "#{provider} - #{model}"
    else
      _missing -> nil
    end
  end

  # The provider half of the footer label, in ADR 0015 §2's ladder order:
  # (a) the base_url's preset ("zai" / "synthetic") — first-class, always
  # ahead of the settings entry's (possibly host-defaulted) label; (b) the
  # active provider's settings label; (c) the URL host (env-only boots,
  # providers []). No base_url — nothing to classify.
  defp provider_name(%DashFloat.Config{base_url: nil}), do: nil

  defp provider_name(%DashFloat.Config{base_url: base_url, providers: providers}) do
    Presets.label(base_url) || settings_label(base_url, providers) ||
      DashFloat.Config.host_label(base_url)
  end

  defp settings_label(base_url, providers) do
    case Enum.find(providers, fn provider ->
           trim_slash(provider.base_url) == trim_slash(base_url)
         end) do
      nil -> nil
      provider -> provider.label
    end
  end

  # The caller (provider_name's ladder) guards base_url nil above; the
  # settings entries always carry a base_url (parse_provider ignores the
  # baseUrl-less).
  defp trim_slash(url), do: String.trim_trailing(url, "/")

  @doc "The selected model's image capability (ADR 0018 §1): true only for a resolved provider carrying `images: true`."
  @spec provider_images?(t()) :: boolean()
  def provider_images?(%__MODULE__{provider: {:ok, %DashFloat.Config{images: true}}}), do: true
  def provider_images?(%__MODULE__{}), do: false

  # The startup phase (ADR 0009) owns every key until it clears: the wizard
  # or the forced-selection modal replaces the chat UI. The global Ctrl+C /
  # Ctrl+Q clauses above still quit from here — deliberateness includes the
  # right to leave.
  defp setup_key(%{setup: {:select, names, index}} = state, code) do
    case code do
      "up" -> {%{state | setup: {:select, names, move_index(index, -1, names)}}, nil}
      "down" -> {%{state | setup: {:select, names, move_index(index, 1, names)}}, nil}
      "enter" -> {state, {:select_profile, Enum.at(names, index)}}
      _other -> {state, nil}
    end
  end

  defp setup_key(%{setup: %Onboarding{} = wizard} = state, code) do
    {wizard, action} = Onboarding.handle_key(wizard, code)
    {%{state | setup: wizard}, translate(action)}
  end

  # The wizard's pure actions become TUI actions the runner executes (file
  # writes through the config layer, the async fetch, the finish handoff);
  # quitting is the TUI router's global Ctrl+C/Ctrl+Q, not a wizard action.
  defp translate(nil), do: nil

  # One keypress can carry an ordered LIST of actions (issue #64: an
  # accepted key writes, then its fetch fires); the wizard's lists never
  # hold nil.
  defp translate(actions) when is_list(actions), do: Enum.map(actions, &translate/1)

  defp translate({:write_key, _spec} = action), do: action
  defp translate({:fetch_models, _spec} = action), do: action
  defp translate({:write_settings, _doc} = action), do: action
  defp translate(:finish), do: :setup_finish

  defp move_index(index, delta, names) do
    count = length(names)
    if count == 0, do: 0, else: rem(index + delta + count, count)
  end

  @doc """
  A selection was made (or the wizard finished): the resolved classification
  replaces the provider everywhere — the UI state here, the agent via the
  TUI's `{:set_provider, _}` send — and the startup phase clears. The
  returned action tells the TUI to do the agent send and start the catalog
  refresh (ADR 0009).
  """
  @spec provider_resolved(t(), DashFloat.Config.classification()) ::
          {t(), {:agent_provider, DashFloat.Config.classification()}}
  def provider_resolved(%__MODULE__{} = state, classification) do
    # The class guard (P1-2, hostile review): leaving setup CLEARS the
    # composer — whatever a routing bug of the day may have dropped there
    # mid-setup, a credential pasted at the wrong moment can never become
    # chat prompt text. A runtime /profile switch (ADR 0020) arrives with
    # setup already nil and keeps the in-progress draft.
    state =
      if state.setup != nil do
        ExRatatui.textarea_set_value(state.input, "")
        state
      else
        state
      end

    {%{state | setup: nil, provider: classification}, {:agent_provider, classification}}
  end

  @doc """
  A paste while the startup phase owns the screen (P1-2, hostile review):
  the wizard's text steps take the content as typed input (newlines
  normalized away — a key pasted with a trailing newline is the common
  shape); the forced-selection modal has no text input, so pastes are
  inert. The chat composer is never touched while setup is active.
  """
  @spec setup_paste(t(), String.t()) :: t()
  def setup_paste(%__MODULE__{setup: %Onboarding{} = wizard} = state, content) do
    %{state | setup: Onboarding.paste(wizard, content)}
  end

  def setup_paste(%__MODULE__{} = state, _content), do: state

  @doc """
  The wizard's `/models` fetch landed (ADR 0009): feeds the picker when the
  wizard is waiting on it, ignores anything stale.
  """
  @spec models_arrived(t(), term()) :: t()
  def models_arrived(%__MODULE__{setup: %Onboarding{} = wizard} = state, result) do
    %{state | setup: Onboarding.models_arrived(wizard, result)}
  end

  def models_arrived(%__MODULE__{} = state, _result), do: state

  @doc """
  A wizard write refused (issue #39): the runner's error message lands on the
  wizard surface — the machine bounces to the step that issued the write
  (key → `:key` with the draft restored, settings → `:loop`), which gates
  `:done` on real write success.
  """
  @spec setup_write_failed(t(), String.t()) :: t()
  def setup_write_failed(%__MODULE__{setup: %Onboarding{} = wizard} = state, message)
      when is_binary(message),
      do: %{state | setup: Onboarding.write_failed(wizard, message)}

  def setup_write_failed(%__MODULE__{} = state, _message), do: state

  @doc """
  The standing catalog refresh landed (ADR 0009): per-provider entries are
  stored in memory — the one observable effect today is the status bar's
  context denominator filling in for a selected model whose config entry
  carried no `context`. Nothing is written back to settings.json5.
  """
  @spec catalog_arrived(t(), %{optional(String.t()) => [DashFloat.Config.Catalog.entry()]}) :: t()
  def catalog_arrived(%__MODULE__{} = state, catalog) when is_map(catalog) do
    %{state | catalog: catalog}
  end

  @doc """
  The provider's context window for the footer denominator (issue #111):
  the explicit config value (`context` on the entry, or env) wins; else
  the catalog's observed value for the selected model when the endpoint
  carries metadata (observed beats the seed — provider truth over a
  static table — but never an explicit user setting); else the resolved
  chain's seed or documented default. Never nil on a resolved provider —
  a stock config shows `used/window` from boot.
  """
  @spec provider_context_tokens(t()) :: pos_integer() | nil
  def provider_context_tokens(%__MODULE__{provider: {:ok, %{}}} = state),
    do: elem(window(state), 0)

  # No provider (the wizard phase) or an unresolved one: no window at all —
  # there is no model to assume a window for.
  def provider_context_tokens(%__MODULE__{}), do: nil

  # The one footer resolution (issue #111): {window, source} with source
  # :configured | :observed | :seeded | :default (:none with no provider —
  # the wizard phase shows the absolute total alone; there is no model to
  # assume a window for). The `~` marker keys on :default — the documented
  # fallback is never silent.
  defp window(%__MODULE__{provider: {:ok, config}, catalog: catalog}) do
    explicit = config.context_tokens

    if is_integer(explicit) and explicit > 0 do
      {explicit, :configured}
    else
      observed = catalog_context(catalog, config.base_url, config.model)

      if observed,
        do: {observed, :observed},
        else: Config.context_window(config)
    end
  end

  defp window(%__MODULE__{}), do: {nil, :none}

  defp catalog_context(catalog, base_url, model) when is_map(catalog) do
    case catalog do
      %{^base_url => entries} -> catalog_context(entries, model)
      _other -> nil
    end
  end

  defp catalog_context(entries, model) when is_list(entries) do
    case Enum.find(entries, &(&1.model == model)) do
      %{context: context} when is_integer(context) and context > 0 -> context
      _other -> nil
    end
  end

  @doc "The status bar's cwd label (`~/<last two segments>`, computed at new/1)."
  @spec cwd_label(t()) :: String.t()
  def cwd_label(%__MODULE__{cwd: cwd}), do: cwd

  defp cwd_label do
    case File.cwd() do
      {:ok, path} -> format_cwd(path)
      {:error, _reason} -> "~"
    end
  end

  defp format_cwd(path) do
    segments =
      path
      |> Path.split()
      |> Enum.reject(&(&1 == "/"))

    case Enum.take(segments, -2) do
      [] -> "~"
      tail -> "~/" <> Path.join(tail)
    end
  end

  defp initial_size(opts) do
    case Keyword.get(opts, :test_mode) do
      {w, h} when is_integer(w) and is_integer(h) ->
        {w, h}

      nil ->
        case ExRatatui.terminal_size() do
          {w, h} when is_integer(w) and is_integer(h) -> {w, h}
          {:error, _reason} -> @default_size
        end
    end
  end

  ## Status labels

  @doc "The live tok/s rate as one decimal, or nil before any rate exists."
  @spec rate_label(t()) :: String.t() | nil
  def rate_label(%__MODULE__{stats: %{rate: nil}}), do: nil

  def rate_label(%__MODULE__{stats: %{rate: rate}}),
    do: :erlang.float_to_binary(rate, decimals: 1)

  @doc """
  The footer's context span (ADR 0015 §2 amendment, issue #67 stage 2):
  tokens-used and percent-of-context from the accounting API (ADR 0022 §7)
  over the agent's snapshot — `4.2k/128k · 3.3%`, `nil` before the first
  snapshot lands (the span is hidden, the rate-span pattern). The
  denominator is the footer's resolution chain (issue #111: config, else
  catalog-observed, else the presets' seed, else the documented default)
  — a default denominator carries the `~` marker (`4.2k/~128k · 3.3%`):
  the visible note that no source knows this model's window.
  """
  @spec context_label(t()) :: String.t() | nil
  def context_label(%__MODULE__{context: nil}), do: nil

  def context_label(%__MODULE__{context: %{messages: messages, anchor: anchor}} = state) do
    {window, source} = window(state)

    case Accounting.usage(messages, anchor, window) do
      %{used: used, window: nil} ->
        humanize(used)

      %{used: used, window: window, percent: percent} ->
        humanize(used) <> "/" <> window_label(window, source) <> " · " <> percent_label(percent)
    end
  end

  # The default window's visible note (issue #111): `~` marks an assumed
  # denominator. Configured, observed, and seeded windows state their
  # number plain.
  defp window_label(window, :default), do: "~" <> humanize(window)
  defp window_label(window, _known), do: humanize(window)

  # One decimal, trailing `.0` trimmed — humanize/1's number rule, stated
  # once (ADR 0015 §2 amendment). The window arm guarantees a percent:
  # Accounting.usage/3 returns nil only with no window.
  defp percent_label(percent), do: trim_zero(percent) <> "%"

  @doc "Token counts for humans: 999 reads 999, 1_500 1.5k, 1_048_576 1m."
  @spec humanize(integer()) :: String.t()
  def humanize(n) when n < 1_000, do: Integer.to_string(n)
  def humanize(n) when n < 999_950, do: trim_zero(n / 1_000) <> "k"
  def humanize(n) when n < 999_950_000, do: trim_zero(n / 1_000_000) <> "m"
  def humanize(n), do: trim_zero(n / 1_000_000_000) <> "b"

  defp trim_zero(x) do
    x
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing(".0")
  end

  ## Input draft

  @doc "Current draft text (lines joined with `\\n`)."
  @spec input_text(t()) :: String.t()
  def input_text(%__MODULE__{input: input}), do: ExRatatui.textarea_get_value(input)

  @doc "Number of lines in the draft."
  @spec input_line_count(t()) :: non_neg_integer()
  def input_line_count(%__MODULE__{input: input}), do: ExRatatui.textarea_line_count(input)

  @doc """
  Inserts pasted text at the cursor (bracketed paste), normalizing CRLF and
  CR. A paste whose ENTIRE content is a path to an existing image file
  converts to an attachment instead — the drag-and-drop shape (issue #112;
  ADR 0018's 2026-10-31 amendment): terminals paste a dropped file's path,
  and the composer answers with a chip, never literal path text. Refusals
  follow the attach prompt's visible-entry rule. Either way the composer
  was edited: the log re-pins to the tail (issue #110).
  """
  @spec paste(t(), String.t()) :: t()
  def paste(%__MODULE__{} = state, content) when is_binary(content) do
    normalized = normalize_newlines(content)

    case dropped_image(state, normalized) do
      nil ->
        ExRatatui.textarea_insert_str(state.input, normalized)
        follow_tail(refresh_palette(dismiss_suggestion(leave_history(state))))

      attached ->
        attached
    end
  end

  # The drop test (ADR 0018 amendment): the whole paste — surrounding
  # whitespace and the trailing newline terminals add stripped, nothing
  # else — must be a single whitespace-free path naming an existing
  # regular image file. A
  # paste with interior newlines, spaces, or a path that is not an image
  # file is ordinary text (a pasted path as prose keeps its Ctrl+O).
  # Detection is paste-only by design: typed paths can never accidentally
  # convert (recorded in the amendment).
  defp dropped_image(%__MODULE__{} = state, normalized) do
    candidate = String.trim(normalized)

    if drop_shaped?(candidate) and Images.image_file?(candidate) do
      {:ok, state} = drop_attach(state, candidate)
      state
    else
      nil
    end
  end

  defp drop_shaped?(""), do: false

  defp drop_shaped?(candidate) do
    not (candidate =~ ~r/\s/) and candidate =~ ~r/\.(png|jpe?g|gif|webp)$/i
  end

  # The drop's gates mirror the attach prompt's Enter (ADR 0018 §4): the
  # capability refusal names the model and keeps the paste out of the
  # draft; a capable model runs the shared path check (an over-cap image
  # refuses visibly — never a silent drop); success appends the pending
  # chip. Any phase may drop — the composer owns pastes whenever no other
  # input mode does, and the queue only rides a submit.
  defp drop_attach(%__MODULE__{provider: {:ok, %DashFloat.Config{images: false}}} = state, _path) do
    {:ok, config} = state.provider

    refusal =
      "[images: model #{image_model_name(config)} does not accept images — attach refused]"

    {:ok, follow_tail(append_entry(state, :system, refusal))}
  end

  defp drop_attach(%__MODULE__{} = state, path) do
    case Images.check(path) do
      {:ok, meta} ->
        {:ok,
         follow_tail(%{state | attachments: state.attachments ++ [Map.put(meta, :path, path)]})}

      {:error, reason} ->
        {:ok, follow_tail(append_entry(state, :system, "[images: " <> reason <> "]"))}
    end
  end

  # Any composer edit re-pins the log to its tail (issue #110): the user
  # extending the conversation watches it grow. Scrolling, cursor-only
  # keys, and history navigation do not ride this — entering text does.
  defp follow_tail(%__MODULE__{} = state), do: %{state | scroll: 0, follow?: true}

  @doc """
  A paste while the attach prompt is open (ADR 0018 §5): bracketed paste
  appends to the path draft, newlines normalized out — a pasted path with a
  trailing newline is the common terminal shape. The composer is never
  touched while the prompt owns the input.
  """
  @spec attach_paste(t(), String.t()) :: t()
  def attach_paste(%__MODULE__{attach: %{draft: draft}} = state, content)
      when is_binary(content),
      do: %{state | attach: %{draft: draft <> strip_newlines(content)}}

  def attach_paste(%__MODULE__{} = state, _content), do: state

  @doc """
  A paste while the /title dialog is open (issue #106): bracketed paste
  appends to the draft, newlines normalized out — the attach prompt's rule
  (ADR 0018 §5). The composer is never touched while the dialog owns the input.
  """
  @spec title_paste(t(), String.t()) :: t()
  def title_paste(%__MODULE__{title_dialog: %{draft: draft} = dialog} = state, content)
      when is_binary(content),
      do: %{state | title_dialog: %{dialog | draft: draft <> strip_newlines(content)}}

  def title_paste(%__MODULE__{} = state, _content), do: state

  defp strip_newlines(content) do
    content
    |> String.replace("\r\n", "")
    |> String.replace("\r", "")
    |> String.replace("\n", "")
  end

  defp normalize_newlines(content) do
    content
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  ## Key routing

  @doc """
  Routes one key event. Modifiers arrive as `ExRatatui` strings
  (`["ctrl"]`, `["shift"]`, ...). Returns `{state, action}`. `now` is
  monotonic milliseconds (injectable so the exit-guard window is testable).
  """
  @spec handle_key(t(), String.t(), [String.t()], integer()) :: {t(), action()}
  def handle_key(state, code, modifiers, now \\ System.monotonic_time(:millisecond)) do
    {state, action} = route_key(state, code, modifiers, now)
    # Any key other than Ctrl+C disarms a pending exit guard — the intent
    # to exit died with the keystroke that was not "exit again" (issue #28).
    {disarm_exit_guard(state, code, modifiers), action}
  end

  # The double Ctrl+C exit guard (issue #28; ADR 0006 amendment): one press
  # arms a 2 s window and shows the prompt; a second press inside it quits
  # through the normal teardown; a late press re-arms. Applies in every
  # phase, including mid-decision.
  defp route_key(state, "c", ["ctrl"], now) do
    if exit_guard_live?(state, now) do
      {%{state | exit_guard_at: nil}, :quit}
    else
      {%{state | exit_guard_at: now}, nil}
    end
  end

  # Ctrl+Q stays the immediate, deliberate quit (named in the placeholder).
  defp route_key(state, "q", ["ctrl"], _now), do: {state, :quit}

  # The startup phase (ADR 0009) owns every key until it clears: the wizard
  # or the forced-selection modal replaces the chat UI. The global quit
  # clauses above still quit from here — deliberateness includes the right
  # to leave.
  defp route_key(%{setup: setup} = state, code, _modifiers, _now) when setup != nil do
    setup_key(state, code)
  end

  # Confirmation mode (a pending confirm from the agent, ADR 0007): Enter
  # approves, Esc rejects, and every other key is swallowed — typing
  # mid-decision must not reach the textarea nor become an accidental
  # approve.
  defp route_key(%{confirm: pending} = state, "enter", mods, _now)
       when pending != nil and mods in [[], ["ctrl"]],
       do: {state, {:confirm, :approved}}

  defp route_key(%{confirm: pending} = state, "esc", _modifiers, _now) when pending != nil,
    do: {state, {:confirm, :rejected}}

  defp route_key(%{confirm: pending} = state, _code, _modifiers, _now) when pending != nil,
    do: {state, nil}

  # The /title dialog (issue #106) is a key mode like the attach prompt
  # (ADR 0018 §5): while open it swallows every key but the global quits
  # above — printable characters and Backspace edit the draft, Enter submits
  # through the UNCHANGED rename seam (the agent's reply closes the dialog or
  # errors it), Esc cancels. No history, no mode cycle, no palette mid-dialog.
  defp route_key(%{title_dialog: %{draft: draft}} = state, "enter", mods, _now)
       when mods in [[], ["ctrl"]],
       do: {%{state | title_dialog: %{draft: draft, error: nil}}, {:set_title, draft}}

  defp route_key(%{title_dialog: %{}} = state, "esc", _modifiers, _now),
    do: {%{state | title_dialog: nil}, nil}

  # The draft's edit rules are the attach prompt's: Backspace slices the last
  # grapheme, single printable characters append (a shifted printable is an
  # UPPERCASE character, not a chord), and every other key is swallowed.
  defp route_key(%{title_dialog: %{draft: draft} = dialog} = state, code, modifiers, _now) do
    cond do
      code == "backspace" ->
        {%{state | title_dialog: %{dialog | draft: String.slice(draft, 0..-2//1)}}, nil}

      modifiers in [[], ["shift"]] and single_char?(code) and String.valid?(code) ->
        {%{state | title_dialog: %{dialog | draft: draft <> code}}, nil}

      true ->
        {state, nil}
    end
  end

  # The attach prompt (ADR 0018 §5) is a key mode like confirmation mode:
  # while open it swallows every key but the global quits above — printable
  # characters and Backspace edit the path draft, Tab completes against the
  # filesystem, Enter attaches, Esc closes (pending attachments kept), Ctrl+D
  # clears them, and a second Ctrl+O closes. It only opens while idle with no
  # other mode open, so it never fights the phase keys below.
  defp route_key(%{attach: nil, phase: :idle, palette: nil} = state, "o", ["ctrl"], _now),
    do: {%{state | attach: %{draft: ""}}, nil}

  defp route_key(%{attach: %{}} = state, "o", ["ctrl"], _now),
    do: {%{state | attach: nil}, nil}

  defp route_key(%{attach: %{draft: draft}} = state, "enter", mods, _now)
       when mods in [[], ["ctrl"]],
       do: attach(state, draft)

  defp route_key(%{attach: %{}} = state, "esc", _modifiers, _now),
    do: {%{state | attach: nil}, nil}

  defp route_key(%{attach: %{}} = state, "d", ["ctrl"], _now),
    do: {%{state | attach: nil, attachments: []}, nil}

  defp route_key(%{attach: %{draft: draft}} = state, "tab", _modifiers, _now),
    do: {%{state | attach: %{draft: complete_path(draft)}}, nil}

  # The draft's edit rules are the wizard's (ADR 0009) — Backspace slices
  # the last grapheme, single printable characters append — and every other
  # key (arrows, chords, the mode cycling, the palette keys) is swallowed:
  # the prompt is the whole input surface while it lives. A chord is not a
  # printable key (ADR 0018 §5): only unmodified characters type.
  defp route_key(%{attach: %{draft: draft}} = state, code, modifiers, _now) do
    cond do
      code == "backspace" ->
        {%{state | attach: %{draft: String.slice(draft, 0..-2//1)}}, nil}

      # A shifted printable is an UPPERCASE character, not a chord: crossterm
      # attaches SHIFT to every `is_uppercase` char (Caps Lock identically),
      # so shift-only must type — ctrl/alt/super chords stay swallowed.
      modifiers in [[], ["shift"]] and single_char?(code) and String.valid?(code) ->
        {%{state | attach: %{draft: draft <> code}}, nil}

      true ->
        {state, nil}
    end
  end

  # The command palette (ADR 0020). Ctrl+P toggles: open from idle, close
  # whatever kind is open. A modal palette swallows every key but
  # Up/Down/Enter/Esc — the mode cycle included — while the global quits and
  # the pending-confirm clauses above keep outranking it (ADR 0016 §3). The
  # filter popup's Up/Down sit above the history clauses: while the popup is
  # visible the arrows address it, never history; its other keys fall
  # through.
  defp route_key(%{palette: %Palette{}} = state, "p", ["ctrl"], _now),
    do: {%{state | palette: nil}, nil}

  defp route_key(%{palette: nil, phase: :idle} = state, "p", ["ctrl"], _now) do
    palette = %Palette{mode: :modal, kind: :commands, items: Commands.all(), selected: 0}
    {%{state | palette: palette}, nil}
  end

  defp route_key(%{palette: %Palette{mode: :modal} = palette} = state, "up", _modifiers, _now),
    do: {%{state | palette: Palette.move(palette, :up)}, nil}

  defp route_key(%{palette: %Palette{mode: :modal} = palette} = state, "down", _modifiers, _now),
    do: {%{state | palette: Palette.move(palette, :down)}, nil}

  defp route_key(%{palette: %Palette{mode: :modal} = palette} = state, "enter", mods, _now)
       when mods in [[], ["ctrl"]],
       do: execute_palette(state, palette)

  defp route_key(%{palette: %Palette{mode: :filter} = palette} = state, "up", _modifiers, _now),
    do: {%{state | palette: Palette.move(palette, :up)}, nil}

  defp route_key(%{palette: %Palette{mode: :filter} = palette} = state, "down", _modifiers, _now),
    do: {%{state | palette: Palette.move(palette, :down)}, nil}

  # Filter Enter executes the SELECTED match (not the typed text) with the
  # submit path's bookkeeping.
  defp route_key(%{palette: %Palette{mode: :filter} = palette} = state, "enter", mods, _now)
       when mods in [[], ["ctrl"]] do
    command = Enum.at(palette.items, palette.selected)
    run_submitted_command(state, input_text(state), command.name, "")
  end

  # Filter Tab COMPLETES to the selected match (issue #105; ADR 0020's
  # 2026-10-31 amendment): the draft becomes "/<name> " — the trailing
  # space closes the popup (args may follow) and leaves the cursor at the
  # end, editable. The selection is the popup's own highlighted row — the
  # same one arrows move and Enter runs, one selection model. Plain Tab
  # only: shift+tab keeps its swallow above the mode cycle, real terminals
  # emit BackTab. The clause sits above the ghost-text Tab: a slash draft
  # is never empty, so the ghost never arms beside it (ADR 0015 §3 arms
  # and lands on an empty draft only) — the two Tab rules cannot fight.
  defp route_key(%{palette: %Palette{mode: :filter} = palette} = state, "tab", [], _now) do
    command = Enum.at(palette.items, palette.selected)

    state
    |> leave_history()
    |> set_draft("/" <> command.name <> " ")
    |> refresh_palette()
    |> dismiss_suggestion()
    |> follow_tail()
    |> then(&{&1, nil})
  end

  # Esc dismisses either palette; the filter's dismissal survives until the
  # next draft edit re-derives it.
  defp route_key(%{palette: palette} = state, "esc", _modifiers, _now) when palette != nil,
    do: {%{state | palette: nil}, nil}

  defp route_key(%{palette: %Palette{mode: :filter}} = state, "tab", ["shift"], _now),
    do: {state, nil}

  defp route_key(%{palette: %Palette{mode: :filter}} = state, "back_tab", _modifiers, _now),
    do: {state, nil}

  defp route_key(%{palette: %Palette{mode: :modal}} = state, _code, _modifiers, _now),
    do: {state, nil}

  # Shift+Tab cycles the interaction mode (ADR 0016 §7): the action carries
  # it to the agent, whose echo applies it — no local change. Real terminals
  # emit BackTab (CSI Z), which the native layer maps to "back_tab" with an
  # arbitrary modifier list — never "tab"+shift — so back_tab cycles in any
  # shape; the tab+shift clause stays for the synthetic shape it tests.
  defp route_key(state, "tab", ["shift"], _now),
    do: {state, {:set_mode, Mode.cycle(state.mode)}}

  defp route_key(state, "back_tab", _modifiers, _now),
    do: {state, {:set_mode, Mode.cycle(state.mode)}}

  # Enter / Ctrl+Enter submit; Shift+Enter / Alt+Enter insert a newline.
  defp route_key(state, "enter", mods, _now) when mods in [[], ["ctrl"]], do: submit(state)
  defp route_key(state, "enter", ["shift"], _now), do: forward(state, "enter", [])
  defp route_key(state, "enter", ["alt"], _now), do: forward(state, "enter", [])

  # Esc interrupts a streaming reply, a running tool, or a safety check
  # (ADR 0005/0007; ADR 0016 §6); a no-op otherwise (including the
  # post-decision confirming gap).
  defp route_key(%{phase: phase} = state, "esc", _modifiers, _now)
       when phase in [:streaming, :executing_tool, :checking],
       do: {state, :cancel}

  defp route_key(state, "esc", _modifiers, _now), do: {state, nil}

  # Log scrolling.
  defp route_key(state, "page_up", _modifiers, _now), do: {page_up(state), nil}
  defp route_key(state, "page_down", _modifiers, _now), do: {page_down(state), nil}

  # History-aware Up/Down: history only at the draft's row boundaries.
  defp route_key(state, "up", _modifiers, _now) do
    if on_first_row?(state), do: {history_prev(state), nil}, else: forward(state, "up", [])
  end

  defp route_key(state, "down", _modifiers, _now) do
    if on_last_row?(state), do: {history_next(state), nil}, else: forward(state, "down", [])
  end

  # A chip pops before the draft loses its last grapheme (issue #112; ADR
  # 0018 amendment): Backspace on an empty draft — the cursor sits at the
  # chips' boundary, the chip row renders ahead of the draft — removes the
  # NEWEST pending attachment; numbering re-derives from the queue. With
  # draft text, Backspace keeps its ordinary edit (the chip is not "over"
  # the cursor until the draft is empty).
  defp route_key(%{attachments: [_chip | _rest]} = state, "backspace", [], _now) do
    if input_text(state) == "" do
      {follow_tail(%{state | attachments: Enum.drop(state.attachments, -1)}), nil}
    else
      forward(state, "backspace", [])
    end
  end

  # Tab materializes the ghost (ADR 0015 §3): the draft becomes the landed
  # suggestion (editable, cursor at end). No ghost — or a non-empty draft —
  # falls through to the textarea unchanged.
  defp route_key(%{suggestion: suggestion} = state, "tab", _modifiers, _now)
       when suggestion != nil do
    if input_text(state) == "" do
      state
      |> set_draft(suggestion)
      |> refresh_palette()
      |> dismiss_suggestion()
      |> follow_tail()
      |> then(&{&1, nil})
    else
      forward(state, "tab", [])
    end
  end

  # Everything else (typing, editing, Emacs shortcuts) goes to the textarea.
  defp route_key(state, code, modifiers, _now) when is_binary(code) and is_list(modifiers),
    do: forward(state, code, modifiers)

  defp forward(state, code, modifiers) do
    before = input_text(state)
    ExRatatui.textarea_handle_key(state.input, code, modifiers)
    # Editing while browsing history keeps the edited text: it becomes the
    # live draft (no longer restorable by navigating down). The filter
    # palette re-derives only when the draft actually changed — Esc's
    # dismissal survives cursor-only keys (ADR 0020) — and a real edit
    # re-pins the log to its tail (issue #110): keystrokes, not focus.
    edited = dismiss_suggestion(leave_history(state))

    state =
      if input_text(edited) == before, do: edited, else: follow_tail(refresh_palette(edited))

    {state, nil}
  end

  # The attach draft's printable-key test — the wizard's edit rule (ADR 0009).
  defp single_char?(code), do: String.length(code) == 1

  ## Filter palette (ADR 0020)

  # Derived state: recomputed after every draft change. Visible only while
  # idle, the draft is a bare slash prefix ("/he" — no whitespace yet), and at
  # least one command matches. An identical match set keeps the selection; any
  # change resets it to 0. Esc's dismissal survives because this only runs on
  # edits.
  defp refresh_palette(%{phase: :idle} = state) do
    case filter_matches(input_text(state)) do
      nil -> %{state | palette: nil}
      items -> upsert_filter(state, items)
    end
  end

  defp refresh_palette(%__MODULE__{} = state), do: %{state | palette: nil}

  defp upsert_filter(%{palette: %Palette{mode: :filter, items: items}} = state, items),
    do: state

  defp upsert_filter(state, items) do
    %{state | palette: %Palette{mode: :filter, kind: :commands, items: items, selected: 0}}
  end

  # The popup's match set: only while the draft ITSELF is a bare slash token —
  # a typed space (args coming) or any other edit hides it (ADR 0020).
  defp filter_matches(text) do
    case bare_slash_prefix(text) do
      nil -> nil
      prefix -> nonempty_matches(prefix)
    end
  end

  defp nonempty_matches(prefix) do
    case Commands.match(prefix) do
      [] -> nil
      items -> items
    end
  end

  ## Exit guard (issue #28; ADR 0006 amendment)

  defp disarm_exit_guard(state, "c", ["ctrl"]), do: state
  defp disarm_exit_guard(%{exit_guard_at: nil} = state, _code, _modifiers), do: state
  defp disarm_exit_guard(state, _code, _modifiers), do: %{state | exit_guard_at: nil}

  @doc "True while the exit-guard window is still live at `now`."
  @spec exit_guard_live?(t(), integer()) :: boolean()
  def exit_guard_live?(%__MODULE__{exit_guard_at: at}, now) when is_integer(at),
    do: now - at <= @exit_window_ms

  def exit_guard_live?(_state, _now), do: false

  @doc """
  Milliseconds left on the exit-guard window, flooring at 0 when it has
  logically expired — the delay for the TUI's one-shot expiry timer. Only
  meaningful while a guard is armed; callers check `exit_guard_at` first
  (`exit_guard_live?/2` for the window test).
  """
  @spec exit_guard_delay(t(), integer()) :: non_neg_integer()
  def exit_guard_delay(%__MODULE__{exit_guard_at: at}, now) when is_integer(at),
    do: max(@exit_window_ms - (now - at), 0)

  @doc """
  True when a transient row sits between log and input: an active phase
  (ADR 0006), the armed exit-guard prompt (issue #28), or the open attach
  prompt (ADR 0018 §5). The view's layout and the scroll viewport both read
  this — one predicate, one height.
  """
  @spec overlay?(t()) :: boolean()
  def overlay?(%__MODULE__{phase: :idle, exit_guard_at: nil, attach: nil}), do: false
  def overlay?(%__MODULE__{}), do: true

  # Only for actual editing keys; history_prev/next call the textarea API
  # directly and must not trip this.
  defp leave_history(%{history_index: nil} = state), do: state

  defp leave_history(state) do
    %{state | history_index: nil, draft: input_text(state)}
  end

  defp on_first_row?(state) do
    {row, _col} = ExRatatui.textarea_cursor(state.input)
    row == 0
  end

  defp on_last_row?(state) do
    {row, _col} = ExRatatui.textarea_cursor(state.input)
    row == ExRatatui.textarea_line_count(state.input) - 1
  end

  ## Submit

  @doc """
  Submits the draft: appends a `:user` entry, pushes history, clears the
  draft, and flips the phase to `:streaming`. A blank draft still submits
  when attachments are pending — the image-only turn (ADR 0018 §5). A
  command-shaped draft (ADR 0020) runs the command instead — no `:user`
  entry, no phase flip, pending attachments untouched; a bare unknown `/foo`
  warns; other slash text submits as an ordinary message. The command paths
  keep submit's idle gate and bookkeeping. Returns `{state, nil}` when
  nothing is submittable — a blank draft and no pending attachments — or a
  request is already in flight (one at a time; queueing is Phase 2).
  """
  @spec submit(t()) :: {t(), action()}
  def submit(%__MODULE__{} = state) do
    text = input_text(state)

    if state.phase == :idle and (String.trim(text) != "" or state.attachments != []) do
      dispatch_submit(state, text)
    else
      {state, nil}
    end
  end

  defp dispatch_submit(state, text) do
    trimmed = String.trim(text)

    case Commands.split_command(trimmed) do
      {name, rest} -> run_submitted_command(state, text, name, rest)
      nil -> plain_or_unknown(state, text, trimmed)
    end
  end

  defp plain_or_unknown(state, text, trimmed) do
    case bare_slash_prefix(trimmed) do
      nil ->
        # The pending attachments ride the plain path only (ADR 0018 §5):
        # the entry's text stays verbatim (ADR 0006) and its rendered lines
        # gain one indicator per image; clearing waits for the agent's
        # streaming echo (§6), so a submit-time refusal keeps the set.
        paths = Enum.map(state.attachments, & &1.path)
        entry_lines = Render.entry_lines(:user, text) ++ indicator_lines(state.attachments)

        state
        |> push_history(text)
        |> put_entry(:user, text, entry_lines)
        |> clear_input()
        |> Map.put(:phase, :streaming)
        # A new question re-pins the log: the user wants to watch its answer
        # arrive even if they had paged up first.
        |> Map.put(:follow?, true)
        |> dismiss_suggestion()
        |> then(&{&1, {:submit, text, paths}})

      # A bare token that is not a registry name can never be an ordinary
      # message — warn instead (ADR 0020).
      prefix ->
        state
        |> push_history(text)
        |> clear_input()
        |> Map.put(:palette, nil)
        |> append_entry(:system, "unknown command: /#{prefix} — try /help")
        |> then(&{&1, nil})
    end
  end

  # The bare-slash-token test (ADR 0020): the text is exactly
  # "/" + one whitespace-free token ("/he", "/" — not "/he x", not "hi").
  # Callers pass the shape they mean: the raw draft for the popup, the
  # trimmed draft for submit.
  defp bare_slash_prefix(text) do
    case Commands.parse(text) do
      {:command, prefix} -> if text == "/" <> prefix, do: prefix, else: nil
      :no_command -> nil
    end
  end

  defp push_history(state, text) do
    history =
      if state.history != [] and List.last(state.history) == text do
        state.history
      else
        Enum.take(state.history ++ [text], -@max_history)
      end

    %{state | history: history, history_index: nil, draft: ""}
  end

  defp clear_input(state) do
    ExRatatui.textarea_set_value(state.input, "")
    state
  end

  ## Attach prompt (ADR 0018 §5)

  # Enter in the attach prompt (ADR 0018 §4): the capability gate first —
  # the same predicate the agent re-checks at submit, the refusal naming the
  # model — then the stat-only path check, the refusal naming the path. A
  # refusal lands as the `[images: …]` system entry and keeps the prompt open
  # with the draft intact; success keeps only the display metadata and closes.
  # Enter on an empty draft attaches nothing and refuses nothing — the
  # prompt just stays open (an empty path is not a user intent to resolve).
  # FIRST, before the capability gate: the no-op is provider-independent.
  defp attach(state, ""), do: {state, nil}

  defp attach(
         %{provider: {:ok, %DashFloat.Config{images: false}} = classification} = state,
         _draft
       ) do
    {:ok, config} = classification
    entry = "[images: model #{image_model_name(config)} does not accept images — attach refused]"
    {append_entry(state, :system, entry), nil}
  end

  defp attach(state, draft) do
    case Images.check(draft) do
      {:ok, meta} ->
        {%{state | attachments: state.attachments ++ [Map.put(meta, :path, draft)], attach: nil},
         nil}

      {:error, reason} ->
        {append_entry(state, :system, "[images: " <> reason <> "]"), nil}
    end
  end

  # The refusal names the model — the nickname, else the id (ADR 0018 §4);
  # the agent's own rule, mirrored for the attach-time gate.
  defp image_model_name(%DashFloat.Config{nickname: nil, model: model}), do: model
  defp image_model_name(%DashFloat.Config{nickname: nickname}), do: nickname

  # Tab completion (ADR 0018 §5 — the sanctioned UI-process read): one
  # readdir of the draft's directory completes its last path segment to the
  # longest common prefix of the visible matches; a completion that lands a
  # directory gains a trailing "/", dotfile entries only surface once the
  # typed segment starts with ".", and no matches is a no-op.
  defp complete_path(draft) do
    segment =
      draft
      |> String.split("/")
      |> List.last()

    prefix = String.replace_suffix(draft, segment, "")
    dir = dir_for(prefix)

    case File.ls(dir) do
      {:ok, entries} ->
        matches = Enum.filter(entries, &segment_match?(&1, segment))
        completed(prefix, draft, matches)

      {:error, _reason} ->
        draft
    end
  end

  # A bare segment reads relative to the cwd — the same shape the draft's
  # prefix keeps when completed.
  defp dir_for(""), do: "."
  defp dir_for(prefix), do: prefix

  defp segment_match?(name, segment) do
    String.starts_with?(name, segment) and
      (not String.starts_with?(name, ".") or String.starts_with?(segment, "."))
  end

  defp completed(_prefix, draft, []), do: draft

  defp completed(prefix, draft, matches) do
    name = Enum.reduce(matches, &shared_prefix/2)
    candidate = prefix <> name

    cond do
      candidate == draft ->
        draft

      name in matches and File.dir?(candidate) ->
        candidate <> "/"

      true ->
        candidate
    end
  end

  defp shared_prefix(a, b) do
    a
    |> String.graphemes()
    |> Enum.zip(String.graphemes(b))
    |> Enum.take_while(fn {x, y} -> x == y end)
    |> Enum.map_join(&elem(&1, 0))
  end

  # The :user entry's indicator lines (ADR 0018 §5): one dim 📎 row per
  # attachment under the prompt text — display only, the entry's text stays
  # the persistence truth (ADR 0006).
  defp indicator_lines([]), do: []

  defp indicator_lines(attachments),
    do:
      Enum.map(attachments, fn %{name: name, kb: kb} ->
        Line.new([Span.new("📎 #{name} (#{kb} KB)", style: Theme.style(:dim))])
      end)

  ## Slash commands (ADR 0020 — the registry is data; transitions live here)

  # Command execution with submit's bookkeeping: history push and draft clear
  # like any submit, palette closed, then the command runs — no `:user` entry,
  # no phase flip. `name` may be the filter's SELECTED match rather than the
  # typed token.
  defp run_submitted_command(state, text, name, rest) do
    state
    |> push_history(text)
    |> clear_input()
    |> dismiss_suggestion()
    |> Map.put(:palette, nil)
    |> then(&run_command(&1, name, rest))
  end

  # Palette Enter — the same rule in both modes (ADR 0020). The modal command
  # palette runs with empty args and pushes NO history: nothing was typed.
  defp execute_palette(state, %Palette{kind: :commands, items: items, selected: selected}) do
    state
    |> dismiss_suggestion()
    |> Map.put(:palette, nil)
    |> then(&run_command(&1, Enum.at(items, selected).name, ""))
  end

  defp execute_palette(state, %Palette{kind: :models} = palette), do: pick_model(state, palette)

  defp execute_palette(state, %Palette{kind: :profiles, items: names, selected: selected}) do
    {%{state | palette: nil}, {:select_profile, Enum.at(names, selected)}}
  end

  # One clause per registry entry; the actions ride to the TUI ({:set_mode,
  # _}, {:set_title, _}, {:switch_model, _}, :list_profiles, :compact, :quit).

  # /clear resets the log; the input history survives (ADR 0020).
  defp run_command(state, "clear", _rest) do
    {%{
       state
       | entries: [],
         in_flight: nil,
         in_flight_lines: nil,
         in_flight_dirty: false,
         selection: nil,
         scroll: 0,
         follow?: true
     }, nil}
  end

  defp run_command(state, "help", _rest) do
    listing = Enum.map_join(Commands.all(), "\n", &"/#{&1.name} — #{&1.description}")
    {append_entry(state, :system, listing <> "\n\n" <> @key_hints), nil}
  end

  defp run_command(state, "quit", _rest), do: {state, :quit}

  # Bare /mode names the current mode; /mode <name> rides shift+tab's seam —
  # the agent validates, applies, and echoes; no local change (ADR 0016 §7).
  defp run_command(state, "mode", "") do
    entry = "[mode: #{Mode.label(state.mode)} — /mode <plan|build|auto|unchained>]"
    {append_entry(state, :system, entry), nil}
  end

  defp run_command(state, "mode", rest) do
    case Mode.from_string(rest) do
      {:ok, mode} ->
        {state, {:set_mode, mode}}

      :error ->
        {append_entry(state, :system, "unknown mode: #{rest} (plan, build, auto, unchained)"),
         nil}
    end
  end

  # Bare /title opens the dialog pre-filled with the current title
  # (issue #106); /title <name> keeps the inline path — the agent owns title
  # normalization, uniqueness, and validation either way (ADR 0023 §7's
  # rename seam).
  defp run_command(state, "title", "") do
    {%{state | title_dialog: %{draft: state.title || "", error: nil}}, nil}
  end

  defp run_command(state, "title", rest), do: {state, {:set_title, rest}}

  # /compact rides ADR 0022's eviction on demand (issue #92): the agent
  # owns the transcript, the anchor, and every feedback entry.
  defp run_command(state, "compact", _rest), do: {state, :compact}

  # /model opens the picker over this provider's catalog entries (ADR 0009's
  # landed sweep), the current model preselected; an empty catalog warns.
  defp run_command(%{provider: {:ok, config}} = state, "model", _rest) do
    case Map.get(state.catalog, config.base_url, []) do
      [] ->
        {append_entry(state, :system, "[model catalog is empty — nothing to pick]"), nil}

      entries ->
        selected = Enum.find_index(entries, &(&1.model == config.model)) || 0
        palette = %Palette{mode: :modal, kind: :models, items: entries, selected: selected}
        {%{state | palette: palette}, nil}
    end
  end

  defp run_command(state, "model", _rest),
    do:
      {append_entry(state, :system, "[no provider resolved — /model needs a working profile]"),
       nil}

  defp run_command(state, "profile", _rest), do: {state, :list_profiles}

  # The model picker's Enter: a catalog id has no nickname — it nils out and
  # the label falls back to the catalog (ADR 0020). The context window
  # re-resolves for the PICKED id (issue #111, hostile review F2): its own
  # settings-menu entry's `context` when one exists (an explicit user
  # setting survives the switch), else nothing explicit and the
  # seed/default chain takes over — never the outgoing model's number. The
  # images flag is NOT carried from the outgoing model: it re-resolves
  # against the settings-side menu by id — a marked entry keeps its
  # capability, a catalog-only id is not capable (ADR 0018 §1). The switch
  # lands on the NEXT request.
  defp pick_model(
         %{provider: {:ok, %DashFloat.Config{} = config}} = state,
         %Palette{items: entries, selected: selected}
       ) do
    picked = Enum.at(entries, selected).model

    switched =
      %DashFloat.Config{
        config
        | model: picked,
          nickname: nil,
          context_tokens: menu_context(config.model_menu, picked),
          images: menu_images(config.model_menu, picked)
      }

    {%{state | provider: {:ok, switched}, palette: nil}, {:switch_model, {:ok, switched}}}
  end

  # The menu entry for `id` decides (ADR 0018 §1's pattern, the context
  # twin): no entry — a catalog-only id — carries no explicit window.
  defp menu_context(menu, id) do
    case Enum.find(menu, fn entry -> entry.model == id end) do
      %{context: context} when is_integer(context) and context > 0 -> context
      _no_entry -> nil
    end
  end

  # The menu entry for `id` decides (ADR 0018 §1); no entry — a catalog-only
  # id — is not image-capable.
  defp menu_images(menu, id) do
    case Enum.find(menu, fn entry -> entry.model == id end) do
      %{images: images} -> images || false
      _no_entry -> false
    end
  end

  @doc """
  The profile names for /profile's picker landed (the TUI reads
  `DashFloat.Config.profile_names/1`, ADR 0020): the modal opens over them,
  or an empty list warns — nothing to switch to.
  """
  @spec profiles_arrived(t(), [String.t()]) :: t()
  def profiles_arrived(%__MODULE__{} = state, []),
    do: append_entry(state, :system, "[no profiles configured]")

  def profiles_arrived(%__MODULE__{} = state, names) when is_list(names) do
    %{state | palette: %Palette{mode: :modal, kind: :profiles, items: names, selected: 0}}
  end

  ## Stream messages (the Phase 2 seam)

  @doc """
  Applies one stream-contract message:

    * `{:token, text}` — append to the in-flight entry verbatim, count it, start
      the rate clock on the first token, mark the live lines stale
    * `{:usage, map}` — reconcile prompt/completion tokens; no phase change
    * `{:context, snapshot}` — adopt the agent's context snapshot (the
      footer's tokens-used source, ADR 0015 §2 amendment); no phase change
    * `{:phase, :streaming}` — set the phase and clear the pending
      attachments (ADR 0018 §6: the turn's images ride the request; a
      submit-time refusal never echoes this phase, so the refused set
      survives); re-announcing streaming
      never finalizes (a producer resuming after a tool interlude must not
      fragment its reply)
    * `{:phase, :executing_tool | :checking | :idle}` — set the phase and
      finalize the in-flight entry, freezing the rate
    * `{:tool_call, call}` — append the gear row built by `Render.tool_call/2`
    * `{:tool_result, result}` — append the status row and dim output built by
      `Render.tool_result/3`
    * `{:confirm, ref, request}` — append the preview entry built by
      `Render.confirm_preview/1`, then arm `state.confirm` and flip to the
      `:confirming` phase (ADR 0007)
    * `{:mode, mode}` — the single-voice echo: set the mode; no entry, no
      phase change (ADR 0016)
    * `{:tool_preview, request}` — append the preview entry built by
      `Render.confirm_preview/1` without arming `state.confirm` (ADR 0016)
    * `{:title, title}` — the display-only title push (ADR 0023's
      2026-10-31 amendment): set the title and close an open dialog —
      the rename succeeded
    * `{:title_refused, reason}` — set the open dialog's error (draft kept);
      a no-op with no dialog open — the agent's system entry is the log
      record for the inline form
    * `{:entry, kind, text}` — append a complete entry

  `now` is monotonic milliseconds (injectable so the rate math is testable).
  Messages that violate the contract have no matching clause and crash —
  contract violations are bugs.
  """
  @spec stream_message(t(), stream_msg(), integer()) :: t()
  def stream_message(state, msg, now \\ System.monotonic_time(:millisecond))

  # A token arriving at idle belongs to a turn that is already over —
  # ignored like a late usage frame below: applying it would set in_flight,
  # and a later {:phase, :idle} would then finalize and arm a suggestion for
  # it, re-opening the duplicate-arm window (ADR 0015 §3's once-per-turn arm
  # stays true).
  def stream_message(%{phase: :idle} = state, {:token, text}, _now) when is_binary(text),
    do: state

  def stream_message(state, {:token, text}, now) when is_binary(text) do
    %{
      state
      | in_flight: (state.in_flight || "") <> text,
        stats: %{
          state.stats
          | tokens: state.stats.tokens + 1,
            first_token_at: state.stats.first_token_at || now
        },
        in_flight_dirty: true
    }
  end

  # A usage frame arriving after the turn finalized belongs to a turn that is
  # already over: applying it would poison the next turn's rate math (its
  # completion count is not this turn's). Ignored.
  def stream_message(%{phase: :idle} = state, {:usage, _usage}, _now), do: state

  def stream_message(state, {:usage, usage}, _now) when is_map(usage) do
    %{prompt_tokens: prompt, completion_tokens: completion} = usage

    # Usage frames carry the turn's running count — single-frame providers
    # send it once, per-chunk reporters on every frame. The turn's truth is
    # the LAST frame (the same last-frame-wins rule as the agent's
    # pending_usage, ADR 0007 §5); the count feeds the rate math only —
    # the footer's tokens-used comes from the context snapshot's
    # Accounting.usage/3 read (ADR 0015 §2 amendment).
    stats = %{
      state.stats
      | prompt_tokens: prompt,
        completion_tokens: completion,
        # The usage frame is the authoritative count: the per-delta estimate is
        # reconciled here, so the frozen rate is computed from real tokens.
        tokens: completion
    }

    %{state | stats: stats}
  end

  # The stage-2 context snapshot (ADR 0015 §2 amendment): pure data in, pure
  # data stored — the footer's usage read happens at render.
  def stream_message(state, {:context, %{messages: messages, anchor: anchor}}, _now)
      when is_list(messages),
      do: %{state | context: %{messages: messages, anchor: anchor}}

  # Any phase message supersedes a pending confirm: the agent is the single
  # voice, and a confirm the UI never decided must not outlive the turn it
  # belonged to (agent death included — agent_down routes through here).
  # A new turn also kills the old ghost — the reap intent rides the
  # resulting state (ADR 0015 §3) — and clears the pending attachments
  # (ADR 0018 §6): the turn's images are on the wire now. Clearing an
  # already-empty list is a no-op, so repeated tool-loop episodes are safe.
  def stream_message(state, {:phase, :streaming}, _now),
    do: dismiss_suggestion(%{state | phase: :streaming, confirm: nil, attachments: []})

  def stream_message(state, {:phase, :idle}, now) do
    # Arm only when THIS transition actually finalized an assistant reply:
    # a re-sent idle (agent_down(:normal), a late phase echo) finalizes
    # nothing, and re-arming would fire a second side-request for one turn
    # (ADR 0015 §3: at most one per completed turn).
    finalized? = state.in_flight not in [nil, ""]

    state
    |> finalize_phase(:idle, now)
    |> maybe_arm_suggestion(finalized?)
  end

  # Tool interludes are mid-turn — a safety check (ADR 0016 §7) no less than
  # an execution: the phase changes and any in-flight partial reply
  # finalizes, but the turn is not complete — never an arm (and every new
  # phase still sets the reap intent, ADR 0015 §3).
  def stream_message(state, {:phase, phase}, now)
      when phase in [:executing_tool, :checking] do
    state
    |> finalize_phase(phase, now)
    |> dismiss_suggestion()
  end

  # The single-voice echo (ADR 0016 §7): the announcing system entry arrives
  # separately as {:entry, :system, _}. The agent validates the mode at its
  # seam, so the echo — like every stream message — is trusted agent voice.
  def stream_message(state, {:mode, mode}, _now), do: %{state | mode: mode}

  # The display-only title push (issue #106): the dialog's prefill and the
  # footer-adjacent state stay current, and an open dialog closes — the rename
  # succeeded, nothing left to show.
  def stream_message(state, {:title, title}, _now) when is_binary(title),
    do: %{state | title: title, title_dialog: nil}

  # The rename refusal lands IN the open dialog (draft kept, issue #106);
  # with no dialog open it is a no-op — the inline form's log record is the
  # agent's own system entry.
  def stream_message(state, {:title_refused, reason}, _now) when is_binary(reason) do
    case state.title_dialog do
      nil -> state
      dialog -> %{state | title_dialog: %{dialog | error: reason}}
    end
  end

  # A proposal or execution receipt (ADR 0016 §4): the preview rows a human
  # would confirm, landed without arming the decision.
  def stream_message(
        state,
        {:tool_preview, %{id: _id, name: _name, args: _args, lines: lines}},
        _now
      ) do
    {text, entry_lines} = Render.confirm_preview(lines)
    put_entry(state, :tool, text, entry_lines)
  end

  def stream_message(state, {:entry, kind, text}, _now)
      when kind in [:tool, :system] and is_binary(text),
      do: append_entry(state, kind, text)

  def stream_message(state, {:tool_call, %{id: _id, name: name, args: args}}, _now) do
    {text, lines} = Render.tool_call(name, args)
    put_entry(state, :tool, text, lines)
  end

  def stream_message(
        state,
        {:tool_result, %{id: _id, name: name, ok: _ok, status: status, output: output}},
        _now
      ) do
    {text, lines} = Render.tool_result(name, status, output)
    put_entry(state, :tool, text, lines)
  end

  def stream_message(
        state,
        {:confirm, ref, %{id: id, name: name, args: _args, lines: lines}},
        _now
      ) do
    {text, entry_lines} = Render.confirm_preview(lines)

    state
    |> put_entry(:tool, text, entry_lines)
    |> Map.put(:confirm, %{ref: ref, id: id, name: name})
    |> Map.put(:phase, :confirming)
  end

  # Finalizing renders the reply once and freezes the cumulative rate; the
  # streaming counters reset for the next turn, the frozen rate and context
  # accumulator stay visible. The in-flight block is replaced by the
  # finalized entry's rows: a selection reaching into the rows that were
  # live at its anchor loses the content under its highlight and clears —
  # see clear_selection_over_reply for the boundary rule.
  defp finalize_phase(state, phase, now) do
    state
    |> finalize_in_flight(now)
    |> Map.put(:phase, phase)
    |> Map.put(:confirm, nil)
  end

  # One-shot arm intent (ADR 0015 §3): only a finalized assistant turn with
  # an empty draft and suggestions enabled arms — at most one side-request
  # per completed turn; draft churn later never re-arms. `false` (nothing
  # finalized here) leaves the state untouched.
  defp maybe_arm_suggestion(state, false), do: state

  defp maybe_arm_suggestion(state, true) do
    armed? =
      match?(%{kind: :assistant}, List.last(state.entries)) and
        input_text(state) == "" and
        suggest_enabled?(state.provider)

    %{state | suggest_arm: armed?}
  end

  defp suggest_enabled?({:ok, %DashFloat.Config{suggest: suggest}}), do: suggest != false
  defp suggest_enabled?(_other), do: false

  # A dismiss clears the landed ghost and sets the reap intent: the TUI's
  # choke point cancels the debounce, kills an in-flight task, and bumps the
  # epoch so any straggler result is dead on arrival (ADR 0015 §3).
  defp dismiss_suggestion(state), do: %{state | suggestion: nil, suggest_reap: true}

  defp finalize_in_flight(%{in_flight: in_flight} = state, now) when in_flight in [nil, ""] do
    %{
      state
      | in_flight: nil,
        in_flight_lines: nil,
        in_flight_dirty: false,
        stats: frozen(state, now)
    }
  end

  defp finalize_in_flight(%{in_flight: in_flight} = state, now) do
    state
    |> append_entry(:assistant, in_flight)
    |> clear_selection_over_reply(state)
    |> Map.merge(%{in_flight: nil, in_flight_lines: nil, in_flight_dirty: false})
    |> Map.put(:stats, frozen(state, now))
  end

  # The boundary is the gesture's OWN base — the entries' display-row count
  # snapshotted at the "down" — not a finalize-time recount: rows appended
  # between the anchor and the finalize (the Esc-cancel contract's system
  # entry, tokens) shift the live block's position, and recounting would
  # misjudge selections by the drift (review P1). Rows below the base are
  # stable under appends and the finalize's replacement; a selection
  # entirely below it survives. Hand-built selections without a base clear
  # conservatively.
  defp clear_selection_over_reply(%{selection: nil} = state, _before), do: state

  defp clear_selection_over_reply(%{selection: selection} = state, _before) do
    {{_from_row, _fc}, {to_row, _tc}} = Selection.range(selection)
    base = Map.get(selection, :base_rows, 0)

    if to_row >= base, do: %{state | selection: nil}, else: state
  end

  # The turn's rate freezes here (ADR 0006); the context total is NOT banked
  # anymore — the footer's tokens-used span reads Accounting.usage/3 off the
  # agent's context snapshot (ADR 0015 §2 amendment, issue #67 stage 2).
  defp frozen(%{stats: stats}, now) do
    %{
      stats
      | rate: rate(stats.tokens, stats.first_token_at, now) || stats.rate,
        tokens: 0,
        first_token_at: nil
    }
  end

  defp rate(tokens, first_token_at, now)
       when is_integer(first_token_at) and is_integer(now) and tokens > 0 and now > first_token_at do
    tokens * 1000 / (now - first_token_at)
  end

  defp rate(_tokens, _first_token_at, _now), do: nil

  # `text` stays verbatim (ADR 0006: it is the persistence truth); `logical`
  # is the width-free render truth, `lines` its wrap at the current width —
  # what the view renders and the scroll math counts. Tool-contract entries
  # carry their styled logical lines from the Render builders.
  defp append_entry(state, kind, text),
    do: put_entry(state, kind, text, Render.entry_lines(kind, text))

  defp put_entry(state, kind, text, logical) do
    entry = %{
      kind: kind,
      text: text,
      logical: logical,
      lines: Wrap.wrap(logical, log_width(state))
    }

    %{state | entries: state.entries ++ [entry]}
  end

  # The wrap width is the padded content width — the log rect's width, from
  # the same split that renders it (issue #28; ADR 0006 amendment). Never
  # the raw frame width.
  defp log_width(%__MODULE__{size: {width, _height}}), do: View.content_width(width)

  ## Animation tick

  @doc """
  Steps the spinner and refreshes the live in-flight render. Returns
  `{state, :halt}` immediately when idle — an idle UI must never keep a timer
  alive (ADR 0006). `now` is monotonic milliseconds.
  """
  @spec tick(t(), integer()) :: {t(), :cont | :halt}
  def tick(%__MODULE__{phase: :idle} = state, _now), do: {state, :halt}

  def tick(%__MODULE__{} = state, now) do
    stats = state.stats

    state =
      state
      |> Map.put(:anim_step, state.anim_step + 1)
      |> Map.put(:stats, %{
        stats
        | rate: rate(stats.tokens, stats.first_token_at, now) || stats.rate
      })
      |> refresh_in_flight()

    {state, :cont}
  end

  @doc """
  Toggles the idle cursor's blink phase (issue #104; ADR 0006's 2026-10-31
  amendment) — one state flip, drawn by the TUI's blink timer frame. Pure;
  the timer lives in the TUI process. Entering an active phase resets the
  phase to visible (`true`) so the first idle frame always shows the
  cursor.
  """
  @spec blink(t()) :: t()
  def blink(%__MODULE__{} = state), do: %{state | blink_on: not state.blink_on}

  defp refresh_in_flight(%{in_flight_dirty: false} = state), do: state

  defp refresh_in_flight(%{in_flight: in_flight} = state)
       when byte_size(in_flight) <= @in_flight_cap do
    width = log_width(state)
    %{state | in_flight_lines: wrapped_assistant(in_flight, width), in_flight_dirty: false}
  end

  # Above the cap the live view keeps its last render; finalize still parses
  # once at the end (ADR 0006).
  defp refresh_in_flight(state), do: state

  @doc "True when an active phase has no tick scheduled yet."
  @spec needs_tick?(t()) :: boolean()
  def needs_tick?(%__MODULE__{phase: :idle}), do: false
  def needs_tick?(%__MODULE__{tick_ref: nil}), do: true
  def needs_tick?(%__MODULE__{}), do: false

  ## Agent monitoring

  @doc """
  Monitors the agent (`state.agent`, a pid or registered name) so its death
  degrades the UI instead of bricking input. A side effect on purpose — the
  only one in this module — called from the TUI process at mount so the
  monitor lives there, not in `new/1` (ADR 0007).
  """
  @spec claim_agent(t()) :: t()
  def claim_agent(%__MODULE__{} = state) do
    %{state | agent_ref: Process.monitor(state.agent)}
  end

  @doc """
  Applies an agent `{:DOWN, ref, :process, _pid, reason}`. Normal exits (and
  `:noproc` — the monitor attaching after an already-dead name) only ensure
  the phase is `:idle` (finalizing any partial reply); anything else
  finalizes the stream, logs a `:system` entry explaining what happened, and
  returns to `:idle` so input keeps working — a dead agent must never brick
  the UI (ADR 0001: failures degrade to chat messages). Returns
  `{state, :handled}` when the ref was ours, `{state, :ignored}` otherwise.
  """
  @spec agent_down(t(), reference(), term()) :: {t(), :handled | :ignored}
  def agent_down(%{agent_ref: ref} = state, ref, reason) do
    cleared = %{state | agent_ref: nil}

    state =
      if reason in [:normal, :noproc] do
        stream_message(cleared, {:phase, :idle})
      else
        stream_failed(cleared, "[agent failed: #{String.slice(inspect(reason), 0, 120)}]")
      end

    {state, :handled}
  end

  def agent_down(state, _other_ref, _reason), do: {state, :ignored}

  @doc """
  Clears the pending confirmation once the decision has been sent to the
  agent. The phase stays `:confirming` until the agent's next phase message
  arrives — the gap is one mailbox hop, invisible under render coalescing.
  """
  @spec confirm_decided(t()) :: t()
  def confirm_decided(%__MODULE__{} = state), do: %{state | confirm: nil}

  @doc """
  Degrades to `:idle` with a `:system` entry explaining the failure. A binary
  reason is already user-facing text and is logged verbatim; anything else is
  inspected.
  """
  @spec stream_failed(t(), term()) :: t()
  def stream_failed(state, reason) do
    state
    |> stream_message({:entry, :system, format_reason(reason)})
    |> stream_message({:phase, :idle})
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: "[stream failed: #{String.slice(inspect(reason), 0, 120)}]"

  ## History navigation

  # history_index counts steps back from the newest entry; nil means the live
  # draft. Entering history saves the draft; navigating past the newest
  # restores it.
  defp history_prev(%{history: []} = state), do: state

  defp history_prev(state) do
    next = min((state.history_index || -1) + 1, length(state.history) - 1)

    refresh_palette(
      state
      |> maybe_save_draft()
      |> set_history_index(next)
      |> dismiss_suggestion()
    )
  end

  defp history_next(%{history_index: nil} = state), do: state

  defp history_next(state) do
    next = state.history_index - 1

    if next < 0 do
      restored =
        state
        |> set_draft(state.draft)
        |> Map.put(:history_index, nil)

      refresh_palette(dismiss_suggestion(restored))
    else
      refresh_palette(dismiss_suggestion(set_history_index(state, next)))
    end
  end

  defp maybe_save_draft(%{history_index: nil} = state), do: %{state | draft: input_text(state)}
  defp maybe_save_draft(state), do: state

  defp set_history_index(state, index) do
    text =
      state.history
      |> Enum.reverse()
      |> Enum.at(index)

    set_draft(state, text)
    %{state | history_index: index}
  end

  defp set_draft(state, text) do
    ExRatatui.textarea_set_value(state.input, text)
    move_cursor_to_end(state.input, text)
    state
  end

  defp move_cursor_to_end(input, text) do
    lines =
      text
      |> String.split("\n")
      |> length()

    # set_value leaves the cursor at {0, 0}; walk to the last line, then end.
    Enum.each(
      List.duplicate("down", max(lines - 1, 0)) ++ ["end"],
      &ExRatatui.textarea_handle_key(input, &1, [])
    )
  end

  ## Scrolling

  @doc "Total display lines in the log (stored entry lines plus any in-flight lines)."
  @spec log_line_count(t()) :: non_neg_integer()
  def log_line_count(%{entries: entries, in_flight_lines: in_flight_lines}) do
    count = Enum.reduce(entries, 0, fn %{lines: lines}, acc -> acc + length(lines) end)
    count + length(in_flight_lines || [])
  end

  @doc """
  Effective scroll offset for a viewport of `height` lines: the intent
  clamped to the content. When following, it is pinned to the bottom.
  """
  @spec effective_scroll(t(), non_neg_integer()) :: non_neg_integer()
  def effective_scroll(state, height) when is_integer(height) and height >= 0 do
    total = log_line_count(state)
    max_offset = max(total - height, 0)

    if state.follow?,
      do: max_offset,
      else: min(state.scroll, max_offset)
  end

  defp page_up(state), do: scroll(state, :up, log_height(state))
  defp page_down(state), do: scroll(state, :down, log_height(state))

  # One wheel notch scrolls three lines — the terminal convention for
  # alternate-screen apps (issue #21; ADR 0006 amendment).
  @wheel_lines 3

  @doc """
  Scrolls the log one wheel notch. Wheel routing is focus-free (ADR 0006
  amendment): it always addresses the log view — never the input draft —
  including mid-confirmation. Semantics mirror the page keys at line
  granularity: up unfollows (with page_up's nothing-to-scroll guard), down
  re-pins at the bottom.
  """
  @spec wheel_scroll(t(), :up | :down) :: t()
  def wheel_scroll(state, :up), do: scroll(state, :up, @wheel_lines)
  def wheel_scroll(state, :down), do: scroll(state, :down, @wheel_lines)

  defp scroll(state, :up, step) do
    height = log_height(state)

    # Nothing to scroll (empty or viewport-sized log): stay pinned. Unfollowing
    # here would make the user miss the next reply entirely.
    if log_line_count(state) - height <= 0 do
      state
    else
      %{state | follow?: false, scroll: max(effective_scroll(state, height) - max(step, 1), 0)}
    end
  end

  defp scroll(state, :down, step) do
    height = log_height(state)
    bottom = max(log_line_count(state) - height, 0)
    target = effective_scroll(state, height) + max(step, 1)

    if target >= bottom do
      %{state | scroll: 0, follow?: true}
    else
      %{state | follow?: false, scroll: target}
    end
  end

  defp log_height(state) do
    %{log: log} = View.regions(state.size, input_line_count(state), overlay?(state))
    log.height
  end

  ## Mouse selection (issue #28; ADR 0006 amendment)

  # A press+release is a click (clears the selection) unless the pointer
  # crossed rows or the anchor-to-release EXTENT spans at least three
  # cells — a deliberate 3-cell same-row selection must copy, while the
  # 1-2 cell wobble of a shaky click must not (review contract).
  @drag_jitter 2
  # The OSC 52 payload is capped: base64 inflates 4/3, so this bounds the
  # escape sequence at ~86 KiB — comfortably inside every mainstream
  # terminal's OSC 52 limit, while dropping monster selections with a log
  # line instead of stalling the writer.
  @copy_cap 64 * 1024

  @doc """
  Applies a left-button mouse event over the log. `"down"` anchors a
  selection at the display row/column under the pointer — snapshotting the
  entries' display-row count as the gesture's base — `"drag"` extends the
  head, `"up"` finishes: a release within the drag threshold (same row,
  under a three-cell extent) clears the selection (click-to-clear), a real
  drag returns `{:copy, text}` — or `{:copy_too_large, bytes}` past the
  cap, decided by a cap-bounded build — and keeps the highlight until the
  next click, drag, or width-changing resize. Coordinates outside the log
  rect clamp to its edges IN SCREEN SPACE before the scroll mapping, so an
  off-pane pointer selects the edge row of the viewport, never rows beyond
  it. A gesture that STARTS Shift-modified is a native-selection gesture:
  the down dismisses any existing app selection and nothing in the gesture
  can select or copy (Shift mid-gesture merely pauses extension).
  Selection is content-anchored (absolute display rows), so it survives
  scrolling and appends.
  """
  @spec select_mouse(t(), String.t(), integer(), integer(), [String.t()]) ::
          {t(), {:copy, String.t()} | {:copy_too_large, pos_integer()} | nil}
  def select_mouse(%__MODULE__{} = state, kind, x, y, modifiers \\ [])
      when kind in ["down", "drag", "up"] and is_integer(x) and is_integer(y) and
             is_list(modifiers) do
    cond do
      kind == "down" and "shift" in modifiers ->
        # Native-selection gesture, latched at its start: the old app
        # selection goes away and no later plain up can copy from a stale
        # anchor (review P2b — the bypass must never write).
        {%{state | selection: nil}, nil}

      "shift" in modifiers ->
        {state, nil}

      true ->
        apply_mouse(state, kind, x, y)
    end
  end

  defp apply_mouse(state, kind, x, y) do
    case cell_at(state, x, y) do
      nil ->
        {state, nil}

      cell ->
        case kind do
          "down" ->
            base = log_line_count(state) - length(state.in_flight_lines || [])
            {%{state | selection: %{anchor: cell, head: cell, base_rows: base}}, nil}

          "drag" ->
            {%{state | selection: extend(state.selection, cell)}, nil}

          "up" ->
            release(state, cell)
        end
    end
  end

  defp extend(nil, _cell), do: nil
  defp extend(selection, cell), do: %{selection | head: cell}

  defp release(state, cell) do
    case state.selection do
      %{anchor: anchor} when anchor != cell ->
        if drag?(anchor, cell) do
          copy(state, cell)
        else
          # Jitter, not a drag: treat as a plain click.
          {%{state | selection: nil}, nil}
        end

      _collapsed_or_absent ->
        # Click-to-clear: a press+release on the same cell.
        {%{state | selection: nil}, nil}
    end
  end

  # A real drag crosses rows or spans at least three cells on a row: the
  # inclusive extent is the column distance plus one, so @drag_jitter = 2
  # as the minimum distance keeps 1-2 cell wobble a click while a
  # deliberate 3-cell selection copies (review contract).
  defp drag?({anchor_row, _ac}, {cell_row, _bc}) when anchor_row != cell_row, do: true

  defp drag?({_anchor_row, ac}, {_cell_row, bc}),
    do: abs(ac - bc) >= @drag_jitter

  # The copy is BUILT bounded: accumulation stops at the cap, so a monster
  # span costs at most one cap-sized pass before the decision — the build,
  # not the write, was the freeze (review P2a).
  defp copy(state, cell) do
    selection = %{state.selection | head: cell}
    {{from_row, _fc}, {to_row, _tc}} = Selection.range(selection)
    count = selection_row_count(from_row, to_row, log_line_count(state))
    rows = if count > 0, do: View.display_lines(state, from_row, count), else: []

    case Selection.extract_capped(selection, rows, from_row, @copy_cap) do
      {:ok, text} ->
        if String.trim(text) == "" do
          # A selection of pure blank rows copies nothing — clear it.
          {%{state | selection: nil}, nil}
        else
          {%{state | selection: selection}, {:copy, text}}
        end

      {:too_large, bytes} ->
        {%{state | selection: selection}, {:copy_too_large, bytes}}
    end
  end

  # The {display_row, column} under pointer (x, y). The pointer clamps
  # into the log rect in SCREEN space first — a click on the status bar or
  # a drag into the input pane selects the rect's edge row, content the
  # user can see under the clamp, never rows beyond the viewport (review
  # P1) — then maps through the current scroll. nil when the log has no
  # rows at all.
  defp cell_at(state, x, y) do
    count = log_line_count(state)
    %{log: log} = View.regions(state.size, input_line_count(state), overlay?(state))

    if count == 0 do
      nil
    else
      width =
        state.size
        |> elem(0)
        |> View.content_width()

      bottom = log.y + max(log.height, 1) - 1
      screen_row = clamp(y, log.y, bottom)
      top = effective_scroll(state, log.height) + (screen_row - log.y)
      row = clamp(top, 0, count - 1)
      col = clamp(x - log.x, 0, width)
      {row, col}
    end
  end

  defp clamp(n, lo, _hi) when n < lo, do: lo
  defp clamp(n, _lo, hi) when n > hi, do: hi
  defp clamp(n, _lo, _hi), do: n

  @doc """
  The copied text of the current selection: display-faithful rows (edge rows
  by column range, interior rows verbatim) joined with newlines. `""` when
  nothing is selected.
  """
  @spec selection_text(t()) :: String.t()
  def selection_text(%__MODULE__{selection: nil}), do: ""

  def selection_text(%__MODULE__{selection: selection} = state) do
    {{from_row, _fc}, {to_row, _tc}} = Selection.range(selection)

    case selection_row_count(from_row, to_row, log_line_count(state)) do
      # Nothing selectable: no selection rows survive the clamp (stale
      # selection over shrunken content).
      count when count <= 0 ->
        ""

      count ->
        rows = View.display_lines(state, from_row, count)
        Selection.extract(selection, rows, from_row)
    end
  end

  # The selection may reference rows the content no longer has (it shrank
  # after the anchor landed) — clamp to what exists.
  defp selection_row_count(from_row, to_row, total)
       when is_integer(from_row) and is_integer(to_row) and is_integer(total) do
    wanted = to_row - from_row + 1
    available = total - from_row
    if wanted <= available, do: wanted, else: available
  end

  ## Resize

  @doc """
  Records the new terminal size and, when the width changed, re-wraps the log
  to it: stored entries re-wrap from their logical lines (no re-parse), and
  the in-flight reply re-renders from its text under the same 64 KiB live
  cap. Above the cap no fresh render is possible until finalize, and a
  stale-width render would truncate at the new edge, so the live view
  clears until the reply finalizes (ADR 0006, amended). Scroll intents stay
  and are clamped at render.
  """
  @spec resize(t(), integer(), integer()) :: t()
  def resize(state, width, height) when is_integer(width) and is_integer(height) do
    width = max(width, 1)
    height = max(height, 1)

    case state.size do
      {^width, ^height} ->
        state

      {old_width, _old_height} when old_width == width ->
        %{state | size: {width, height}}

      _old_size ->
        # Re-wrap at the padded content width — the same width append and
        # tick wrap at (issue #28), never the raw frame width. A width
        # change invalidates the display-row geometry a selection indexes,
        # so it clears (ADR 0006 amendment).
        wrap_width = View.content_width(width)

        %{
          state
          | size: {width, height},
            entries: Enum.map(state.entries, &rewrap_entry(&1, wrap_width)),
            in_flight_lines: rewrap_in_flight(state, wrap_width),
            selection: nil
        }
    end
  end

  defp rewrap_entry(entry, width) do
    logical = Map.get(entry, :logical, entry.lines)
    %{entry | lines: Wrap.wrap(logical, width)}
  end

  defp rewrap_in_flight(%{in_flight: in_flight} = _state, width)
       when is_binary(in_flight) and in_flight != "" and byte_size(in_flight) <= @in_flight_cap,
       do: wrapped_assistant(in_flight, width)

  defp rewrap_in_flight(_state, _width), do: nil

  defp wrapped_assistant(text, width) do
    :assistant
    |> Render.entry_lines(text)
    |> Wrap.wrap(width)
  end
end
