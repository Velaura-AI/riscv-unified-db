# Run via: ./bin/mise exec -- bundle exec ruby tools/ruby-gems/udb-gen/test/test_single_idl_roundtrip.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "pathname"
require "udb/cfg_arch"

class SingleIdlRoundTrip < Minitest::Test
  def test_emitted_isa_typechecks_as_overlay_globals
    Dir.mktmpdir do |dir|
      dir = Pathname.new(dir)
      # 1. Emit the single-idl for rv64 into an overlay's isa/globals.isa.
      overlay = dir / "overlay"
      FileUtils.mkdir_p(overlay / "isa")
      system("./bin/generate", "single-idl", "-c", "rv64", "-o", (overlay / "isa" / "globals.isa").to_s) \
        or flunk "generator failed"

      # 2. A config that uses our emitted file as its globals via arch_overlay (absolute path).
      cfg = dir / "rt.yaml"
      cfg.write(<<~YAML)
        $schema: config_schema.json#
        kind: architecture configuration
        type: partially configured
        name: rt
        description: round-trip config using the emitted single-idl as overlay globals
        params:
          MXLEN: 64
        mandatory_extensions:
          - name: "I"
            version: ">= 0"
          - name: "Sm"
            version: ">= 0"
        arch_overlay: #{overlay}
      YAML

      # 3. Resolve + type-check; must not raise.
      ca = Udb::Resolver.new.cfg_arch_for(cfg)
      ca.type_check(show_progress: false)
      assert ca.global_ast.functions.size > 0
    end
  end
end
