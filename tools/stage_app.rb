# Runs INSIDE the tebako runtime ruby (driven by tools/build via the
# deploy-driver shim — never the host ruby). Installs the pinned closure
# into the staging GEM_HOME; brotli arrives pre-fetched and gets a
# per-triplet source build against the SDK header dir.
#
# ENV in:  STAGE_DIR   staging GEM_HOME (host path)
#          GEMPKGS_DIR directory of sha256-verified .gem files
#          CERT_DIR    host dir for CA cert copies (memfs is C-invisible)
require "fileutils"

CERT_DIR = ENV.fetch("CERT_DIR")
FileUtils.mkdir_p(CERT_DIR)
require "rubygems/request"
# OpenSSL reads certificate files at the C level, where the memfs is
# invisible; give rubygems host-side copies of the vendored CA certs
# (same trick as tebako-cli's deploy driver).
module TebakoDeployCerts
  def get_cert_files
    super.map do |src|
      dst = File.join(CERT_DIR, File.basename(src))
      FileUtils.cp(src, dst) unless File.exist?(dst)
      dst
    end
  end
end
Gem::Request.singleton_class.prepend(TebakoDeployCerts)

stage = ENV.fetch("STAGE_DIR")
gempkgs = ENV.fetch("GEMPKGS_DIR")

require "rubygems/gem_runner"
Dir[File.join(gempkgs, "*.gem")].sort.each do |gem_file|
  base = File.basename(gem_file)
  # windows leg: brotli is built and installed by tools/stage_brotli_manual.rb
  # (no ruby shim / no memfs spawn on Windows — rubygems' ExtConfBuilder
  # subprocess cannot run there).
  next if ENV["BROTLI_MANUAL"] && base.start_with?("brotli-")
  argv = ["install", gem_file, "--local", "--ignore-dependencies",
          "--no-document", "--install-dir", stage,
          "--bindir", File.join(stage, "bin")]
  # brotli is built per triplet; --enable-vendor statically links the
  # vendored brotli sources (default: link a system libbrotli — which a
  # target machine may not have; the payload must be self-contained).
  argv += ["--", "--enable-vendor"] if base.start_with?("brotli-")
  puts "   ... @ gem #{argv.join(' ')}"
  begin
    Gem::GemRunner.new.run(argv)
  rescue SystemExit => e
    raise "install of #{gem_file} failed (exit #{e.status})" unless e.status.zero?
  end
  Gem::Specification.reset
end
puts "STAGE-OK"
