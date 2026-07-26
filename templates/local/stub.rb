# frozen_string_literal: true

# Compatibility entry for the v0.15.x launcher ABI: those runtimes mount the
# image at their memfs point and unconditionally run /local/stub.rb; forward
# to the real entrypoint. Spec 07 dispatchers ignore this file and load the
# manifest's entrypoint (/bin/fontist) directly.
load File.expand_path("../bin/fontist", __dir__)
