defmodule DashFloat.Herdr do
  @moduledoc """
  The Herdr integration (ADR 0024): reports DashFloat's state, the command
  that reopens its session, and its departure to the Herdr multiplexer
  owning this pane — so DashFloat shows in Herdr's sidebar, participates in
  `herdr agent list`/`wait`/notifications, and restores its session after a
  Herdr restart.

  Inert by default: `detect/1` returns a context only inside a Herdr pane
  (`HERDR_ENV=1` plus `HERDR_PANE_ID` and `HERDR_SOCKET_PATH`); outside,
  the context is `nil` and every entry point here is a no-op — no task, no
  connection, no log. Reports are fire-and-forget tasks under
  `DashFloat.TaskSupervisor` (the suggester discipline): bounded, silenced,
  and fail-open absolutely. Seq is the wall clock, forced strictly
  increasing — Herdr ignores stale seqs, which makes out-of-order reports
  harmless.

  Delivery speaks Herdr's socket API directly (newline-delimited JSON over
  `HERDR_SOCKET_PATH`, the documented in-pane alternative to the CLI): the
  CLI invoked from inside a pane silently drops `pane report-agent` on
  Herdr 0.9.5, while the same request over the socket lands (ADR 0024 §4).
  """

  alias DashFloat.TUI.State

  @command_timeout_ms 2_000
  @source "dashfloat"
  @agent_name "dashfloat"
  # Herdr's resume rules: at most 64 args and 8 KiB total; args may carry no
  # apostrophe or control character (ADR 0024 §5).
  @max_resume_args 64
  @max_resume_bytes 8 * 1024

  @enforce_keys [:pane, :socket]
  defstruct [
    :pane,
    :socket,
    :runner,
    :supervisor,
    timeout_ms: @command_timeout_ms,
    seq: 0,
    sig: nil
  ]

  @typedoc "The detected Herdr pane context; `nil` outside Herdr (inert)."
  @type t :: %__MODULE__{
          pane: String.t(),
          socket: Path.t(),
          runner: (request() -> term()) | nil,
          supervisor: module() | nil,
          timeout_ms: pos_integer(),
          seq: integer(),
          sig: term()
        }

  @type agent_state :: :idle | :working | :blocked

  @typedoc "One socket-API request: method plus params, as the runner seam sees it."
  @type request :: %{method: String.t(), params: map()}

  @typedoc """
  What the TUI derives per event for `report/2` — the phase machine's phase,
  the two non-phase prompts (a pending confirm's tool name, the armed exit
  guard), the startup setup flag, and the resume identity (session id plus
  the provider selection the boot does not restore on its own).
  """
  @type snapshot :: %{
          phase: State.phase(),
          confirm: String.t() | nil,
          exit_prompt: boolean(),
          setup: boolean(),
          session_id: String.t() | nil,
          profile: String.t() | nil,
          model: String.t() | nil
        }

  @doc """
  Detects Herdr from the boot environment: a context only when `HERDR_ENV`
  is `1` and both `HERDR_PANE_ID` and `HERDR_SOCKET_PATH` are non-empty.
  """
  @spec detect(map()) :: t() | nil
  def detect(env) when is_map(env) do
    with "1" <- env["HERDR_ENV"],
         pane when is_binary(pane) and pane != "" <- env["HERDR_PANE_ID"],
         socket when is_binary(socket) and socket != "" <- env["HERDR_SOCKET_PATH"] do
      %__MODULE__{pane: pane, socket: socket}
    else
      _not_herdr -> nil
    end
  end

  @doc """
  The Herdr state for a snapshot (ADR 0024 §2): a pending confirm, the armed
  exit guard, and the startup setup prompt all need the user — `blocked`,
  with a message naming the decision; a busy agent is `working`; the idle
  composer is `idle`.
  """
  @spec state_for(snapshot()) :: {agent_state(), String.t() | nil}
  def state_for(snapshot) do
    cond do
      snapshot.confirm != nil -> {:blocked, "approve " <> snapshot.confirm}
      snapshot.exit_prompt -> {:blocked, "exit? press Ctrl+C again"}
      snapshot.setup -> {:blocked, "first-run setup: choose a provider"}
      true -> {phase_state(snapshot.phase), nil}
    end
  end

  @doc "The bare phase map (ADR 0024 §2): idle composer, busy agent, pending decision."
  @spec phase_state(State.phase()) :: agent_state()
  def phase_state(:idle), do: :idle
  def phase_state(:streaming), do: :working
  def phase_state(:executing_tool), do: :working
  def phase_state(:checking), do: :working
  def phase_state(:confirming), do: :blocked

  @doc """
  The next seq (ADR 0024 §3): the wall clock in ms, forced strictly
  increasing against the last sent — same-millisecond bursts still order,
  and the value survives restarts, which Herdr requires.
  """
  @spec next_seq(integer(), integer()) :: integer()
  def next_seq(now_ms, last) when is_integer(now_ms) and is_integer(last),
    do: max(now_ms, last + 1)

  @doc """
  The command tail that reopens the session (ADR 0024 §5): the plain PATH
  command name, the resume id, then only what `--resume` alone does not
  restore — the profile/model selection. Values Herdr would reject
  (apostrophe, control character) are dropped rather than losing the whole
  report; the UUIDv7 id is always clean.
  """
  @spec resume_argv(String.t(), String.t() | nil, String.t() | nil) :: [String.t()] | nil
  def resume_argv(id, profile, model) do
    extras =
      [profile_arg(profile), model_arg(model)]
      |> Enum.reject(&is_nil/1)
      |> List.flatten()

    argv = ["dashfloat", "--resume", id] ++ extras
    bytes = byte_size(Enum.join(argv, " "))

    if length(argv) <= @max_resume_args and bytes <= @max_resume_bytes, do: argv
  end

  defp profile_arg(nil), do: nil
  defp profile_arg(profile), do: if(clean?(profile), do: ["--profile", profile])

  defp model_arg(nil), do: nil
  defp model_arg(model), do: if(clean?(model), do: ["--model", model])

  # Herdr's documented rule: no apostrophe, no control character (ADR 0024
  # §5). Everything else — model ids, profile names — is fair game.
  defp clean?(value) when is_binary(value) do
    not String.contains?(value, ["'" | control_chars()])
  end

  defp clean?(_other), do: false

  defp control_chars, do: for(code <- Enum.to_list(0..0x1F) ++ [0x7F], do: <<code::utf8>>)

  @doc """
  Reports the current state, following with the resume command whenever the
  snapshot names a session (ADR 0024 §4–5). Deduped: nothing fires while
  the signature — state, message, session, provider selection — is
  unchanged, so token spam never reaches Herdr. Fire-and-forget; returns
  the context with its seq and signature advanced.

  A named session sends TWO requests: the state report (which must hold the
  pane first), then `pane.report_agent_session` carrying the resume argv —
  the exact pair Herdr's seq guard orders.
  """
  @spec report(t() | nil, snapshot()) :: t() | nil
  def report(nil, _snapshot), do: nil

  def report(%__MODULE__{} = herdr, snapshot) do
    {state, message} = state_for(snapshot)
    sig = {state, message, snapshot.session_id, snapshot.profile, snapshot.model}

    if sig == herdr.sig do
      herdr
    else
      seq = next_seq(System.system_time(:millisecond), herdr.seq)

      requests = [
        state_request(herdr, seq, state, message) | session_requests(herdr, seq, snapshot)
      ]

      case fire(herdr, requests) do
        {:ok, sent} ->
          %{herdr | seq: max(seq, sent), sig: sig}

        # A spawn failure (a dead supervisor) leaves the signature
        # UNCOMMITTED: the next event's report re-fires the same state — a
        # transient failure is retried, not swallowed (ADR 0024 §4).
        :error ->
          herdr
      end
    end
  end

  defp state_request(herdr, seq, state, message) do
    params =
      maybe_put(
        %{
          pane_id: herdr.pane,
          source: @source,
          agent: @agent_name,
          state: Atom.to_string(state),
          seq: seq
        },
        :message,
        message
      )

    %{method: "pane.report_agent", params: params}
  end

  # The session reference rides its own request behind the state report:
  # Herdr keeps the resume command only while the same source holds the
  # pane, so the state report goes first and the session follows with the
  # next seq.
  defp session_requests(_herdr, _seq, %{session_id: nil}), do: []

  defp session_requests(herdr, seq, %{session_id: id, profile: profile, model: model}) do
    case resume_argv(id, profile, model) do
      nil ->
        []

      argv ->
        params = %{
          pane_id: herdr.pane,
          source: @source,
          agent: @agent_name,
          agent_session_id: id,
          seq: seq + 1,
          resume_argv: argv
        }

        [%{method: "pane.report_agent_session", params: params}]
    end
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value) when is_binary(value), do: Map.put(params, key, value)

  @doc """
  Releases the pane on the real quit path (ADR 0024 §6) — the one
  synchronous-bounded call: it runs in the TUI's `terminate/2`, user-paced,
  and must land before the VM stops. Herdr's idle-prompt self-clear is the
  safety net, not the mechanism.
  """
  @spec release(t() | nil) :: :ok
  def release(nil), do: :ok

  def release(%__MODULE__{} = herdr) do
    seq = next_seq(System.system_time(:millisecond), herdr.seq)

    params = %{pane_id: herdr.pane, source: @source, agent: @agent_name, seq: seq}

    _released = run_now(herdr, [%{method: "pane.release_agent", params: params}])
    :ok
  end

  ## Delivery (ADR 0024 §4): supervised, bounded, silenced, fail-open

  # The test seam first: an injected runner hears each request inline; the
  # real path is one temporary task per report whose outcome nobody reads.
  # Returns the last seq consumed by the request list.
  defp fire(%__MODULE__{runner: runner, seq: last} = _herdr, requests)
       when is_function(runner, 1) do
    seq = Enum.reduce(requests, last, &max(&2, &1.params.seq))
    Enum.each(requests, runner)
    {:ok, seq}
  end

  defp fire(%__MODULE__{seq: last, supervisor: sup} = herdr, requests) do
    seq = Enum.reduce(requests, last, &max(&2, &1.params.seq))

    result =
      try do
        Task.Supervisor.start_child(sup || DashFloat.TaskSupervisor, fn ->
          run_now(herdr, requests)
        end)
      catch
        # A dead supervisor EXITS the start call — the report is fail-open
        # absolutely (the title/suggest rule), and the caller hears :error
        # so the signature stays uncommitted for a retry.
        :exit, _reason -> :error
      end

    case result do
      {:ok, _pid} -> {:ok, seq}
      _no_task -> :error
    end
  end

  # Bounded: each request gets `timeout_ms` to connect, send, and hear one
  # reply line, on its own connection — a hung server never accumulates.
  # Silenced: nothing is logged, nothing read beyond the reply line, and
  # every failure is an error tuple — the task is fire-and-forget and
  # unmonitored, so even a crash changes nothing for the caller.
  defp run_now(%__MODULE__{runner: runner} = herdr, requests) when is_function(runner, 1) do
    Enum.each(requests, runner)
    herdr
  end

  defp run_now(%__MODULE__{} = herdr, requests) do
    Enum.each(requests, &send_request(herdr, &1))
    :ok
  end

  defp send_request(%__MODULE__{} = herdr, request) do
    line =
      Jason.encode_to_iodata!(%{id: "dashfloat", method: request.method, params: request.params})

    case :gen_tcp.connect(
           {:local, herdr.socket},
           0,
           [:binary, active: false, packet: :line],
           herdr.timeout_ms
         ) do
      {:ok, sock} ->
        # Outcomes are unread by design (fail-open); the socket closes on
        # every path that opened one — ownership stays explicit.
        _sent = :gen_tcp.send(sock, [line, ~c"\n"])
        _reply = :gen_tcp.recv(sock, 0, herdr.timeout_ms)
        :gen_tcp.close(sock)
        :ok

      _connect_failed ->
        :ok
    end
  end
end
