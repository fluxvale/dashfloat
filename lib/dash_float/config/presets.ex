defmodule DashFloat.Config.Presets do
  @moduledoc """
  The first-class onboarding provider presets
  ([ADR 0009](../../docs/decisions/0009-config-v3-persona-profiles.md)).

  Two presets plus the custom-OpenAI-compatible path the wizard offers
  alongside them. Verified endpoints only — the Synthetic base URL was
  confirmed against dev.synthetic.new's API Overview ("OpenAI-compatible
  endpoints — Base Url: https://api.synthetic.new/openai/v1") and
  Octofriend's provider table; both want an API-key paste, no OAuth.
  Code constants: nothing configurable, nothing secret.
  """

  @type preset :: %{id: atom(), name: String.t(), label: String.t(), base_url: String.t()}

  @presets [
    %{
      id: :zai,
      name: "Z.AI Coding Plan",
      label: "zai",
      base_url: "https://api.z.ai/api/coding/paas/v4"
    },
    %{
      id: :synthetic,
      name: "Synthetic",
      label: "synthetic",
      base_url: "https://api.synthetic.new/openai/v1"
    }
  ]

  @doc "The wizard's preset list, in display order."
  @spec all() :: [preset()]
  def all, do: @presets
end
