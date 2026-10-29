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

  # The provider→cheap-side-request-model table (ADR 0015 §3): the
  # officially supported presets ship one each — the owner's budget call
  # (cheap tier = low spend by default). A custom OpenAI-compatible provider
  # has no official cheap tier and falls back to the active model.
  @suggest_models %{
    "https://api.z.ai/api/coding/paas/v4" => "glm-5.3-flash",
    "https://api.synthetic.new/openai/v1" => "glm-4.7-flash"
  }

  @doc """
  The provider's default cheap suggestion model (ADR 0015 §3), keyed by
  base URL; nil for custom providers (the caller falls back to the active
  model). The URL is normalized like `Config.Catalog.fetch`'s (a trailing
  slash is convention, not identity), so a preset URL pasted with one
  still resolves.
  """
  @spec suggest_model(String.t()) :: String.t() | nil
  def suggest_model(base_url),
    do: Map.get(@suggest_models, String.trim_trailing(base_url, "/"))

  @doc """
  The shared tri-state → model resolution behind both side-requests (the
  ghost text, ADR 0015 §3, and the session title, #80): `false` reads nil —
  the caller never requests then (the hard stop); a string targets exactly
  that model id; nil is the provider's preset cheap model, falling back to
  the active model for a custom provider.
  """
  @spec side_model(false | String.t() | nil, String.t(), String.t() | nil) ::
          String.t() | nil
  def side_model(false, _base_url, _active_model), do: nil
  def side_model(id, _base_url, _active_model) when is_binary(id), do: id
  def side_model(_default, base_url, active_model), do: suggest_model(base_url) || active_model
end
