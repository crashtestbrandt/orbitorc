# The job suite drives real processes through /bin/sh and is tagged :unix; on Windows it is skipped
# rather than failed. Everything else runs on every platform CI has.
exclude = if match?({:win32, _}, :os.type()), do: [:unix], else: []
ExUnit.start(exclude: exclude)
