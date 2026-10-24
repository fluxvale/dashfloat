defmodule DashFloat.TUI.Theme do
  @moduledoc """
  The role -> `%Style{}` vocabulary of the TUI. Pure data: extending the look
  means adding roles here, never branching in the view. See ADR 0006.
  """

  alias ExRatatui.Style

  @accent %Style{fg: {:rgb, 217, 119, 87}}
  @dim %Style{fg: :dark_gray}

  @styles %{
    accent: @accent,
    dim: @dim,
    dim_italic: %Style{fg: :dark_gray, modifiers: [:italic]},
    user: @dim,
    assistant: %Style{},
    tool: @dim,
    heading1: %Style{fg: {:rgb, 217, 119, 87}, modifiers: [:bold]},
    heading2: %Style{modifiers: [:bold]},
    heading3: %Style{fg: :dark_gray, modifiers: [:bold]},
    emphasis_bold: %Style{modifiers: [:bold]},
    emphasis_italic: %Style{modifiers: [:italic]},
    strikethrough: %Style{modifiers: [:crossed_out]},
    inline_code: %Style{fg: {:indexed, 215}},
    code: %Style{fg: {:indexed, 252}, bg: {:indexed, 234}},
    code_lang: @dim,
    link: %Style{modifiers: [:underlined]},
    quote: @dim,
    rule: @dim,
    hint: @dim,
    status_busy: @accent,
    status_tool: %Style{fg: :light_yellow},
    status_idle: @dim
  }

  @spinner_frames ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  @doc "The style for a role. An unknown role is a programming error."
  @spec style(atom()) :: Style.t()
  def style(role), do: Map.fetch!(@styles, role)

  @doc "The braille activity spinner, one frame per tick."
  @spec spinner_frames() :: [String.t()]
  def spinner_frames, do: @spinner_frames
end
