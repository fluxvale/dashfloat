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

  @doc false
  @spec bundle_sctp(Mix.Release.t(), String.t() | nil) :: Mix.Release.t()
  def bundle_sctp(release, source \\ nil) do
    src =
      source || System.get_env("DASHFLOAT_LIBSCTP") ||
        Enum.find_value(@fallback_sources, fn path -> File.exists?(path) && path end)

    if src && File.exists?(src) do
      dir = Path.join(release.path, "lib/sctp")
      File.mkdir_p!(dir)
      bundled = Path.join(dir, "libsctp.so.1")
      File.cp!(src, bundled)
    end

    release
  end
end
