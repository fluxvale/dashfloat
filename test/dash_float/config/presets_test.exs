defmodule DashFloat.Config.PresetsTest do
  @moduledoc false
  # Issue #111: the seeded per-model windows for the standard presets — the
  # table that makes a stock config (fresh wizard, no `context` on any
  # entry) work out of the box — and the documented default with its
  # visible note. Numbers are the providers' real ones: Z.AI's officially
  # documented 1M-token windows (docs.z.ai, GLM-5.3/GLM-5.2 pages),
  # Synthetic's live catalog `context_length` values (probed 2026-10-30).
  use ExUnit.Case, async: true

  alias DashFloat.Config.Presets

  describe "context_window/2 — the seeded windows (issue #111's Done-when)" do
    test "the Z.AI coding plan's current GLM generation: the documented 1M windows" do
      zai = "https://api.z.ai/api/coding/paas/v4"

      for model <- ["glm-5.2", "glm-5.3", "glm-5.3-flash", "glm-5.3-flashx"] do
        assert Presets.context_window(zai, model) == 1_048_576,
               "the seed lost #{model}"
      end
    end

    test "Synthetic's first-party catalog: the live context_length values" do
      synthetic = "https://api.synthetic.new/openai/v1"

      for model <- [
            "infinite:small:vision",
            "syn:large:text",
            "syn:large:vision",
            "syn:small:vision"
          ] do
        assert Presets.context_window(synthetic, model) == 524_288
      end

      assert Presets.context_window(synthetic, "syn:small:text") == 196_608
    end

    test "a trailing slash on the base URL is convention, not identity" do
      assert Presets.context_window("https://api.z.ai/api/coding/paas/v4/", "glm-5.3") ==
               1_048_576
    end

    test "nil for an unseeded provider or model — never a guess" do
      assert Presets.context_window("https://custom.example/v1", "glm-5.3") == nil
      assert Presets.context_window("https://api.z.ai/api/coding/paas/v4", "glm-4.7") == nil
      assert Presets.context_window("https://api.z.ai/api/coding/paas/v4", "mystery") == nil
    end
  end

  test "default_window/0 — the documented fallback every consumer notes visibly" do
    assert Presets.default_window() == 131_072
  end
end
