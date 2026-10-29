defmodule DashFloat.ModeTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.Mode

  @classes [:safe, :mutating, :risky]

  describe "gate/2" do
    test "every mode × class cell matches the ADR 0016 §3 matrix" do
      matrix = %{
        {:plan, :safe} => :run,
        {:plan, :mutating} => :propose,
        {:plan, :risky} => :propose,
        {:build, :safe} => :run,
        {:build, :mutating} => :confirm,
        {:build, :risky} => :confirm,
        {:auto, :safe} => :run,
        {:auto, :mutating} => :vet,
        {:auto, :risky} => :vet,
        {:unchained, :safe} => :run,
        {:unchained, :mutating} => :run,
        {:unchained, :risky} => :run
      }

      for mode <- Mode.modes(), class <- @classes do
        assert Mode.gate(mode, class) == matrix[{mode, class}],
               "gate(#{inspect(mode)}, #{inspect(class)})"
      end
    end
  end

  describe "cycle/1" do
    test "cycles all four modes in order, wrapping unchained to plan" do
      assert Mode.cycle(:plan) == :build
      assert Mode.cycle(:build) == :auto
      assert Mode.cycle(:auto) == :unchained
      assert Mode.cycle(:unchained) == :plan
    end
  end

  describe "valid?/1" do
    test "each mode is valid; everything else is not" do
      for mode <- Mode.modes(), do: assert(Mode.valid?(mode))

      refute Mode.valid?(:buidl)
      refute Mode.valid?("build")
      refute Mode.valid?(nil)
    end
  end

  describe "from_string/1" do
    test "parses the exact, case-sensitive names" do
      assert Mode.from_string("plan") == {:ok, :plan}
      assert Mode.from_string("build") == {:ok, :build}
      assert Mode.from_string("auto") == {:ok, :auto}
      assert Mode.from_string("unchained") == {:ok, :unchained}
    end

    test "anything else is :error" do
      assert Mode.from_string("Build") == :error
      assert Mode.from_string("b") == :error
      assert Mode.from_string("") == :error
      assert Mode.from_string("nonsense") == :error
    end
  end

  describe "label/1" do
    test "labels all four modes" do
      assert Mode.label(:plan) == "Plan"
      assert Mode.label(:build) == "Build"
      assert Mode.label(:auto) == "Auto"
      assert Mode.label(:unchained) == "Unchained"
    end
  end

  describe "cycle/1 guard (hostile-review m3)" do
    test "raises ArgumentError on an unknown mode instead of an arithmetic error" do
      assert_raise ArgumentError, "unknown mode: :yolo", fn -> Mode.cycle(:yolo) end
    end
  end
end
