# Runs INSIDE the tebako runtime ruby (the windows leg's driver entry —
# never the host ruby). Builds and installs brotli's native extension
# WITHOUT rubygems' ExtConfBuilder: that builder spawns Gem.ruby as a
# subprocess, and on Windows there is no ruby shim and no memfs spawn
# (tebako-cli deploy.rs + the ruby spawn patch are POSIX-only), so
# `gem install` of a source-native gem cannot work there. Instead:
#
#   extconf  phase: unpack the gem, run its extconf.rb IN-PROCESS (mkmf
#                   only shells out to the C toolchain, never to ruby).
#                   `$0` is pinned to "extconf.rb" — mkmf anchors srcdir
#                   and the Makefile's TARGET on it (a plain `load` with
#                   a foreign $0 yields an empty TARGET).
#   place    phase: after the host ran make, install the built .so the
#                   way rubygems would: gem tree copy, extensions
#                   bookkeeping dir (<platform>/<api>/<full_name>/
#                   gem.build_complete), and the installed-spec stub
#                   (spec.to_ruby — specifications/*.gemspec are ruby,
#                   not yaml).
#
# ENV in:  BROTLI_GEM   sha256-verified brotli .gem file (host path)
#          STAGE_DIR    staging GEM_HOME (host path)
#          BROTLI_BUILD build workspace (host path)
require "fileutils"
require "rubygems/package"

PHASE = ARGV.fetch(0)
GEM_FILE = ENV.fetch("BROTLI_GEM")
STAGE_DIR = ENV.fetch("STAGE_DIR")
BUILD_DIR = ENV.fetch("BROTLI_BUILD")

case PHASE
when "extconf"
  FileUtils.rm_rf(BUILD_DIR)
  FileUtils.mkdir_p(BUILD_DIR)
  Gem::Package.new(GEM_FILE).extract_files(BUILD_DIR)
  ext_dir = File.join(BUILD_DIR, "ext", "brotli")
  Dir.chdir(ext_dir) do
    $0 = "extconf.rb"
    ARGV.replace(["--enable-vendor"])
    load "extconf.rb"
  end
  puts "EXTCONF-OK #{File.join(ext_dir, 'Makefile')}"
when "place"
  spec = Gem::Package.new(GEM_FILE).spec
  version = spec.version.to_s
  soext = RbConfig::CONFIG["DLEXT"]
  ext_dir = File.join(BUILD_DIR, "ext", "brotli")
  built = File.join(ext_dir, "brotli.#{soext}")
  raise "no built extension at #{built}" unless File.file?(built)

  gem_dir = File.join(STAGE_DIR, "gems", "brotli-#{version}")
  # the gem's files as installed (same as a rubygems install layout)
  FileUtils.rm_rf(gem_dir)
  Gem::Package.new(GEM_FILE).extract_files(gem_dir)
  lib_dir = File.join(gem_dir, "lib", "brotli")
  FileUtils.mkdir_p(lib_dir)
  FileUtils.cp(built, File.join(lib_dir, "brotli.#{soext}"))

  # the extensions bookkeeping tree (rubygems' installed layout: the
  # platform segment is Gem::Platform.local, NOT RbConfig's arch)
  ext_book = File.join(STAGE_DIR, "extensions",
                       Gem::Platform.local.to_s, Gem.extension_api_version,
                       "brotli-#{version}")
  FileUtils.mkdir_p(File.join(ext_book, "brotli"))
  FileUtils.cp(built, File.join(ext_book, "brotli", "brotli.#{soext}"))
  File.write(File.join(ext_book, "gem.build_complete"), "")
  mkmf_log = File.join(ext_dir, "mkmf.log")
  FileUtils.cp(mkmf_log, File.join(ext_book, "mkmf.log")) if File.file?(mkmf_log)

  spec_dir = File.join(STAGE_DIR, "specifications")
  FileUtils.mkdir_p(spec_dir)
  File.write(File.join(spec_dir, "brotli-#{version}.gemspec"), spec.to_ruby)
  puts "PLACE-OK #{gem_dir}"
else
  raise "usage: stage_brotli_manual.rb {extconf|place}"
end
