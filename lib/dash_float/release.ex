defmodule DashFloat.Release do
  @moduledoc false

  # ERTS in the Linux build image is compiled with SCTP support, so at VM init
  # it dlopens libsctp.so.1 and prints an `=ESOCK WARNING` block to stdout when
  # the user's machine lacks the library. Bundling the genuine library inside
  # the release (and putting its directory on LD_LIBRARY_PATH in
  # rel/env.sh.eex) makes that dlopen succeed. There is no runtime switch that
  # suppresses the warning. See ADR 0010.
  @fallback_sources [
    "/usr/lib/x86_64-linux-gnu/libsctp.so.1",
    "/usr/lib/aarch64-linux-gnu/libsctp.so.1",
    "/usr/lib64/libsctp.so.1",
    "/usr/lib/libsctp.so.1"
  ]

  @license Path.expand("../../rel/sctp-COPYING", __DIR__)

  @doc false
  @spec bundle_sctp(Mix.Release.t(), String.t() | nil) :: Mix.Release.t()
  def bundle_sctp(release, source \\ nil) do
    src =
      source || System.get_env("DASHFLOAT_LIBSCTP") ||
        Enum.find_value(@fallback_sources, fn path -> File.exists?(path) && path end)

    dir = Path.join(release.path, "lib/sctp")
    # A rebuild that no longer bundles must not leave the previous library
    # behind: env.sh exports the directory whenever it exists, so a stale copy
    # would keep being loaded.
    File.rm_rf(dir)

    if src && File.exists?(src) do
      File.mkdir_p!(dir)
      File.cp!(src, Path.join(dir, "libsctp.so.1"))
      # LGPL-2.1+: the licence travels with the redistributed library.
      File.cp!(@license, Path.join(dir, "COPYING"))
    end

    release
  end
end
