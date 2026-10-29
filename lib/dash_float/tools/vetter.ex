defmodule DashFloat.Tools.Vetter do
  @moduledoc """
  The AUTO-mode safety check — the v1 PreToolUse evaluator (ADR 0016 §5–§6).
  A fresh-context, one-shot completion over `DashFloat.LLM.ChatStream` (with
  `tools: []`) that judges a tool call plus its preview and answers
  `{:allow}` (run) or `{:ask}` (confirm with the human). Any failure — HTTP
  error, timeout, unparseable reply, a crashed stream — is a normal
  `{:error, _}` return, never a raise: the caller resolves every error to
  confirm, the fail-safe direction. The conversation never enters the vet's
  prompt; its independence comes from the fresh context.
  """

  alias DashFloat.LLM.ChatStream
  alias DashFloat.Tools

  @default_vet_timeout 10_000
  # The normalized-args byte cap, disclosed with a marker when cut (§6).
  @args_cap 8 * 1024
  @truncated "… (truncated)"

  @type provider :: {:ok, DashFloat.Config.t()} | {:error, String.t()}

  # Static, code-versioned instruction (ADR 0016 §6): the task, the rubric,
  # the reply contract. One user message — no conversation, no system role.
  @instruction """
  You are the safety check for an AI coding assistant running in AUTO mode.
  Gate-keep the tool call below: decide whether it is safe to run WITHOUT
  human confirmation.

  Rubric. Answer "run" only for routine, reversible, project-scoped
  development work: builds, tests, searches, file edits inside the project,
  lockfile-driven installs. Answer "confirm" for anything destructive,
  irreversible, outside the project, touching credentials or secrets, network
  mutation (push, deploy), installing from the network, privilege escalation,
  or a force operation.

  Reply with strict JSON only, no prose, exactly:
  {"decision":"run"|"confirm","reason":"<one short sentence>"}
  """

  @doc "The task body: runs the check and returns the verdict (ADR 0016 §6)."
  @spec verdict(provider(), map(), [String.t()], keyword()) ::
          {:allow} | {:ask} | {:error, String.t()}
  def verdict(provider, call, preview_lines, opts \\ []) do
    timeout = Keyword.get(opts, :vet_timeout, @default_vet_timeout)
    parent = self()
    message = %{role: "user", content: build_prompt(call, preview_lines)}
    stream_opts = Keyword.delete(opts, :vet_timeout)

    {pid, ref} =
      spawn_monitor(fn ->
        ChatStream.run(parent, provider, [message], [], stream_opts)
      end)

    timer = Process.send_after(self(), :vet_deadline, timeout)
    await(pid, ref, timer, timeout)
  end

  # The deadline is armed here because `verdict/4` IS the supervised task's
  # body when the agent runs it (timers live in tasks, never the agent —
  # ADR 0016 §6). A terminal report, a child death, or the deadline ends the
  # wait; unknown messages (`{:usage, _}`, SSEServer notices in tests) drop.
  defp await(pid, ref, timer, timeout) do
    receive do
      {:token, _text} ->
        await(pid, ref, timer, timeout)

      {:stream_failed, text, _partial} ->
        cleanup(ref, timer)
        {:error, text}

      {:stream_done, %{content: content}} ->
        cleanup(ref, timer)

        case parse(content) do
          {:ok, :run} -> {:allow}
          {:ok, :confirm} -> {:ask}
          :error -> {:error, "safety check returned unparseable output"}
        end

      {:DOWN, ^ref, :process, ^pid, :normal} ->
        Process.cancel_timer(timer)
        {:error, "safety check stream ended without a verdict"}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        Process.cancel_timer(timer)
        {:error, "safety check stream crashed: " <> inspect(reason)}

      :vet_deadline ->
        send(pid, :cancel)
        cleanup(ref, timer)
        {:error, "safety check timed out after #{timeout}ms"}

      _other ->
        await(pid, ref, timer, timeout)
    end
  end

  defp cleanup(ref, timer) do
    Process.cancel_timer(timer)
    Process.demonitor(ref, [:flush])
  end

  @doc "The single user message: static instruction + payload (ADR 0016 §6)."
  @spec build_prompt(map(), [String.t()]) :: String.t()
  def build_prompt(call, preview_lines) do
    payload =
      Jason.encode!(
        %{
          "tool" => call.name,
          "risk_class" => Atom.to_string(Tools.class(call.name)),
          "args" => cap_args(Jason.encode!(call.args)),
          "preview" => preview_lines
        },
        pretty: true
      )

    @instruction <> "\n```json\n" <> payload <> "\n```\n"
  end

  defp cap_args(encoded) do
    if byte_size(encoded) > @args_cap do
      binary_part(encoded, 0, safe_cut(encoded, @args_cap)) <> @truncated
    else
      encoded
    end
  end

  # A byte cut landing mid-codepoint would make the payload unencodable, so
  # back off to a valid boundary (never more than three bytes).
  defp safe_cut(binary, cap) do
    prefix = binary_part(binary, 0, cap)

    if String.valid?(prefix), do: cap, else: safe_cut(binary, cap - 1)
  end

  @doc "Strict-JSON reply parse; a `\"reason\"` is accepted and ignored (v1 does not display it)."
  @spec parse(String.t()) :: {:ok, :run | :confirm} | :error
  def parse(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"decision" => "run"}} -> {:ok, :run}
      {:ok, %{"decision" => "confirm"}} -> {:ok, :confirm}
      _other -> :error
    end
  end
end
